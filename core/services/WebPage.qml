pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// What the shell gives the browser's pages (docs/browser.md): the new tab
// page's data (plugin `browser-newtab`), identities in sign-up forms
// (`browser-forms`), mailto: and calendar links (`browser-mail`) and the
// sites kept away during focus time (`browser-focus`). WebLink sends the
// switches with the config and newtabData whenever it changes, and hands
// over what the extension asks (`ask`) and tells (`event`).
//
// Nothing happens on its own: a calendar link is only offered for import,
// sites are only kept away once the offer at the start of focus time was
// taken. Nothing of a private window is kept (no draft, no file).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-link")

	// what content/page.js intercepts
	readonly property var intercept: ({
		mailto: root.enabled && Plugins.on("browser-mail") && Mail.enabled,
		calendar: root.enabled && Plugins.on("browser-mail") && MsCalendar.enabled && MsCalendar.signedIn
	})
	// the identity button in sign-up forms
	readonly property bool forms: root.enabled && Plugins.on("browser-forms") && Identities.enabled
	// the shell's day on the extension's new tab page (the page is the extension's either way)
	readonly property bool newtab: root.enabled && Plugins.on("browser-newtab")
	// [{ host, until (ms, 0 = until focus time ends) }]
	readonly property var blocked: root.enabled && Plugins.on("browser-focus") && root.blocking
		? root.focusSites.filter(host => !root.lifted.includes(host)).map(host => ({ host: host, until: 0 }))
		: []
	// newtab.js: { palette: { bg, fg, primary, dark }, radius, font, wallpaper,
	//              weather, todos, events, notes }
	property var newtabData: null

	// ── focus time ───────────────────────────────────────────────────────
	readonly property var defaultFocusSites: ["youtube.com", "reddit.com", "x.com", "twitter.com", "instagram.com", "tiktok.com", "facebook.com"]
	// the sites offered to keep away (~/.local/state/pshell/browser-focus.json)
	property var focusSites: root.defaultFocusSites
	// qtrack runs or do-not-disturb was switched on by hand
	readonly property bool focusing: (Plugins.on("qtrack") && QtrackTimer.tracking && !QtrackTimer.paused) || Notifs.dndManual
	// the offer was taken for this focus time
	property bool blocking: false
	// hosts let through again for this focus time
	property var lifted: []
	property bool offered: false

	function host(text) {
		return String(text || "").trim().toLowerCase()
			.replace(/^[a-z][a-z0-9+.-]*:\/\//, "").replace(/[\/?#:].*$/, "").replace(/^www\./, "");
	}

	function setFocusSites(list) {
		const hosts = [];
		for (const entry of list || []) {
			const host = root.host(entry);
			if (host !== "" && /^[a-z0-9.-]+$/.test(host) && !hosts.includes(host)) hosts.push(host);
		}
		root.focusSites = hosts;
		focusFile.setText(JSON.stringify({ sites: hosts }, null, "\t") + "\n");
	}

	function blockNow() {
		root.offered = true;
		root.lifted = [];
		root.blocking = true;
	}

	function unblockAll() {
		root.blocking = false;
		root.lifted = [];
	}

	function offerFocus() {
		if (root.offered || root.blocking || !root.focusing || !WebLink.connected) return;
		if (!Plugins.on("browser-focus") || root.focusSites.length === 0) return;
		root.offered = true;
		const names = root.focusSites.slice(0, 3).join(", ") + (root.focusSites.length > 3 ? ` +${root.focusSites.length - 3}` : "");
		Notifs.pushInternal("", "Keep distracting sites away?", names, {
			icon: "block_helper",
			duration: 12000,
			actions: [{ label: "Until focus ends", icon: "block_helper", run: () => root.blockNow() }]
		});
	}

	onFocusingChanged: {
		if (root.focusing) root.offerFocus();
		else {
			root.offered = false;
			root.unblockAll();
		}
	}

	Connections {
		target: WebLink

		function onConnectedChanged() {
			root.offerFocus();
		}
	}

	// ── the tab rail ─────────────────────────────────────────────────────
	// style: hover (icons, opens while the pointer rests), open (titles),
	// icons (never opens), top (tabs above the page); width of the open rail.
	// The extension's chrome part (experiments/chrome.js) sets it live.
	readonly property var railStyles: ["hover", "open", "icons", "top"]
	property var rail: ({ style: "hover", width: 300 })

	function setRail(patch) {
		const next = Object.assign({}, root.rail, patch || {});
		if (!root.railStyles.includes(next.style)) next.style = "hover";
		next.width = Math.round(Math.max(200, Math.min(480, Number(next.width) || 300)));
		root.rail = next;
		railFile.setText(JSON.stringify(next, null, "\t") + "\n");
	}

	FileView {
		id: railFile

		path: Paths.stateFile("browser-rail.json")
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(text());
				root.rail = {
					style: root.railStyles.includes(saved.style) ? saved.style : "hover",
					width: Math.round(Math.max(200, Math.min(480, Number(saved.width) || 300)))
				};
			} catch (error) {
			}
		}
	}

	// ── the tabs (docs/browser.md › Tabs) ────────────────────────────────
	// what the extension's chrome part does with the rail and the pages:
	// recent tiles, pinned at the foot, environments, hints, peek, spur,
	// the archive offer. ~/.local/state/pshell/browser-tabs.json
	readonly property var tabsDefaults: ({
		recent: { on: true, minutes: 10, count: 6 },
		dock: true,
		ctrlTab: true,
		states: true,
		filter: true,
		bySite: true,
		envs: {
			on: true,
			group: true,
			// in this order before every other tab; Alt+E goes round those with
			// cycle, the first of them being where a site lives
			list: [
				{ id: "live", name: "Live", color: "#e5534b", patterns: [], cycle: true },
				{ id: "stage", name: "Stage", color: "#4d9ef0", patterns: ["staging.*", "stage.*", "*.staging.*"], cycle: true },
				{ id: "dev", name: "Dev", color: "#57ab5a", patterns: ["localhost", "*.test", "*.ddev.site", "*.local"], cycle: true }
			]
		},
		hints: { on: true, chars: "asdfghjkl" },
		peek: { on: true, external: "peek" },
		spur: { on: true, columns: 3 },
		archive: { on: true, after: 24, keep: 30 },
		launcherKey: true,
		urlbarLauncher: false
	})
	property var tabs: root.tabsDefaults

	function clampNumber(value, low, high, fallback) {
		const number = Number(value);
		return Math.round(Math.max(low, Math.min(high, isFinite(number) && value !== "" && value !== null ? number : fallback)));
	}

	// "a, b" → ["a", "b"]; a comma inside /…/ belongs to the regex
	function splitPatterns(text) {
		const out = [];
		let current = "";
		let inRegex = false;
		for (const ch of String(text)) {
			if (ch === "/" && current.trim() === "") inRegex = true;
			else if (ch === "/" && inRegex) inRegex = false;
			if (ch === "," && !inRegex) {
				out.push(current);
				current = "";
			} else {
				current += ch;
			}
		}
		out.push(current);
		return out;
	}

	// a host pattern ("*" for any part) or a regular expression as /…/
	function patterns(list, fallback) {
		if (typeof list === "string") list = root.splitPatterns(list);
		if (!Array.isArray(list)) return fallback.slice();
		const out = [];
		for (const entry of list) {
			let text = String(entry || "").trim();
			if (/^\/.+\/$/.test(text)) {
				try {
					new RegExp(text.slice(1, -1));
				} catch (error) {
					continue;
				}
			} else {
				text = text.toLowerCase().replace(/^[a-z][a-z0-9+.-]*:\/\//, "").replace(/\/.*$/, "");
				if (!/^[a-z0-9.*:-]+$/.test(text)) continue;
			}
			if (text !== "" && !out.includes(text)) out.push(text);
		}
		return out;
	}

	readonly property var envPalette: ["#e5534b", "#4d9ef0", "#57ab5a", "#c69026", "#a371f7", "#39c5cf", "#e275ad", "#8b949e"]

	// the groups of envs: each with a unique id (its tabs' pshell-env), a name,
	// a colour, its patterns and whether Alt+E goes through it
	function cleanEnvList(envs) {
		let list = envs.list;
		if (!Array.isArray(list)) {
			// before the list: live, stage, dev and their colours
			const colors = envs.colors && typeof envs.colors === "object" ? envs.colors : {};
			list = root.tabsDefaults.envs.list.map(d => ({
				id: d.id, name: d.name, color: colors[d.id] || d.color,
				patterns: envs[d.id] !== undefined ? envs[d.id] : d.patterns, cycle: true
			}));
		}
		const out = [];
		const ids = [];
		for (const raw of list.slice(0, 12)) {
			if (!raw || typeof raw !== "object") continue;
			const name = String(raw.name || "").trim().slice(0, 24) || "Group";
			let id = typeof raw.id === "string" && /^[a-z0-9-]{1,24}$/.test(raw.id) ? raw.id : name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20) || "group";
			if (ids.includes(id)) {
				let n = 2;
				while (ids.includes(`${id}-${n}`)) n++;
				id = `${id}-${n}`;
			}
			ids.push(id);
			const color = /^#[0-9a-fA-F]{6}$/.test(String(raw.color)) ? String(raw.color).toLowerCase() : root.envPalette[out.length % root.envPalette.length];
			out.push({ id: id, name: name, color: color, patterns: root.patterns(raw.patterns, []), cycle: raw.cycle !== false });
		}
		return out;
	}

	function addEnv() {
		const list = root.tabs.envs.list.slice();
		const used = list.map(e => e.color);
		const color = root.envPalette.find(c => !used.includes(c)) || root.envPalette[list.length % root.envPalette.length];
		list.push({ name: "Group " + (list.length + 1), color: color, patterns: [], cycle: false });
		root.setTabs({ envs: { list: list } });
	}

	function changeEnv(id, patch) {
		root.setTabs({ envs: { list: root.tabs.envs.list.map(e => e.id === id ? Object.assign({}, e, patch) : e) } });
	}

	function removeEnv(id) {
		root.setTabs({ envs: { list: root.tabs.envs.list.filter(e => e.id !== id) } });
	}

	function moveEnv(id, step) {
		const list = root.tabs.envs.list.slice();
		const at = list.findIndex(e => e.id === id);
		const to = at + step;
		if (at < 0 || to < 0 || to >= list.length) return;
		list.splice(to, 0, list.splice(at, 1)[0]);
		root.setTabs({ envs: { list: list } });
	}

	// a whole, valid set from whatever was saved or patched
	function cleanTabs(raw) {
		const d = root.tabsDefaults;
		const t = raw || {};
		const part = (key) => Object.assign({}, d[key], (t[key] && typeof t[key] === "object") ? t[key] : {});
		const flag = (value, fallback) => typeof value === "boolean" ? value : fallback;
		const recent = part("recent");
		const envs = part("envs");
		const hints = part("hints");
		const peek = part("peek");
		const spur = part("spur");
		const archive = part("archive");
		let chars = "";
		for (const ch of String(hints.chars || "").toLowerCase()) {
			if (/[a-z]/.test(ch) && !chars.includes(ch)) chars += ch;
		}
		if (chars.length < 4) chars = d.hints.chars;
		return {
			recent: {
				on: flag(recent.on, true),
				minutes: root.clampNumber(recent.minutes, 5, 15, 10),
				count: root.clampNumber(recent.count, 3, 9, 6)
			},
			dock: flag(t.dock, d.dock),
			ctrlTab: flag(t.ctrlTab, d.ctrlTab),
			states: flag(t.states, d.states),
			filter: flag(t.filter, d.filter),
			bySite: flag(t.bySite, d.bySite),
			envs: {
				on: flag(envs.on, true),
				group: flag(envs.group, true),
				list: root.cleanEnvList((t.envs && typeof t.envs === "object") ? t.envs : {})
			},
			hints: { on: flag(hints.on, true), chars: chars },
			peek: { on: flag(peek.on, true), external: peek.external === "tab" ? "tab" : "peek" },
			spur: { on: flag(spur.on, true), columns: root.clampNumber(spur.columns, 2, 4, 3) },
			archive: {
				on: flag(archive.on, true),
				after: root.clampNumber(archive.after, 6, 168, 24),
				keep: root.clampNumber(archive.keep, 1, 365, 30)
			},
			launcherKey: flag(t.launcherKey, d.launcherKey),
			urlbarLauncher: flag(t.urlbarLauncher, d.urlbarLauncher)
		};
	}

	// one level deep: setTabs({ envs: { group: false } }) keeps the other envs keys
	function setTabs(patch) {
		const next = Object.assign({}, root.tabs);
		for (const key of Object.keys(patch || {})) {
			const value = patch[key];
			next[key] = value && typeof value === "object" && !Array.isArray(value) && root.tabs[key] && typeof root.tabs[key] === "object"
				? Object.assign({}, root.tabs[key], value)
				: value;
		}
		root.tabs = root.cleanTabs(next);
		tabsFile.setText(JSON.stringify(root.tabs, null, "\t") + "\n");
	}

	FileView {
		id: tabsFile

		path: Paths.stateFile("browser-tabs.json")
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			try {
				root.tabs = root.cleanTabs(JSON.parse(text()));
			} catch (error) {
			}
		}
	}

	// ── the archive ──────────────────────────────────────────────────────
	// tabs closed through the archive offer: [{ title, url, host, favicon, closedAt }]
	// (~/.local/state/pshell/browser-archive.json), newest first; the
	// launcher's >tab finds them. Nothing of a private window comes here.
	property var archive: []
	// the day the offer was last made (once a day)
	property string offeredDay: ""

	function keptArchive(list) {
		const oldest = Date.now() - root.tabs.archive.keep * 86400000;
		return (list || []).filter(entry => entry && entry.url && Number(entry.closedAt || 0) >= oldest);
	}

	function saveArchive() {
		archiveFile.setText(JSON.stringify({ offered: root.offeredDay, tabs: root.archive }, null, "\t") + "\n");
	}

	// the extension's tabs untouched for a while: offered once a day
	function offerArchive(message) {
		if (!root.enabled || !root.tabs.archive.on || message.private) return;
		const stale = (Array.isArray(message.tabs) ? message.tabs : []).filter(tab => tab && tab.id !== undefined);
		if (stale.length === 0) return;
		const today = Qt.formatDate(new Date(), "yyyy-MM-dd");
		if (root.offeredDay === today) return;
		root.offeredDay = today;
		root.saveArchive();
		const source = String(message.source || "");
		const ids = stale.map(tab => tab.id);
		const hours = root.tabs.archive.after;
		const since = hours >= 48 ? `${Math.round(hours / 24)} days` : hours >= 24 ? "yesterday" : `${hours} hours`;
		const names = stale.slice(0, 3).map(tab => String(tab.host || tab.title || "")).filter(Boolean).join(", ") + (stale.length > 3 ? ` +${stale.length - 3}` : "");
		Notifs.pushInternal("", stale.length === 1 ? `A tab untouched since ${since}` : `${stale.length} tabs untouched since ${since}`, names, {
			icon: "archive_outline",
			duration: 15000,
			actions: [{ label: "Archive", icon: "archive_outline", run: () => root.archiveTabs(ids, source) }]
		});
	}

	function archiveTabs(ids, source) {
		WebLink.command("archive", { tabIds: ids }, (ok, data) => {
			if (!ok || !Array.isArray(data)) {
				Notifs.pushInternal("error", "The tabs could not be archived", String(data || ""), { icon: "archive_outline" });
				return;
			}
			const added = data.filter(entry => entry && entry.url && !entry.private).map(entry => ({
				title: String(entry.title || ""),
				url: String(entry.url),
				host: String(entry.host || root.host(entry.url)),
				favicon: String(entry.favicon || "").length < 24000 ? String(entry.favicon || "") : "",
				closedAt: Number(entry.closedAt || Date.now())
			}));
			root.archive = root.keptArchive(added.concat(root.archive));
			root.saveArchive();
		}, source || undefined);
	}

	// back from the archive: opened, and out of it
	function reopenArchived(entry) {
		if (!entry) return;
		root.archive = root.archive.filter(item => !(item.url === entry.url && item.closedAt === entry.closedAt));
		root.saveArchive();
		WebLink.open(entry.url);
	}

	FileView {
		id: archiveFile

		path: Paths.stateFile("browser-archive.json")
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(text());
				root.offeredDay = String(saved.offered || "");
				root.archive = root.keptArchive(Array.isArray(saved.tabs) ? saved.tabs : []);
			} catch (error) {
			}
		}
	}

	// ── habits ───────────────────────────────────────────────────────────
	// which host was opened from the launcher at which hour, so the
	// launcher lifts what is usually opened around now
	// (~/.local/state/pshell/browser-habits.json): { host: [24 counts] }
	property var habits: ({})

	function noteHabit(url) {
		const host = root.host(url);
		if (host === "") return;
		const next = Object.assign({}, root.habits);
		const hours = Array.isArray(next[host]) && next[host].length === 24 ? next[host].slice() : new Array(24).fill(0);
		hours[new Date().getHours()] = Math.min(999, hours[new Date().getHours()] + 1);
		next[host] = hours;
		// at most 300 hosts: the least used go
		const hosts = Object.keys(next);
		if (hosts.length > 300) {
			hosts.sort((a, b) => next[a].reduce((s, n) => s + n, 0) - next[b].reduce((s, n) => s + n, 0));
			for (const drop of hosts.slice(0, hosts.length - 300)) delete next[drop];
		}
		root.habits = next;
		habitsFile.setText(JSON.stringify(next) + "\n");
	}

	// 0…1: how much this host belongs to this time of day (±1 hour)
	function habit(url) {
		const hours = root.habits[root.host(url)];
		if (!Array.isArray(hours)) return 0;
		const now = new Date().getHours();
		const near = hours[now] + 0.5 * (hours[(now + 23) % 24] + hours[(now + 1) % 24]);
		return Math.min(1, near / 6);
	}

	FileView {
		id: habitsFile

		path: Paths.stateFile("browser-habits.json")
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(text());
				if (saved && typeof saved === "object") root.habits = saved;
			} catch (error) {
			}
		}
	}

	// a link the shell opens itself (mail, chat, notifications): in the
	// browser's peek when that is wanted, else as before
	function openLink(url, source) {
		const text = String(url || "");
		if (!/^https?:\/\//i.test(text)) return false;
		if (!root.enabled || !WebLink.connected || !root.tabs.peek.on || root.tabs.peek.external !== "peek") return false;
		return WebLink.command("peek", { url: text, source: String(source || "") }, (ok, data) => {
			if (ok) WebLink.focusBrowserWindow("", "");
			else Browser.open(text);
		});
	}

	FileView {
		id: focusFile

		path: Plugins.on("browser-focus") ? Paths.stateFile("browser-focus.json") : ""
		printErrors: false
		onLoaded: {
			try {
				const sites = JSON.parse(text()).sites;
				if (Array.isArray(sites)) root.focusSites = sites.map(String);
			} catch (error) {
			}
		}
	}

	// ── the new tab page ─────────────────────────────────────────────────
	property string wallpaper: ""
	// the day changes, and events end
	property real now: Date.now()

	Timer {
		interval: 60000
		repeat: true
		running: root.newtab
		onTriggered: root.now = Date.now()
	}

	function clock(date) {
		return Qt.formatTime(date, "hh:mm");
	}

	function todaysEvents() {
		if (!MsCalendar.enabled || !MsCalendar.signedIn) return [];
		const now = new Date(root.now);
		return MsCalendar.eventsOn(now)
			.filter(event => MsCalendar.active(event) && (event.allDay || new Date(event.end).getTime() > root.now))
			.map(event => ({
				id: String(event.id),
				title: String(event.subject || ""),
				when: event.allDay ? "Ganztägig" : `${root.clock(new Date(event.start))}–${root.clock(new Date(event.end))}`,
				where: String(event.location || "")
			}));
	}

	function build() {
		const today = Weather.daily?.[0] ?? null;
		return {
			palette: { bg: WebLink.css(Theme.bg), fg: WebLink.css(Theme.fg), primary: WebLink.css(Theme.primary), dark: Theme.dark },
			radius: Theme.windowRadius,
			font: Theme.fontFamily,
			wallpaper: root.wallpaper,
			weather: Plugins.on("weather") && Weather.available ? {
				temp: Weather.temperatureValue,
				text: String(Weather.description || ""),
				place: String(Weather.location || Weather.city || ""),
				high: today ? today.max : undefined,
				low: today ? today.min : undefined
			} : null,
			todos: Plugins.on("todos") ? Todos.openTasks.slice()
				.sort((a, b) => (b.priority || 0) - (a.priority || 0))
				.slice(0, 6)
				.map(task => ({
					id: String(task.key),
					text: String(task.text || ""),
					due: task.group && task.group !== Todos.inbox ? String(task.group) : "",
					overdue: (task.priority || 0) >= 3
				})) : [],
			events: root.todaysEvents(),
			notes: Plugins.on("notes") ? Notes.pinned.slice(0, 2).map(note => ({
				id: String(note.id),
				title: Notes.titleOf(note),
				text: String(note.body || "").slice(0, 400)
			})) : []
		};
	}

	readonly property var draft: root.newtab ? root.build() : null
	onDraftChanged: newtabDue.restart()

	Timer {
		id: newtabDue

		interval: 400
		onTriggered: root.newtabData = root.draft
	}

	// the picture worn, shrunk to a JPEG in memory (a message to the browser stays below 1 MB)
	FileView {
		path: root.newtab ? `${Paths.themeState}/current/media-signature` : ""
		watchChanges: true
		printErrors: false
		onLoaded: wallpaperDue.restart()
		onFileChanged: reload()
	}

	Timer {
		id: wallpaperDue

		interval: 700
		onTriggered: {
			wallpaperProc.running = false;
			wallpaperProc.running = true;
		}
	}

	Process {
		id: wallpaperProc

		command: ["sh", "-c", 'ffmpeg -nostdin -loglevel error -i "$1" -frames:v 1 -vf "scale=1280:-2" -q:v 7 -f mjpeg - | base64 -w0', "_", `${Paths.themeState}/current/frame.png`]
		stdout: StdioCollector {
			onStreamFinished: {
				const data = text.trim();
				if (data !== "" && data.length < 900000) root.wallpaper = `data:image/jpeg;base64,${data}`;
			}
		}
	}

	onNewtabChanged: {
		if (root.newtab) wallpaperDue.restart();
		else root.wallpaper = "";
	}

	// ── what the extension asks ──────────────────────────────────────────
	// reply(ok, data)
	function ask(what, args, reply) {
		switch (what) {
		case "newtab":
			if (!root.newtab) return reply(false, "the new tab page is off");
			return reply(true, root.newtabData ?? root.build());
		case "identities":
			if (!root.forms) return reply(true, []);
			return reply(true, Identities.saved.map(identity => root.identityFor(identity)));
		default:
			return reply(false, `nothing answers ${what}`);
		}
	}

	// an identity as content/page.js fills it in
	function identityFor(identity) {
		const given = String(identity.first || "");
		const family = String(identity.last || "");
		return {
			id: String(identity.id),
			label: String(identity.title || `${given} ${family}`.trim()),
			fields: {
				email: String(identity.mail?.address || ""),
				username: String(identity.username || ""),
				password: String(identity.password || ""),
				given: given,
				family: family,
				name: `${given} ${family}`.trim(),
				phone: String(identity.phone?.number || ""),
				birthday: String(identity.birthday || ""),
				street: String(identity.street || ""),
				zip: String(identity.postcode || ""),
				city: String(identity.city || ""),
				country: String(identity.country || ""),
				gender: String(identity.gender || "")
			}
		};
	}

	// ── what the extension tells ─────────────────────────────────────────
	// { name, source, … }
	function event(message) {
		switch (message.name) {
		case "newtabOpen":
			return root.openFromNewtab(String(message.what || ""), String(message.id || ""));
		case "mailto":
			if (root.intercept.mailto) root.mailto(String(message.url || ""), !!message.private);
			return;
		case "calendar":
			if (root.intercept.calendar) root.fetchCalendar(String(message.url || ""), !!message.private);
			return;
		case "unblock": {
			const host = root.host(message.host);
			if (host !== "" && !root.lifted.includes(host)) root.lifted = root.lifted.concat([host]);
			return;
		}
		// Ctrl K in the browser: the launcher on >tab
		case "launcher":
			if (root.tabs.launcherKey) {
				Popups.withFocusedScreen(screen => {
					if (Popups.current === "launcher") Popups.close();
					Popups.open("launcher", screen, "", ">tab ");
				});
			}
			return;
		// tabs untouched for a while
		case "stale":
			return root.offerArchive(message);
		// identityUsed: Identities keeps no record of where one was used
		// blockedVisit: nothing to do, the browser showed the page
		default:
			return;
		}
	}

	function openFromNewtab(what, id) {
		switch (what) {
		case "weather":
			Popups.withFocusedScreen(screen => Popups.open("today", screen));
			return;
		case "event": {
			const found = MsCalendar.eventsOn(new Date()).find(event => String(event.id) === id);
			if (found) MsCalendar.show(found);
			else Popups.withFocusedScreen(screen => Popups.open("today", screen));
			return;
		}
		case "todo":
			if (Plugins.on("todos") && id !== "") Todos.openTask(id);
			return;
		case "note":
			if (Plugins.on("notes")) Popups.withFocusedScreen(screen => Popups.open("notes", screen, id));
			return;
		}
	}

	// mailto:a@b,c@d?subject=…&body=…&cc=…
	function mailto(url, isPrivate) {
		if (!/^mailto:/i.test(url)) return;
		const [head, query] = url.slice(7).split("?");
		const fields = {};
		for (const pair of String(query || "").split("&")) {
			const at = pair.indexOf("=");
			if (at <= 0) continue;
			const key = pair.slice(0, at).toLowerCase();
			let value = pair.slice(at + 1);
			try {
				value = decodeURIComponent(value.replace(/\+/g, "%20"));
			} catch (error) {
			}
			fields[key] = value;
		}
		let to = head;
		try {
			to = decodeURIComponent(head);
		} catch (error) {
		}
		to = [to, fields.to || ""].filter(Boolean).join(", ");
		if (isPrivate) {
			// a draft is kept on disk: only the address
			Messages.open(to !== "" ? `new:${to.split(",")[0].trim()}` : "new");
			return;
		}
		const escape = text => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
		const html = fields.body ? escape(fields.body).replace(/\r?\n/g, "<br>") : "";
		Mail.keep("new", { html: html, files: [], to: to, cc: fields.cc || "", bcc: fields.bcc || "", subject: fields.subject || "" });
		Messages.open("new");
	}

	// ── calendar links: fetched, looked at, offered ──────────────────────
	property int calendarCount: 0

	function fetchCalendar(url, isPrivate) {
		if (!/^https?:\/\//i.test(url)) return;
		root.calendarCount += 1;
		const path = `${Paths.runtime}/browser/calendar-${root.calendarCount}.ics`;
		const job = calendarJob.createObject(root, { path: path, url: url, isPrivate: isPrivate });
		job.start();
	}

	Component {
		id: calendarJob

		QtObject {
			id: job

			property string path
			property string url
			property bool isPrivate
			property var events: []

			function start() {
				fetchProc.running = true;
			}

			function done() {
				dropProc.running = true;
			}

			function offer() {
				const first = job.events[0];
				const start = new Date(first.start);
				const when = first.allDay ? Qt.formatDate(start, "ddd d MMM") : `${Qt.formatDate(start, "ddd d MMM")}, ${Qt.formatTime(start, "hh:mm")}`;
				const title = job.events.length === 1 ? first.subject : `${job.events.length} events`;
				const detail = job.events.length === 1 ? [when, first.location].filter(Boolean).join(" · ") : `${when} · ${first.subject}`;
				Notifs.pushInternal("", title, detail, {
					icon: "calendar_plus",
					duration: 15000,
					actions: [{ label: "Add to calendar", icon: "calendar_plus", run: () => importProc.running = true }]
				});
				// the file goes once the offer is gone
				dropLater.start();
			}

			property Timer dropLater: Timer {
				interval: 16000
				onTriggered: if (!importProc.running) job.done()
			}

			property Process fetchProc: Process {
				command: ["sh", "-c", 'mkdir -p "$(dirname "$2")" && curl -fsSL --max-time 20 --max-filesize 2000000 -o "$2" "$1"', "_", job.url, job.path]
				onExited: code => {
					if (code !== 0) {
						Notifs.pushInternal("error", "The calendar link did not load", "", { icon: "calendar_outline" });
						job.done();
						return;
					}
					peekProc.running = true;
				}
			}

			property Process peekProc: Process {
				command: ["python3", `${Paths.scripts}/ms_calendar.py`, "peek", job.path]
				stdout: StdioCollector {
					onStreamFinished: {
						let answer = {};
						try {
							answer = JSON.parse(text.trim().split("\n").pop() || "{}");
						} catch (error) {
						}
						job.events = Array.isArray(answer.events) ? answer.events : [];
						if (job.events.length === 0) {
							Notifs.pushInternal("error", "No events in the calendar link", "", { icon: "calendar_outline" });
							job.done();
						} else job.offer();
					}
				}
			}

			property Process importProc: Process {
				command: ["python3", `${Paths.scripts}/ms_calendar.py`, "import", job.path]
				stdout: StdioCollector {
					onStreamFinished: {
						let answer = {};
						try {
							answer = JSON.parse(text.trim().split("\n").pop() || "{}");
						} catch (error) {
							answer = { error: "The calendar did not answer" };
						}
						job.done();
						if (answer.error) {
							Notifs.pushInternal("error", String(answer.error), "", { icon: "calendar_outline" });
							return;
						}
						Sounds.play("taskDone");
						Notifs.pushInternal("", answer.imported === 1 ? "The event is in the calendar" : `${answer.imported} events are in the calendar`, "", { icon: "calendar_check" });
						MsCalendar.refresh();
					}
				}
			}

			property Process dropProc: Process {
				command: ["rm", "-f", job.path]
				onExited: job.destroy()
			}
		}
	}
}
