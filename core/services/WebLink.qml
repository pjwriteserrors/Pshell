pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The browser as part of the shell (plugin `browser-link`, docs/browser.md).
// The Pshell extension (dotfiles/floorp/pshell) reports through
// scripts/browser_host.py, which the browser starts and which connects to the
// socket here: what is open (tabs, windows, groups, containers, what plays,
// what uses camera or microphone), clicks in its Pshell menu, links it hands
// over and what its pages ask for. Nothing listens on the network.
//
// The other way the shell colours the browser live (browser.theme, from
// Theme's roles), writes the shell's measures for pshell.css
// (~/.local/state/pshell/floorp/pshell-vars.css: radius, font, gaps, motion)
// and asks the browser to do things: `command()`, or the helpers below it.
//
// What the menu offers and does is WebMenu's, what the pages get (new tab
// page, identities in forms, links, blocked sites) is WebPage's.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-link")
	// WebMenu and WebPage read WebLink too: touching them while this singleton
	// is still being built makes Qt give up on creating them (silently, for
	// good), so they are read only once it stands
	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	// the hosts that are connected: { source: { link, browser, version } }
	property var links: ({})
	readonly property bool connected: Object.keys(root.links).length > 0
	readonly property string browserName: {
		const sources = Object.keys(root.links);
		return sources.length > 0 ? String(root.links[sources[sources.length - 1]].browser || "") : "";
	}

	// { key: tab }, a tab:
	// { key, source, id, windowId, index, title, url, host, favicon (data: url or ""),
	//   active, audible, muted, pinned, hidden (another Floorp workspace), discarded,
	//   loading, lastAccessed, group: { id, title, color, collapsed } | null,
	//   container: { name, color, icon } | null,
	//   sharing: { camera, microphone, screen ("" or what is shared) } }
	property var table: ({})
	// [{ key, source, id, focused, title }]
	property var windows: []

	// in the browser's order: window by window, tab by tab
	readonly property var tabs: Object.values(root.table).sort((a, b) => a.windowId - b.windowId || a.index - b.index)
	readonly property var focusedWindow: root.windows.find(window => window.focused) ?? root.windows[0] ?? null
	// the tab in front of the window last used
	readonly property var activeTab: {
		const window = root.focusedWindow;
		return root.tabs.find(tab => tab.active && (!window || (tab.source === window.source && tab.windowId === window.id))) ?? null;
	}
	readonly property var audibleTabs: root.tabs.filter(tab => tab.audible)
	readonly property var sharingTabs: root.tabs.filter(tab => tab.sharing && (tab.sharing.camera || tab.sharing.microphone || tab.sharing.screen))
	// most recently used first, for the launcher and Alt+Tab
	readonly property var recentTabs: root.tabs.slice().sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))

	// a click in the browser's Pshell menu (WebMenu runs it) and anything else
	// the extension tells (WebPage takes those)
	signal menuClicked(string action, var info)
	signal eventReceived(var event)
	// the tabs changed (also on every update of one)
	signal tabsUpdated

	// commands on their way: { rid: { callback, at } }
	property var pending: ({})
	property int nextRid: 1

	function tabsOf(source) {
		return root.tabs.filter(tab => tab.source === source);
	}

	function tab(key) {
		return root.table[key] ?? null;
	}

	// ── asking the browser ──────────────────────────────────────────────────
	// callback(ok, data | error); goes to `source` or to the browser last heard of
	function command(cmd, args, callback, source) {
		const sources = Object.keys(root.links);
		const target = source && root.links[source] ? source : sources[sources.length - 1];
		if (!target) {
			if (callback) callback(false, "no browser connected");
			return false;
		}
		const rid = `s${root.nextRid++}`;
		if (callback) root.pending = Object.assign({}, root.pending, { [rid]: { callback: callback, at: Date.now() } });
		root.write(target, Object.assign({}, args || {}, { type: "cmd", cmd: cmd, rid: rid }));
		return true;
	}

	// the tab to the front, and its window in niri
	function activate(tab, callback) {
		if (!tab) return;
		root.command("activate", { tabId: tab.id }, (ok, data) => {
			if (ok) root.focusBrowserWindow(String(data?.windowTitle || ""), String(tab.title || ""));
			if (callback) callback(ok, data);
		}, tab.source);
	}

	// niri knows the window by its title, which is the page's title
	function focusBrowserWindow(windowTitle, tabTitle) {
		const browsers = Niri.windows.filter(window => /floorp|firefox|librewolf|zen|waterfox/i.test(String(window.app_id || "")));
		const exact = browsers.find(window => windowTitle !== "" && String(window.title || "") === windowTitle);
		const close = browsers.find(window => tabTitle !== "" && String(window.title || "").startsWith(tabTitle));
		const found = exact ?? close ?? (browsers.length === 1 ? browsers[0] : null);
		if (found) Niri.focusWindow(found.id);
	}

	function close(tab) {
		if (tab) root.command("close", { tabId: tab.id }, null, tab.source);
	}

	function mute(tab, muted) {
		if (tab) root.command("mute", { tabId: tab.id, muted: muted }, null, tab.source);
	}

	function open(url, callback) {
		if (!root.command("open", { url: String(url) }, (ok, data) => {
			if (ok) root.focusBrowserWindow("", "");
			if (callback) callback(ok, data);
		})) Browser.open(url);
	}

	// bookmarks and history: callback({ bookmarks, history })
	function search(query, limit, callback) {
		root.command("search", { query: String(query), limit: limit || 12 }, (ok, data) => callback(ok ? data : { bookmarks: [], history: [] }));
	}

	// the page in front (or tab) as a picture file: callback(ok, { path, title, url })
	function capture(full, callback, tab) {
		root.command("capture", { full: !!full, tabId: tab ? tab.id : -1 }, callback, tab ? tab.source : undefined);
	}

	// the readable text of the page in front (or tab): callback(ok, { title, url, text })
	function pageText(callback, tab) {
		root.command("text", { tabId: tab ? tab.id : -1 }, callback, tab ? tab.source : undefined);
	}

	// everything that plays stops; callback(ok, { tabs }) – hand the tabs to resumeMedia
	function pauseMedia(callback) {
		root.command("pauseMedia", {}, callback);
	}

	function resumeMedia(tabIds) {
		root.command("resumeMedia", { tabs: tabIds || [] }, null);
	}

	// an identity (fields as content/page.js knows them) into the sign-up form of a tab
	function fill(tab, identity, callback) {
		if (tab) root.command("fill", { tabId: tab.id, identity: identity }, callback, tab.source);
	}

	// ── what the browser says ───────────────────────────────────────────────
	function write(source, message) {
		const entry = root.links[source];
		if (!entry) return;
		entry.link.write(JSON.stringify(message) + "\n");
		entry.link.flush();
	}

	function broadcast(message) {
		for (const source of Object.keys(root.links)) root.write(source, message);
	}

	function receive(link, line) {
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!message) return;
		if (message.type === "hello") {
			link.source = String(message.source || "");
			root.links = Object.assign({}, root.links, { [link.source]: { link: link, browser: "", version: "" } });
			return;
		}
		const source = link.source;
		if (source === "" || !root.links[source]) return;
		switch (message.type) {
		case "ready":
			root.links = Object.assign({}, root.links, { [source]: { link: link, browser: String(message.browser || ""), version: String(message.version || "") } });
			root.write(source, { type: "config", config: root.config() });
			root.write(source, { type: "theme", theme: root.theme() });
			if (WebPage.newtabData) root.write(source, { type: "newtab", data: WebPage.newtabData });
			return;
		case "tabs": {
			const next = {};
			for (const key of Object.keys(root.table)) if (root.table[key].source !== source) next[key] = root.table[key];
			for (const tab of message.tabs || []) next[`${source}/${tab.id}`] = Object.assign({}, tab, { key: `${source}/${tab.id}`, source: source });
			root.table = next;
			root.windows = root.windows.filter(window => window.source !== source)
				.concat((message.windows || []).map(window => Object.assign({}, window, { key: `${source}/${window.id}`, source: source })));
			root.tabsUpdated();
			return;
		}
		case "tab":
			if (!message.tab) return;
			root.table = Object.assign({}, root.table, { [`${source}/${message.tab.id}`]: Object.assign({}, message.tab, { key: `${source}/${message.tab.id}`, source: source }) });
			root.tabsUpdated();
			return;
		case "tabGone": {
			const next = Object.assign({}, root.table);
			delete next[`${source}/${message.id}`];
			root.table = next;
			root.tabsUpdated();
			return;
		}
		case "menu":
			root.menuClicked(String(message.action || ""), Object.assign({}, message.info || {}, { source: source }));
			WebMenu.run(String(message.action || ""), Object.assign({}, message.info || {}, { source: source }));
			return;
		case "event":
			root.eventReceived(Object.assign({}, message, { source: source }));
			WebPage.event(Object.assign({}, message, { source: source }));
			return;
		case "ask": {
			const rid = message.rid;
			WebPage.ask(String(message.what || ""), message.args || {}, (ok, data) => root.write(source, { type: "answer", rid: rid, ok: ok !== false, data: data ?? null }));
			return;
		}
		case "answer": {
			const waiting = root.pending[message.rid];
			if (!waiting) return;
			const next = Object.assign({}, root.pending);
			delete next[message.rid];
			root.pending = next;
			try {
				waiting.callback(message.ok !== false, message.ok !== false ? message.data : message.error);
			} catch (error) {
				console.warn("WebLink: answer:", error);
			}
			return;
		}
		}
	}

	function dropped(link) {
		const source = link.source;
		if (!source || !root.links[source]) return;
		const next = Object.assign({}, root.links);
		delete next[source];
		root.links = next;
		const tabs = {};
		for (const key of Object.keys(root.table)) if (root.table[key].source !== source) tabs[key] = root.table[key];
		root.table = tabs;
		root.windows = root.windows.filter(window => window.source !== source);
		root.tabsUpdated();
	}

	// ── what the browser gets ───────────────────────────────────────────────
	function config() {
		return {
			menu: WebMenu.entries,
			intercept: WebPage.intercept,
			forms: WebPage.forms,
			newtab: WebPage.newtab,
			blocked: WebPage.blocked,
			rail: WebPage.rail,
			tabs: WebPage.tabs
		};
	}

	// a colour as CSS (Qt writes alpha first)
	function css(color) {
		const c = Qt.color(color);
		const byte = value => Math.round(value * 255);
		return c.a >= 0.999 ? `rgb(${byte(c.r)}, ${byte(c.g)}, ${byte(c.b)})` : `rgba(${byte(c.r)}, ${byte(c.g)}, ${byte(c.b)}, ${Math.round(c.a * 1000) / 1000})`;
	}

	// the roles go through theme keys pshell.css reads back (docs/browser.md)
	function theme() {
		const bg = root.css(Theme.bg);
		const fg = root.css(Theme.fg);
		const scheme = Theme.dark ? "dark" : "light";
		return {
			colors: {
				frame: bg,
				frame_inactive: bg,
				toolbar: bg,
				popup: bg,
				sidebar: bg,
				ntp_background: bg,
				tab_background_text: fg,
				toolbar_text: fg,
				popup_text: fg,
				sidebar_text: fg,
				ntp_text: fg,
				icons: fg,
				tab_text: fg,
				bookmark_text: fg,
				icons_attention: root.css(Theme.primary),
				tab_line: root.css(Theme.secondary),
				toolbar_bottom_separator: root.css(Theme.tertiary),
				tab_background_separator: root.css(Theme.danger),
				toolbar_vertical_separator: root.css(Theme.warning),
				toolbar_top_separator: root.css(Theme.success),
				popup_highlight: root.css(Theme.primarySoft),
				popup_highlight_text: root.css(Theme.onPrimary),
				tab_loading: root.css(Theme.primary),
				tab_selected: root.css(Theme.layer2),
				button_background_hover: root.css(Theme.layer2),
				button_background_active: root.css(Theme.layer3),
				toolbar_field: root.css(Theme.layer1),
				toolbar_field_text: fg,
				toolbar_field_focus: root.css(Theme.layer2),
				toolbar_field_text_focus: fg,
				toolbar_field_border: "transparent",
				toolbar_field_border_focus: root.css(Theme.primary),
				toolbar_field_highlight: root.css(Theme.primary),
				toolbar_field_highlight_text: root.css(Theme.onPrimary),
				popup_border: root.css(Theme.outline),
				sidebar_border: "transparent",
				sidebar_highlight: root.css(Theme.primarySoft),
				sidebar_highlight_text: fg
			},
			properties: { color_scheme: scheme, content_color_scheme: scheme }
		};
	}

	// the shell's measures as CSS custom properties for pshell.css
	function bezier(points) {
		return `cubic-bezier(${points[0]}, ${points[1]}, ${points[2]}, ${points[3]})`;
	}

	readonly property string varsText: [
		"/* Written by the shell (core/services/WebLink.qml): its measures for pshell.css. */",
		":root {",
		`\t--pshell-radius-window: ${Theme.windowRadius}px;`,
		`\t--pshell-radius-small: ${Theme.radius.small}px;`,
		`\t--pshell-radius-medium: ${Theme.radius.medium}px;`,
		`\t--pshell-radius-large: ${Theme.radius.large}px;`,
		`\t--pshell-radius-huge: ${Theme.radius.huge}px;`,
		`\t--pshell-font: "${Theme.fontFamily}";`,
		`\t--pshell-font-mono: "${Theme.monoFamily}";`,
		`\t--pshell-font-size: ${Theme.size.body}px;`,
		`\t--pshell-gap-xs: ${Theme.gap.xs}px;`,
		`\t--pshell-gap-sm: ${Theme.gap.sm}px;`,
		`\t--pshell-gap-md: ${Theme.gap.md}px;`,
		`\t--pshell-gap-lg: ${Theme.gap.lg}px;`,
		`\t--pshell-gap-xl: ${Theme.gap.xl}px;`,
		`\t--pshell-bar-height: ${Theme.barHeight}px;`,
		`\t--pshell-bar-opacity: ${Theme.barOpacity};`,
		`\t--pshell-micro: ${Motion.micro}ms;`,
		`\t--pshell-short: ${Motion.short}ms;`,
		`\t--pshell-medium: ${Motion.medium}ms;`,
		`\t--pshell-long: ${Motion.long}ms;`,
		`\t--pshell-extra-long: ${Motion.extraLong}ms;`,
		`\t--pshell-spatial: ${root.bezier(Motion.spatial)};`,
		`\t--pshell-spatial-fast: ${root.bezier(Motion.spatialFast)};`,
		`\t--pshell-standard: ${root.bezier(Motion.standard)};`,
		`\t--pshell-accel: ${root.bezier(Motion.accel)};`,
		`\t--pshell-decel: ${root.bezier(Motion.decel)};`,
		`\t--pshell-dark: ${Theme.dark ? 1 : 0};`,
		"}",
		""
	].join("\n")

	readonly property string themeText: root.enabled ? JSON.stringify(root.theme()) : ""
	onThemeTextChanged: themeDue.restart()
	onVarsTextChanged: if (root.enabled) varsDue.restart()
	onEnabledChanged: if (root.enabled) varsDue.restart()

	// what the menu and the pages need changed: tell every browser
	readonly property string configText: root.built && root.enabled ? JSON.stringify(root.config()) : ""
	onConfigTextChanged: configDue.restart()

	Connections {
		target: root.built ? WebPage : null

		function onNewtabDataChanged() {
			if (root.enabled && WebPage.newtabData) root.broadcast({ type: "newtab", data: WebPage.newtabData });
		}
	}

	Timer {
		id: themeDue

		interval: 120
		onTriggered: if (root.connected) root.broadcast({ type: "theme", theme: root.theme() })
	}

	Timer {
		id: configDue

		interval: 120
		onTriggered: if (root.connected) root.broadcast({ type: "config", config: root.config() })
	}

	Timer {
		id: varsDue

		interval: 400
		onTriggered: varsFolder.running = true
	}

	Process {
		id: varsFolder

		command: ["mkdir", "-p", `${Paths.state}/floorp`]
		onExited: {
			if (String(varsFile.text()) !== root.varsText) varsFile.setText(root.varsText);
		}
	}

	FileView {
		id: varsFile

		path: `${Paths.state}/floorp/pshell-vars.css`
		blockLoading: true
		printErrors: false
	}

	// commands the browser never answered (it went away mid-way)
	Timer {
		interval: 5000
		repeat: true
		running: Object.keys(root.pending).length > 0
		onTriggered: {
			const now = Date.now();
			const next = {};
			for (const rid of Object.keys(root.pending)) {
				const waiting = root.pending[rid];
				if (now - waiting.at < 30000) next[rid] = waiting;
				else
					try {
						waiting.callback(false, "the browser did not answer");
					} catch (error) {}
			}
			root.pending = next;
		}
	}

	// the socket's folder first
	Process {
		id: folder

		running: root.enabled
		command: ["mkdir", "-p", Paths.runtime]
		onExited: server.active = Qt.binding(() => root.enabled)
	}

	SocketServer {
		id: server

		path: `${Paths.runtime}/browser.sock`
		handler: Socket {
			id: link

			property string source: ""

			parser: SplitParser {
				onRead: line => root.receive(link, line)
			}
			onConnectedChanged: if (!link.connected) root.dropped(link)
		}
	}
}
