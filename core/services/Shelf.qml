pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Shelves: floating stashes for files, folders, links and text, like
// Dropover. A shelf opens by keybind (`shelf toggle`, `shelf clipboard`), as
// one of the commands that shaking the pointer mid-drag brings up
// (DropCommands), or when a new file lands in a watched
// folder (Downloads, screenshots, recordings; host profile "shelf.watch").
// Items only point at their files; dropped image data, clipboard images and
// collected screenshots are kept in the state directory (files nothing
// points at any more are pruned after a day). Open shelves survive
// restarts, closed ones stay in `recent` for a while (shelf.json).
//
// Screenshot series (off by default): once a second screenshot is copied
// to the clipboard shortly after another, both land on a shelf, and so does
// every further one of that series.
Singleton {
	id: root

	readonly property string helper: `${Quickshell.shellDir}/scripts/shelf.py`
	readonly property string stash: Paths.stateFile("shelf")
	readonly property int recentSize: 10

	// [{ id, name, output, x, y, docked, grid, items: [item] }]
	// item: { id, kind: "file" | "text" | "link", path, name, text, url, dir, size, mime, width, height,
	//         preview (a picture for a link, in the stash), site }
	property var shelves: []
	property var recent: []
	property bool hidden: false
	property int counter: 0
	// a shelf that just opened and waits for the pointer to say where; the
	// screen that sees the pointer first puts it there (Shelves)
	property string locating: ""

	property bool shake: true
	property bool openOnNew: true
	property bool collectShots: false

	// screenshot series: copies wait here until a second one joins them
	readonly property int seriesGap: 2 * 60 * 1000
	property real lastShotAt: 0
	property string pendingShot: ""
	property string seriesShelf: ""
	property bool shakeAccess: true
	property bool loaded: false

	readonly property var watchDirs: {
		const configured = Host.profile.shelf?.watch;
		const dirs = Array.isArray(configured) ? configured : ["~/Downloads", "~/Pictures/Screenshots", "~/Videos/Recordings"];
		return dirs.map(dir => String(dir).replace(/^~(?=\/|$)/, Paths.home));
	}

	function nextId() {
		root.counter += 1;
		return `${Date.now().toString(36)}-${root.counter}`;
	}

	function shelfById(id) {
		return root.shelves.find(shelf => shelf.id === id) ?? null;
	}

	function update(id, changes) {
		root.shelves = root.shelves.map(shelf => shelf.id === id ? Object.assign({}, shelf, changes) : shelf);
		root.save();
	}

	// ── opening ──────────────────────────────────────────────────────────
	function locate(id) {
		root.locating = id;
		locateTimeout.restart();
	}

	// no screen saw the pointer: the shelf stays where it was put
	Timer {
		id: locateTimeout

		interval: 500
		onTriggered: root.locating = ""
	}

	// a new shelf at the pointer; cascaded from the right edge of the focused
	// screen when the pointer does not show up. `at` ({ output, x, y }) puts
	// it there instead.
	function create(items, name, at) {
		const id = root.nextId();
		if (at) {
			root.shelves = root.shelves.concat([{ id: id, name: name ?? "", output: at.output, x: at.x, y: at.y, docked: false, grid: true, items: [] }]);
			root.hidden = false;
			root.addItems(id, items ?? []);
			root.save();
			return id;
		}
		Popups.withFocusedScreen(screen => {
			const count = root.shelves.filter(s => s.output === String(screen?.name ?? "")).length;
			const width = screen?.width ?? 1920;
			const height = screen?.height ?? 1080;
			root.shelves = root.shelves.concat([{
				id: id,
				name: name ?? "",
				output: String(screen?.name ?? ""),
				x: width - 300 - 24 - count * 28,
				y: Math.round(height / 2 - 160 + count * 28),
				docked: false,
				grid: true,
				items: []
			}]);
			root.hidden = false;
			root.locate(id);
			root.addItems(id, items ?? []);
			root.save();
		});
		return id;
	}

	// shaking mid-drag brings up the commands; the shelf is one of them
	function shaken() {
		if (!root.shake || !Plugins.on("drop-commands")) return;
		DropCommands.summon();
		Haptics.play("pinned");
	}

	// the shelf things go to: the one opened last, or a new one at `at`
	function current(at) {
		const last = root.shelves[root.shelves.length - 1];
		if (!last) return root.create([], "", at);
		root.hidden = false;
		if (last.docked) root.update(last.id, { docked: false });
		return last.id;
	}

	function keep(items, at) {
		root.addItems(root.current(at), items);
	}

	function toggle() {
		if (!Plugins.on("shelves")) return;
		if (root.shelves.length === 0) {
			root.create([]);
			return;
		}
		root.hidden = !root.hidden;
	}

	function fromClipboard() {
		if (Plugins.on("shelves")) clipProc.running = true;
	}

	function close(id) {
		const shelf = root.shelfById(id);
		if (!shelf) return;
		root.shelves = root.shelves.filter(s => s.id !== id);
		if (shelf.items.length > 0) root.recent = [shelf].concat(root.recent.filter(s => s.id !== id)).slice(0, root.recentSize);
		root.save();
	}

	function closeAll() {
		for (const shelf of root.shelves.slice())
			root.close(shelf.id);
	}

	function reopen(id) {
		const shelf = id ? root.recent.find(s => s.id === id) : root.recent[0];
		if (!shelf) return;
		root.recent = root.recent.filter(s => s.id !== shelf.id);
		root.shelves = root.shelves.concat([Object.assign({}, shelf, { docked: false })]);
		root.hidden = false;
		root.save();
	}

	function forgetRecent(id) {
		root.recent = root.recent.filter(s => s.id !== id);
		root.save();
	}

	// ── items ────────────────────────────────────────────────────────────
	// items: [{ kind: "file", path } | { kind: "text", text } | { kind: "link", url }]
	function addItems(id, items) {
		const shelf = root.shelfById(id);
		if (!shelf || items.length === 0) return;
		const known = shelf.items.map(item => item.path || item.url || item.text);
		const fresh = [];
		const files = [];
		for (const raw of items) {
			const key = raw.path || raw.url || raw.text;
			if (!key || known.includes(key) || fresh.some(item => (item.path || item.url || item.text) === key)) continue;
			const item = { id: root.nextId(), kind: raw.kind, path: raw.path ?? "", url: raw.url ?? "", text: raw.text ?? "", name: "", dir: false, size: 0, mime: "", width: 0, height: 0 };
			if (item.kind === "file") {
				item.name = item.path.split("/").filter(p => p !== "").pop() ?? item.path;
				files.push(item.path);
			} else if (item.kind === "link") {
				item.name = item.url.replace(/^https?:\/\/(www\.)?/, "");
			} else {
				item.name = item.text.trim().split("\n")[0].slice(0, 120);
			}
			fresh.push(item);
		}
		if (fresh.length === 0) return;
		root.update(id, { items: shelf.items.concat(fresh), docked: false });
		if (files.length > 0) root.describe(id, files);
		root.previewLinks(id, fresh.filter(item => item.kind === "link"));
		// what lies in /tmp or the runtime dir is gone after a reboot: a copy goes into the stash
		const volatile = files.filter(path => root.isVolatile(path));
		if (volatile.length > 0) root.keepCopies(id, volatile);
	}

	readonly property var volatileRoots: ["/tmp/", "/dev/shm/", "/run/", `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user"}/`]

	function isVolatile(path) {
		const p = String(path);
		return !p.startsWith(root.stash) && root.volatileRoots.some(prefix => p.startsWith(prefix));
	}

	function keepCopies(id, paths) {
		const proc = stashCopier.createObject(root, { shelfId: id });
		proc.command = ["python3", root.helper, "keep", root.stash].concat(paths);
		proc.running = true;
	}

	// the copies take the originals' place on the shelf
	function applyKept(id, text) {
		let moved = [];
		try {
			moved = JSON.parse(text);
		} catch (error) {
			return;
		}
		const shelf = root.shelfById(id);
		if (!shelf || moved.length === 0) return;
		const to = {};
		for (const entry of moved) to[entry.from] = entry.to;
		root.update(id, { items: shelf.items.map(item => item.kind === "file" && to[item.path] ? Object.assign({}, item, { path: to[item.path] }) : item) });
	}

	Component {
		id: stashCopier

		Process {
			id: copyProc

			property string shelfId: ""

			stdout: StdioCollector {
				onStreamFinished: root.applyKept(copyProc.shelfId, text)
			}
			onExited: copyProc.destroy()
		}
	}

	// Qt hands over drops as URLs and text; files get a first guess at
	// their type so instant actions can use them right away
	function itemsOfDrop(drop) {
		const items = [];
		for (const url of drop.urls ?? []) {
			const value = String(url);
			if (value.startsWith("file://")) {
				const path = decodeURIComponent(value.slice(7));
				items.push({ kind: "file", path: path, name: path.split("/").pop(), mime: root.guessMime(path) });
			} else if (/^https?:/.test(value)) {
				items.push({ kind: "link", url: value });
			}
		}
		if (items.length === 0 && drop.hasText && String(drop.text).trim() !== "") {
			const text = String(drop.text);
			if (/^https?:\/\/\S+$/.test(text.trim())) items.push({ kind: "link", url: text.trim() });
			else items.push({ kind: "text", text: text });
		}
		return items;
	}

	function addDrop(id, drop) {
		root.addItems(id, root.itemsOfDrop(drop));
	}

	function guessMime(path) {
		const ext = String(path).split(".").pop().toLowerCase();
		const images = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", bmp: "image/bmp", svg: "image/svg+xml", avif: "image/avif", tif: "image/tiff", tiff: "image/tiff" };
		return images[ext] ?? "";
	}

	// the clipboard into a shelf that is open already
	function pasteInto(id) {
		pasteProc.shelfId = id;
		pasteProc.running = true;
	}

	function titleOf(shelf) {
		if (!shelf) return "";
		if (shelf.name) return shelf.name;
		const items = shelf.items ?? [];
		if (items.length === 0) return "Shelf";
		if (items.length === 1) return items[0].name || "Shelf";
		return `${items.length} items`;
	}

	function remove(id, itemId) {
		const shelf = root.shelfById(id);
		if (!shelf) return;
		root.update(id, { items: shelf.items.filter(item => item.id !== itemId) });
	}

	function clear(id) {
		root.update(id, { items: [] });
	}

	function describe(id, paths) {
		const proc = describer.createObject(root, { shelfId: id, paths: paths });
		proc.command = ["python3", root.helper, "describe"].concat(paths);
		proc.running = true;
	}

	// links to things with a picture (YouTube videos) get it, and their title
	function previewLinks(id, items) {
		const urls = items.filter(item => root.hasLinkPreview(item.url) && !item.preview).map(item => item.url);
		if (urls.length === 0) return;
		const proc = linkPreviewer.createObject(root, { shelfId: id });
		proc.command = ["python3", root.helper, "linkpreview", root.stash].concat(urls);
		proc.running = true;
	}

	function hasLinkPreview(url) {
		return /(?:youtube\.com\/(?:watch\?|shorts\/|live\/|embed\/)|youtu\.be\/)/.test(String(url));
	}

	function applyLinkPreview(id, text) {
		let found = [];
		try {
			found = JSON.parse(text);
		} catch (error) {
			return;
		}
		const shelf = root.shelfById(id);
		if (!shelf || !Array.isArray(found)) return;
		const byUrl = {};
		for (const entry of found) byUrl[entry.url] = entry;
		root.update(id, { items: shelf.items.map(item => {
			const entry = item.kind === "link" ? byUrl[item.url] : null;
			if (!entry) return item;
			return Object.assign({}, item, { preview: String(entry.image || ""), site: String(entry.site || ""), name: entry.title ? String(entry.title) : item.name });
		}) });
	}

	function applyDescription(id, paths, text) {
		let found = [];
		try {
			found = JSON.parse(text);
		} catch (error) {
			return;
		}
		const shelf = root.shelfById(id);
		if (!shelf) return;
		const byPath = {};
		for (const entry of found) byPath[entry.path] = entry;
		// files that are gone are dropped
		const items = shelf.items.filter(item => item.kind !== "file" || !paths.includes(item.path) || byPath[item.path])
			.map(item => {
				const entry = byPath[item.path];
				return entry ? Object.assign({}, item, { name: entry.name, dir: entry.dir, size: entry.size, mime: entry.mime, width: entry.width, height: entry.height }) : item;
			});
		root.update(id, { items: items });
	}

	// ── what an item is ──────────────────────────────────────────────────
	function isImage(item) {
		return item.kind === "file" && String(item.mime).startsWith("image/");
	}

	// the picture that stands for an item: an image file itself, a link's preview
	function pictureOf(item) {
		if (root.isImage(item)) return String(item.path);
		return item.kind === "link" ? String(item.preview ?? "") : "";
	}

	function iconFor(item) {
		if (item.kind === "text") return "text_box";
		if (item.kind === "link") return item.site === "YouTube" ? "youtube" : "web";
		if (item.dir) return "folder";
		const mime = String(item.mime);
		if (mime.startsWith("image/")) return "image";
		if (mime.startsWith("video/")) return "television";
		if (mime.startsWith("audio/")) return "music_note";
		if (/zip|tar|compressed|archive|7z|rar/.test(mime)) return "package_variant";
		if (mime === "application/pdf" || mime.startsWith("text/")) return "file_document";
		return "file";
	}

	function sizeText(bytes) {
		const n = Number(bytes) || 0;
		if (n < 1024) return `${n} B`;
		if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
		if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
		return `${(n / 1024 / 1024 / 1024).toFixed(1)} GB`;
	}

	function detailOf(item) {
		if (item.kind === "text") return `${item.text.length} characters`;
		if (item.kind === "link") return item.url;
		if (item.dir) return "Folder";
		const parts = [root.sizeText(item.size)];
		if (item.width > 0) parts.unshift(`${item.width}×${item.height}`);
		return parts.join(" · ");
	}

	function fileUri(path) {
		return "file://" + String(path).split("/").map(part => encodeURIComponent(part)).join("/");
	}

	// what a drag out of the shelf carries
	function mimeFor(items) {
		const files = items.filter(item => item.kind === "file");
		if (files.length > 0) return { "text/uri-list": files.map(item => root.fileUri(item.path)).join("\r\n") + "\r\n", "text/plain": files.map(item => item.path).join("\n") };
		const links = items.filter(item => item.kind === "link");
		if (links.length > 0) return { "text/uri-list": links.map(item => item.url).join("\r\n") + "\r\n", "text/plain": links.map(item => item.url).join("\n") };
		return { "text/plain": items.map(item => item.text).join("\n\n") };
	}

	// ── actions ──────────────────────────────────────────────────────────
	function copyText(text, label) {
		Quickshell.execDetached(["wl-copy", "--", String(text)]);
		Notifs.pushInternal("done", label, "", { icon: "content_copy", duration: 2000 });
	}

	function copyPath(item) {
		if (item.kind === "file") root.copyText(item.path, "Path copied");
		else if (item.kind === "link") root.copyText(item.url, "Link copied");
		else root.copyText(item.text, "Text copied");
	}

	function copyPaths(items) {
		const values = items.map(item => item.kind === "file" ? item.path : (item.kind === "link" ? item.url : item.text));
		root.copyText(values.join("\n"), items.length === 1 ? "Path copied" : `${items.length} paths copied`);
	}

	// files as files: they paste into file managers and uploads. A single
	// image goes as picture data instead: chats like Teams upload pasted
	// files to cloud storage (and refuse where sharing is locked down) but
	// show pasted pictures inline.
	function copyItems(items) {
		const files = items.filter(item => item.kind === "file");
		if (files.length === 0) {
			if (items.length > 0) root.copyText(root.textOf(items), items.every(item => item.kind === "link") ? "Link copied" : "Text copied");
			return;
		}
		if (files.length === 1 && root.isImage(files[0])) {
			Quickshell.execDetached(["python3", root.helper, "copyimage", files[0].path]);
			Notifs.pushInternal("done", "Image copied", "", { icon: "content_copy", duration: 2000 });
			return;
		}
		const uris = files.map(item => root.fileUri(item.path)).join("\n");
		Quickshell.execDetached(["sh", "-c", 'printf "%s" "$1" | wl-copy --type text/uri-list', "sh", uris]);
		Notifs.pushInternal("done", files.length === 1 ? "File copied" : `${files.length} files copied`, "", { icon: "content_copy", duration: 2000 });
	}

	// what text actions work on: texts and links as they are, files by name
	function textOf(items) {
		return items.map(item => item.kind === "file" ? (item.name || item.path.split("/").pop()) : (item.kind === "link" ? item.url : item.text)).join("\n\n");
	}

	// links open as they are, anything else is searched for
	function search(items) {
		for (const item of items.filter(item => item.kind === "link"))
			Browser.open(item.url);
		const rest = items.filter(item => item.kind !== "link");
		if (rest.length > 0) Browser.search(root.textOf(rest));
	}

	// an action of AiActions on the items, as a temporary chat in the launcher
	function askAi(items, prompt) {
		const text = root.textOf(items.filter(item => item.kind !== "file")).replace(/\r\n/g, "\n");
		if (text.trim() === "") {
			Notifs.pushInternal("error", "No text to work on", "", { icon: "creation" });
			return;
		}
		Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", { aiPrompt: prompt, aiText: text }));
	}

	function open(item) {
		Quickshell.execDetached(["xdg-open", item.kind === "link" ? item.url : item.path]);
	}

	function showInFolder(item) {
		Quickshell.execDetached(["sh", "-c", 'dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems array:string:"$1" string:"" >/dev/null 2>&1 || xdg-open "$(dirname "$2")"',
			"sh", root.fileUri(item.path), item.path]);
	}

	function rename(id, item, name) {
		const clean = String(name).trim().replace(/\//g, "-");
		if (item.kind !== "file" || clean === "" || clean === item.name) return;
		const target = item.path.slice(0, item.path.lastIndexOf("/") + 1) + clean;
		const proc = actionProc.createObject(root, { shelfId: id, replaces: item.id });
		proc.command = ["sh", "-c", '[ ! -e "$2" ] && mv -- "$1" "$2" && printf "%s\\n" "$2"', "sh", item.path, target];
		proc.running = true;
	}

	function trash(id, items) {
		const files = items.filter(item => item.kind === "file");
		if (files.length === 0) return;
		Quickshell.execDetached(["gio", "trash", "--"].concat(files.map(item => item.path)));
		const ids = files.map(item => item.id);
		const shelf = root.shelfById(id);
		if (shelf) root.update(id, { items: shelf.items.filter(item => !ids.includes(item.id)) });
	}

	function sendToPhone(items) {
		for (const item of items) {
			if (item.kind === "file") Phone.shareFile(item.path);
			else if (item.kind === "link") Phone.shareUrl(item.url);
			else Phone.sendText(item.text);
		}
	}

	function extractText(item) {
		if (root.isImage(item)) Screenshot.runOcr(item.path, null, false);
	}

	// a new file made from the items lands in the same shelf
	function zip(id, items) {
		const files = items.filter(item => item.kind === "file");
		if (files.length === 0) return;
		const name = files.length === 1 ? files[0].name.replace(/\.[^.]*$/, "") : `Shelf ${Qt.formatDateTime(new Date(), "yyyy-MM-dd HH.mm")}`;
		const proc = actionProc.createObject(root, { shelfId: id });
		proc.command = ["python3", root.helper, "zip", `${root.stash}/${name}.zip`].concat(files.map(item => item.path));
		proc.running = true;
	}

	// "resize" (50 %), "png", "jpg"
	function convertImage(id, item, action) {
		if (!root.isImage(item)) return;
		const proc = actionProc.createObject(root, { shelfId: id });
		proc.command = ["python3", root.helper, "image", action, item.path, root.stash];
		proc.running = true;
	}

	function setOption(option, on) {
		if (option === "shake") root.shake = !!on;
		else if (option === "openOnNew") root.openOnNew = !!on;
		else if (option === "collectShots") root.collectShots = !!on;
		root.save();
	}

	// ── screenshot series ────────────────────────────────────────────────
	function shotCopied(path) {
		if (!root.collectShots) return;
		const now = Date.now();
		const follows = now - root.lastShotAt < root.seriesGap;
		root.lastShotAt = now;
		// the capture lives in tmpfs only as long as its toast: keep a copy
		const target = `${root.stash}/Screenshot ${Qt.formatDateTime(new Date(), "yyyy-MM-dd HH.mm.ss.zzz")}.png`;
		const proc = keeper.createObject(root, { target: target, follows: follows });
		proc.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && cp "$1" "$2"', "sh", path, target];
		proc.running = true;
	}

	function shotKept(path, follows) {
		if (!follows) {
			// a new series may start with this one; an earlier lonely shot goes
			if (root.pendingShot !== "") Quickshell.execDetached(["rm", "-f", root.pendingShot]);
			root.pendingShot = path;
			root.seriesShelf = "";
			return;
		}
		const items = [root.pendingShot, path].filter(p => p !== "").map(p => ({ kind: "file", path: p }));
		root.pendingShot = "";
		const shelf = root.shelfById(root.seriesShelf);
		if (shelf) {
			root.addItems(shelf.id, items);
			root.hidden = false;
		} else {
			root.seriesShelf = root.create(items, "Screenshots");
		}
	}

	Connections {
		target: Screenshot
		function onShotCopied(path) {
			root.shotCopied(path);
		}
	}

	Component {
		id: keeper

		Process {
			id: proc

			property string target: ""
			property bool follows: false

			onExited: exitCode => {
				if (exitCode === 0) root.shotKept(proc.target, proc.follows);
				proc.destroy();
			}
		}
	}

	// ── watched folders ──────────────────────────────────────────────────
	function arrived(path) {
		if (!Plugins.on("shelves")) return;
		const target = root.shelves[root.shelves.length - 1] ?? null;
		if (target) {
			root.addItems(target.id, [{ kind: "file", path: path }]);
			if (!root.openOnNew) return;
			root.hidden = false;
			return;
		}
		if (!root.openOnNew) return;
		root.create([{ kind: "file", path: path }]);
	}

	// ── persistence ──────────────────────────────────────────────────────
	function save() {
		if (root.loaded) saveDelay.restart();
	}

	Timer {
		id: saveDelay

		interval: 800
		onTriggered: store.setText(JSON.stringify({
			shelves: root.shelves,
			recent: root.recent,
			shake: root.shake,
			openOnNew: root.openOnNew,
			collectShots: root.collectShots
		}))
	}

	FileView {
		id: store

		path: Paths.stateFile("shelf.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.shelves = Array.isArray(data.shelves) ? data.shelves : [];
				root.recent = Array.isArray(data.recent) ? data.recent : [];
				root.shake = data.shake !== false;
				root.openOnNew = data.openOnNew !== false;
				root.collectShots = data.collectShots === true;
			} catch (error) {}
			root.loaded = true;
			root.prune();
			// files may have moved while the shell was away; links from before
			// there were previews get theirs
			for (const shelf of root.shelves) {
				const paths = shelf.items.filter(item => item.kind === "file").map(item => item.path);
				if (paths.length > 0) root.describe(shelf.id, paths);
				root.previewLinks(shelf.id, shelf.items.filter(item => item.kind === "link" && item.preview === undefined));
			}
		}
		onLoadFailed: root.loaded = true
	}

	// stash files that no shelf (open or recent) points at any more
	function prune() {
		const kept = [];
		for (const shelf of root.shelves.concat(root.recent))
			for (const item of shelf.items ?? [])
				for (const path of [item.kind === "file" ? item.path : "", item.preview ?? ""])
					if (path !== "" && path.startsWith(root.stash)) kept.push(path);
		Quickshell.execDetached(["python3", root.helper, "prune", root.stash].concat(kept));
	}

	// ── helpers ──────────────────────────────────────────────────────────
	Component {
		id: describer

		Process {
			id: proc

			property string shelfId: ""
			property var paths: []

			stdout: StdioCollector {
				onStreamFinished: root.applyDescription(proc.shelfId, proc.paths, text)
			}
			onExited: proc.destroy()
		}
	}

	Component {
		id: linkPreviewer

		Process {
			id: proc

			property string shelfId: ""

			stdout: StdioCollector {
				onStreamFinished: root.applyLinkPreview(proc.shelfId, text)
			}
			onExited: proc.destroy()
		}
	}

	// actions that produce a file: it is added to the shelf (or replaces an item)
	Component {
		id: actionProc

		Process {
			id: proc

			property string shelfId: ""
			property string replaces: ""

			stdout: StdioCollector {
				onStreamFinished: {
					const path = String(text).trim().split("\n").pop();
					if (path === "") return;
					if (proc.replaces !== "") {
						const shelf = root.shelfById(proc.shelfId);
						if (shelf) root.update(proc.shelfId, { items: shelf.items.map(item => item.id === proc.replaces ? Object.assign({}, item, { path: path, name: path.split("/").pop() }) : item) });
					} else {
						root.addItems(proc.shelfId, [{ kind: "file", path: path }]);
					}
				}
			}
			onExited: exitCode => {
				if (exitCode !== 0) Notifs.pushInternal("error", "Shelf action failed", "", { icon: "alert_circle" });
				proc.destroy();
			}
		}
	}

	Process {
		id: pasteProc

		property string shelfId: ""
		command: ["python3", root.helper, "clip", root.stash]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.addItems(pasteProc.shelfId, JSON.parse(text));
				} catch (error) {}
			}
		}
	}

	Process {
		id: clipProc

		command: ["python3", root.helper, "clip", root.stash]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const items = JSON.parse(text);
					if (items.length > 0) root.create(items);
				} catch (error) {}
			}
		}
	}

	Process {
		id: watcher

		running: Plugins.on("shelves") && root.watchDirs.length > 0
		command: ["python3", root.helper, "watch"].concat(root.watchDirs)
		stdout: SplitParser {
			onRead: line => root.arrived(line)
		}
	}

	Process {
		id: shaker

		running: Plugins.on("drop-commands") && root.shake
		command: ["python3", root.helper, "shake"]
		stdout: SplitParser {
			onRead: line => {
				if (line === "shake") root.shaken();
				else if (line === "noaccess") root.shakeAccess = false;
			}
		}
	}
}
