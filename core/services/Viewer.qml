pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The shell's pictures: a window that shows them and changes them (plugin
// "viewer", `viewer-default` makes it what pictures open in). Changes are a
// recipe, not pixels (core/views/viewer/Recipe.js): kept per picture in
// ~/.local/state/pshell/viewer/edits, shown at once by a shader, taken back
// step by step, and written only as a copy beside the picture
// ("name (edited).jpg"). A helper (scripts/viewer/viewer.py) lists folders,
// reads what the camera wrote, decodes what Qt cannot, finds the horizon,
// a document's corners, the subject, and encodes the copy.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("viewer")
	readonly property string helperScript: `${Paths.scripts}/viewer/viewer.py`
	readonly property string editsDir: `${Paths.state}/viewer/edits`
	readonly property string workDir: `${Paths.runtime}/viewer`
	readonly property string windowTitle: root.current ? `${root.current.name} – Pictures` : "Pictures"

	// ── what is shown ──────────────────────────────────────────────────────
	property bool windowOpen: false
	// [{ path, name, mtime, size }] the pictures of the folder (or those handed over)
	property var files: []
	property int index: -1
	property string folder: ""
	readonly property var current: root.index >= 0 && root.index < root.files.length ? root.files[root.index] : null
	readonly property string path: root.current?.path ?? ""
	// what the helper read: { width, height, animated, proxy, camera, gps … }
	property var info: null
	// what Qt loads: the file, or the helper's decode of it
	property string shownPath: ""
	property bool decoding: false
	property string error: ""
	// "view" | "adjust" | "crop" | "markup"
	property string mode: "view"
	property bool infoShown: false
	// a picture of the clipboard: no file of its own until it is saved
	property bool pasted: false
	// where the last open came from, for the window's growth: { x, y, w, h, screen }
	property var origin: null
	property int openSerial: 0
	// which way the last step went (the next picture slides in from there)
	property int direction: 1

	// ── the recipe ─────────────────────────────────────────────────────────
	property var recipe: blankRecipe()
	// what the last step left (sliders move `recipe` live, commit on release)
	property var committed: blankRecipe()
	property var past: []
	property var future: []
	// the sidecar of the picture: { recipe, copy, savedRecipe, original, time }
	property var sidecar: ({})
	readonly property bool edited: !root.plain(root.recipe)
	// the copy beside it shows what the recipe says
	readonly property bool saved: !!root.sidecar.copy && root.same(root.sidecar.savedRecipe, root.recipe)
	// a copy of another picture (this window made it): { original }
	readonly property string madeFrom: String(root.sidecar.original || "")
	property bool busy: false
	property string busyText: ""

	// ── settings ───────────────────────────────────────────────────────────
	property var settings: ({
		sort: "name", reverse: false, format: "same", quality: 92, metadata: true, location: true,
		resize: null, watermark: null, ambient: true, filmstrip: true, info: false
	})
	property bool loaded: false

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n");
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("viewer.json")
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
			root.infoShown = root.setting("info", false);
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// the recipe helpers live in the view's Recipe.js; these few are needed here
	function blankRecipe() {
		return { adjust: {}, curves: {}, tones: {}, look: "", geometry: { rot: 0, flip: false, angle: 0, vertical: 0, horizontal: 0, quad: null, crop: { x: 0, y: 0, w: 1, h: 1 } }, cutout: "", markup: { items: [] } };
	}

	function same(a, b) {
		return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
	}

	function plain(r) {
		if (!r) return true;
		const nonzero = Object.values(r.adjust || {}).some(v => Math.abs(Number(v) || 0) > 1e-4);
		const curves = Object.values(r.curves || {}).some(points => (points || []).some(p => Math.abs(p[0] - p[1]) > 1e-4));
		const tones = (Number(r.tones?.shadowAmount) || 0) > 0 || (Number(r.tones?.highlightAmount) || 0) > 0;
		const g = r.geometry || {};
		const c = g.crop || { x: 0, y: 0, w: 1, h: 1 };
		const shaped = (g.rot || 0) % 4 !== 0 || !!g.flip || Math.abs(g.angle || 0) > 1e-4 || Math.abs(g.vertical || 0) > 1e-4 || Math.abs(g.horizontal || 0) > 1e-4 || !!g.quad
			|| c.x > 1e-5 || c.y > 1e-5 || c.w < 1 - 1e-5 || c.h < 1 - 1e-5;
		return !nonzero && !curves && !tones && !shaped && !r.cutout && (r.markup?.items || []).length === 0;
	}

	// ── opening ────────────────────────────────────────────────────────────
	// open(path, { from: { x, y, w, h, screen }, mode, list: [paths] })
	function open(path, options) {
		if (!root.enabled || !path) return;
		const o = options || {};
		path = String(path).replace(/^file:\/\//, "");
		try {
			path = decodeURIComponent(path);
		} catch (error) {}
		root.origin = o.from || null;
		root.openSerial += 1;
		root.pasted = !!o.pasted;
		const wanted = o.mode || "view";
		if (o.list && o.list.length > 0) {
			root.files = o.list.map(p => root.entryFor(String(p)));
			root.folder = "";
			root.show(Math.max(0, o.list.indexOf(path)), wanted);
		} else {
			// at once with this one picture, its folder follows
			root.files = [root.entryFor(path)];
			root.folder = path.slice(0, path.lastIndexOf("/")) || "/";
			root.show(0, wanted);
			if (!root.pasted) root.listFolder(path);
		}
		root.windowOpen = true;
		root.focusWindow();
	}

	// where an item of a window of the shell is on its screen, for open()'s
	// `from`: a layer surface knows its own place, a window asks niri
	function originOf(item, windowTitle) {
		if (!item) return null;
		const p = item.mapToItem(null, 0, 0);
		let x = p.x, y = p.y, output = "";
		if (windowTitle) {
			const window = Niri.windows.find(w => String(w.title) === windowTitle && /quickshell/i.test(String(w.app_id)));
			const at = window?.layout?.tile_pos_in_workspace_view;
			if (!at) return null;
			const offset = window.layout.window_offset_in_tile ?? [0, 0];
			x += at[0] + offset[0];
			y += at[1] + offset[1];
			output = Niri.workspaces.find(ws => ws.id === window.workspace_id)?.output ?? "";
		}
		return { screen: output, x: x, y: y, w: item.width, h: item.height };
	}

	function entryFor(path) {
		return { path: path, name: path.slice(path.lastIndexOf("/") + 1), mtime: 0, size: 0 };
	}

	function listFolder(path) {
		root.request("list", { path: path, sort: root.setting("sort", "name"), reverse: root.setting("reverse", false) }, (data, error) => {
			if (error || !data || root.path !== path) return;
			root.folder = data.folder;
			root.files = data.files;
			root.index = Math.max(0, data.index);
		});
	}

	function resort(sort, reverse) {
		root.setSetting("sort", sort);
		root.setSetting("reverse", reverse);
		if (root.path && root.folder) root.listFolder(root.path);
	}

	function show(i, mode) {
		if (i < 0 || i >= root.files.length) return;
		root.leaveMode();
		root.index = i;
		root.load();
		if (mode && mode !== "view") Qt.callLater(() => root.setMode(mode));
	}

	function step(delta) {
		if (root.files.length < 2) return;
		root.direction = delta > 0 ? 1 : -1;
		root.show((root.index + delta + root.files.length) % root.files.length);
	}

	function first() {
		root.show(0);
	}

	function last() {
		root.show(root.files.length - 1);
	}

	// the picture's facts, then what Qt is to load, then its recipe
	signal aboutToLoad

	function load() {
		const path = root.path;
		root.aboutToLoad();
		root.info = null;
		root.error = "";
		root.shownPath = "";
		root.decoding = false;
		root.readSidecar(path);
		const known = root.infoCache[path];
		if (known && !known.proxy) {
			root.info = known;
			root.shownPath = path;
			root.prefetch();
			return;
		}
		root.request("info", { path: path }, (data, error) => {
			if (root.path !== path) return;
			if (error) {
				root.error = error;
				return;
			}
			root.remember(path, data);
			root.info = data;
			root.prefetch();
			if (!data.proxy) {
				root.shownPath = path;
				return;
			}
			root.decoding = true;
			root.request("decode", { path: path }, (decoded, failed) => {
				if (root.path !== path) return;
				root.decoding = false;
				if (failed) root.error = failed;
				else {
					root.info = Object.assign({}, root.info, { width: decoded.width, height: decoded.height });
					root.shownPath = decoded.proxy;
				}
			});
		});
	}

	// what the helper read of the pictures around, so stepping is instant
	property var infoCache: ({})
	// [{ path, width, height }] the neighbours' facts, for decoding them ahead
	property var ahead: []

	function remember(path, data) {
		const next = Object.assign({}, root.infoCache);
		next[path] = data;
		const keys = Object.keys(next);
		if (keys.length > 200) delete next[keys[0]];
		root.infoCache = next;
	}

	function prefetch() {
		if (root.files.length < 2) {
			root.ahead = [];
			return;
		}
		const around = [1, -1, 2].map(d => root.files[(root.index + d + root.files.length) % root.files.length].path).filter((p, i, all) => p !== root.path && all.indexOf(p) === i);
		for (const path of around) {
			if (root.infoCache[path]) continue;
			root.request("info", { path: path }, data => {
				if (!data) return;
				root.remember(path, data);
				root.ahead = root.aheadOf(around);
			});
		}
		root.ahead = root.aheadOf(around);
	}

	function aheadOf(paths) {
		return paths.map(p => ({ path: p, info: root.infoCache[p] })).filter(e => e.info && !e.info.proxy && !e.info.animated && e.info.width > 0);
	}

	function close() {
		root.leaveMode();
		root.windowOpen = false;
	}

	function toggle() {
		if (root.windowOpen) root.close();
		else if (root.files.length > 0) root.windowOpen = true;
	}

	// a window that is already up somewhere is brought here
	function focusWindow() {
		focusTimer.restart();
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = Niri.windows.find(window => String(window.title) === root.windowTitle && /quickshell/i.test(String(window.app_id)));
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	// ── the picture in the clipboard ───────────────────────────────────────
	function paste() {
		pasteProc.target = `${root.workDir}/Pasted ${Qt.formatDateTime(new Date(), "yyyy-MM-dd HH-mm-ss")}.png`;
		pasteProc.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && wl-paste --type image/png > "$1" && [ -s "$1" ]', "sh", pasteProc.target];
		pasteProc.running = true;
	}

	// a picture of the clipboard history: a copy of its own to change
	function openCopied(path) {
		const ext = String(path).split(".").pop() || "png";
		pasteProc.target = `${root.workDir}/Clipboard ${Qt.formatDateTime(new Date(), "yyyy-MM-dd HH-mm-ss")}.${ext}`;
		pasteProc.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && cp "$2" "$1"', "sh", pasteProc.target, String(path)];
		pasteProc.running = true;
	}

	Process {
		id: pasteProc

		property string target: ""

		onExited: code => {
			if (code === 0) root.open(pasteProc.target, { pasted: true });
			else root.say("There is no picture in the clipboard", "clipboard_alert_outline");
		}
	}

	// ── modes ──────────────────────────────────────────────────────────────
	function setMode(mode) {
		if (!root.current || root.info?.animated && mode !== "view") {
			if (root.info?.animated) root.say("Moving pictures can only be looked at", "image_off_outline");
			return;
		}
		root.mode = mode;
	}

	function leaveMode() {
		if (root.mode !== "view") root.mode = "view";
	}

	function toggleInfo() {
		root.infoShown = !root.infoShown;
		root.setSetting("info", root.infoShown);
	}

	// ── recipe: preview, commit, undo ──────────────────────────────────────
	function preview(next) {
		root.recipe = next;
	}

	function commit(next) {
		if (root.same(next, root.committed)) {
			root.recipe = next;
			return;
		}
		root.past = root.past.concat([root.committed]).slice(-80);
		root.future = [];
		root.recipe = next;
		root.committed = next;
		root.writeSidecar();
	}

	function undo() {
		if (root.past.length === 0) return;
		root.future = [root.committed].concat(root.future);
		root.committed = root.past[root.past.length - 1];
		root.past = root.past.slice(0, -1);
		root.recipe = root.committed;
		root.writeSidecar();
	}

	function redo() {
		if (root.future.length === 0) return;
		root.past = root.past.concat([root.committed]);
		root.committed = root.future[0];
		root.future = root.future.slice(1);
		root.recipe = root.committed;
		root.writeSidecar();
	}

	// everything back to the picture as it is (one step, so it can come back)
	function revert() {
		root.commit(root.blankRecipe());
	}

	// ── sidecars ───────────────────────────────────────────────────────────
	function sidecarPath(path) {
		return `${root.editsDir}/${Qt.md5(path)}.json`;
	}

	function readSidecar(path) {
		let data = {};
		if (path && !root.pasted) {
			store.path = root.sidecarPath(path);
			try {
				data = JSON.parse(String(store.text() || "{}"));
			} catch (error) {
				data = {};
			}
			if (data.path !== path) data = {};
		}
		root.sidecar = data;
		const r = data.recipe ? Object.assign(root.blankRecipe(), data.recipe) : root.blankRecipe();
		root.past = [];
		root.future = [];
		root.recipe = r;
		root.committed = r;
	}

	function writeSidecar() {
		const path = root.path;
		if (!path || root.pasted) return;
		const data = Object.assign({}, root.sidecar, { path: path, time: Date.now() });
		if (root.plain(root.committed) && !data.copy && !data.original) {
			// nothing worth keeping
			store.path = root.sidecarPath(path);
			store.setText("{}\n");
			root.sidecar = {};
			return;
		}
		data.recipe = root.committed;
		root.sidecar = data;
		store.path = root.sidecarPath(path);
		store.setText(JSON.stringify(data) + "\n");
	}

	function writeSidecarOf(path, data) {
		store.path = root.sidecarPath(path);
		store.setText(JSON.stringify(Object.assign({ path: path, time: Date.now() }, data)) + "\n");
	}

	// the copy opened: back to its original, with the recipe that made it
	function editOriginal() {
		const original = root.madeFrom;
		if (!original) return;
		root.open(original, { mode: "adjust" });
	}

	FileView {
		id: store

		blockLoading: true
		blockWrites: true
		printErrors: false
		atomicWrites: true
	}

	Process {
		running: true
		command: ["mkdir", "-p", root.editsDir, root.workDir]
	}

	// ── saving ─────────────────────────────────────────────────────────────
	// the view renders the result (render(path, done)) and registers here
	property var renderer: null

	// a copy beside the picture (again the same copy when there is one), or
	// to `options.target`; { format, quality, resize, watermark, metadata, location }
	function saveCopy(options, done) {
		if (!root.renderer || !root.current || root.busy) return;
		const o = Object.assign({
			format: root.setting("format", "same"), quality: root.setting("quality", 92), resize: root.setting("resize", null),
			watermark: root.setting("watermark", null), metadata: root.setting("metadata", true), location: root.setting("location", true)
		}, options || {});
		const original = root.path;
		const recipe = root.committed;
		root.busy = true;
		root.busyText = "Saving…";
		const src = `${root.workDir}/render-${Date.now()}.tiff`;
		root.renderer.render(src, ok => {
			if (!ok) {
				root.busy = false;
				root.fail("The picture could not be rendered");
				return;
			}
			const ext = root.extensionFor(o.format, original);
			const request = {
				src: src, original: root.pasted ? "" : original, format: o.format, quality: o.quality, resize: o.resize,
				watermark: o.watermark, metadata: o.metadata, location: o.location
			};
			const again = root.sidecar.copy && root.exists(root.sidecar.copy) && root.sidecar.copy.toLowerCase().endsWith("." + ext);
			if (o.target) request.target = o.target;
			else if (root.pasted) request.beside = { path: `${Paths.home}/Pictures/${root.current.name.replace(/\.[^.]+$/, "")}.${ext}`, label: "", ext: ext };
			else if (again) request.target = root.sidecar.copy;
			else request.beside = { path: original, label: "edited", ext: ext };
			root.request("encode", request, (data, error) => {
				root.busy = false;
				Quickshell.execDetached(["rm", "-f", src]);
				if (error) {
					root.fail(error);
					if (done) done("");
					return;
				}
				if (!root.pasted && !o.target) {
					root.sidecar = Object.assign({}, root.sidecar, { copy: data.path, savedRecipe: recipe });
					root.writeSidecar();
				}
				root.writeSidecarOf(data.path, { original: root.pasted ? "" : original, recipe: recipe });
				root.copies = Object.assign({}, root.copies, { [data.path]: true });
				root.announceSaved(data.path, data.bytes);
				if (root.folder && root.path === original) root.listFolder(original);
				if (done) done(data.path);
			});
		});
	}

	// paths this session wrote (so "exists" knows them without asking the disk)
	property var copies: ({})

	function exists(path) {
		return !!root.copies[path] || root.files.some(f => f.path === path);
	}

	function extensionFor(format, original) {
		const own = original.slice(original.lastIndexOf(".") + 1).toLowerCase();
		switch (format) {
		case "jpeg":
			return "jpg";
		case "png":
		case "webp":
		case "avif":
		case "tiff":
			return format;
		}
		// the same as the picture where it can be written
		if (["jpg", "jpeg", "png", "webp", "avif", "tif", "tiff"].includes(own)) return own;
		return root.info?.alpha || root.recipe.cutout ? "png" : "jpg";
	}

	function announceSaved(path, bytes) {
		const name = path.slice(path.lastIndexOf("/") + 1);
		Notifs.post({
			app: "Pictures",
			summary: `Saved as ${name}`,
			body: bytes ? Format.bytes(bytes) : "",
			image: path,
			icon: "content_save_check_outline",
			actions: [
				{ text: "Show", invoke: () => Files.reveal([path]) },
				{ text: "Open", invoke: () => root.open(path) }
			]
		});
		Sounds.play("taskDone");
	}

	// the result, to the clipboard (a picture, like a screenshot)
	function copyResult() {
		if (!root.renderer || !root.current) return;
		const out = `${root.workDir}/copy-${Date.now()}.png`;
		root.renderer.render(out, ok => {
			if (!ok) return root.fail("The picture could not be rendered");
			Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"; sleep 120; rm -f "$1"', "sh", out]);
			root.say("The picture is in the clipboard", "content_copy");
		});
	}

	// the result as a file for others (share, wallpaper …): done(path)
	function renderTemp(name, done) {
		if (!root.renderer || !root.current) return;
		if (root.plain(root.committed) && !root.pasted && !root.info?.proxy) {
			done(root.path);
			return;
		}
		const stem = root.current.name.replace(/\.[^.]+$/, "");
		const png = `${root.workDir}/${stem}${name ? " " + name : ""}.png`;
		const src = `${root.workDir}/share-${Date.now()}.tiff`;
		root.renderer.render(src, ok => {
			if (!ok) return root.fail("The picture could not be rendered");
			root.request("encode", { src: src, original: root.pasted ? "" : root.path, target: png, format: "png", metadata: false }, (data, error) => {
				Quickshell.execDetached(["rm", "-f", src]);
				if (error) root.fail(error);
				else done(data.path);
			});
		});
	}

	// ── talking to the helper ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})
	property var progress: ({})
	property var queued: []

	function request(op, args, done) {
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const line = JSON.stringify(Object.assign({ id: id, op: op }, args || {})) + "\n";
		if (!helper.running) {
			root.queued.push(line);
			helper.running = true;
		} else helper.write(line);
		idle.restart();
		return id;
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.event === "progress") {
			root.progress = Object.assign({}, root.progress, { [message.id]: { value: message.value ?? 0, text: message.text ?? "" } });
			return;
		}
		const done = root.callbacks[message.id];
		delete root.callbacks[message.id];
		if (root.progress[message.id]) {
			const next = Object.assign({}, root.progress);
			delete next[message.id];
			root.progress = next;
		}
		if (done) done(message.error ? null : message, message.error ?? "");
	}

	Process {
		id: helper

		stdinEnabled: true
		command: ["python3", "-u", root.helperScript]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(`viewer: ${line}`)
		}
		onRunningChanged: {
			if (!helper.running) return;
			for (const line of root.queued) helper.write(line);
			root.queued = [];
		}
		onExited: {
			// what was asked dies with it
			for (const id in root.callbacks) root.callbacks[id](null, "The picture helper stopped");
			root.callbacks = {};
			root.progress = {};
		}
	}

	// the helper goes when nothing has been asked for a while and the window is closed
	Timer {
		id: idle

		interval: 300000
		onTriggered: {
			if (root.windowOpen || Object.keys(root.callbacks).length > 0) idle.restart();
			else helper.running = false;
		}
	}

	onWindowOpenChanged: {
		if (root.windowOpen && !helper.running) helper.running = true;
		idle.restart();
	}

	// ── as an app of the desktop ───────────────────────────────────────────
	// the entry "Pshell Pictures" is there while the plugin is on; with
	// viewer-default pictures opened anywhere come here (scripts/viewer/default.py)
	readonly property bool isDefault: root.enabled && Plugins.on("viewer-default")
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/viewer/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}

	onEnabledChanged: root.applyDefault()
	onIsDefaultChanged: root.applyDefault()
	Component.onCompleted: root.applyDefault()

	Process {
		id: defaultProc
	}

	// what the window does on a word (ipc viewer act …, keys of other
	// surfaces): auto, horizon, page, cutout, export, copy, wallpaper,
	// look:<id>, aspect:<id>, turn, mirror, compare, fit, actual
	signal acted(string action)

	function act(action) {
		if (root.windowOpen) root.acted(action);
	}

	// ── telling ────────────────────────────────────────────────────────────
	signal said(string text, string icon)

	function say(text, icon) {
		root.said(text, icon || "information_outline");
	}

	function fail(text) {
		Sounds.play("error");
		root.said(text, "alert_circle_outline");
	}
}
