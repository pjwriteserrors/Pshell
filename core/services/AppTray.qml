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
	readonly property var reveals: ["always", "hover", "click", "key"]
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
		const t = root.full(tray);
		const size = Math.max(24, Math.min(96, Number(t.iconSize) || 48));
		const n = Math.max(1, (t.items ?? []).length);
		return n * size + (n - 1) * Math.round(size * 0.16) + 2 * Math.round(size * 0.2);
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
				const gap = Math.max(0, Number(tray.snapGap ?? 8)) * scale;
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
		}
		return false;
	}

	// puts items in before `index` (or at the end); one that is there already moves
	function addItems(trayId, items, index) {
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

	function removeItem(trayId, itemId) {
		const tray = root.trayById(trayId);
		if (!tray) return;
		root.update(trayId, { items: (tray.items ?? []).filter(item => item.id !== itemId) });
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
		file.setText(JSON.stringify({ trays: root.trays }, null, 2) + "\n");
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
