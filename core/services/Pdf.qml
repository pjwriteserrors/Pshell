pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The shell's PDF viewer and editor (plugin "pdf", `pdf-default` makes it
// what PDFs open in): a window of its own (core/views/pdf/). QtQuick.Pdf
// (PDFium) draws the pages inside the shell's scene, so they can glide,
// fade from a small picture to a sharp one and be marked live; only the
// views import it. What is done to a document is a recipe – data, shown
// at once by the window and written only on saving by the helper
// (scripts/pdf/pdf.py, lines of JSON like the video's): pages in a new
// order, turned, cropped, merged, the marks and notes as real annotations,
// forms, signatures, texts, blacked-out words, and what is done to the
// whole file at the end. The document lives here, not in the window, so
// ipc, the launcher, Files and the radial menu steer the same thing.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("pdf")
	readonly property string helperScript: `${Paths.scripts}/pdf/pdf.py`
	// the width of a page's small picture (PdfPage.qml), shared by the thumbnails and the glow
	readonly property int smallPx: 320
	// pictures PDFium is drawing now: it draws one at a time and holds every other PDF call meanwhile
	property int rendering: 0
	// the file as it is read now (a new one, or written again)
	readonly property string docKey: `${root.path}#${root.generation}`
	property var drawing: new Set()
	// not a property of its own: a binding that takes a ticket must not follow the count
	property var tickets: ({ n: 0 })

	function ticket() {
		root.tickets.n += 1;
		return root.tickets.n;
	}
	// a picture loading or not (also when it goes away), by its ticket
	function rendered(ticket, busy) {
		if (busy) root.drawing.add(ticket);
		else root.drawing.delete(ticket);
		root.rendering = root.drawing.size;
	}
	readonly property string windowTitle: root.current ? `${root.nameOf(root.path)} – PDF` : "PDF"

	function isPdf(path) {
		return /\.pdf$/i.test(String(path || ""));
	}

	function plainPath(path) {
		let p = String(path || "").replace(/^file:\/\//, "");
		try {
			p = decodeURIComponent(p);
		} catch (error) {}
		return p;
	}

	function fileUrl(path) {
		return path ? "file://" + String(path).split("/").map(part => encodeURIComponent(part)).join("/") : "";
	}

	function nameOf(path) {
		const name = String(path).slice(String(path).lastIndexOf("/") + 1);
		return name.replace(/\.pdf$/i, "");
	}

	function folderOf(path) {
		return String(path).slice(0, Math.max(1, String(path).lastIndexOf("/")));
	}

	function formatBytes(bytes) {
		const b = Number(bytes) || 0;
		if (b < 1024) return `${b} B`;
		if (b < 1024 * 1024) return `${Math.round(b / 1024)} KB`;
		return `${(b / 1024 / 1024).toFixed(b < 10 * 1024 * 1024 ? 1 : 0)} MB`;
	}

	// ── what is open ───────────────────────────────────────────────────────
	property bool windowOpen: false
	property string path: ""
	readonly property bool current: root.path !== ""
	// what probe said of it
	property var meta: null
	readonly property string title: root.meta?.title && String(root.meta.title).length > 2 ? String(root.meta.title) : root.nameOf(root.path)
	// the PDFs of its folder, in order
	property var list: []
	readonly property int listIndex: root.list.indexOf(root.path)
	property string password: ""
	// asked for a password (the window shows a field); `wrong` after a bad one
	property bool locked: false
	property bool wrongPassword: false
	property string error: ""
	// grows when the file under the window changed (saved): the views load it again
	property int generation: 0
	property bool loading: false

	// ── how it is looked at ────────────────────────────────────────────────
	// index into `pages`; zoom 1 = 100 % (a point is 96/72 px); fit "width" | "page" | "" (free)
	property int page: 0
	property real zoom: 1
	property string fit: "width"
	// "scroll" one under the other | "two" side by side | "book" (the first alone, then pairs)
	property string layout: root.setting("layout", "scroll")
	property bool night: false
	property bool presenting: false
	// "" | "pages" | "outline" | "notes" | "search" | "files"
	property string sidebar: root.setting("sidebar", "")
	// the reader's text selection: { page: id, text, quads: [[x,y,w,h]] } or null
	property var selection: null
	readonly property string selectionText: root.selection?.text ?? ""
	property string searchText: ""
	property int searchCount: 0
	property int searchCurrent: -1
	signal searchStep(int delta)

	// ── editing ────────────────────────────────────────────────────────────
	// "read" | "edit"; tool: "" | annotate | pages | text | forms | sign | redact | stamp | layout | crop |
	// export | security | info | compare | scan | ai
	property string mode: "read"
	readonly property bool editing: root.mode === "edit"
	property string tool: ""
	// the annotate tool's pen: select | highlight | underline | strike | squiggly | pen | marker | eraser |
	// rect | ellipse | line | arrow | note | textbox | stamp | link | field | text | whiteout | image | signature | redact
	property string draw: "select"
	property var style: ({ color: "#ffd54f", width: 2, opacity: 1, size: 12, fill: "" })
	property var selected: []
	property var selectedPages: []
	property var recipe: root.blankRecipe()
	readonly property var pages: root.recipe.pages ?? []
	readonly property int pageCount: root.pages.length
	readonly property var items: root.recipe.items ?? []
	property var undoStack: []
	property var redoStack: []
	property var undoLabels: []
	readonly property bool canUndo: root.undoStack.length > 0
	readonly property bool canRedo: root.redoStack.length > 0
	// the recipe as the file is: anything else is unsaved
	property string baseline: ""
	readonly property bool dirty: root.current && root.baseline !== "" && JSON.stringify(root.recipe) !== root.baseline
	// the file's form fields (helper `strip`), page as an index into the source
	property var fields: []
	// the file's own outline, read once
	property var fileOutline: []
	readonly property var outlineNow: root.recipe.outline ?? root.fileOutline
	property bool stripped: false
	property bool saving: false

	function blankRecipe() {
		return { v: 1, next: 1, sources: {}, pages: [], items: [], forms: {}, outline: null, meta: null, attach: { add: [], remove: [] },
			doc: { watermark: null, numbers: null, header: null, footer: null, bates: null },
			finish: { grayscale: false, flatten: false, compress: "", pdfa: false, sanitize: false, protect: null, unlock: false, ocr: null, sign: null } };
	}

	function clone(value) {
		return JSON.parse(JSON.stringify(value));
	}

	// the file a source is drawn from: the working copy once its marks were taken out
	function sourcePath(key) {
		const s = root.recipe.sources?.[key];
		return s ? (s.work || s.path) : "";
	}

	readonly property var sourceKeys: Object.keys(root.recipe.sources ?? {})

	function pageById(id) {
		return root.pages.find(p => p.id === id) ?? null;
	}

	function indexOf(id) {
		return root.pages.findIndex(p => p.id === id);
	}

	function itemsOf(pageId) {
		return root.items.filter(item => item.page === pageId);
	}

	function itemById(id) {
		return root.items.find(item => item.id === id) ?? null;
	}

	// a page's size as its source has it (page space, before crop and turn): sizes come from probe
	property var sizes: ({})

	function baseSize(p) {
		if (!p) return Qt.size(595.3, 841.9);
		if (p.blank) return Qt.size(p.blank[0], p.blank[1]);
		if (p.image) return Qt.size(p.size?.[0] ?? 595.3, p.size?.[1] ?? 841.9);
		const s = root.sizes[p.src]?.[p.n];
		return s ? Qt.size(s[0], s[1]) : Qt.size(595.3, 841.9);
	}

	// as it is shown: cropped, then turned
	function sizeOf(p) {
		const b = root.baseSize(p);
		const w = p?.crop ? p.crop[2] : b.width, h = p?.crop ? p.crop[3] : b.height;
		return (p?.rot ?? 0) % 180 === 90 ? Qt.size(h, w) : Qt.size(w, h);
	}

	// ── settings ───────────────────────────────────────────────────────────
	property var settings: ({ layout: "scroll", sidebar: "", nightAuto: false, resume: true, barsFade: true, glow: true, hoverLinks: true,
		smooth: true, saveMode: "replace", author: "", signatures: [], stamps: [], shellAccent: false, presenterLaser: true, autosave: false,
		ocrLang: "deu+eng", defaultColor: "#ffd54f", speakVoice: "" })

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		settingsSave.restart();
	}

	Timer {
		id: settingsSave

		interval: 300
		onTriggered: settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n")
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("pdf.json")
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
		}
	}

	onLayoutChanged: if (root.layout !== root.setting("layout", "scroll")) root.setSetting("layout", root.layout)
	onSidebarChanged: if (root.sidebar !== root.setting("sidebar", "")) root.setSetting("sidebar", root.sidebar)

	// ── opening ────────────────────────────────────────────────────────────
	// open(path, { page, origin: { screen, x, y, w, h, image }, edit, tool, password, search, list })
	property var origin: null
	// asked for while it loads: applied when the pages are known
	property var pending: null

	function open(path, options) {
		if (!root.enabled || !path) return;
		const o = options || {};
		path = root.plainPath(path);
		root.origin = o.origin ?? null;
		if (o.list && o.list.length > 0) root.list = o.list.map(p => root.plainPath(p));
		else if (!root.list.includes(path)) {
			root.list = [path];
			root.request("folder", { path: path }, data => {
				if (data?.paths?.length > 0 && data.paths.includes(root.path)) root.list = data.paths;
			});
		}
		root.pending = { page: o.page ?? -1, edit: !!o.edit || !!o.tool, tool: o.tool ?? "", search: o.search ?? "" };
		if (root.path === path && root.meta && !root.locked && !o.password) {
			root.showWindow();
			root.takePending();
			return;
		}
		root.load(path, o.password ?? "");
		root.showWindow();
	}

	function openMany(paths) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => root.isPdf(p));
		if (list.length === 0) return;
		if (list.length === 1) return root.open(list[0]);
		// several at once: the first, the others merged behind it in the editor
		root.open(list[0], { list: list, edit: true, tool: "pages" });
		root.pendingMerge = list.slice(1);
	}

	property var pendingMerge: []

	function edit(path, tool) {
		root.open(path || root.path, { edit: true, tool: tool || "" });
	}

	function load(path, password) {
		root.keepState();
		root.leaveFile();
		root.path = path;
		root.password = password || "";
		root.meta = null;
		root.locked = false;
		root.wrongPassword = false;
		root.error = "";
		root.loading = true;
		root.stripped = false;
		root.fields = [];
		root.fileOutline = [];
		root.selection = null;
		root.selected = [];
		root.selectedPages = [];
		root.undoStack = [];
		root.redoStack = [];
		root.undoLabels = [];
		root.searchText = "";
		root.remember(path);
		root.request("probe", { path: path, password: root.password }, (data, error, code) => {
			if (root.path !== path) return;
			root.loading = false;
			if (!data) {
				if (code === "password" || /password/i.test(error)) {
					root.wrongPassword = root.password !== "";
					root.locked = true;
					return;
				}
				root.error = error || "This PDF cannot be read";
				return;
			}
			if (data.locked) {
				root.wrongPassword = root.password !== "";
				root.locked = true;
				return;
			}
			root.meta = data;
			root.sizes = { a: data.sizes || [] };
			root.startRecipe(data);
		});
	}

	function unlockWith(password) {
		if (root.current) root.load(root.path, password);
	}

	// the recipe of a file just read: its pages as they are, or what was left unsaved
	function startRecipe(data) {
		const fresh = root.blankRecipe();
		fresh.sources = { a: { path: root.path, password: root.password } };
		fresh.pages = (data.sizes || []).map((s, i) => ({ id: `p${i + 1}`, src: "a", n: i, rot: 0, crop: null }));
		fresh.next = fresh.pages.length + 1;
		root.baseline = JSON.stringify(fresh);
		const kept = root.files_[root.path];
		const unsaved = kept?.recipe && kept.bytes === data.bytes && kept.modified === data.modified ? kept.recipe : null;
		root.recipe = unsaved ? Object.assign(root.blankRecipe(), unsaved) : fresh;
		// keep the user's own source passwords up to date
		if (unsaved) root.recipe.sources.a = Object.assign({}, root.recipe.sources.a, { path: root.path, password: root.password, work: "" });
		// pages of other files merged before: their sizes again
		for (const key of Object.keys(root.recipe.sources))
			if (key !== "a") root.probeSource(key);
		// the marks the file has are taken out of the drawn copy when edited (or kept edits need them)
		if (unsaved && root.items.some(item => item.orig)) root.strip(true);
		root.generation += 1;
		const view = kept?.view;
		root.page = 0;
		if (view && root.setting("resume", true)) {
			root.zoom = view.zoom ?? 1;
			root.fit = view.fit ?? "width";
			root.night = !!view.night;
			if (view.page > 0 && view.page < root.pageCount) root.page = view.page;
			root.resumedFrom = view.page > 2 ? view.page : -1;
		} else {
			root.fit = "width";
			root.zoom = 1;
			root.night = root.setting("nightAuto", false) && Theme.dark;
			root.resumedFrom = -1;
		}
		root.takePending();
		if (root.pendingMerge.length > 0) {
			const merge = root.pendingMerge;
			root.pendingMerge = [];
			for (const p of merge) root.insertFile(p, -1);
		}
		root.opened(root.path);
	}

	// where it was left last (a chip offers the start instead)
	property int resumedFrom: -1

	signal opened(string path)

	function takePending() {
		const p = root.pending;
		root.pending = null;
		if (!p) return;
		if (p.page >= 0) root.goTo(Math.min(root.pageCount - 1, p.page));
		if (p.edit) root.startEditing(p.tool);
		if (p.search) {
			root.sidebar = "search";
			root.searchText = p.search;
		}
	}

	function probeSource(key) {
		const s = root.recipe.sources[key];
		if (!s) return;
		root.request("probe", { path: s.work || s.path, password: s.password || "" }, data => {
			if (!data) return;
			root.sizes = Object.assign({}, root.sizes, { [key]: data.sizes || [] });
		});
	}

	// the file's annotations come out of the copy that is drawn and become the recipe's items,
	// so they can be moved, changed and removed; its fields and outline are read at the same time
	function strip(keepItems) {
		if (root.stripped || !root.current) return;
		root.stripped = true;
		const path = root.path;
		root.request("strip", { path: path, password: root.password }, data => {
			if (!data || root.path !== path) return;
			const source = Object.assign({}, root.recipe.sources.a, { work: data.path || "" });
			const next = Object.assign({}, root.recipe, { sources: Object.assign({}, root.recipe.sources, { a: source }) });
			root.fields = data.fields || [];
			root.fileOutline = root.outlineToIds(data.outline || []);
			if (!keepItems) {
				const idOf = n => root.pages.find(p => p.src === "a" && p.n === n)?.id ?? "";
				let counter = next.next || 1;
				const items = (data.items || []).map(item => Object.assign({}, item, { id: `i${counter++}`, page: idOf(item.page) })).filter(item => item.page);
				next.items = items.concat(next.items || []);
				next.next = counter;
			}
			// the same file as before, only drawn from elsewhere: not an edit
			const base = JSON.parse(root.baseline);
			base.sources.a.work = source.work;
			if (!keepItems) {
				base.items = next.items.filter(item => item.orig);
				base.next = next.next;
			}
			root.baseline = JSON.stringify(base);
			root.recipe = next;
			root.generation += 1;
		});
	}

	function outlineToIds(list) {
		const idOf = n => root.pages.find(p => p.src === "a" && p.n === n)?.id ?? "";
		return (list || []).map(entry => ({ title: entry.title, page: idOf(entry.page), y: entry.y ?? 0, children: root.outlineToIds(entry.children) }));
	}

	// the outline before editing: read without taking anything out
	function readOutline() {
		if (!root.current || root.fileOutline.length > 0) return;
		const path = root.path;
		root.request("strip", { path: path, password: root.password, outlineOnly: true }, data => {
			if (data && root.path === path) {
				root.fileOutline = root.outlineToIds(data.outline || []);
				if (root.fields.length === 0) root.fields = data.fields || [];
			}
		});
	}

	function leaveFile() {
		root.mode = "read";
		root.tool = "";
		root.presenting = false;
	}

	function next() {
		if (root.listIndex >= 0 && root.listIndex < root.list.length - 1) root.open(root.list[root.listIndex + 1]);
	}

	function previous() {
		if (root.listIndex > 0) root.open(root.list[root.listIndex - 1]);
	}

	// ── moving around ──────────────────────────────────────────────────────
	// the reader follows `page`; goTo asks it to scroll there (y in page space of that page)
	signal jump(int index, real y)

	function goTo(index, y) {
		if (root.pageCount === 0) return;
		const i = Math.max(0, Math.min(root.pageCount - 1, index));
		root.page = i;
		root.jump(i, y ?? -1);
	}

	function nextPage() {
		root.goTo(root.page + (root.layout === "scroll" ? 1 : 2));
	}

	function previousPage() {
		root.goTo(root.page - (root.layout === "scroll" ? 1 : 2));
	}

	function setZoom(z) {
		root.fit = "";
		root.zoom = Math.max(0.1, Math.min(16, z));
	}

	function zoomBy(factor) {
		root.setZoom(root.zoom * factor);
	}

	function cycleLayout() {
		root.layout = root.layout === "scroll" ? "two" : (root.layout === "two" ? "book" : "scroll");
	}

	// ── the recipe ─────────────────────────────────────────────────────────
	// a step done: kept, and can be taken back
	function commit(next, label) {
		root.undoStack = root.undoStack.concat([JSON.stringify(root.recipe)]).slice(-300);
		root.undoLabels = root.undoLabels.concat([label || "Edit"]).slice(-300);
		root.redoStack = [];
		root.recipe = next;
		keepSoon.restart();
	}

	// a step still moving (a dragged handle): shown, kept only by `commit`
	function preview(next) {
		root.recipe = next;
	}

	function undo() {
		if (root.undoStack.length === 0) return;
		root.redoStack = root.redoStack.concat([JSON.stringify(root.recipe)]);
		root.recipe = JSON.parse(root.undoStack[root.undoStack.length - 1]);
		root.undoStack = root.undoStack.slice(0, -1);
		const label = root.undoLabels[root.undoLabels.length - 1] || "";
		root.undoLabels = root.undoLabels.slice(0, -1);
		root.redoLabels = root.redoLabels.concat([label]);
		root.selected = root.selected.filter(id => root.itemById(id));
		keepSoon.restart();
		if (label) root.say(`Undone: ${label}`, "undo");
	}

	property var redoLabels: []

	function redo() {
		if (root.redoStack.length === 0) return;
		root.undoStack = root.undoStack.concat([JSON.stringify(root.recipe)]);
		root.recipe = JSON.parse(root.redoStack[root.redoStack.length - 1]);
		root.redoStack = root.redoStack.slice(0, -1);
		const label = root.redoLabels[root.redoLabels.length - 1] || "Edit";
		root.redoLabels = root.redoLabels.slice(0, -1);
		root.undoLabels = root.undoLabels.concat([label]);
		keepSoon.restart();
	}

	// everything back as the file is
	function revert() {
		if (!root.dirty) return;
		root.commit(JSON.parse(root.baseline), "Back to the saved file");
	}

	function newId(next, prefix) {
		const id = `${prefix}${next.next || 1}`;
		next.next = (next.next || 1) + 1;
		return id;
	}

	function startEditing(tool) {
		if (!root.current || root.locked) return;
		root.mode = "edit";
		root.presenting = false;
		if (tool !== undefined) root.tool = tool;
		if (!root.stripped && ((root.meta?.annots ?? 0) > 0 || (root.meta?.forms ?? 0) > 0)) root.strip(false);
	}

	function stopEditing() {
		root.mode = "read";
		root.tool = "";
		root.draw = "select";
		root.selected = [];
		root.keepState();
	}

	function toggleEditing() {
		if (root.editing) root.stopEditing();
		else root.startEditing(root.tool || "annotate");
	}

	function useTool(name) {
		if (!root.editing) root.startEditing(name);
		else root.tool = root.tool === name ? "" : name;
		if (name === "forms" || name === "info") root.readOutline();
	}

	// ── items ──────────────────────────────────────────────────────────────
	function addItem(item, label) {
		const next = root.clone(root.recipe);
		const made = Object.assign({ author: root.setting("author", "") }, item, { id: root.newId(next, "i") });
		next.items.push(made);
		root.commit(next, label || root.itemLabel(made.kind));
		root.selected = [made.id];
		return made.id;
	}

	function itemLabel(kind) {
		return ({ highlight: "Marked", underline: "Underlined", strike: "Struck out", squiggly: "Underlined", ink: "Drawn", rect: "Box",
			ellipse: "Circle", line: "Line", arrow: "Arrow", note: "Note", textbox: "Text box", stamp: "Stamp", link: "Link", field: "Field",
			text: "Text changed", whiteout: "Covered", image: "Picture", signature: "Signed", redact: "Blacked out" })[kind] || "Edit";
	}

	// fields of an item changed; `live` while it is still dragged
	function updateItem(id, fields, label, live) {
		const next = root.clone(root.recipe);
		const item = next.items.find(i => i.id === id);
		if (!item) return;
		Object.assign(item, fields);
		if (live) root.preview(next);
		else root.commit(next, label || "Changed");
	}

	// a drag that was previewed is kept: the step is taken from where it started
	function commitFrom(before, label) {
		root.undoStack = root.undoStack.concat([before]).slice(-300);
		root.undoLabels = root.undoLabels.concat([label || "Moved"]).slice(-300);
		root.redoStack = [];
		keepSoon.restart();
	}

	function removeItems(ids) {
		if (!ids || ids.length === 0) return;
		const next = root.clone(root.recipe);
		next.items = next.items.filter(item => !ids.includes(item.id));
		root.commit(next, ids.length === 1 ? "Removed" : `${ids.length} removed`);
		root.selected = root.selected.filter(id => !ids.includes(id));
	}

	function duplicateItems(ids) {
		const next = root.clone(root.recipe);
		const made = [];
		for (const id of ids) {
			const item = next.items.find(i => i.id === id);
			if (!item) continue;
			const copy = root.clone(item);
			copy.id = root.newId(next, "i");
			delete copy.orig;
			root.shiftItem(copy, 12, 12);
			next.items.push(copy);
			made.push(copy.id);
		}
		root.commit(next, "Duplicated");
		root.selected = made;
	}

	function shiftItem(item, dx, dy) {
		if (item.rect) item.rect = [item.rect[0] + dx, item.rect[1] + dy, item.rect[2], item.rect[3]];
		if (item.at) item.at = [item.at[0] + dx, item.at[1] + dy];
		if (item.points) item.points = item.points.map(p => [p[0] + dx, p[1] + dy]);
		if (item.strokes) item.strokes = item.strokes.map(s => s.map(p => [p[0] + dx, p[1] + dy]));
		if (item.quads) item.quads = item.quads.map(q => [q[0] + dx, q[1] + dy, q[2], q[3]]);
		if (item.cover) item.cover = [item.cover[0] + dx, item.cover[1] + dy, item.cover[2], item.cover[3]];
	}

	// the text the reader has selected, marked (highlight, underline, strike, squiggly, redact, note)
	function markSelection(kind, extra) {
		const s = root.selection;
		if (!s || !s.quads || s.quads.length === 0) return "";
		if (!root.editing) root.startEditing("annotate");
		const color = kind === "highlight" ? (root.style.color || "#ffd54f") : (kind === "redact" ? "#000000" : (kind === "strike" ? "#e53935" : "#1e88e5"));
		const item = kind === "redact" ? { kind: "redact", page: s.page, quads: s.quads } : { kind: kind, page: s.page, quads: s.quads, color: color, opacity: kind === "highlight" ? 0.45 : 1, text: s.text };
		const id = root.addItem(Object.assign(item, extra || {}));
		root.selection = null;
		root.clearSelection();
		return id;
	}

	signal clearSelection()

	// ── pages ──────────────────────────────────────────────────────────────
	function movePages(ids, toIndex) {
		const next = root.clone(root.recipe);
		const moving = next.pages.filter(p => ids.includes(p.id));
		if (moving.length === 0) return;
		const before = next.pages.slice(0, toIndex).filter(p => !ids.includes(p.id)).length;
		const rest = next.pages.filter(p => !ids.includes(p.id));
		rest.splice(before, 0, ...moving);
		if (JSON.stringify(rest.map(p => p.id)) === JSON.stringify(root.pages.map(p => p.id))) return;
		next.pages = rest;
		root.commit(next, moving.length === 1 ? "Page moved" : `${moving.length} pages moved`);
	}

	function rotatePages(ids, deg) {
		const next = root.clone(root.recipe);
		for (const p of next.pages)
			if (ids.includes(p.id)) p.rot = (((p.rot || 0) + deg) % 360 + 360) % 360;
		root.commit(next, ids.length === 1 ? "Page turned" : `${ids.length} pages turned`);
	}

	function deletePages(ids) {
		if (!ids || ids.length === 0 || ids.length >= root.pageCount) {
			if (ids && ids.length >= root.pageCount) root.say("A PDF keeps at least one page", "alert_circle_outline");
			return;
		}
		const next = root.clone(root.recipe);
		next.pages = next.pages.filter(p => !ids.includes(p.id));
		next.items = next.items.filter(item => !ids.includes(item.page));
		root.commit(next, ids.length === 1 ? "Page removed" : `${ids.length} pages removed`);
		root.selectedPages = [];
		if (root.page >= root.pageCount) root.page = root.pageCount - 1;
	}

	function duplicatePages(ids) {
		const next = root.clone(root.recipe);
		const out = [];
		for (const p of next.pages) {
			out.push(p);
			if (!ids.includes(p.id)) continue;
			const copy = root.clone(p);
			copy.id = root.newId(next, "p");
			out.push(copy);
			for (const item of root.items.filter(i => i.page === p.id)) {
				const c = root.clone(item);
				c.id = root.newId(next, "i");
				c.page = copy.id;
				delete c.orig;
				next.items.push(c);
			}
		}
		next.pages = out;
		root.commit(next, ids.length === 1 ? "Page doubled" : `${ids.length} pages doubled`);
	}

	// pages put in at an index (-1 the end): recipe page objects without ids
	function insertPages(atIndex, list, label) {
		const next = root.clone(root.recipe);
		const at = atIndex < 0 || atIndex > next.pages.length ? next.pages.length : atIndex;
		const made = list.map(p => Object.assign({ rot: 0, crop: null }, p, { id: root.newId(next, "p") }));
		next.pages.splice(at, 0, ...made);
		root.commit(next, label || (made.length === 1 ? "Page added" : `${made.length} pages added`));
		root.goTo(at);
		return made.map(p => p.id);
	}

	function insertBlank(atIndex, size) {
		const s = size || [root.sizeOf(root.pages[Math.max(0, Math.min(root.pageCount - 1, atIndex - 1))]).width, root.sizeOf(root.pages[Math.max(0, Math.min(root.pageCount - 1, atIndex - 1))]).height];
		return root.insertPages(atIndex, [{ blank: [s[0] || 595.3, s[1] || 841.9] }], "Empty page added");
	}

	function insertImage(path, atIndex) {
		const p = root.plainPath(path);
		return root.insertPages(atIndex, [{ image: p, size: [595.3, 841.9] }], "Picture added as a page");
	}

	// another PDF's pages (all, or some indexes) in this one
	function insertFile(path, atIndex, only, password) {
		const p = root.plainPath(path);
		if (!root.isPdf(p)) {
			if (/\.(png|jpe?g|webp|tiff?|bmp|gif|heic|avif)$/i.test(p)) return root.insertImage(p, atIndex);
			// an office file or the like: made a PDF first
			root.startJob("tool", { tool: "officetopdf", paths: [p], options: {} }, "Making a PDF of it", result => {
				if (result?.created?.length > 0) root.insertFile(result.created[0], atIndex);
			});
			return [];
		}
		root.request("probe", { path: p, password: password || "" }, data => {
			if (!data) return root.say("That PDF cannot be read", "alert_circle_outline");
			if (data.locked) return root.passwordFor(p, given => root.insertFile(p, atIndex, only, given));
			let key = Object.keys(root.recipe.sources).find(k => root.recipe.sources[k].path === p && !root.recipe.sources[k].work);
			const next = root.clone(root.recipe);
			if (!key) {
				let code = 98;
				while (next.sources[String.fromCharCode(code)]) code += 1;
				key = String.fromCharCode(code);
				next.sources[key] = { path: p, password: password || "" };
			}
			root.sizes = Object.assign({}, root.sizes, { [key]: data.sizes || [] });
			const indexes = only && only.length > 0 ? only : (data.sizes || []).map((s, i) => i);
			const at = atIndex < 0 || atIndex > next.pages.length ? next.pages.length : atIndex;
			const made = indexes.map(n => ({ id: root.newId(next, "p"), src: key, n: n, rot: 0, crop: null }));
			next.pages.splice(at, 0, ...made);
			root.commit(next, `${root.nameOf(p)} added`);
			root.say(`${made.length} ${made.length === 1 ? "page" : "pages"} of ${root.nameOf(p)} added`, "file_document_multiple_outline");
			root.goTo(at);
		});
		return [];
	}

	// a password asked for a file put in (the window answers with `given`)
	signal passwordWanted(string path)
	property var passwordAnswers: ({})

	function passwordFor(path, done) {
		root.passwordAnswers[path] = done;
		root.passwordWanted(path);
	}

	function answerPassword(path, given) {
		const done = root.passwordAnswers[path];
		delete root.passwordAnswers[path];
		if (done && given) done(given);
	}

	function cropPages(ids, rect) {
		const next = root.clone(root.recipe);
		for (const p of next.pages)
			if (ids.includes(p.id)) p.crop = rect ? rect.slice() : null;
		root.commit(next, rect ? "Cropped" : "Crop taken off");
	}

	// the pages taken out as a file of their own, beside this one
	function extractPages(ids, done) {
		const next = root.clone(root.recipe);
		next.pages = next.pages.filter(p => ids.includes(p.id));
		next.items = next.items.filter(item => ids.includes(item.page));
		next.outline = [];
		const name = ids.length === 1 ? `page ${root.indexOf(ids[0]) + 1}` : `pages ${root.rangeText(ids)}`;
		root.startJob("apply", { recipe: next, out: `${root.folderOf(root.path)}/${root.nameOf(root.path)} (${name}).pdf`, mode: "copy" }, "Taking pages out", result => {
			if (result?.path) root.tellMade(result.path, "Pages taken out");
			if (done) done(result?.path ?? "");
		});
	}

	// "1–3, 7": the indexes of pages, read by people
	function rangeText(ids) {
		const numbers = ids.map(id => root.indexOf(id) + 1).filter(n => n > 0).sort((a, b) => a - b);
		const parts = [];
		let start = -1, last = -1;
		for (const n of numbers) {
			if (start < 0) start = last = n;
			else if (n === last + 1) last = n;
			else {
				parts.push(start === last ? `${start}` : `${start}–${last}`);
				start = last = n;
			}
		}
		if (start > 0) parts.push(start === last ? `${start}` : `${start}–${last}`);
		return parts.join(", ");
	}

	// a file cut in parts: after each of these pages a new one starts
	function splitAfter(ids, done) {
		const cuts = ids.map(id => root.indexOf(id)).filter(i => i >= 0 && i < root.pageCount - 1).sort((a, b) => a - b);
		if (cuts.length === 0) return root.say("Choose the pages after which a new file begins", "information_outline");
		const parts = [];
		let start = 0;
		for (const c of cuts.concat([root.pageCount - 1])) {
			parts.push(root.pages.slice(start, c + 1).map(p => p.id));
			start = c + 1;
		}
		let made = [];
		let left = parts.length;
		parts.forEach((part, i) => {
			const next = root.clone(root.recipe);
			next.pages = next.pages.filter(p => part.includes(p.id));
			next.items = next.items.filter(item => part.includes(item.page));
			next.outline = [];
			root.startJob("apply", { recipe: next, out: `${root.folderOf(root.path)}/${root.nameOf(root.path)} (part ${i + 1}).pdf`, mode: "copy" }, `Part ${i + 1} of ${parts.length}`, result => {
				if (result?.path) made.push(result.path);
				left -= 1;
				if (left === 0) {
					root.say(`Cut in ${made.length} files`, "content_cut");
					if (done) done(made);
				}
			});
		});
	}

	function setForm(name, value) {
		const next = root.clone(root.recipe);
		next.forms[name] = value;
		root.commit(next, "Form filled");
	}

	function setDoc(key, value, label) {
		const next = root.clone(root.recipe);
		next.doc[key] = value;
		root.commit(next, label || ({ watermark: "Watermark", numbers: "Page numbers", header: "Header", footer: "Footer", bates: "Numbered" })[key] || "Changed");
	}

	function setFinish(key, value, label) {
		const next = root.clone(root.recipe);
		next.finish[key] = value;
		root.commit(next, label || "Changed");
	}

	function setMeta(meta) {
		const next = root.clone(root.recipe);
		next.meta = meta;
		root.commit(next, "Details changed");
	}

	function setOutline(outline, label) {
		const next = root.clone(root.recipe);
		next.outline = outline;
		root.commit(next, label || "Contents changed");
	}

	function setAttachments(attach, label) {
		const next = root.clone(root.recipe);
		next.attach = attach;
		root.commit(next, label || "Attachments changed");
	}

	// a whole-file step that changes what is drawn (OCR, scans cleaned): a new
	// working copy of source `a`, the pages and marks stay where they are
	function bake(what, options, label) {
		if (!root.current) return;
		const s = root.recipe.sources.a;
		root.startJob("bake", { path: s.work || s.path, password: s.password || "", what: what, options: options || {} }, label || "Working", result => {
			if (!result?.path) return;
			const next = root.clone(root.recipe);
			next.sources.a = Object.assign({}, next.sources.a, { work: result.path, baked: (next.sources.a.baked || []).concat([what]) });
			root.commit(next, label || "Done");
			root.generation += 1;
			root.say(`${label || "Done"} – save to keep it`, "check");
		});
	}

	// ── saving ─────────────────────────────────────────────────────────────
	// replace: the file itself (its old self kept among the versions), copy: beside it
	function save() {
		if (!root.current) return;
		if (!root.dirty) return root.say("Nothing changed", "check");
		root.write(root.setting("saveMode", "replace"), "");
	}

	function saveCopy() {
		root.write("copy", "");
	}

	function saveAs(path) {
		root.write("path", root.plainPath(path));
	}

	// the file chooser asks where (Files' own chooser when it runs)
	function chooseSaveAs() {
		Files.chooseSave?.(`${root.nameOf(root.path)}.pdf`, root.folderOf(root.path), chosen => {
			if (chosen) root.saveAs(chosen);
		});
	}

	signal savedTo(string path)

	function write(mode, target) {
		if (root.saving) return;
		root.saving = true;
		const out = mode === "copy" ? `${root.folderOf(root.path)}/${root.nameOf(root.path)} (edited).pdf` : (mode === "path" ? target : root.path);
		root.startJob("apply", { recipe: root.recipe, out: out, mode: mode, target: mode === "replace" ? root.path : target }, "Saving", result => {
			root.saving = false;
			if (!result?.path) return;
			root.savedTo(result.path);
			Files.refreshThumb?.(result.path);
			if (mode === "replace" || mode === "path") {
				const view = { page: root.page, zoom: root.zoom, fit: root.fit, night: root.night };
				// the saved file is the document now; nothing unsaved is left
				root.dropKept(root.path);
				const editing = root.editing, tool = root.tool;
				root.pending = { page: root.page, edit: editing, tool: tool, search: "" };
				root.load(result.path, mode === "path" ? root.password : (root.recipe.finish.protect?.user || root.password));
				root.say(mode === "replace" ? "Saved" : `Saved as ${root.nameOf(result.path)}`, "content_save_check_outline");
			} else root.tellMade(result.path, "Saved as a copy");
		});
	}

	function tellMade(file, what) {
		Notifs.pushInternal("done", what, file.slice(file.lastIndexOf("/") + 1), {
			app: "PDF", icon: "file_pdf_box", duration: 6000,
			actions: [{ label: "Open", icon: "open_in_app", run: () => root.open(file) }, { label: "Show", icon: "folder_open_outline", run: () => Files.reveal(file) }]
		});
	}

	// earlier states of the file, kept on each save
	function versions(done) {
		root.request("versions", { path: root.path }, data => done(data?.versions ?? []));
	}

	// ── kept per file: where it was read, what was left unsaved ────────────
	property var files_: ({})

	FileView {
		id: filesFile

		path: Paths.stateFile("pdf-files.json")
		printErrors: false
		onLoaded: {
			try {
				root.files_ = JSON.parse(String(filesFile.text() || "{}"));
			} catch (error) {}
		}
	}

	function keptOf(path) {
		return root.files_[root.plainPath(path)] ?? null;
	}

	// how far it was read (0–1) for Files' tiles and the launcher
	function progressOf(path) {
		const kept = root.keptOf(path);
		return kept?.view && kept.pages > 1 ? Math.min(1, (kept.view.page + 1) / kept.pages) : 0;
	}

	function keepState() {
		if (!root.current || !root.meta) return;
		const next = Object.assign({}, root.files_);
		const recipe = root.dirty ? root.recipe : null;
		next[root.path] = { view: { page: root.page, zoom: root.zoom, fit: root.fit, night: root.night }, pages: root.pageCount,
			recipe: recipe, bytes: root.meta.bytes, modified: root.meta.modified, at: Date.now() };
		root.files_ = next;
		filesSave.restart();
	}

	function dropKept(path) {
		const next = Object.assign({}, root.files_);
		if (next[path]) next[path] = Object.assign({}, next[path], { recipe: null });
		root.files_ = next;
		filesSave.restart();
	}

	Timer {
		id: keepSoon

		interval: 1200
		onTriggered: root.keepState()
	}

	onPageChanged: keepSoon.restart()

	Timer {
		id: filesSave

		interval: 1500
		onTriggered: {
			let entries = Object.entries(root.files_);
			if (entries.length > 500) {
				entries.sort((a, b) => (b[1].at || 0) - (a[1].at || 0));
				root.files_ = Object.fromEntries(entries.slice(0, 400));
			}
			filesFile.setText(JSON.stringify(root.files_) + "\n");
		}
	}

	// the recently opened, newest first (the launcher)
	property var recent: []

	FileView {
		id: recentFile

		path: Paths.stateFile("pdf-recent.json")
		printErrors: false
		onLoaded: {
			try {
				root.recent = JSON.parse(String(recentFile.text() || "[]"));
			} catch (error) {}
		}
	}

	function remember(path) {
		if (!path) return;
		root.recent = [path].concat(root.recent.filter(p => p !== path)).slice(0, 80);
		recentFile.setText(JSON.stringify(root.recent) + "\n");
	}

	function forget(path) {
		root.recent = root.recent.filter(p => p !== path);
		recentFile.setText(JSON.stringify(root.recent) + "\n");
	}

	// ── text and pages out ─────────────────────────────────────────────────
	function textOf(done, pages) {
		if (!root.current) return done("");
		root.request("text", { path: root.sourcePath("a"), password: root.password, pages: pages || [] }, data => done(data?.text ?? "", data?.pages ?? []));
	}

	// a page as a picture (dpi 150) – for the clipboard, a drag, the shelf
	function pagePng(index, done, dpi) {
		const p = root.pages[index];
		if (!p) return done("");
		if (p.image) return done(p.image);
		if (p.blank) return done("");
		root.request("pagepng", { path: root.sourcePath(p.src), page: p.n, dpi: dpi || 150, password: root.recipe.sources[p.src]?.password || "" }, data => done(data?.image ?? ""));
	}

	function copyPage(index) {
		root.pagePng(index, image => {
			if (!image) return;
			Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"', "sh", image]);
			Sounds.play("copied");
			root.say(`Page ${index + 1} copied as a picture`, "content_copy");
		}, 200);
	}

	// pages (ids) as a PDF of their own in the runtime folder (dragged out, sent, shelved)
	function pagePdf(ids, done) {
		const next = root.clone(root.recipe);
		next.pages = next.pages.filter(p => ids.includes(p.id));
		next.items = next.items.filter(item => ids.includes(item.page));
		next.outline = [];
		next.finish = root.blankRecipe().finish;
		const name = ids.length === 1 ? `page ${root.indexOf(ids[0]) + 1}` : `pages ${root.rangeText(ids)}`;
		root.startJob("apply", { recipe: next, out: `${Paths.runtime}/pdf-out/${root.nameOf(root.path)} (${name}).pdf`, mode: "temp" }, "Making the pages a file", result => done(result?.path ?? ""));
	}

	// the edited document as a file now (without saving it): mail, phone, shelf take this
	function asFile(done) {
		if (!root.dirty) return done(root.path);
		root.startJob("apply", { recipe: root.recipe, out: `${Paths.runtime}/pdf-out/${root.nameOf(root.path)}.pdf`, mode: "temp" }, "Making the file", result => done(result?.path ?? ""));
	}

	// ── jobs ───────────────────────────────────────────────────────────────
	property var jobs: ({})
	property var jobDone: ({})

	// a job of the helper with its progress shown; done(result) at its end
	function startJob(op, args, label, done) {
		root.request(op, args, (data, error, code) => {
			if (error || !data) {
				if (code === "password" && args.paths?.[0]) {
					root.passwordFor(args.paths[0], given => root.startJob(op, Object.assign({}, args, { options: Object.assign({}, args.options || {}, { password: given }) }), label, done));
					return;
				}
				root.say(error || `${label} did not work`, "alert_circle_outline");
				if (done) done(null);
				return;
			}
			if (!data.job) {
				if (done) done(data);
				return;
			}
			const next = Object.assign({}, root.jobs);
			next[data.job] = { kind: op, label: label, progress: 0, state: "running", text: "", result: null };
			root.jobs = next;
			if (done) root.jobDone[data.job] = done;
		});
	}

	function cancelJob(id) {
		root.request("cancel", { job: id });
	}

	function jobEvent(m) {
		const known = root.jobs[m.job];
		if (known) {
			const next = Object.assign({}, root.jobs);
			next[m.job] = Object.assign({}, known, { progress: m.progress ?? known.progress, state: m.state || known.state, text: m.text ?? known.text, result: m.result ?? known.result });
			root.jobs = next;
		}
		if (m.state === "done" || m.state === "error" || m.state === "cancelled") {
			const done = root.jobDone[m.job];
			delete root.jobDone[m.job];
			if (m.state === "error" && known) root.say(m.text || `${known.label} did not work`, "alert_circle_outline");
			if (m.state !== "done" && known?.kind === "apply") root.saving = false;
			if (done) done(m.state === "done" ? (m.result || {}) : null);
			if (known) forgetJob.restart();
		}
	}

	readonly property var runningJobs: Object.entries(root.jobs).filter(([id, job]) => job.state === "running").map(([id, job]) => Object.assign({ id: id }, job))

	Timer {
		id: forgetJob

		interval: 15000
		onTriggered: {
			const next = {};
			for (const id in root.jobs)
				if (root.jobs[id].state === "running") next[id] = root.jobs[id];
			root.jobs = next;
		}
	}

	// ── the window ─────────────────────────────────────────────────────────
	// what the window does on a word from outside (ipc `pdf act`, the radial menu, keys):
	// edit, read, search, sidebar, outline, pages, night, layout, fit-width, fit-page, zoom-in, zoom-out,
	// present, print-less export, undo, redo, save, tool-<name>, draw-<name>, rotate, delete-page …
	signal act(string name)

	function showWindow() {
		if (!root.enabled) return;
		root.windowOpen = true;
		root.focusWindow();
		if (!root.current && root.recent.length > 0) root.open(root.recent[0]);
	}

	function close() {
		root.keepState();
		root.presenting = false;
		root.windowOpen = false;
		if (root.dirty) root.say("Your changes are kept – open it again to save them", "content_save_alert_outline");
	}

	function toggleWindow() {
		if (root.windowOpen) root.close();
		else root.showWindow();
	}

	function focusWindow() {
		focusTimer.restart();
	}

	function niriWindow() {
		return Niri.windows.find(window => /( – PDF|^PDF)$/.test(String(window.title)) && /quickshell/i.test(String(window.app_id))) ?? null;
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = root.niriWindow();
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	function niri(args) {
		const window = root.niriWindow();
		if (!window) return;
		Quickshell.execDetached(["niri", "msg", "action"].concat(args.map(a => a === "@id" ? String(window.id) : String(a))));
	}

	property bool fullscreen: false

	function toggleFullscreen() {
		if (!root.niriWindow()) return;
		root.fullscreen = !root.fullscreen;
		root.niri(["fullscreen-window", "--id", "@id"]);
	}

	// slides: fullscreen, one page at a time, the laser along
	function present(on) {
		const want = on === undefined ? !root.presenting : !!on;
		if (want === root.presenting) return;
		root.presenting = want;
		if (want && root.editing) root.stopEditing();
		if (want !== root.fullscreen) root.toggleFullscreen();
	}

	// ── talking to the helper ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})
	property var queued: []

	function request(op, args, done) {
		if (!root.enabled) return 0;
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const line = JSON.stringify(Object.assign({ id: id, op: op }, args || {})) + "\n";
		if (!helper.running) {
			root.queued.push(line);
			helper.running = true;
		} else helper.write(line);
		idleTimer.restart();
		return id;
	}

	function receive(line) {
		let m;
		try {
			m = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (m.id !== undefined && m.id !== null) {
			const done = root.callbacks[m.id];
			delete root.callbacks[m.id];
			if (done) done(m.error ? null : m, m.error ?? "", m.code ?? "");
			return;
		}
		switch (m.event) {
		case "job":
			root.jobEvent(m);
			break;
		case "bridge":
			root.bridged(m);
			break;
		case "error":
			console.warn(`pdf: ${m.error}`);
			break;
		default:
			root.helperEvent(m);
			break;
		}
	}

	// the phone bridge's word (a signature drawn, pages photographed, the remote): helper `bridge`
	signal bridged(var m)
	// any other word of the helper (speak done, …)
	signal helperEvent(var m)

	Process {
		id: helper

		stdinEnabled: true
		command: ["python3", "-u", root.helperScript]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(`pdf: ${line}`)
		}
		onRunningChanged: {
			if (!helper.running) return;
			for (const line of root.queued) helper.write(line);
			root.queued = [];
		}
		onExited: {
			for (const id in root.callbacks) root.callbacks[id](null, "The PDF helper stopped", "");
			root.callbacks = {};
			for (const id in root.jobDone) root.jobDone[id](null);
			root.jobDone = {};
			root.jobs = {};
			root.saving = false;
		}
	}

	// the helper goes when nothing is open and nothing runs for a while
	Timer {
		id: idleTimer

		interval: 300000
		onTriggered: {
			if (root.windowOpen || root.runningJobs.length > 0 || Object.keys(root.callbacks).length > 0) idleTimer.restart();
			else if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
	}

	onEnabledChanged: {
		if (!root.enabled) {
			root.close();
			if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
		root.applyDefault();
	}

	// ── as an app of the desktop ───────────────────────────────────────────
	// "Pshell PDF" is there while the plugin is on; with pdf-default PDFs
	// opened anywhere come here (scripts/pdf/default.py)
	readonly property bool isDefault: root.enabled && Plugins.on("pdf-default")
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/pdf/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}

	onIsDefaultChanged: root.applyDefault()
	Component.onCompleted: root.applyDefault()

	Process {
		id: defaultProc
	}

	// ── integration additions ──────────────────────────────────────────────
	// how the document meets the rest of the shell: Files, the shelf, mail,
	// notes and tasks, the AI, invoices, reading aloud, the phone bridge

	// the second file the compare tool starts with (Files' "Compare in the editor")
	property string compareWith: ""

	// PDFs and pictures put together into one: the first PDF, the others behind it in the editor
	function openTogether(paths) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => p);
		const first = list.find(p => root.isPdf(p));
		if (!first) {
			if (list.length === 0) return;
			root.startJob("images", { paths: list, out: `${root.folderOf(list[0])}/${root.nameOf(list[0]).replace(/\.[^.]+$/, "")}.pdf` }, "Making a PDF of the pictures", result => {
				if (result?.path) root.open(result.path, { edit: true, tool: "pages" });
			});
			return;
		}
		const rest = list.filter(p => p !== first);
		if (root.path === first && root.meta && !root.locked) {
			root.open(first, { edit: true, tool: "pages" });
			for (const p of rest) root.insertFile(p, -1);
			return;
		}
		root.pendingMerge = rest;
		root.open(first, { list: list.filter(p => root.isPdf(p)), edit: true, tool: "pages" });
	}

	// a link to a page of a PDF (notes, tasks): file:///….pdf#page=3; true when it was one
	function pageLink(number, path) {
		return `${root.fileUrl(path || root.path)}#page=${number}`;
	}

	function openLink(link) {
		const m = String(link).match(/^file:\/\/(.+\.pdf)(?:#page=(\d+))?$/i);
		if (!m || !root.enabled) return false;
		root.open(root.plainPath(`file://${m[1]}`), { page: m[2] ? Math.max(0, Number(m[2]) - 1) : -1 });
		return true;
	}

	// ── the shelf ──
	readonly property string keptFolder: `${Paths.cache}/pdf-shelf`

	function shelve(paths, text) {
		const items = paths.filter(p => p).map(p => ({ kind: "file", path: p }));
		if (items.length === 0) return;
		if (Shelf.shelves.length === 0) Shelf.create(items);
		else Shelf.keep(items, null);
		Sounds.play("pinned");
		root.say(text || "On the shelf", "tray_arrow_down");
	}

	// pages (ids) as a PDF of their own on the shelf (kept in the cache, not the runtime folder)
	function toShelf(ids) {
		const next = root.clone(root.recipe);
		next.pages = next.pages.filter(p => ids.includes(p.id));
		next.items = next.items.filter(item => ids.includes(item.page));
		next.outline = [];
		next.finish = root.blankRecipe().finish;
		const name = ids.length === 1 ? `page ${root.indexOf(ids[0]) + 1}` : `pages ${root.rangeText(ids)}`;
		root.startJob("apply", { recipe: next, out: `${root.keptFolder}/${root.nameOf(root.path)} (${name}).pdf`, mode: "copy" }, "Putting the pages on the shelf", result => {
			if (result?.path) root.shelve([result.path], ids.length === 1 ? "The page is on the shelf" : `${ids.length} pages on the shelf`);
		});
	}

	// … or as pictures, one per page
	function pagesToShelf(ids) {
		const made = [];
		let left = ids.length;
		for (const id of ids) {
			root.pagePng(root.indexOf(id), image => {
				if (image) made.push(image);
				left -= 1;
				if (left === 0) root.shelve(made, made.length === 1 ? "The page is on the shelf as a picture" : `${made.length} pages on the shelf as pictures`);
			}, 150);
		}
	}

	// the whole document, as it is now
	function documentToShelf() {
		if (!root.dirty) return root.shelve([root.path], "On the shelf");
		root.asFile(file => root.shelve([file], "On the shelf, as it is now"));
	}

	// ── mail, chats, the phone ──
	// a mail's PDF opened here knows its mail: it can go back as the answer (filled, signed)
	property var mailOrigin: null
	readonly property var replyTarget: root.mailOrigin && root.mailOrigin.path === root.path ? root.mailOrigin : null
	property var mailAsked: null
	property int mailRequests: 9000

	function openMailAttachment(chat, message, attachment) {
		root.mailRequests += 1;
		root.mailAsked = { req: root.mailRequests, chat: chat, message: message?.id ?? "", email: message?.from?.email ?? "", name: message?.from?.name ?? "", subject: message?.subject ?? "" };
		Mail.attachmentPath(chat, message?.id ?? "", attachment?.id ?? "", root.mailRequests);
	}

	Connections {
		target: Mail

		function onFileReady(request, path) {
			const asked = root.mailAsked;
			if (!asked || asked.req !== request || !path) return;
			root.mailAsked = null;
			root.mailOrigin = Object.assign({ path: root.plainPath(path) }, asked);
			root.open(path);
		}
	}

	// the edited PDF into the answer to that mail (not sent: the chat opens with it attached)
	function replyWithIt() {
		const to = root.replyTarget;
		if (!to) return;
		root.asFile(file => {
			if (!file) return;
			const kept = Mail.drafts[to.chat] ?? { html: "", files: [] };
			Mail.keep(to.chat, Object.assign({}, kept, { files: (kept.files ?? []).filter(f => f !== file).concat([file]) }));
			Mail.show(to.chat);
		});
	}

	function sendByMail() {
		root.asFile(file => file && Files.mailFiles([file]));
	}

	// where it can go (mail, chats, the phone, other PCs, the clipboard): ShareTargets' entries,
	// the edited state made a file first when there are changes
	function shareEntries() {
		if (!root.current) return [];
		return ShareTargets.entries([root.path], root.dirty ? (done => root.asFile(done)) : undefined);
	}

	// ── the text ──
	signal aiAnswer(string title, string text)
	property bool asking: false

	// the selected text, or a page's: copied, translated, explained, read, kept
	function selectionAction(name) {
		const text = root.selectionText.trim();
		const number = root.selection ? root.indexOf(root.selection.page) + 1 : root.page + 1;
		if (text === "") return;
		switch (name) {
		case "copy":
			Quickshell.execDetached(["wl-copy", "--", text]);
			Sounds.play("copied");
			return root.say("Copied", "content_copy");
		case "translate":
			return root.askText("Übersetze den folgenden Text: Ist er auf Deutsch, übersetze ihn ins Englische, sonst ins Deutsche. Gib nur die Übersetzung aus.", text, "Translation");
		case "explain":
			return root.askText("Erkläre den folgenden Ausschnitt aus einem Dokument kurz und verständlich. Antworte auf Deutsch.", text, "Explained");
		case "ask":
			return Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", { aiPrompt: `Aus „${root.title}", Seite ${number}:`, aiText: text }));
		case "speak":
			return root.speak(text);
		case "note":
			return root.toNote(text, number);
		case "todo":
			return root.toTodo(text, number);
		case "search":
			return Qt.openUrlExternally(`https://duckduckgo.com/?q=${encodeURIComponent(text.slice(0, 300))}`);
		}
	}

	// one answer of the local model to a prompt and a text, in the window (aiAnswer)
	function askText(prompt, text, title, done) {
		if (askProc.running) return root.say("Still thinking about the last one…", "timer_sand");
		root.asking = true;
		askProc.title = title || "";
		askProc.done = done || null;
		askProc.command = ["python3", `${Paths.scripts}/files/ai_ask.py`, JSON.stringify({ prompt: prompt, text: text })];
		askProc.running = true;
	}

	Process {
		id: askProc

		property string title: ""
		property var done: null

		stdout: StdioCollector {
			onStreamFinished: {
				root.asking = false;
				let answer = null;
				try {
					answer = JSON.parse(this.text);
				} catch (error) {}
				const done = askProc.done;
				askProc.done = null;
				if (!answer || answer.error) {
					root.say(answer?.error || "The model did not answer", "alert_circle_outline");
					if (done) done("");
					return;
				}
				if (done) done(answer.text ?? "");
				else root.aiAnswer(askProc.title, answer.text ?? "");
			}
		}
	}

	// a chat about the whole document, in the launcher (it reads the PDF itself)
	function askAi(question) {
		if (!root.current) return;
		const go = file => Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", {
			aiFiles: [{ path: file, name: `${root.nameOf(root.path)}.pdf`, mimeType: "application/pdf", size: root.meta?.bytes ?? 0, isDir: false }],
			aiAsk: question || ""
		}));
		if (root.dirty) root.asFile(go);
		else go(root.path);
	}

	function summarize() {
		root.askAi("Fasse dieses Dokument kurz zusammen: worum es geht, die wichtigsten Punkte, was zu tun ist und bis wann. Antworte auf Deutsch.");
	}

	// kept as a sticky note with a way back to the page
	function toNote(text, number) {
		const quoted = String(text).trim().split("\n").map(line => `> ${line}`).join("\n");
		Notes.upsert("", `${root.title} · p. ${number}`, `${quoted}\n\n[${root.title}, page ${number}](${root.pageLink(number)})`);
		Sounds.play("pinned");
		root.say("Kept as a note", "note_outline");
	}

	function toTodo(text, number) {
		const words = String(text).replace(/\s+/g, " ").trim().slice(0, 160);
		Todos.addTask("", `${words} – [${root.title}, p. ${number}](${root.pageLink(number)})`);
		Sounds.play("listDone");
		root.say("Added to the tasks", "checkbox_marked_circle_plus_outline");
	}

	// a name for the file from what it says (the local model), offered in Info
	function suggestName(done) {
		root.textOf(text => {
			if (!text.trim()) return done("");
			root.askText("Schlage für dieses Dokument einen kurzen, eindeutigen Dateinamen vor, im Stil „2026-03 Rechnung Telekom“ oder „Mietvertrag Musterstraße 4“: Datum (falls erkennbar) vorn, Art des Dokuments, Absender oder Thema. Ohne Endung, ohne Anführungszeichen, nur der Name.", text.slice(0, 5000), "", answer => {
				done(String(answer || "").split("\n")[0].replace(/["„“”/\\:*?<>|]/g, "").replace(/\.pdf$/i, "").trim().slice(0, 90));
			});
		}, [0, 1]);
	}

	function renameTo(name) {
		const clean = String(name || "").trim();
		if (!root.current || !clean) return;
		const old = root.path;
		const target = `${root.folderOf(old)}/${clean}.pdf`;
		if (target === old) return;
		root.keepState();
		Files.rename(old, `${clean}.pdf`, job => {
			if (job.state !== "done") return;
			const next = Object.assign({}, root.files_);
			if (next[old]) {
				next[target] = next[old];
				delete next[old];
				root.files_ = next;
			}
			root.forget(old);
			root.load(target, root.password);
			root.say(`Now ${clean}.pdf`, "rename_box");
		});
	}

	// a table of a page (or of a part of it) as a sheet beside the PDF
	function tableOut(index, rect) {
		const p = root.pages[index];
		if (!p || p.blank || p.image) return root.say("There is no table on this page", "table_off");
		root.request("tables", { path: root.sourcePath(p.src), page: p.n, rect: rect || null, out: `${root.folderOf(root.path)}/${root.nameOf(root.path)} (table p${index + 1})` }, data => {
			if (!data || !(data.rows?.length > 0)) return root.say("No table found on this page", "table_off");
			const file = data.xlsx || data.csv;
			Notifs.pushInternal("done", "Table taken out", `${data.rows.length} rows · ${file.slice(file.lastIndexOf("/") + 1)}`, {
				app: "PDF", icon: "table_arrow_right", duration: 7000,
				actions: [{ label: "Open", icon: "open_in_app", run: () => Files.launch([file]) }, { label: "Show", icon: "folder_open_outline", run: () => Files.reveal(file) }]
			});
		});
	}

	// ── reading aloud ──
	property bool speaking: false

	function speak(text) {
		root.speaking = true;
		root.request("speak", { text: String(text), lang: root.setting("speakVoice", "") }, data => {
			if (!data?.ok) root.speaking = false;
		});
	}

	function readAloud() {
		if (root.speaking) return root.stopSpeaking();
		const p = root.pages[root.page];
		if (!p || p.src !== "a") return;
		root.textOf(text => text.trim() ? root.speak(text) : root.say("This page has no text to read (OCR in Tools)", "text_box_remove_outline"), [p.n]);
	}

	function stopSpeaking() {
		root.speaking = false;
		root.request("stopspeak", {});
	}

	// ── invoices ──
	// a PDF that reads like an invoice gets a chip: amount, due date, IBAN, a task to pay it
	property var invoiceFound: null
	readonly property var invoice: root.invoiceFound && root.invoiceFound.path === root.path ? root.invoiceFound : null

	Connections {
		target: root

		function onOpened(path) {
			if (root.speaking) root.stopSpeaking();
			if (!root.meta || root.meta.pages > 8 || root.meta.scanned) return;
			root.request("invoice", { path: path, password: root.password }, data => {
				if (data && (data.confidence ?? 0) >= 0.6 && root.path === path) root.invoiceFound = Object.assign({ path: path }, data);
			});
			root.followColour();
		}

		function onBridged(m) {
			root.bridgeEvent(m);
		}

		// the helper's other words: reading aloud came to its end
		function onHelperEvent(m) {
			if (m.event === "speak" && m.state === "done") root.speaking = false;
		}
	}

	function copyInvoice(field) {
		const value = String(root.invoice?.[field] ?? "");
		if (!value) return;
		Quickshell.execDetached(["wl-copy", "--", field === "iban" ? value.replace(/\s+/g, "") : value]);
		Sounds.play("copied");
		root.say(`${field === "iban" ? "IBAN" : (field === "amount" ? "Amount" : "Reference")} copied`, "content_copy");
	}

	function invoiceText() {
		const i = root.invoice;
		if (!i) return "";
		const amount = i.amount ? `${Number(i.amount).toLocaleString(Qt.locale(), "f", 2)} ${i.currency || "€"}` : "";
		return [i.sender, amount].filter(s => s).join(" · ");
	}

	// a task to pay it (by the due date), with the way back to the PDF
	function remindInvoice() {
		const i = root.invoice;
		if (!i) return;
		const due = i.due ? ` bis ${Qt.formatDate(new Date(i.due), "d. MMMM yyyy")}` : "";
		Todos.addTask("", `!! Rechnung bezahlen: ${root.invoiceText()}${due}${i.number ? ` (Nr. ${i.number})` : ""} – [${root.nameOf(root.path)}](${root.pageLink(1)})`);
		Sounds.play("listDone");
		root.say("Added to the tasks", "checkbox_marked_circle_plus_outline");
	}

	// the customer whose name or address the invoice names (Customers), if one does
	readonly property var invoiceCustomer: {
		const i = root.invoice;
		if (!i) return null;
		const sender = String(i.sender || "").toLowerCase();
		const email = String(i.email || "").toLowerCase();
		return Customers.list.find(c => (sender && c.name && (sender.includes(String(c.name).toLowerCase()) || String(c.name).toLowerCase().includes(sender)))
			|| (email && (c.people || []).some(p => String(p.email ?? p).toLowerCase() === email))) ?? null;
	}

	// a copy among the invoices: ~/Documents/Invoices/<customer or sender>/<month> <name>.pdf
	function fileInvoice() {
		const i = root.invoice;
		if (!i) return;
		const who = String(root.invoiceCustomer?.name || i.sender || "Other").replace(/[/\\:*?"<>|]/g, "").trim() || "Other";
		const month = (i.issued || i.due || Qt.formatDate(new Date(), "yyyy-MM-dd")).slice(0, 7);
		const docs = Quickshell.env("XDG_DOCUMENTS_DIR") || `${Paths.home}/Documents`;
		const folder = `${docs}/Invoices/${who}`;
		const target = `${folder}/${month} ${root.nameOf(root.path)}.pdf`;
		Quickshell.execDetached(["sh", "-c", 'mkdir -p "$1" && cp -n "$2" "$3"', "sh", folder, root.path, target]);
		Notifs.pushInternal("done", "Filed with the invoices", `${who} · ${month}`, {
			app: "PDF", icon: "folder_account_outline", duration: 6000,
			actions: [{ label: "Show", icon: "folder_open_outline", run: () => Files.reveal(target) }]
		});
	}

	// ── the shell's accent from the document (setting shellAccent) ──
	readonly property bool tintsShell: root.enabled && root.setting("shellAccent", false) && root.windowOpen && root.current
	property string accentHex: ""

	function followColour() {
		if (!root.setting("shellAccent", false)) return;
		const path = root.path;
		root.pagePng(0, image => {
			if (!image || root.path !== path) return;
			colourProc.command = ["python3", "-c", "import sys\nfrom PIL import Image\nim = Image.open(sys.argv[1]).convert('RGB').resize((48, 64))\nbest, score = '', 0\nfor count, (r, g, b) in im.getcolors(4096) or []:\n    hi, lo = max(r, g, b), min(r, g, b)\n    s = (hi - lo) / 255 * count * (0.3 + hi / 255)\n    if hi - lo > 60 and s > score:\n        best, score = '#%02x%02x%02x' % (r, g, b), s\nprint(best)", image];
			colourProc.running = true;
		}, 20);
	}

	Process {
		id: colourProc

		stdout: StdioCollector {
			onStreamFinished: {
				root.accentHex = this.text.trim();
				if (root.tintsShell) Theme.accentOverride = root.accentHex || "transparent";
			}
		}
	}

	onTintsShellChanged: {
		if (root.tintsShell && root.accentHex) Theme.accentOverride = root.accentHex;
		else if (!root.tintsShell && root.accentHex) Theme.accentOverride = "transparent";
	}

	// ── the phone bridge: a page on the phone (QR code) to sign, photograph pages, steer slides ──
	property string bridgeKind: ""
	property string bridgeUrl: ""
	property string bridgeQr: ""
	property string bridgeToken: ""
	// the signature drawn on the phone (a PNG); the sign tool takes it
	signal bridgeSignature(string image)

	function bridgeStart(kind) {
		if (root.bridgeToken) root.bridgeStop();
		root.bridgeKind = kind;
		root.request("bridge", { kind: kind, title: root.title }, data => {
			if (!data) {
				root.bridgeKind = "";
				return;
			}
			root.bridgeUrl = data.url || "";
			root.bridgeQr = data.qr || "";
			root.bridgeToken = data.token || "";
		});
	}

	function bridgeStop() {
		if (root.bridgeToken) root.request("bridgestop", { token: root.bridgeToken });
		root.bridgeKind = "";
		root.bridgeUrl = "";
		root.bridgeQr = "";
		root.bridgeToken = "";
	}

	function bridgeEvent(m) {
		if (!m || (root.bridgeToken && m.token !== root.bridgeToken)) return;
		// it shut itself (idle ten minutes)
		if (m.closed) {
			root.bridgeKind = "";
			root.bridgeUrl = "";
			root.bridgeQr = "";
			root.bridgeToken = "";
			return;
		}
		switch (m.kind) {
		case "sign":
			if (m.image) {
				Sounds.play("received");
				root.bridgeSignature(m.image);
				root.say("The signature came from the phone", "cellphone_check");
			}
			break;
		case "scan": {
			const images = m.images || [];
			if (images.length === 0) break;
			const at = root.page + 1;
			root.startJob("scanpages", { images: images, clean: true }, `Making ${images.length} ${images.length === 1 ? "page" : "pages"} of the photos`, result => {
				if (result?.path) root.insertFile(result.path, at);
			});
			break;
		}
		case "remote":
			switch (m.command) {
			case "next":
				return root.nextPage();
			case "previous":
				return root.previousPage();
			case "laser":
				return Laser.toggle();
			case "end":
				return root.present(false);
			case "move":
				// the phone as a touchpad: the real pointer moves (the laser follows it)
				return Quickshell.execDetached(["ydotool", "mousemove", "--", String(Math.round(m.dx || 0)), String(Math.round(m.dy || 0))]);
			}
			break;
		}
	}

	onPresentingChanged: if (!root.presenting && root.bridgeKind === "remote") root.bridgeStop()

	// ── telling ────────────────────────────────────────────────────────────
	signal said(string text, string icon)

	// in the window while it is looked at, else as a toast
	property bool watching: false

	function say(text, icon) {
		if (root.windowOpen && root.watching) root.said(text, icon || "information_outline");
		else Notifs.pushInternal("done", text, "", { app: "PDF", icon: icon || "file_pdf_box" });
	}

	// ── editor additions ───────────────────────────────────────────────────
	// what the editor's panels and the pages' overlays share (core/views/pdf/
	// ToolDock.qml, Tool*.qml, PageOverlay.qml, PageGrid.qml)

	// a picture or stamp waiting for a click on a page:
	// { kind: "stamp" | "signature" | "image", label, image, color, date, w, h } (w, h in points)
	property var placing: null
	// the kind of a new form field drawn with the "field" pen
	property string fieldType: "text"
	// crop boxes being drawn, by page id (page space), shown before they are applied
	property var cropDraft: ({})
	// a search to black out, every hit shown before it is: [{ page: id, rects: [[x,y,w,h]], text, on }]
	property var redactHits: []
	// the organizer over the whole window
	property bool gridOpen: false
	// (compareWith, the file compared with this one, is the integration's above: while set, Compare.qml lies over the window)
	// differences found: [{ page: n, boxes }] in page space of both
	property var compareBoxes: []
	// the item whose words are typed on the page right now
	property string editingText: ""
	// the pages a page tool works on: "this" | "selected" | "all" | "odd" | "even"
	property string pageScope: "this"

	function scopeIds(scope) {
		const s = scope || root.pageScope;
		if (s === "all") return root.pages.map(p => p.id);
		if (s === "odd") return root.pages.filter((p, i) => i % 2 === 0).map(p => p.id);
		if (s === "even") return root.pages.filter((p, i) => i % 2 === 1).map(p => p.id);
		if (s === "selected" && root.selectedPages.length > 0) return root.selectedPages.slice();
		const p = root.pages[root.page];
		return p ? [p.id] : [];
	}

	// the words of a page's source with their boxes (helper `words`), asked once
	property var wordsCache: ({})

	function wordsOf(pageId, done) {
		const p = root.pageById(pageId);
		if (!p || p.blank || p.image) return done({ words: [], lines: [] });
		const key = `${root.sourcePath(p.src)}#${p.n}`;
		if (root.wordsCache[key]) return done(root.wordsCache[key]);
		root.request("words", { path: root.sourcePath(p.src), page: p.n, password: root.recipe.sources[p.src]?.password || "" }, data => {
			const found = { words: data?.words ?? [], lines: data?.lines ?? [] };
			root.wordsCache[key] = found;
			done(found);
		});
	}

	onGenerationChanged: root.wordsCache = {}

	// the bounding box of an item in page space [x, y, w, h]
	function boundsOf(item) {
		if (!item) return [0, 0, 0, 0];
		if (item.rect) return item.rect;
		if (item.at) return [item.at[0], item.at[1], 20, 20];
		let xs = [], ys = [];
		if (item.quads) for (const q of item.quads) {
			xs.push(q[0], q[0] + q[2]);
			ys.push(q[1], q[1] + q[3]);
		}
		if (item.points) for (const p of item.points) {
			xs.push(p[0]);
			ys.push(p[1]);
		}
		if (item.strokes) for (const s of item.strokes) for (const p of s) {
			xs.push(p[0]);
			ys.push(p[1]);
		}
		if (xs.length === 0) return [0, 0, 0, 0];
		const x0 = Math.min(...xs), y0 = Math.min(...ys);
		return [x0, y0, Math.max(...xs) - x0, Math.max(...ys) - y0];
	}

	function deleteSelected() {
		if (root.selected.length > 0) root.removeItems(root.selected.slice());
	}

	function duplicateSelected() {
		if (root.selected.length > 0) root.duplicateItems(root.selected.slice());
	}

	function nudgeSelected(dx, dy) {
		if (root.selected.length === 0) return;
		const next = root.clone(root.recipe);
		for (const item of next.items)
			if (root.selected.includes(item.id)) root.shiftItem(item, dx, dy);
		root.commit(next, "Moved");
	}

	function selectAllOnPage() {
		const p = root.pages[root.page];
		if (p) root.selected = root.itemsOf(p.id).map(item => item.id);
	}

	// several steps back at once (the history list)
	function undoSteps(count) {
		for (let i = 0; i < count && root.canUndo; i += 1) root.undo();
	}

	// keys of the editor; the window asks here first and stops when true
	function editKey(key, modifiers) {
		if (!root.editing) return false;
		const ctrl = (modifiers & Qt.ControlModifier) !== 0, shift = (modifiers & Qt.ShiftModifier) !== 0;
		if (root.editingText !== "") return false;
		if (key === Qt.Key_Escape) {
			if (root.placing) {
				root.placing = null;
				return true;
			}
			if (root.gridOpen) {
				root.gridOpen = false;
				return true;
			}
			if (root.compareWith !== "") {
				root.compareWith = "";
				return true;
			}
			if (root.draw !== "select") {
				root.draw = "select";
				return true;
			}
			if (root.selected.length > 0) {
				root.selected = [];
				return true;
			}
			return false;
		}
		if (root.selected.length > 0) {
			const step = shift ? 10 : 1;
			if (key === Qt.Key_Delete || key === Qt.Key_Backspace) {
				root.deleteSelected();
				return true;
			}
			if (ctrl && key === Qt.Key_D) {
				root.duplicateSelected();
				return true;
			}
			if (key === Qt.Key_Left) return root.nudgeSelected(-step, 0), true;
			if (key === Qt.Key_Right) return root.nudgeSelected(step, 0), true;
			if (key === Qt.Key_Up) return root.nudgeSelected(0, -step), true;
			if (key === Qt.Key_Down) return root.nudgeSelected(0, step), true;
		}
		if (ctrl && key === Qt.Key_A && root.tool === "annotate") {
			root.selectAllOnPage();
			return true;
		}
		if (!ctrl && key === Qt.Key_G) {
			root.gridOpen = !root.gridOpen;
			return true;
		}
		// the pens by letter while annotating
		if (!ctrl && root.tool === "annotate") {
			const pens = { [Qt.Key_V]: "select", [Qt.Key_H]: "highlight", [Qt.Key_U]: "underline", [Qt.Key_P]: "pen", [Qt.Key_M]: "marker",
				[Qt.Key_E]: "eraser", [Qt.Key_R]: "rect", [Qt.Key_O]: "ellipse", [Qt.Key_L]: "line", [Qt.Key_A]: "arrow", [Qt.Key_N]: "note", [Qt.Key_T]: "textbox" };
			if (pens[key]) {
				root.draw = pens[key];
				return true;
			}
		}
		return false;
	}

	// words from outside for the editor (tool-<name> and draw-<name> are the window's, PdfView.act):
	// grid, delete-selected, duplicate-selected, select-all
	function editorAct(name) {
		if (name === "grid") root.gridOpen = !root.gridOpen;
		else if (name === "delete-selected") root.deleteSelected();
		else if (name === "duplicate-selected") root.duplicateSelected();
		else if (name === "select-all") root.selectAllOnPage();
	}

	onAct: name => root.editorAct(name)

	// what `placing` holds, put on a page where it was clicked (x, y the centre, page space)
	function placeAt(pageId, x, y) {
		const what = root.placing;
		if (!what) return "";
		const w = what.w || 160, h = what.h || 60;
		const rect = [x - w / 2, y - h / 2, w, h];
		let id = "";
		if (what.kind === "stamp") id = root.addItem(what.image ? { kind: "stamp", page: pageId, rect: rect, image: what.image } : { kind: "stamp", page: pageId, rect: rect, label: what.label, color: what.color || "#c62828", date: !!what.date }, "Stamp");
		else if (what.kind === "signature") id = root.addItem({ kind: "signature", page: pageId, rect: rect, path: what.image }, "Signed");
		else id = root.addItem({ kind: "image", page: pageId, rect: rect, path: what.image, opacity: 1 }, "Picture");
		if (!what.keep) root.placing = null;
		Sounds.play("filed");
		return id;
	}

	// a picture in the clipboard as a page of its own
	function insertClipboard(atIndex) {
		const out = `${Paths.runtime}/pdf-paste-${Date.now()}.png`;
		pasteProc.target = out;
		pasteProc.at = atIndex;
		pasteProc.command = ["sh", "-c", 'wl-paste --type image/png > "$1" && [ -s "$1" ]', "sh", out];
		pasteProc.running = true;
	}

	Process {
		id: pasteProc

		property string target: ""
		property int at: -1
		onExited: code => {
			if (code === 0) root.insertImage(pasteProc.target, pasteProc.at);
			else root.say("There is no picture in the clipboard", "clipboard_alert_outline");
		}
	}

	// a part of the screen, chosen now, as a page
	function insertScreenshot(atIndex) {
		const out = `${Paths.runtime}/pdf-shot-${Date.now()}.png`;
		shotProc.target = out;
		shotProc.at = atIndex;
		shotProc.command = ["sh", "-c", 'sleep 0.25; grim -g "$(slurp)" "$1"', "sh", out];
		shotProc.running = true;
	}

	Process {
		id: shotProc

		property string target: ""
		property int at: -1
		onExited: code => {
			if (code === 0) root.insertImage(shotProc.target, shotProc.at);
		}
	}

	// the hits of a search turned into black boxes, in one step
	function applyRedactHits() {
		const on = root.redactHits.filter(h => h.on !== false);
		if (on.length === 0) return;
		const next = root.clone(root.recipe);
		for (const hit of on)
			for (const r of hit.rects) next.items.push({ id: root.newId(next, "i"), kind: "redact", page: hit.page, rect: r, text: hit.text || "" });
		root.commit(next, `${on.length} blacked out`);
		root.redactHits = [];
		root.say(`${on.length} ${on.length === 1 ? "place" : "places"} will be black for good when saved`, "eye_off_outline");
	}

	// crop boxes drawn (cropDraft) applied to the pages of the scope; the box of the page it was drawn on goes to all
	function applyCrop(scope) {
		const ids = root.scopeIds(scope);
		const drawn = root.cropDraft[root.pages[root.page]?.id] ?? Object.values(root.cropDraft)[0];
		if (!drawn) return root.say("Draw the box on the page first", "crop");
		root.cropPages(ids, drawn);
		root.cropDraft = {};
	}

	// a form's fields are read at once: PDFium draws no widgets, the pages' overlays show and fill them
	Connections {
		target: root

		function onOpened(path) {
			if ((root.meta?.forms ?? 0) > 0 && root.fields.length === 0) root.readOutline();
		}
	}

	// your own details for forms ("Fill from my details"), kept in pdf.json
	readonly property var details: root.setting("details", ({}))

	// a file-manager tool (scripts/files/pdftools.py) on the document as it is now
	// (made a file first when it has unsaved changes); what it made is told
	function runTool(tool, options, label, done, quiet) {
		root.asFile(path => {
			if (!path) return done?.(null);
			root.startJob("tool", { tool: tool, paths: [path], options: options || {} }, label || "Working", result => {
				const made = result?.created ?? [];
				if (!quiet) {
					if (made.length === 1) root.tellMade(made[0], label || "Done");
					else if (made.length > 1) root.say(`${made.length} files made beside it`, "check");
				}
				if (done) done(result);
			});
		});
	}

	// each pen keeps its own colour, width and the like (pdf.json "pens")
	readonly property var penDefaults: ({
		select: { color: "#ffd54f" }, highlight: { color: "#ffd54f", opacity: 0.45 }, underline: { color: "#1e88e5", opacity: 1 },
		strike: { color: "#e53935", opacity: 1 }, squiggly: { color: "#43a047", opacity: 1 }, pen: { color: "#1e88e5", width: 2, opacity: 1 },
		marker: { color: "#ffd54f", width: 2, opacity: 0.4 }, eraser: { width: 3 }, rect: { color: "#e53935", width: 2, opacity: 1, fill: "" },
		ellipse: { color: "#e53935", width: 2, opacity: 1, fill: "" }, line: { color: "#e53935", width: 2, opacity: 1 }, arrow: { color: "#e53935", width: 2, opacity: 1 },
		note: { color: "#ffd54f" }, textbox: { color: "#000000", size: 12, fill: "", font: "Helvetica", align: "left" }, link: {}, field: {},
		text: {}, whiteout: { coverColor: "#ffffff" }, redact: {}, "redact-box": {}
	})

	function penStyle(pen) {
		return Object.assign({ color: "#ffd54f", width: 2, opacity: 1, size: 12, fill: "" }, root.penDefaults[pen] ?? {}, root.setting("pens", ({}))[pen] ?? {});
	}

	function setPenStyle(changes) {
		root.style = Object.assign({}, root.style, changes);
		const pens = Object.assign({}, root.setting("pens", ({})));
		pens[root.draw] = Object.assign({}, pens[root.draw] ?? {}, changes);
		root.setSetting("pens", pens);
	}

	onDrawChanged: root.style = root.penStyle(root.draw)

	// fields set on every chosen mark at once; `live` while a slider moves (kept by commitFrom)
	property string liveBefore: ""

	function setOnSelected(fields, live, label) {
		if (root.selected.length === 0) return;
		if (live && root.liveBefore === "") root.liveBefore = JSON.stringify(root.recipe);
		const next = root.clone(root.recipe);
		for (const item of next.items)
			if (root.selected.includes(item.id)) Object.assign(item, fields);
		if (live) root.preview(next);
		else if (root.liveBefore !== "") {
			root.preview(next);
			root.commitFrom(root.liveBefore, label || "Changed");
			root.liveBefore = "";
		} else root.commit(next, label || "Changed");
	}

	// the file's earlier saves
	property var versionList: []

	function loadVersions() {
		if (!root.current) return;
		const path = root.path;
		root.versions(list => {
			if (root.path === path) root.versionList = list;
		});
	}

}
