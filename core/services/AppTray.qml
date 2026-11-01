pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The app trays: strips on a screen's edge that hold apps, launcher
// commands (and so the plugins), shell commands, files, folders and links.
// Each tray has its screen, its edge, where along the edge it sits and how
// it shows: always, when the pointer reaches the edge, from a handle that is
// clicked, or only from a key (`scripts/ipc.sh apptray toggle`). What goes
// in comes by drag and drop (from the launcher, the file manager, any app)
// or from the editor (Pshell settings › App tray). Kept in app-tray.json.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("app-tray")
	readonly property var edges: ["left", "right", "top", "bottom"]
	readonly property var reveals: ["always", "smart", "hover", "click", "key"]
	// what a new tray starts with
	readonly property var defaults: ({
		name: "Tray",
		output: "",
		edge: "bottom",
		position: 0.5,
		reveal: "hover",
		iconSize: 48,
		magnify: 0.45,
		gap: 8,
		look: "glass",
		labels: true,
		dots: true,
		focusRunning: true,
		reserve: false,
		gameHide: true,
		delay: 180,
		snap: null,
		snapGap: 8,
		// open apps that are not in it come in behind a line
		running: false,
		accent: "theme",
		accentColor: "#7aa2f7",
		blur: true,
		compact: false,
		labelStyle: "bubble",
		badges: true,
		previews: true,
		motion: "lively",
		// when it is there at all: { workspaces, apps, from, to, game }
		when: null,
		items: []
	})
	// the mime type items travel in between the launcher, the editor and the trays
	readonly property string mime: "application/x-pshell-tray-item"

	property var trays: []
	property bool loaded: false
	// app-tray.json was there (a setup whose trays were all taken away gets no new one)
	property bool existed: false
	// something that can go into a tray is being dragged inside the shell:
	// every tray shows, so it can be dropped on
	property bool carrying: false
	// trays opened by a click or a key (id → true)
	property var opened: ({})
	// the commands of the launcher, published by it: [{ command, name, glyph, group }]
	property var commandCatalog: []
	// the tray the editor shows, and whether the editor is open: that tray
	// stays out on the desktop while it is placed
	property string editing: ""
	property bool previewing: false

	// saved sets of trays: { name: trays }, and the one in use
	property var profiles: ({})
	property string profile: ""
	readonly property var profileNames: Object.keys(root.profiles).sort()
	// the tray that has the keyboard (opened by `apptray focus`)
	property string keyboardTray: ""
	// the windows of the trays by id (they answer where a point falls)
	property var windows: ({})
	// the clock, for trays that come at certain hours (a tick a minute)
	property real now: Date.now()

	Timer {
		running: root.enabled && root.trays.some(tray => !!tray.when)
		interval: 30000
		repeat: true
		onTriggered: root.now = Date.now()
	}

	// a tray asks the launcher to run one of its commands
	signal commandRequested(string token)
	// an item was started: its tray lets it hop
	signal launched(string itemId)

	function trayById(id) {
		return root.trays.find(tray => tray.id === id) ?? null;
	}

	// a tray with every setting, also those it was saved without
	function full(tray) {
		return Object.assign({}, root.defaults, tray ?? {});
	}

	function uid(prefix) {
		return `${prefix}${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
	}

	function primaryName() {
		return String(Popups.primaryScreen?.name ?? (Quickshell.screens[0]?.name ?? ""));
	}

	// the screen a tray is on; one of a screen that is gone shows on the primary one
	function outputOf(tray) {
		const name = String(tray?.output ?? "");
		if (name !== "" && Quickshell.screens.some(screen => String(screen.name) === name)) return name;
		return root.primaryName();
	}

	// ── changing trays ──────────────────────────────────────────────────
	// `keep` holds a change in memory only (while the editor drags a tray)
	function update(id, patch, keep) {
		root.trays = root.trays.map(tray => tray.id === id ? Object.assign({}, tray, patch) : tray);
		if (!keep) root.save();
	}

	function addTray(output, edge) {
		const id = root.uid("tray-");
		const taken = root.trays.filter(tray => root.outputOf(tray) === (output || root.primaryName())).map(tray => tray.edge);
		const free = root.edges.find(each => !taken.includes(each)) ?? "bottom";
		const tray = Object.assign({}, root.defaults, {
			id: id,
			name: root.trays.length === 0 ? "Tray" : `Tray ${root.trays.length + 1}`,
			output: output || root.primaryName(),
			edge: edge || free,
			items: []
		});
		root.trays = root.trays.concat([tray]);
		root.editing = id;
		root.save();
		return id;
	}

	// a tray snapped to the one that goes takes its place in the row
	function removeTray(id) {
		const gone = root.trayById(id);
		root.trays = root.trays.filter(tray => tray.id !== id).map(tray => {
			if (tray.snap?.to !== id) return tray;
			return Object.assign({}, tray, { snap: gone?.snap ?? null, position: gone?.position ?? tray.position });
		});
		if (root.editing === id) root.editing = root.trays[0]?.id ?? "";
		root.save();
	}

	// ── trays side by side ──────────────────────────────────────────────
	// A tray can be snapped to another on the same edge: `snap: { to, side }`
	// ("before" or "after" it along the edge) with `snapGap` px between
	// them. It then goes where that one ends, whatever that one holds.

	// how long a tray is along its edge, in px (as its window draws it)
	function lengthOf(tray) {
		if (!root.active(tray)) return 0;
		const t = root.full(tray);
		const size = Math.max(24, Math.min(96, Number(t.iconSize) || 48));
		const items = root.shownItems(t);
		const n = Math.max(1, items.length);
		const units = items.length === 0 ? 1 : items.reduce((sum, item) => sum + root.slotFactor(item, t), 0);
		return units * size + (n - 1) * Math.round(size * 0.16) + 2 * Math.round(size * 0.2);
	}

	// the tray a tray is snapped to, while both are on the same edge
	function anchorOf(tray, all) {
		const to = tray?.snap?.to;
		if (!to) return null;
		const other = (all ?? root.trays).find(each => each.id === to);
		if (!other || root.outputOf(other) !== root.outputOf(tray) || (other.edge ?? "bottom") !== (tray.edge ?? "bottom")) return null;
		return other;
	}

	// whether `id` is in the chain `tray` hangs from (snapping to it would go round)
	function hangsFrom(tray, id, all) {
		let at = tray;
		for (let depth = 0; at && depth < 16; depth += 1) {
			if (at.id === id) return true;
			at = root.anchorOf(at, all);
		}
		return false;
	}

	// the middle of a tray along an edge `len` long; `k` turns px into the
	// unit of `len`; `override` stands in for one tray (the one being carried)
	function centerOf(id, len, k, override) {
		const scale = k ?? 1;
		const all = override ? root.trays.map(tray => tray.id === override.id ? Object.assign({}, tray, override) : tray) : root.trays;
		const walk = (tray, depth) => {
			const half = root.lengthOf(tray) * scale / 2;
			const anchor = depth < 16 ? root.anchorOf(tray, all) : null;
			if (anchor) {
				const at = walk(anchor, depth + 1);
				const gap = root.active(tray) && root.active(anchor) ? Math.max(0, Number(tray.snapGap ?? 8)) * scale : 0;
				const other = root.lengthOf(anchor) * scale / 2;
				return tray.snap.side === "before" ? at - other - gap - half : at + other + gap + half;
			}
			return Math.max(half + 8 * scale, Math.min(len - half - 8 * scale, (Number(tray.position ?? 0.5) || 0) * len));
		};
		const tray = all.find(each => each.id === id);
		return tray ? walk(tray, 0) : len / 2;
	}

	// the length of a screen's edge in px
	function edgeLength(output, edge) {
		const screen = Quickshell.screens.find(each => String(each.name) === output) ?? Quickshell.screens[0];
		if (!screen) return 1;
		return edge === "left" || edge === "right" ? screen.height : screen.width;
	}

	// snapped to `to` on that side. A tray already there moves out one
	// place: `id` goes in between. Trays snapped to `id` come along.
	function snapTo(id, to, side) {
		const tray = root.trayById(id);
		const other = root.trayById(to);
		if (!tray || !other || id === to || root.hangsFrom(other, id)) return;
		const opposite = side === "after" ? "before" : "after";
		// the last of the trays that follow `id` on that side
		let end = id;
		for (let depth = 0; depth < 16; depth += 1) {
			const next = root.trays.find(each => each.id !== id && each.snap?.to === end && each.snap?.side === side);
			if (!next) break;
			end = next.id;
		}
		const changes = {};
		changes[id] = { output: root.outputOf(other), edge: other.edge ?? "bottom", snap: { to: to, side: side } };
		// one snapped to `to` on that side follows the row of `id` now
		const follower = root.trays.find(each => each.id !== id && each.snap?.to === to && each.snap?.side === side);
		if (follower) changes[follower.id] = { snap: { to: end, side: side } };
		// `to` hangs from the tray on that side of it: `id` goes in between
		else if (other.snap?.side === opposite && other.snap?.to !== id && root.anchorOf(other)) {
			changes[id].snap = { to: other.snap.to, side: opposite };
			changes[to] = { snap: { to: id, side: opposite } };
		}
		root.trays = root.trays.map(each => changes[each.id] ? Object.assign({}, each, changes[each.id]) : each);
		root.save();
	}

	// on its own again, where it is now
	function detach(id) {
		const tray = root.trayById(id);
		if (!tray?.snap) return;
		const len = root.edgeLength(root.outputOf(tray), tray.edge ?? "bottom");
		const at = root.centerOf(id, len, 1);
		root.update(id, { snap: null, position: Math.round(Math.max(0, Math.min(1, at / len)) * 1000) / 1000 });
	}

	// a new tray right after `id`, on its edge
	function addBeside(id) {
		const tray = root.trayById(id);
		if (!tray) return root.addTray("", "");
		const fresh = root.addTray(root.outputOf(tray), tray.edge ?? "bottom");
		root.update(fresh, { snap: { to: id, side: "after" }, iconSize: root.full(tray).iconSize, reveal: root.full(tray).reveal, look: root.full(tray).look, gap: root.full(tray).gap });
		return fresh;
	}

	// ── more kinds of items ─────────────────────────────────────────────
	// separator: a line between groups; spacer: room; group: items of its
	// own that open from one icon; file with `stack`: a folder shown as a
	// stack of its newest files; widget: a live clock, weather, cpu, media,
	// timer, battery, volume; action: what is dropped on it goes somewhere
	// (a shelf, the phone, the AI, another PC, the trash, the clipboard);
	// game: a game of the library with its cover; phone: the phone.
	// and every live status of the shell (Live) as `live:<id>`; a curve
	// wants a wider tile
	readonly property var widgets: root.ownWidgets.concat(Live.catalog.map(each => ({ id: `live:${each.id}`, name: each.name, glyph: each.glyph, wide: Live.styleOf(each.id) === "spark" ? 1.5 : 1, live: true, plugin: each.plugin })))
	readonly property var ownWidgets: [
		{ id: "clock", name: "Clock", glyph: "clock_outline", wide: 1.6 },
		{ id: "weather", name: "Weather", glyph: "weather_partly_cloudy", wide: 1 },
		{ id: "cpu", name: "CPU", glyph: "chip", wide: 1.4 },
		{ id: "memory", name: "Memory", glyph: "memory", wide: 1.4 },
		{ id: "media", name: "Now playing", glyph: "music_note", wide: 3 },
		{ id: "timer", name: "Time tracking", glyph: "timer_outline", wide: 1.6 },
		{ id: "battery", name: "Battery", glyph: "battery", wide: 1 },
		{ id: "volume", name: "Volume", glyph: "volume_high", wide: 1 }
	]
	readonly property var actions: {
		const out = [
			{ id: "shelf", name: "Put on a shelf", glyph: "tray_full", plugin: "shelves" },
			{ id: "ai", name: "Ask the AI", glyph: "creation", plugin: "chat" },
			{ id: "phone", name: "Send to the phone", glyph: "cellphone_arrow_down", plugin: "phone" },
			{ id: "copy", name: "Copy the paths", glyph: "content_copy", plugin: "" },
			{ id: "trash", name: "Move to the trash", glyph: "delete_outline", plugin: "" },
			{ id: "open", name: "Open together", glyph: "open_in_new", plugin: "" }
		];
		for (const pc of Pcs.devices)
			out.push({ id: "pc", pc: String(pc.id), name: `Send to ${pc.name ?? "PC"}`, glyph: "monitor_multiple", plugin: "pc-link" });
		return out.filter(action => action.plugin === "" || Plugins.on(action.plugin));
	}

	function widgetOf(id) {
		return root.widgets.find(each => each.id === id) ?? null;
	}
	function widgetName(id) {
		const src = String(id).startsWith("live:") ? Live.source(id) : null;
		if (src) return src.text !== "" ? `${src.name} · ${src.text}` : src.name;
		return root.widgetOf(id)?.name ?? "Widget";
	}
	function widgetGlyph(id) {
		if (String(id).startsWith("live:")) return Live.source(id)?.glyph ?? "heart_pulse";
		if (id === "weather") return Weather.icon || "weather_partly_cloudy";
		if (id === "battery") return SysStats.batteryAvailable ? SysStats.batteryIcon : "battery";
		if (id === "volume") return Audio.muted ? "volume_off" : (Audio.volume > 0.5 ? "volume_high" : "volume_medium");
		return root.widgetOf(id)?.glyph ?? "apps";
	}

	function actionOf(item) {
		return root.actions.find(each => each.id === item?.action && (each.pc ?? "") === (item?.pc ?? "")) ?? null;
	}

	// how wide an item is, in icons
	function slotFactor(item, tray) {
		const compact = !!tray?.compact;
		switch (item?.kind) {
		case "separator": return 0.3;
		case "spacer": return 0.6;
		case "widget": return compact ? 1 : (root.widgetOf(item.widget)?.wide ?? 1);
		}
		return 1;
	}

	// what a tray shows: its items, and with `running` the open apps it
	// does not have, behind a line
	function shownItems(tray) {
		const items = tray?.items ?? [];
		if (!tray?.running) return items;
		const have = new Set();
		const add = list => list.forEach(item => {
			if (item.kind === "app") have.add(String(root.entryOf(item)?.id ?? item.app));
			if (item.kind === "group") add(item.items ?? []);
		});
		add(items);
		const extra = Object.keys(root.windowsByApp).filter(key => !have.has(key)).sort()
			.map(key => ({ id: `run:${key}`, kind: "app", app: key, transient: true }));
		return extra.length === 0 ? items : items.concat([{ id: "run-line", kind: "separator", transient: true }], extra);
	}

	// a group of items under one icon
	function addGroup(trayId, index) {
		const id = root.uid("group-");
		root.addItems(trayId, [{ id: id, kind: "group", name: "Group", items: [] }], index ?? -1);
		return id;
	}

	// into a group (from the tray itself or from a drop)
	function addToGroup(trayId, groupId, items) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		const fresh = items.map(item => Object.assign({}, item, { id: item.id && !String(item.id).startsWith("run:") ? item.id : root.uid("item-") }));
		const ids = fresh.map(item => item.id);
		const list = (tray.items ?? []).filter(item => !ids.includes(item.id)).map(item => item.id !== groupId ? item
			: Object.assign({}, item, { items: (item.items ?? []).filter(child => !fresh.some(other => root.sameThing(other, child))).concat(fresh) }));
		root.update(trayId, { items: list });
	}

	// out of a group, back into the tray after it
	function takeOutOfGroup(trayId, groupId, itemId) {
		const tray = root.trayById(trayId);
		const group = (tray?.items ?? []).find(item => item.id === groupId);
		const child = (group?.items ?? []).find(item => item.id === itemId);
		if (!child) return;
		const list = root.withoutItem(tray.items, itemId);
		list.splice(list.findIndex(item => item.id === groupId) + 1, 0, child);
		root.update(trayId, { items: list });
	}

	// the item moves to another tray (dragged from one to the other)
	function moveToTray(fromId, itemId, toId, index) {
		if (fromId === toId) return;
		const from = root.trayById(fromId);
		const item = (from?.items ?? []).find(each => each.id === itemId) ?? root.findInGroups(from?.items ?? [], itemId);
		if (!item) return;
		root.update(fromId, { items: root.withoutItem(from.items, itemId) }, true);
		root.addItems(toId, [item], index);
	}

	// where in which tray a point of the screens falls: { trayId, index } or null
	function trayAt(gx, gy, except) {
		for (const id in root.windows) {
			if (id === except) continue;
			const index = root.windows[id]?.indexAtGlobal(gx, gy) ?? -1;
			if (index >= 0) return { trayId: id, index: index };
		}
		return null;
	}

	// ── badges ──────────────────────────────────────────────────────────
	// what an icon has to say: { count, text, progress (0…1, -1 none), dot, urgent }
	function badgeOf(item) {
		const out = { count: 0, text: "", progress: -1, dot: false, urgent: false };
		if (!item) return out;
		switch (item.kind) {
		case "app": {
			const groups = root.notifsOf(item);
			out.count = groups.reduce((sum, group) => sum + (group.notifications?.length ?? 1), 0);
			out.urgent = groups.some(group => Number(group.urgency) >= 2);
			out.dot = out.count > 0;
			if (root.isBrowser(item) && Downloads.enabled && Downloads.running.length > 0) out.progress = Downloads.ratio;
			break;
		}
		case "command":
			switch (String(item.command)) {
			case "messages": out.count = Messages.enabled ? Messages.unread : 0; break;
			case "updates": out.count = Updates.packages.length; break;
			case "downloads": out.count = Downloads.active?.length ?? 0; out.progress = Downloads.running.length > 0 ? Downloads.ratio : -1; break;
			case "torrents": out.count = Torrents.running.length; out.progress = Torrents.running.length > 0 ? Torrents.ratio : -1; break;
			case "printer": out.progress = Printer.printing ? Printer.progress : -1; break;
			case "games": out.count = Games.running.length; break;
			case "shelf": out.count = Shelf.shelves.length; break;
			}
			break;
		case "game": {
			const minutes = Number(Games.game(item.game)?.playtime ?? 0);
			if (minutes > 0) out.text = minutes >= 60 ? `${Math.round(minutes / 60)} h` : `${minutes} m`;
			out.dot = Games.isRunning(String(item.game));
			break;
		}
		case "phone":
			if (Phone.reachable && Phone.battery >= 0) out.text = `${Phone.battery}%`;
			out.urgent = Phone.reachable && Phone.battery >= 0 && Phone.battery <= 15 && !Phone.charging;
			break;
		case "group":
			out.count = (item.items ?? []).reduce((sum, child) => sum + root.badgeOf(child).count, 0);
			break;
		}
		return out;
	}

	// the notification groups of an app
	function notifsOf(item) {
		const entry = root.entryOf(item);
		if (!entry) return [];
		const name = String(entry.name ?? "").toLowerCase();
		const id = String(entry.id ?? "").toLowerCase();
		const icon = String(entry.icon ?? "").toLowerCase();
		return Notifs.groups.filter(group => {
			const app = String(group.appName ?? "").toLowerCase();
			const key = String(group.key ?? "").toLowerCase();
			const gIcon = String(group.appIcon ?? "").toLowerCase();
			return app !== "" && (app === name || app === id || key.includes(id) || (icon !== "" && gIcon === icon));
		});
	}

	function dismissNotifs(item) {
		for (const group of root.notifsOf(item)) Notifs.dismissGroup(group.key);
	}

	function isBrowser(item) {
		const id = String(root.entryOf(item)?.id ?? item?.app ?? "").toLowerCase();
		return /floorp|firefox|chrom|brave|vivaldi|librewolf|zen|epiphany|qutebrowser/.test(id);
	}

	// ── dropped on an item ──────────────────────────────────────────────
	// whether files dropped on it do something with them
	function takesFiles(item) {
		if (!item) return false;
		if (item.kind === "app" || item.kind === "shell" || item.kind === "action" || item.kind === "phone") return true;
		return item.kind === "file" && !!item.folder;
	}

	function pathsOfDrop(drop) {
		return Array.from(drop.urls ?? []).map(String).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
	}

	// opens the files with the app, hands them to the line, copies them into the folder …
	function openWith(trayId, item, paths) {
		if (!item || paths.length === 0) return;
		switch (item.kind) {
		case "app": {
			const entry = root.entryOf(item);
			if (!entry) return;
			AppUsage.recordLaunch(entry);
			Quickshell.execDetached(["gtk-launch", String(entry.id).replace(/\.desktop$/, "")].concat(paths));
			break;
		}
		case "shell":
			Quickshell.execDetached(["sh", "-c", `${item.exec} "$@"`, "sh"].concat(paths));
			break;
		case "file":
			Quickshell.execDetached(["gio", "copy", "--"].concat(paths, [String(item.path) + "/"]));
			Notifs.post({ summary: `Copied into ${root.nameOf(item)}`, body: paths.map(path => path.split("/").pop()).join(", ") });
			break;
		case "phone":
			for (const path of paths) Phone.shareFile(path);
			break;
		case "action":
			root.runActionItem(item, paths);
			return;
		}
		root.launched(item.id);
	}

	function runActionItem(item, paths) {
		const action = root.actionOf(item);
		if (!action) return;
		if (paths.length === 0) {
			Notifs.post({ summary: action.name, body: "Drop files on it" });
			return;
		}
		switch (action.id) {
		case "shelf":
			Shelf.create(paths.map(path => ({ kind: "file", path: path, name: path.split("/").pop(), mime: Shelf.guessMime(path) })), "");
			break;
		case "ai":
			Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", { aiFiles: paths, aiAsk: "" }));
			break;
		case "phone":
			for (const path of paths) Phone.shareFile(path);
			break;
		case "pc":
			Pcs.sendFiles(String(item.pc), paths, "");
			break;
		case "copy":
			Quickshell.execDetached(["wl-copy", paths.join("\n")]);
			break;
		case "trash":
			Quickshell.execDetached(["gio", "trash", "--"].concat(paths));
			Notifs.post({ summary: `${paths.length} in the trash`, body: paths.map(path => path.split("/").pop()).join(", ") });
			break;
		case "open":
			for (const path of paths) Quickshell.execDetached(["xdg-open", path]);
			break;
		}
		root.launched(item.id);
	}

	// ── widgets ─────────────────────────────────────────────────────────
	function widgetClicked(item) {
		if (String(item.widget).startsWith("live:")) {
			Live.activate(item.widget, null, null);
			return;
		}
		switch (item.widget) {
		case "clock":
		case "weather":
			Popups.withFocusedScreen(screen => Popups.open("today", screen));
			break;
		case "media":
			Media.player?.togglePlaying();
			break;
		case "timer":
			Popups.withFocusedScreen(screen => Popups.open("timer", screen));
			break;
		case "volume":
			if (Audio.sink?.audio) Audio.sink.audio.muted = !Audio.sink.audio.muted;
			break;
		case "cpu":
		case "memory":
			Quickshell.execDetached(Terminal.command({ title: "btop" }, ["btop"]));
			break;
		}
	}

	// the wheel on an item: through an app's windows, the volume, a player's volume
	function scrolled(item, up) {
		if (item?.kind === "app") {
			const windows = root.windowsOf(item).slice().sort((a, b) => a.id - b.id);
			if (windows.length === 0) return;
			const at = windows.findIndex(window => window.is_focused);
			const next = at < 0 ? 0 : (at + (up ? -1 : 1) + windows.length) % windows.length;
			Niri.focusWindow(windows[next].id);
		} else if (item?.kind === "widget" && String(item.widget).startsWith("live:")) {
			Live.scroll(item.widget, up);
		} else if (item?.kind === "widget" && item.widget === "volume") {
			Audio.setVolume(Math.max(0, Math.min(1.5, Audio.volume + (up ? 0.05 : -0.05))));
		} else if (item?.kind === "widget" && item.widget === "media" && Media.player) {
			Media.player.volume = Math.max(0, Math.min(1, Number(Media.player.volume ?? 1) + (up ? 0.05 : -0.05)));
		}
	}

	// ── when a tray is there ────────────────────────────────────────────
	// `when`: { workspaces: "1, web", apps: "code, firefox", from: "08:00",
	// to: "18:00", game: "on" | "off" }; all that is set must hold
	function active(tray) {
		const rule = tray?.when;
		if (!rule) return true;
		const list = text => String(text ?? "").split(",").map(each => each.trim().toLowerCase()).filter(each => each !== "");
		const spaces = list(rule.workspaces);
		if (spaces.length > 0) {
			const output = root.outputOf(tray);
			const ws = Niri.workspaces.find(each => each.is_active && String(each.output) === output) ?? Niri.workspaces.find(each => each.is_focused);
			const names = [String(ws?.name ?? "").toLowerCase(), String(ws?.idx ?? "")];
			if (!spaces.some(each => names.includes(each))) return false;
		}
		const apps = list(rule.apps);
		if (apps.length > 0) {
			const focused = String(Niri.windows.find(window => window.is_focused)?.app_id ?? "").toLowerCase();
			if (!apps.some(each => focused.includes(each))) return false;
		}
		if (rule.from || rule.to) {
			const time = new Date(root.now);
			const minutes = time.getHours() * 60 + time.getMinutes();
			const parse = text => {
				const match = String(text ?? "").match(/^(\d{1,2}):?(\d{2})?$/);
				return match ? Number(match[1]) * 60 + Number(match[2] ?? 0) : -1;
			};
			const from = parse(rule.from);
			const to = parse(rule.to);
			if (from >= 0 && to >= 0) {
				const inside = from <= to ? minutes >= from && minutes < to : minutes >= from || minutes < to;
				if (!inside) return false;
			}
		}
		if (rule.game === "on" && !GameMode.active) return false;
		if (rule.game === "off" && GameMode.active) return false;
		return true;
	}

	// ── profiles ────────────────────────────────────────────────────────
	function saveProfile(name) {
		const key = String(name ?? "").trim();
		if (key === "") return;
		const next = Object.assign({}, root.profiles);
		next[key] = JSON.parse(JSON.stringify(root.trays));
		root.profiles = next;
		root.profile = key;
		root.save();
	}

	function useProfile(name) {
		const saved = root.profiles[name];
		if (!saved) return;
		// what is set up now is kept under the profile in use
		if (root.profile !== "" && root.profile !== name && root.profiles[root.profile]) {
			const next = Object.assign({}, root.profiles);
			next[root.profile] = JSON.parse(JSON.stringify(root.trays));
			root.profiles = next;
		}
		root.trays = JSON.parse(JSON.stringify(saved));
		root.profile = name;
		root.editing = root.trays[0]?.id ?? "";
		root.save();
		Notifs.post({ summary: `Tray profile: ${name}` });
	}

	function deleteProfile(name) {
		const next = Object.assign({}, root.profiles);
		delete next[name];
		root.profiles = next;
		if (root.profile === name) root.profile = "";
		root.save();
	}

	// ── keys ────────────────────────────────────────────────────────────
	// the n-th item (1…) of the tray with the keyboard, the edited one or the first
	function launchIndex(n, trayId) {
		const tray = root.trayById(trayId) ?? root.trayById(root.keyboardTray) ?? root.trays.find(each => root.active(each));
		if (!tray) return;
		const items = root.shownItems(root.full(tray)).filter(item => item.kind !== "separator" && item.kind !== "spacer");
		const item = items[n - 1];
		if (item) root.run(tray.id, item, false);
	}

	// opens a tray with the keyboard on it: arrows, Enter, 1…9, Escape
	function focusTray(id) {
		const tray = root.trayById(id) ?? root.trays.find(each => root.active(each));
		if (!tray) return;
		root.keyboardTray = root.keyboardTray === tray.id ? "" : tray.id;
	}

	readonly property string bindMods: "Mod+Alt"
	function isOurBind(bind) {
		return (bind.args ?? []).join(" ").includes("ipc call apptray");
	}
	readonly property bool keysBound: Keybinds.binds.some(bind => root.isOurBind(bind))

	// Mod+Alt+1…9 start the items, Mod+Alt+0 gives a tray the keyboard;
	// keys that do something else are left alone
	function bindKeys(on) {
		if (!Keybinds.loaded) {
			Keybinds.load();
			bindRetry.on = on;
			bindRetry.restart();
			return;
		}
		const others = Keybinds.binds.filter(bind => !root.isOurBind(bind));
		const added = [];
		const skipped = [];
		if (on) {
			for (let n = 0; n <= 9; n += 1) {
				const key = `${root.bindMods}+${n}`;
				if (others.some(other => !other.disabled && Keybinds.norm(other.key) === Keybinds.norm(key))) {
					skipped.push(key);
					continue;
				}
				added.push({ key: key, props: {}, action: "spawn", args: ["qs", "-c", "shell", "ipc", "call", "apptray", n === 0 ? "focus" : "launch", n === 0 ? "" : String(n)], aprops: {}, disabled: false });
			}
		}
		Keybinds.commit(others.concat(added), on ? "Tray keys added" : "Tray keys removed");
		if (skipped.length > 0) Notifs.post({ summary: "Some tray keys are taken", body: skipped.join(", ") });
	}

	Timer {
		id: bindRetry

		property bool on: true

		interval: 400
		onTriggered: {
			if (Keybinds.loaded) root.bindKeys(bindRetry.on);
			else bindRetry.restart();
		}
	}

	// ── sharing a tray ──────────────────────────────────────────────────
	// a tray as a file (`.pshell-tray.json`): sent to another PC, dropped on
	// a tray or the editor there, it comes in as a tray of its own
	function exportTray(id) {
		const tray = root.trayById(id);
		if (!tray) return "";
		const name = String(tray.name ?? "Tray").replace(/[^A-Za-z0-9_-]+/g, "-");
		const path = `${Paths.cache}/trays/${name}.pshell-tray.json`;
		Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1"', "sh", path, JSON.stringify({ pshellTray: 1, tray: tray })]);
		return path;
	}

	function sendTray(id, pc) {
		const path = root.exportTray(id);
		if (path === "") return;
		sendLater.pc = pc;
		sendLater.path = path;
		sendLater.restart();
	}

	Timer {
		id: sendLater

		property string pc: ""
		property string path: ""

		interval: 400
		onTriggered: {
			Pcs.sendFiles(sendLater.pc, [sendLater.path], "");
			Notifs.post({ summary: `Tray sent to ${Pcs.nameOf(sendLater.pc)}`, body: "Drop the file on a tray or on Pshell settings › App tray there" });
		}
	}

	function isTrayFile(path) {
		return /\.pshell-tray\.json$/.test(String(path));
	}

	function importTray(path) {
		importer.command = ["cat", String(path)];
		importer.running = true;
	}

	Process {
		id: importer

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(this.text);
					const tray = data?.tray;
					if (!tray || !Array.isArray(tray.items)) throw new Error("no tray");
					const copy = Object.assign({}, tray, { id: root.uid("tray-"), snap: null, output: root.outputOf(tray) });
					root.trays = root.trays.concat([copy]);
					root.editing = copy.id;
					root.save();
					Notifs.post({ summary: `Tray ${copy.name ?? ""} came in`, body: `${copy.items.length} items` });
				} catch (error) {
					Notifs.post({ summary: "Not a tray", body: String(error) });
				}
			}
		}
	}

	// ── pictures of windows (the previews over an app) ──────────────────
	property var shotFiles: ({})
	property int shotsRev: 0
	readonly property string shotDir: `${Paths.runtime}/tray-shots`

	function shoot(windows) {
		const line = windows.filter(window => window.layout?.window_size).map(window => `${window.id}:${window.layout.window_size[0]}:${window.layout.window_size[1]}`).join(" ");
		if (line === "") return;
		shots.pending = line;
		if (shots.running) shots.write(line + "\n");
		else shots.running = true;
	}

	Process {
		id: shots

		property string pending: ""

		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "480", "0"]
		stdinEnabled: true
		onStarted: shots.write(shots.pending + "\n")
		stdout: SplitParser {
			onRead: line => {
				try {
					const data = JSON.parse(line);
					const files = Object.assign({}, root.shotFiles);
					files[data.id] = String(data.file);
					root.shotFiles = files;
					root.shotsRev++;
				} catch (error) {}
			}
		}
	}

	// ── its items ───────────────────────────────────────────────────────
	// an item is the same as one already there when it starts the same thing
	function sameThing(a, b) {
		if (a.kind !== b.kind) return false;
		switch (a.kind) {
		case "app": return a.app === b.app;
		case "command": return a.command === b.command;
		case "shell": return a.exec === b.exec;
		case "file": return a.path === b.path;
		case "link": return a.url === b.url;
		case "widget": return a.widget === b.widget;
		case "action": return a.action === b.action && (a.pc ?? "") === (b.pc ?? "");
		case "game": return a.game === b.game;
		case "phone": return true;
		}
		// lines, gaps and groups are each their own
		return false;
	}

	// puts items in before `index` (or at the end); one that is there already moves
	function addItems(trayId, raws, index) {
		// a tray file comes in as a tray of its own
		for (const each of raws.filter(item => item.kind === "trayfile")) root.importTray(each.path);
		const items = raws.filter(item => item.kind !== "trayfile");
		const tray = root.trayById(trayId);
		if (!tray || items.length === 0) return;
		let list = (tray.items ?? []).slice();
		let at = index >= 0 && index <= list.length ? index : list.length;
		for (const raw of items) {
			const item = Object.assign({ id: root.uid("item-") }, raw);
			const known = list.findIndex(other => root.sameThing(other, item));
			if (known >= 0) {
				if (known < at) at -= 1;
				item.id = list[known].id;
				list.splice(known, 1);
			}
			list.splice(at, 0, item);
			at += 1;
		}
		root.update(trayId, { items: list });
	}

	// taken out, with a way back for a while
	function removeItem(trayId, itemId, quiet) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		const before = (tray.items ?? []).slice();
		const gone = before.find(item => item.id === itemId) ?? root.findInGroups(before, itemId);
		root.update(trayId, { items: root.withoutItem(before, itemId) });
		if (quiet || !gone || gone.kind === "separator" || gone.kind === "spacer") return;
		Notifs.post({
			summary: `${root.nameOf(gone)} is out of the tray`,
			body: String(tray.name ?? "Tray"),
			actions: [{ text: "Undo", identifier: "undo", invoke: () => {
				if (root.trayById(trayId)) root.update(trayId, { items: before });
			} }]
		});
	}

	// a list without an item, also taken out of a group
	function withoutItem(list, itemId) {
		return list.filter(item => item.id !== itemId).map(item => item.kind === "group"
			? Object.assign({}, item, { items: (item.items ?? []).filter(child => child.id !== itemId) }) : item);
	}

	function findInGroups(list, itemId) {
		for (const item of list)
			if (item.kind === "group") {
				const found = (item.items ?? []).find(child => child.id === itemId);
				if (found) return found;
			}
		return null;
	}

	function updateItem(trayId, itemId, patch) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		root.update(trayId, { items: (tray.items ?? []).map(item => item.id === itemId ? Object.assign({}, item, patch) : item) });
	}

	// moves an item to `to` (an index in the list without it)
	function moveItem(trayId, itemId, to) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		const list = (tray.items ?? []).slice();
		const from = list.findIndex(item => item.id === itemId);
		if (from < 0) return;
		const [item] = list.splice(from, 1);
		list.splice(Math.max(0, Math.min(list.length, to)), 0, item);
		root.update(trayId, { items: list });
	}

	// a whole new order: old indices in the new order (the editor's list)
	function reorder(trayId, order) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		const list = tray.items ?? [];
		root.update(trayId, { items: order.map(i => list[i]).filter(item => !!item) });
	}

	// from the launcher: into the tray being edited, else the first one
	// (a tray is made when there is none)
	function addToTray(item) {
		if (!root.enabled) return;
		let id = root.trayById(root.editing) ? root.editing : (root.trays[0]?.id ?? "");
		if (id === "") id = root.addTray("", "bottom");
		root.addItems(id, [item], -1);
		Notifs.post({ summary: `${root.nameOf(item)} is in the tray`, body: root.trayById(id)?.name ?? "" });
	}

	function inAnyTray(item) {
		return root.trays.some(tray => (tray.items ?? []).some(other => root.sameThing(other, item)));
	}

	// ── what a drop brings ──────────────────────────────────────────────
	function itemsOfDrop(drop) {
		const out = [];
		const formats = Array.from(drop.formats ?? []).map(String);
		if (formats.includes(root.mime)) {
			try {
				const data = JSON.parse(String(drop.getDataAsString(root.mime)));
				for (const item of Array.isArray(data) ? data : [data])
					if (item && item.kind) out.push(item);
			} catch (error) {}
			if (out.length > 0) return out;
		}
		for (const url of drop.urls ?? []) {
			const value = String(url);
			if (value.startsWith("file://")) out.push(root.itemOfPath(decodeURIComponent(value.slice(7))));
			else if (/^https?:/.test(value)) out.push({ kind: "link", url: value, name: root.hostOf(value) });
			else if (value.startsWith("applications:")) out.push({ kind: "app", app: value.slice(13) });
		}
		if (out.length === 0 && drop.hasText) {
			const text = String(drop.text ?? "").trim();
			if (/^https?:\/\/\S+$/.test(text)) out.push({ kind: "link", url: text, name: root.hostOf(text) });
			else if (text.startsWith("/") && !text.includes("\n")) out.push(root.itemOfPath(text));
			// a line of text: a command to run
			else if (text !== "" && !text.includes("\n") && text.length < 300) out.push({ kind: "shell", exec: text, name: text.split(/\s+/)[0].split("/").pop(), glyph: "console" });
		}
		return out.filter(item => !!item);
	}

	function accepts(drop) {
		const formats = Array.from(drop.formats ?? []).map(String);
		return formats.includes(root.mime) || drop.hasUrls || drop.hasText;
	}

	// a desktop file is its app; anything else opens with its program
	function itemOfPath(path) {
		const clean = String(path).replace(/\/+$/, "") || "/";
		if (root.isTrayFile(clean)) return { kind: "trayfile", path: clean };
		const base = clean.split("/").pop();
		if (base.endsWith(".desktop")) {
			const entry = DesktopEntries.byId(base.slice(0, -8)) ?? DesktopEntries.byId(base);
			if (entry) return { kind: "app", app: String(entry.id) };
		}
		return { kind: "file", path: clean, name: base || clean, folder: !/\.[A-Za-z0-9]{1,6}$/.test(base) };
	}

	function hostOf(url) {
		const match = String(url).match(/^https?:\/\/(?:www\.)?([^/:?#]+)/);
		return match ? match[1] : String(url);
	}

	// the mime data an item is dragged with
	function mimeFor(item) {
		const out = {};
		out[root.mime] = JSON.stringify(item);
		return out;
	}

	// ── how items look ──────────────────────────────────────────────────
	function entryOf(item) {
		if (item?.kind !== "app") return null;
		return DesktopEntries.byId(String(item.app)) ?? DesktopEntries.heuristicLookup(String(item.app).replace(/\.desktop$/, ""));
	}

	function commandOf(item) {
		if (item?.kind !== "command") return null;
		return root.commandCatalog.find(each => each.command === item.command) ?? null;
	}

	function nameOf(item) {
		if (!item) return "";
		if (String(item.label ?? "").trim() !== "") return String(item.label).trim();
		switch (item.kind) {
		case "app": return String(root.entryOf(item)?.name ?? item.name ?? item.app);
		case "command": return String(root.commandOf(item)?.name ?? item.name ?? `>${item.command}`);
		case "shell": return String(item.name || item.exec);
		case "file": return String(item.name || item.path.split("/").pop());
		case "link": return String(item.name || root.hostOf(item.url));
		case "group": return String(item.name || `${(item.items ?? []).length} items`);
		case "separator": return "Line";
		case "spacer": return "Gap";
		case "widget": return root.widgetName(item.widget);
		case "action": return root.actionOf(item)?.name ?? "Action";
		case "game": return String(Games.game(item.game)?.name ?? item.name ?? "Game");
		case "phone": return Phone.reachable ? `${Phone.name} · ${Phone.battery >= 0 ? `${Phone.battery}%` : ""}` : (Phone.paired ? `${Phone.name} (away)` : "Phone");
		}
		return "";
	}

	// a picture for the item ("" = it is drawn as a glyph on a tile)
	function iconOf(item) {
		if (!item) return "";
		if (item.icon) return String(item.icon).startsWith("/") ? `file://${item.icon}` : AppIcons.app(item.icon);
		switch (item.kind) {
		case "app": {
			const entry = root.entryOf(item);
			return entry ? AppIcons.forEntry(entry) : AppIcons.forAppId(String(item.app).replace(/\.desktop$/, ""));
		}
		case "file":
			if (root.isImage(item.path)) return `file://${item.path}`;
			return AppIcons.app(root.themeIconOf(item), ["text-x-generic"]);
		case "game": {
			const cover = Games.game(item.game)?.art?.cover ?? "";
			return cover !== "" ? (cover.startsWith("/") ? `file://${cover}` : cover) : "";
		}
		}
		return "";
	}

	function glyphOf(item) {
		if (!item) return "help";
		if (item.glyph) return String(item.glyph);
		switch (item.kind) {
		case "command": return String(root.commandOf(item)?.glyph ?? "console");
		case "shell": return "console";
		case "link": return "web";
		case "file": return item.folder ? "folder" : "file_outline";
		case "group": return "apps";
		case "widget": return root.widgetGlyph(item.widget);
		case "action": return root.actionOf(item)?.glyph ?? "lightning_bolt";
		case "game": return "gamepad_variant";
		case "phone": return "cellphone";
		}
		return "apps";
	}

	// the hue a glyph tile is tinted with: steady per item, so a tray of
	// commands is not one colour
	function hueOf(item) {
		const text = String(item?.command ?? item?.exec ?? item?.url ?? item?.path ?? item?.id ?? "");
		let hash = 0;
		for (let i = 0; i < text.length; i += 1) hash = (hash * 31 + text.charCodeAt(i)) % 360;
		return hash / 360;
	}

	function isImage(path) {
		return /\.(png|jpe?g|webp|gif|bmp|svg|avif)$/i.test(String(path));
	}

	function themeIconOf(item) {
		if (item.folder) {
			const home = Quickshell.env("HOME");
			const special = { Downloads: "folder-download", Documents: "folder-documents", Pictures: "folder-pictures", Music: "folder-music", Videos: "folder-videos", Desktop: "user-desktop" };
			if (item.path === home) return "user-home";
			for (const name in special)
				if (item.path === `${home}/${name}`) return special[name];
			return "folder";
		}
		const ext = String(item.path).split(".").pop().toLowerCase();
		if (ext === "pdf") return "application-pdf";
		if (["mp4", "mkv", "webm", "mov", "avi"].includes(ext)) return "video-x-generic";
		if (["mp3", "flac", "ogg", "opus", "wav", "m4a"].includes(ext)) return "audio-x-generic";
		if (["zip", "tar", "gz", "xz", "zst", "7z", "rar"].includes(ext)) return "package-x-generic";
		if (["sh", "py", "js", "qml", "rs", "c", "cpp", "go"].includes(ext)) return "text-x-script";
		if (["odt", "docx", "doc"].includes(ext)) return "x-office-document";
		if (["ods", "xlsx", "csv"].includes(ext)) return "x-office-spreadsheet";
		return "text-x-generic";
	}

	// the open windows of every app in a tray, the last focused first
	readonly property var windowsByApp: {
		const map = {};
		if (!root.enabled || root.trays.length === 0) return map;
		for (const window of Niri.windows) {
			const appId = String(window.app_id || "");
			if (appId === "") continue;
			const entry = DesktopEntries.heuristicLookup(appId);
			const key = entry ? String(entry.id || "") : appId;
			(map[key] = map[key] || []).push(window);
		}
		for (const key in map) map[key].sort((a, b) => Niri.focusTimestampValue(b) - Niri.focusTimestampValue(a));
		return map;
	}

	function windowsOf(item) {
		if (item?.kind !== "app") return [];
		const entry = root.entryOf(item);
		return root.windowsByApp[String(entry?.id ?? item.app)] ?? [];
	}

	// ── starting ────────────────────────────────────────────────────────
	// `fresh` starts another one even when the app has a window
	function run(trayId, item, fresh) {
		if (!item) return;
		const tray = root.full(root.trayById(trayId));
		switch (item.kind) {
		case "app": {
			const windows = root.windowsOf(item);
			if (!fresh && tray.focusRunning && windows.length > 0) {
				// the next window of the app when one of them has the focus already
				const focused = windows.findIndex(window => window.is_focused);
				Niri.focusWindow(windows[focused >= 0 ? (focused + 1) % windows.length : 0].id);
				break;
			}
			const entry = root.entryOf(item);
			if (!entry) {
				Notifs.post({ summary: "The app is gone", body: String(item.app) });
				return;
			}
			AppUsage.recordLaunch(entry);
			Quickshell.execDetached({
				command: entry.runInTerminal ? ["app2unit", "--"].concat(Terminal.command({}, entry.command)) : ["app2unit", "--", ...entry.command],
				workingDirectory: entry.workingDirectory
			});
			root.launched(item.id);
			break;
		}
		case "command":
			root.commandRequested(String(item.command));
			break;
		case "shell":
			if (item.terminal) Quickshell.execDetached(Terminal.shellCommand({ title: root.nameOf(item) }, String(item.exec)));
			else Quickshell.execDetached(["sh", "-c", String(item.exec)]);
			root.launched(item.id);
			break;
		case "file":
			Quickshell.execDetached(["xdg-open", String(item.path)]);
			root.launched(item.id);
			break;
		case "link":
			Browser.open(String(item.url));
			root.launched(item.id);
			break;
		case "game":
			Games.launch(String(item.game));
			root.launched(item.id);
			break;
		case "widget":
			root.widgetClicked(item);
			return;
		case "action":
			root.runActionItem(item, []);
			return;
		case "phone":
			Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", ">phone "));
			return;
		// a group or a stack opens in its tray; nothing to start
		case "group":
		case "separator":
		case "spacer":
			return;
		}
		// a tray opened for this closes again
		if (tray.reveal === "click" || tray.reveal === "key") root.setOpen(trayId, false);
	}

	// one of the app's own actions (a private window, a new document …)
	function runAction(item, action) {
		const entry = root.entryOf(item);
		if (!entry || !action) return;
		AppUsage.recordLaunch(entry);
		Quickshell.execDetached({
			command: entry.runInTerminal ? ["app2unit", "--"].concat(Terminal.command({}, action.command)) : ["app2unit", "--", ...action.command],
			workingDirectory: entry.workingDirectory
		});
		root.launched(item.id);
	}

	function closeWindows(item) {
		for (const window of root.windowsOf(item)) Niri.closeWindow(window.id);
	}

	// ── showing ─────────────────────────────────────────────────────────
	function isOpen(id) {
		return root.opened[id] === true;
	}

	function setOpen(id, on) {
		if (root.isOpen(id) === on) return;
		const next = Object.assign({}, root.opened);
		if (on) next[id] = true;
		else delete next[id];
		root.opened = next;
	}

	function toggle(id) {
		const tray = root.trayById(id) ?? root.trays[0];
		if (tray) root.setOpen(tray.id, !root.isOpen(tray.id));
	}

	// every tray that hides opens (or all close again)
	function toggleAll() {
		const hiding = root.trays.filter(tray => root.full(tray).reveal !== "always");
		const any = hiding.some(tray => root.isOpen(tray.id));
		for (const tray of hiding) root.setOpen(tray.id, !any);
	}

	// ── kept ────────────────────────────────────────────────────────────
	function save() {
		root.existed = true;
		file.setText(JSON.stringify({ trays: root.trays, profiles: root.profiles, profile: root.profile }, null, 2) + "\n");
	}

	// the first tray: at the bottom of the primary screen, with the
	// launcher's pinned apps
	function seed() {
		let pins = [];
		try {
			pins = JSON.parse(String(pinsFile.text() || "{}")).pins ?? [];
		} catch (error) {}
		const apps = pins.map(String).filter(id => !!DesktopEntries.byId(id)).slice(0, 8);
		const id = root.addTray(root.primaryName(), "bottom");
		root.addItems(id, apps.map(app => ({ kind: "app", app: app })), -1);
	}

	FileView {
		id: file

		path: Paths.stateFile("app-tray.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(file.text() || "{}"));
				root.trays = Array.isArray(data?.trays) ? data.trays.filter(tray => tray && tray.id) : [];
				root.profiles = data?.profiles && typeof data.profiles === "object" ? data.profiles : {};
				root.profile = String(data?.profile ?? "");
			} catch (error) {
				root.trays = [];
			}
			root.editing = root.trays[0]?.id ?? "";
			root.existed = true;
			root.loaded = true;
		}
		onLoadFailed: {
			root.loaded = true;
			if (root.enabled) seedTimer.start();
		}
	}

	FileView {
		id: pinsFile

		path: Paths.stateFile("launcher-apps.json")
		blockLoading: true
		printErrors: false
	}

	// the desktop entries are read a moment after start
	Timer {
		id: seedTimer

		interval: 1500
		onTriggered: if (root.enabled && !root.existed && root.trays.length === 0) root.seed()
	}

	// a missing app-tray.json says neither loaded nor failed
	Component.onCompleted: {
		if (root.loaded) return;
		root.loaded = true;
		if (root.enabled && !root.existed) seedTimer.start();
	}

	// switched on for the first time on this setup
	onEnabledChanged: if (root.enabled && root.loaded && root.trays.length === 0 && !root.existed) seedTimer.start()
}
