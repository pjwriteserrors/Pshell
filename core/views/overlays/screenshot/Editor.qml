pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import "Sensitive.js" as Sensitive

// Screenshot editor. The capture grows out of the spot it was taken from into
// the middle of the screen. Annotations live in image pixels inside `exported`,
// an unscaled item the size of the crop, so copy/save render at native
// resolution; only the stage around it is scaled to fit.
//
// Keys (swappy-compatible where possible):
//   v select · b brush · h highlighter · l line · a arrow · r/s rectangle
//   o/c ellipse · t/e text · n step · g spotlight · m magnifier · u measure
//   p pixelate · d blur · w smart erase · x crop · i pick colour
//   Tab / Shift+Tab cycle tools · wheel over the canvas changes the size
//   1–8 palette · Shift+R/G/B red/green/blue · Shift+C custom colour
//   + / - size · = reset size · f fill · Shift+T transparency · k clear all
//   Delete remove selected · Ctrl+Z undo · Ctrl+Shift+Z / Ctrl+Y redo
//   Enter / Ctrl+C copy · Ctrl+S save (Shift keeps the editor open)
//   Ctrl+P pin on top of all windows · Ctrl+R redact sensitive text
//   Ctrl+T translate · Ctrl+M send to phone · Ctrl+F beautify
//   Ctrl+B toggle toolbars · Esc / q / Ctrl+W close
// Drawing: Shift keeps squares, circles and 45° lines; Ctrl draws from the centre.
// Spotlight dims everything outside its boxes (the size sets how dark).
// Magnifier: drag from the spot to where the loupe goes. Measure: Shift keeps
// the line level or upright, Ctrl measures a box. Smart erase fills the box
// with the colours around it.
// Select: drag moves, the handles resize (Shift keeps the proportions), arrow
// keys nudge (Shift: 10 px), double-click edits text, Delete removes; colour,
// size and fill changes apply to the selected annotation.
FocusScope {
	id: editor

	required property string source
	required property rect initialCrop
	required property bool fromFrozen
	required property real density

	readonly property string sourceUrl: Screenshot.fileUrl(editor.source)
	readonly property real srcW: base.implicitWidth
	readonly property real srcH: base.implicitHeight

	// ── document state ─────────────────────────────────────────────────────
	property var items: []
	property rect crop: Qt.rect(0, 0, 1, 1)
	property var past: []
	property var future: []
	property bool savedOnce: false
	property bool busy: false

	// ── tool state ─────────────────────────────────────────────────────────
	property string tool: Screenshot.lastTool
	property string toolBeforeCrop: "rect"
	property color color: Screenshot.lastColor
	property int lineSize: Screenshot.lineSize
	property int textSize: Screenshot.textSize
	property bool fill: Screenshot.fillShape
	property bool transparent: Screenshot.transparent
	property bool panels: true
	property bool popover: false

	// ── interaction state ──────────────────────────────────────────────────
	property var draft: null
	property int selected: -1
	property real moveX: 0
	property real moveY: 0
	property var textDraft: null
	// an erase box waiting for its colours
	property var pendingErase: null
	property rect cropDraft: Qt.rect(0, 0, 1, 1)
	property string cropGrab: ""
	property var press: null
	// select tool: the handle being dragged and the resized annotation
	property string resizeGrab: ""
	property var liveItem: null
	property point hoverPoint: Qt.point(-1, -1)
	property bool hovering: false
	// OCR-based action that is running: "", "redact" or "translate"
	property string working: ""
	property string translateText: ""

	readonly property var palette: ["#ef4444", "#f97316", "#facc15", "#22c55e", "#3b82f6", "#a855f7", "#ffffff", "#111111"]
	readonly property var tools: [
		{ id: "select", icon: "cursor_default_outline", label: "Select", key: "V", group: 0 },
		{ id: "brush", icon: "brush", label: "Brush", key: "B", group: 1 },
		{ id: "marker", icon: "marker", label: "Highlighter", key: "H", group: 1 },
		{ id: "line", icon: "vector_line", label: "Line", key: "L", group: 1 },
		{ id: "arrow", icon: "arrow_top_right", label: "Arrow", key: "A", group: 1 },
		{ id: "rect", icon: "rectangle_outline", label: "Rectangle", key: "R", group: 1 },
		{ id: "ellipse", icon: "ellipse_outline", label: "Ellipse", key: "O", group: 1 },
		{ id: "text", icon: "format_text", label: "Text", key: "T", group: 1 },
		{ id: "step", icon: "numeric_1_circle", label: "Step", key: "N", group: 1 },
		{ id: "spotlight", icon: "spotlight_beam", label: "Spotlight", key: "G", group: 2 },
		{ id: "magnifier", icon: "magnify_plus_outline", label: "Magnifier", key: "M", group: 2 },
		{ id: "measure", icon: "ruler", label: "Measure", key: "U", group: 2 },
		{ id: "pixelate", icon: "checkerboard", label: "Pixelate", key: "P", group: 3 },
		{ id: "blur", icon: "blur", label: "Blur", key: "D", group: 3 },
		{ id: "erase", icon: "eraser_variant", label: "Smart erase", key: "W", group: 3 },
		{ id: "crop", icon: "crop", label: "Crop", key: "X", group: 4 },
		{ id: "eyedropper", icon: "eyedropper_variant", label: "Pick colour", key: "I", group: 4 }
	]
	// annotations that replace image content sit below the spotlight dimming
	readonly property var surfaceTypes: ["pixelate", "blur", "erase"]

	// which size the slider edits
	readonly property var selectedItem: editor.selected >= 0 ? editor.items[editor.selected] ?? null : null
	readonly property bool textSized: {
		const type = editor.selectedItem ? editor.selectedItem.type : editor.tool;
		return type === "text" || type === "step";
	}
	readonly property int sizeMin: editor.textSized ? 10 : 1
	readonly property int sizeMax: editor.textSized ? 160 : 40
	readonly property int currentSize: {
		const item = editor.selectedItem;
		if (item) return editor.textSized ? item.fontSize : item.size;
		return editor.textSized ? editor.textSize : editor.lineSize;
	}

	// ── view: the crop (or the whole frame while cropping) fits the screen ──
	readonly property real availX: 40
	readonly property real availY: editor.panels ? 96 : 40
	readonly property real availW: editor.width - 80
	readonly property real availH: editor.height - editor.availY - (editor.panels ? 100 : 40)
	readonly property rect view: editor.tool === "crop" ? Qt.rect(0, 0, editor.srcW, editor.srcH) : editor.crop
	readonly property real fitScale: Math.min(editor.availW / Math.max(1, editor.view.width), editor.availH / Math.max(1, editor.view.height), 1 / editor.density)
	property bool settled: false
	readonly property real startScale: editor.fromFrozen ? 1 / editor.density : editor.fitScale * 0.92
	readonly property real viewScale: editor.settled ? editor.fitScale : editor.startScale

	function viewOrigin(scale, horizontal) {
		const v = editor.view;
		if (horizontal) return editor.availX + editor.availW / 2 - (v.x + v.width / 2) * scale;
		return editor.availY + editor.availH / 2 - (v.y + v.height / 2) * scale;
	}

	Component.onCompleted: {
		Phone.refresh();
		const initial = editor.initialCrop.width > 0 && editor.initialCrop.height > 0 ? editor.initialCrop : Qt.rect(0, 0, editor.srcW, editor.srcH);
		editor.crop = initial;
		editor.cropDraft = initial;
		if (editor.tool === "crop" || editor.tool === "eyedropper") editor.tool = "rect";
		Qt.callLater(() => editor.settled = true);
	}

	// ── helpers ────────────────────────────────────────────────────────────
	// rect properties read in JS stay bound to the property; keep a snapshot
	function rectCopy(r) {
		return Qt.rect(r.x, r.y, r.width, r.height);
	}

	function toImage(x, y) {
		return Qt.point((x - stage.x) / stage.scale, (y - stage.y) / stage.scale);
	}

	function markerWidth(size) {
		return Math.max(10, size * 3.5);
	}

	function bbox(a) {
		if (!a) return Qt.rect(0, 0, 0, 0);
		switch (a.type) {
		case "brush":
		case "marker": {
			const w = (a.type === "marker" ? editor.markerWidth(a.size) : a.size) / 2;
			const xs = a.points.map(p => p[0]);
			const ys = a.points.map(p => p[1]);
			const x = Math.min(...xs) - w;
			const y = Math.min(...ys) - w;
			return Qt.rect(x, y, Math.max(...xs) + w - x, Math.max(...ys) + w - y);
		}
		case "line":
		case "arrow": {
			const pad = a.type === "arrow" ? Math.max(16, a.size * 3.6) * 0.55 : a.size / 2;
			const x = Math.min(a.x1, a.x2) - pad;
			const y = Math.min(a.y1, a.y2) - pad;
			return Qt.rect(x, y, Math.abs(a.x2 - a.x1) + pad * 2, Math.abs(a.y2 - a.y1) + pad * 2);
		}
		case "text": {
			const pad = a.fill ? Math.round(a.fontSize * 0.28) : 0;
			return Qt.rect(a.x - pad, a.y - pad, a.w + pad * 2, a.h + pad * 2);
		}
		case "step": {
			const r = Math.max(22, a.fontSize * 1.45) / 2;
			return Qt.rect(a.x - r, a.y - r, r * 2, r * 2);
		}
		case "magnifier":
			return Qt.rect(a.x2 - a.r, a.y2 - a.r, a.r * 2, a.r * 2);
		case "measure": {
			if (a.box) break;
			const pad = Math.max(10, a.size * 3) / 2;
			const x = Math.min(a.x1, a.x2) - pad;
			const y = Math.min(a.y1, a.y2) - pad;
			return Qt.rect(x, y, Math.abs(a.x2 - a.x1) + pad * 2, Math.abs(a.y2 - a.y1) + pad * 2);
		}
		}
		return Qt.rect(Math.min(a.x1, a.x2), Math.min(a.y1, a.y2), Math.abs(a.x2 - a.x1), Math.abs(a.y2 - a.y1));
	}

	function segmentDistance(p, a, b) {
		const vx = b[0] - a[0];
		const vy = b[1] - a[1];
		const len = vx * vx + vy * vy;
		const t = len > 0 ? Math.max(0, Math.min(1, ((p.x - a[0]) * vx + (p.y - a[1]) * vy) / len)) : 0;
		const dx = p.x - (a[0] + t * vx);
		const dy = p.y - (a[1] + t * vy);
		return Math.sqrt(dx * dx + dy * dy);
	}

	function hitTest(p) {
		const tolerance = 8 / stage.scale;
		// clicks inside a spotlight reach what lies in it first
		let spot = -1;
		for (let i = editor.items.length - 1; i >= 0; i -= 1) {
			const a = editor.items[i];
			if (a.type === "spotlight") {
				const r = editor.bbox(a);
				const inside = p.x >= r.x - tolerance && p.x <= r.x + r.width + tolerance && p.y >= r.y - tolerance && p.y <= r.y + r.height + tolerance;
				const nearEdge = inside && (p.x <= r.x + tolerance || p.x >= r.x + r.width - tolerance || p.y <= r.y + tolerance || p.y >= r.y + r.height - tolerance);
				if (nearEdge) return i;
				if (inside && spot < 0) spot = i;
			} else if (a.type === "magnifier") {
				const dl = Math.hypot(p.x - a.x2, p.y - a.y2);
				const ds = Math.hypot(p.x - a.x1, p.y - a.y1);
				if (dl <= a.r + tolerance || ds <= a.r / (a.zoom || 2.5) + tolerance) return i;
			} else if (a.type === "measure" && !a.box) {
				if (editor.segmentDistance(p, [a.x1, a.y1], [a.x2, a.y2]) <= Math.max(10, a.size * 3) / 2 + tolerance) return i;
			} else if (a.type === "brush" || a.type === "marker") {
				const reach = (a.type === "marker" ? editor.markerWidth(a.size) : a.size) / 2 + tolerance;
				const pts = a.points;
				for (let j = 0; j < pts.length; j += 1)
					if (editor.segmentDistance(p, pts[j], pts[Math.min(j + 1, pts.length - 1)]) <= reach) return i;
			} else if (a.type === "line" || a.type === "arrow") {
				if (editor.segmentDistance(p, [a.x1, a.y1], [a.x2, a.y2]) <= a.size / 2 + tolerance) return i;
			} else {
				const r = editor.bbox(a);
				if (p.x >= r.x - tolerance && p.x <= r.x + r.width + tolerance && p.y >= r.y - tolerance && p.y <= r.y + r.height + tolerance) return i;
			}
		}
		return spot;
	}

	// resize handles of an annotation, in image pixels
	function handlesOf(a) {
		if (!a) return [];
		if (a.type === "line" || a.type === "arrow" || (a.type === "measure" && !a.box))
			return [{ id: "p1", x: a.x1, y: a.y1 }, { id: "p2", x: a.x2, y: a.y2 }];
		const r = editor.bbox(a);
		const corners = [
			{ id: "nw", x: r.x, y: r.y }, { id: "ne", x: r.x + r.width, y: r.y },
			{ id: "sw", x: r.x, y: r.y + r.height }, { id: "se", x: r.x + r.width, y: r.y + r.height }
		];
		if (a.type === "text" || a.type === "step") return corners;
		// the loupe scales from its corners, the source spot moves on its own
		if (a.type === "magnifier") return corners.concat([{ id: "p1", x: a.x1, y: a.y1, fixed: true }]);
		return corners.concat([
			{ id: "n", x: r.x + r.width / 2, y: r.y }, { id: "s", x: r.x + r.width / 2, y: r.y + r.height },
			{ id: "w", x: r.x, y: r.y + r.height / 2 }, { id: "e", x: r.x + r.width, y: r.y + r.height / 2 }
		]);
	}

	function handleAt(p) {
		const reach = 9 / stage.scale;
		const handles = editor.handlesOf(editor.liveItem ?? editor.selectedItem);
		for (const h of handles)
			if (Math.abs(p.x - h.x) <= reach && Math.abs(p.y - h.y) <= reach) return h.id;
		return "";
	}

	function handleCursor(id) {
		switch (id) {
		case "nw":
		case "se":
			return Qt.SizeFDiagCursor;
		case "ne":
		case "sw":
			return Qt.SizeBDiagCursor;
		case "n":
		case "s":
			return Qt.SizeVerCursor;
		case "w":
		case "e":
			return Qt.SizeHorCursor;
		case "p1":
		case "p2":
			return Qt.CrossCursor;
		}
		return Qt.ArrowCursor;
	}

	// `a` resized by dragging handle `grab` by (dx, dy); `box` is a's bbox
	function resized(a, box, grab, dx, dy, mods) {
		const out = JSON.parse(JSON.stringify(a));
		if (a.type === "magnifier" && grab === "p1") {
			out.x1 = a.x1 + dx;
			out.y1 = a.y1 + dy;
			return out;
		}
		if (grab === "p1" || grab === "p2") {
			const fixed = grab === "p1" ? { x: a.x2, y: a.y2 } : { x: a.x1, y: a.y1 };
			const moving = grab === "p1" ? { x: a.x1 + dx, y: a.y1 + dy } : { x: a.x2 + dx, y: a.y2 + dy };
			const end = editor.constrained(fixed, moving, mods & Qt.ShiftModifier, a.type === "measure" ? "axis" : "line");
			if (grab === "p1") {
				out.x1 = end.x2;
				out.y1 = end.y2;
			} else {
				out.x2 = end.x2;
				out.y2 = end.y2;
			}
			return out;
		}
		let x1 = box.x;
		let y1 = box.y;
		let x2 = box.x + box.width;
		let y2 = box.y + box.height;
		if (grab.indexOf("w") >= 0) x1 += dx;
		if (grab.indexOf("e") >= 0) x2 += dx;
		if (grab.indexOf("n") >= 0) y1 += dy;
		if (grab.indexOf("s") >= 0) y2 += dy;
		const corner = grab.length === 2;
		const proportional = a.type === "text" || a.type === "step" || a.type === "magnifier" || (corner && (mods & Qt.ShiftModifier));
		if (proportional) {
			// the opposite corner stays, both sides follow the larger change
			const f = Math.max(0.05, Math.max(Math.abs(x2 - x1) / Math.max(1, box.width), Math.abs(y2 - y1) / Math.max(1, box.height)));
			const w = box.width * f;
			const h = box.height * f;
			if (grab.indexOf("w") >= 0) x1 = x2 - w;
			else x2 = x1 + w;
			if (grab.indexOf("n") >= 0) y1 = y2 - h;
			else y2 = y1 + h;
		}
		const nx = Math.min(x1, x2);
		const ny = Math.min(y1, y2);
		const nw = Math.max(2, Math.abs(x2 - x1));
		const nh = Math.max(2, Math.abs(y2 - y1));
		switch (a.type) {
		case "brush":
		case "marker": {
			const sx = nw / Math.max(1, box.width);
			const sy = nh / Math.max(1, box.height);
			const flipX = x2 < x1;
			const flipY = y2 < y1;
			out.points = a.points.map(pt => [
				flipX ? nx + nw - (pt[0] - box.x) * sx : nx + (pt[0] - box.x) * sx,
				flipY ? ny + nh - (pt[1] - box.y) * sy : ny + (pt[1] - box.y) * sy
			]);
			return out;
		}
		case "text": {
			const f = nw / Math.max(1, box.width);
			out.fontSize = Math.max(6, Math.round(a.fontSize * f));
			const pad = a.fill ? Math.round(out.fontSize * 0.28) : 0;
			out.w = a.w * f;
			out.h = a.h * f;
			out.x = nx + pad;
			out.y = ny + pad;
			return out;
		}
		case "step": {
			const d = Math.max(22, nw);
			out.fontSize = Math.max(8, Math.round(d / 1.45));
			out.x = nx + nw / 2;
			out.y = ny + nh / 2;
			return out;
		}
		case "magnifier":
			out.r = Math.max(12, nw / 2);
			out.x2 = nx + nw / 2;
			out.y2 = ny + nh / 2;
			return out;
		default:
			out.x1 = x1;
			out.y1 = y1;
			out.x2 = x2;
			out.y2 = y2;
			return out;
		}
	}

	function nudge(dx, dy) {
		if (editor.selected < 0) return;
		const next = editor.items.slice();
		next[editor.selected] = editor.translated(next[editor.selected], dx, dy);
		editor.commit(next);
	}

	function translated(a, dx, dy) {
		const out = Object.assign({}, a);
		if (a.type === "magnifier") {
			out.x2 = a.x2 + dx;
			out.y2 = a.y2 + dy;
			return out;
		}
		if (a.points) out.points = a.points.map(p => [p[0] + dx, p[1] + dy]);
		if (a.x1 !== undefined) {
			out.x1 = a.x1 + dx;
			out.x2 = a.x2 + dx;
			out.y1 = a.y1 + dy;
			out.y2 = a.y2 + dy;
		}
		if (a.x !== undefined) {
			out.x = a.x + dx;
			out.y = a.y + dy;
		}
		return out;
	}

	// ── history ────────────────────────────────────────────────────────────
	function commit(nextItems, nextCrop) {
		editor.past = editor.past.concat([{ items: editor.items, crop: editor.rectCopy(editor.crop) }]).slice(-200);
		editor.future = [];
		editor.items = nextItems;
		if (nextCrop !== undefined) {
			editor.crop = nextCrop;
			editor.cropDraft = nextCrop;
		}
	}

	function undo() {
		editor.commitText();
		if (editor.past.length === 0) return;
		const state = editor.past[editor.past.length - 1];
		editor.future = [{ items: editor.items, crop: editor.rectCopy(editor.crop) }].concat(editor.future);
		editor.past = editor.past.slice(0, -1);
		editor.items = state.items;
		editor.crop = state.crop;
		editor.cropDraft = state.crop;
		editor.selected = -1;
	}

	function redo() {
		if (editor.future.length === 0) return;
		const state = editor.future[0];
		editor.past = editor.past.concat([{ items: editor.items, crop: editor.rectCopy(editor.crop) }]);
		editor.future = editor.future.slice(1);
		editor.items = state.items;
		editor.crop = state.crop;
		editor.cropDraft = state.crop;
		editor.selected = -1;
	}

	function updateSelected(changes) {
		if (editor.selected < 0) return false;
		const next = editor.items.slice();
		next[editor.selected] = Object.assign({}, next[editor.selected], changes);
		editor.commit(next);
		return true;
	}

	function deleteSelected() {
		if (editor.selected < 0) return;
		editor.commit(editor.items.filter((_, i) => i !== editor.selected));
		editor.selected = -1;
	}

	function clearAll() {
		editor.commitText();
		if (editor.items.length === 0) return;
		editor.commit([]);
		editor.selected = -1;
	}

	// ── settings ───────────────────────────────────────────────────────────
	function setTool(id) {
		if (id === editor.tool) return;
		editor.commitText();
		if (editor.tool === "crop") editor.applyCrop(false);
		if (id === "crop") {
			editor.toolBeforeCrop = editor.tool;
			editor.cropDraft = editor.crop;
		}
		if (id !== "select") editor.selected = -1;
		editor.tool = id;
		if (id !== "crop" && id !== "eyedropper") Screenshot.lastTool = id;
	}

	function setColor(c) {
		editor.color = c;
		Screenshot.lastColor = c;
		if (editor.textDraft) editor.textDraft = Object.assign({}, editor.textDraft, { color: String(c) });
		editor.updateSelected({ color: String(c) });
	}

	function setSize(value) {
		const v = Math.max(editor.sizeMin, Math.min(editor.sizeMax, Math.round(value)));
		if (editor.selectedItem) {
			editor.updateSelected(editor.textSized ? { fontSize: v } : { size: v });
			return;
		}
		if (editor.textSized) {
			editor.textSize = v;
			if (editor.textDraft) editor.textDraft = Object.assign({}, editor.textDraft, { fontSize: v });
		} else {
			editor.lineSize = v;
		}
	}

	function resetSize() {
		editor.setSize(editor.textSized ? Screenshot.textSize : Screenshot.lineSize);
	}

	function toggleFill() {
		editor.fill = !editor.fill;
		if (editor.textDraft) editor.textDraft = Object.assign({}, editor.textDraft, { fill: editor.fill });
		editor.updateSelected({ fill: editor.fill });
	}

	function toggleTransparent() {
		editor.transparent = !editor.transparent;
		editor.updateSelected({ opacity: editor.transparent ? Screenshot.transparency / 100 : 1 });
	}

	function newItem(type, extra) {
		return Object.assign({
			type: type,
			color: String(editor.color),
			size: editor.lineSize,
			fill: editor.fill,
			opacity: editor.transparent ? Screenshot.transparency / 100 : 1
		}, extra);
	}

	// ── text ───────────────────────────────────────────────────────────────
	function startText(x, y, index) {
		const existing = index !== undefined && index >= 0 ? editor.items[index] : null;
		editor.textDraft = existing ? Object.assign({ index: index }, existing) : editor.newItem("text", { x: x, y: y - editor.textSize * 0.62, text: "", fontSize: editor.textSize, index: -1 });
		liveText.text = editor.textDraft.text;
		Qt.callLater(() => {
			liveText.forceActiveFocus();
			liveText.cursorPosition = liveText.length;
		});
	}

	function commitText() {
		const t = editor.textDraft;
		if (!t) return;
		editor.textDraft = null;
		const text = liveText.text.replace(/\s+$/, "");
		const item = Object.assign({}, t, { text: text, w: liveText.contentWidth, h: liveText.contentHeight });
		delete item.index;
		const next = editor.items.slice();
		if (t.index >= 0) {
			if (text === "") next.splice(t.index, 1);
			else next[t.index] = item;
			editor.commit(next);
		} else if (text !== "") {
			next.push(item);
			editor.commit(next);
		}
		editor.forceActiveFocus();
	}

	// ── crop ───────────────────────────────────────────────────────────────
	function applyCrop(leave) {
		const r = editor.cropDraft;
		const c = editor.crop;
		if (r.width >= 4 && r.height >= 4 && (r.x !== c.x || r.y !== c.y || r.width !== c.width || r.height !== c.height))
			editor.commit(editor.items, Qt.rect(Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)));
		else
			editor.cropDraft = editor.crop;
		if (leave) editor.tool = editor.toolBeforeCrop === "crop" ? "rect" : editor.toolBeforeCrop;
	}

	function cancelCrop() {
		editor.cropDraft = editor.crop;
		editor.tool = editor.toolBeforeCrop === "crop" ? "rect" : editor.toolBeforeCrop;
	}

	function cropHandleAt(p) {
		const r = editor.cropDraft;
		const t = 14 / stage.scale;
		const nearL = Math.abs(p.x - r.x) <= t;
		const nearR = Math.abs(p.x - (r.x + r.width)) <= t;
		const nearT = Math.abs(p.y - r.y) <= t;
		const nearB = Math.abs(p.y - (r.y + r.height)) <= t;
		const insideX = p.x > r.x - t && p.x < r.x + r.width + t;
		const insideY = p.y > r.y - t && p.y < r.y + r.height + t;
		let edge = "";
		if (nearT && insideX) edge += "n";
		else if (nearB && insideX) edge += "s";
		if (nearL && insideY) edge += "w";
		else if (nearR && insideY) edge += "e";
		if (edge !== "") return edge;
		if (p.x > r.x && p.x < r.x + r.width && p.y > r.y && p.y < r.y + r.height) return "move";
		return "new";
	}

	function clampRect(x1, y1, x2, y2) {
		const cx1 = Math.max(0, Math.min(editor.srcW, Math.min(x1, x2)));
		const cy1 = Math.max(0, Math.min(editor.srcH, Math.min(y1, y2)));
		const cx2 = Math.max(0, Math.min(editor.srcW, Math.max(x1, x2)));
		const cy2 = Math.max(0, Math.min(editor.srcH, Math.max(y1, y2)));
		return Qt.rect(cx1, cy1, cx2 - cx1, cy2 - cy1);
	}

	// ── drawing with the pointer ───────────────────────────────────────────
	function constrained(start, p, mods, kind) {
		let x = p.x;
		let y = p.y;
		if (mods & Qt.ShiftModifier) {
			const dx = x - start.x;
			const dy = y - start.y;
			if (kind === "axis") {
				if (Math.abs(dx) >= Math.abs(dy)) y = start.y;
				else x = start.x;
			} else if (kind === "line") {
				const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
				const len = Math.sqrt(dx * dx + dy * dy);
				x = start.x + Math.cos(angle) * len;
				y = start.y + Math.sin(angle) * len;
			} else {
				const side = Math.max(Math.abs(dx), Math.abs(dy));
				x = start.x + (dx < 0 ? -side : side);
				y = start.y + (dy < 0 ? -side : side);
			}
		}
		if (kind === "box" && (mods & Qt.ControlModifier))
			return { x1: start.x - (x - start.x), y1: start.y - (y - start.y), x2: x, y2: y };
		return { x1: start.x, y1: start.y, x2: x, y2: y };
	}

	function pointerPressed(mouse) {
		editor.popover = false;
		const p = editor.toImage(mouse.x, mouse.y);
		if (editor.textDraft) {
			editor.commitText();
			if (editor.tool === "text") return;
		}
		editor.press = { x: p.x, y: p.y, sx: mouse.x, sy: mouse.y };
		switch (editor.tool) {
		case "select": {
			const grab = editor.selected >= 0 ? editor.handleAt(p) : "";
			if (grab !== "") {
				const item = editor.items[editor.selected];
				editor.resizeGrab = grab;
				editor.press.item = JSON.parse(JSON.stringify(item));
				editor.press.box = editor.rectCopy(editor.bbox(item));
				break;
			}
			const hit = editor.hitTest(p);
			editor.selected = hit;
			editor.moveX = 0;
			editor.moveY = 0;
			if (hit >= 0) {
				const item = editor.items[hit];
				editor.textSize = item.fontSize ?? editor.textSize;
				editor.lineSize = item.size ?? editor.lineSize;
				editor.color = item.color;
				editor.fill = !!item.fill;
				editor.transparent = (item.opacity ?? 1) < 1;
			}
			break;
		}
		case "brush":
		case "marker":
			editor.draft = editor.newItem(editor.tool, { points: [[p.x, p.y]] });
			break;
		case "line":
		case "arrow":
		case "rect":
		case "ellipse":
		case "pixelate":
		case "blur":
			editor.draft = editor.newItem(editor.tool, { x1: p.x, y1: p.y, x2: p.x, y2: p.y });
			break;
		case "spotlight":
			editor.draft = editor.newItem("spotlight", { x1: p.x, y1: p.y, x2: p.x, y2: p.y, radius: Math.round(10 * editor.density), opacity: 1 });
			break;
		case "erase":
			editor.draft = editor.newItem("erase", { x1: p.x, y1: p.y, x2: p.x, y2: p.y, opacity: 1 });
			break;
		case "measure":
			editor.draft = editor.newItem("measure", { x1: p.x, y1: p.y, x2: p.x, y2: p.y, box: (mouse.modifiers & Qt.ControlModifier) !== 0, fontSize: Math.max(12, Math.round(13 * editor.density)) });
			break;
		case "magnifier": {
			const r = Math.round(Math.max(40, Math.min(110 * editor.density, Math.min(editor.crop.width, editor.crop.height) * 0.14)));
			editor.draft = editor.newItem("magnifier", { x1: p.x, y1: p.y, x2: p.x, y2: p.y, r: r, zoom: 2.5 });
			break;
		}
		case "step": {
			const n = editor.items.filter(a => a.type === "step").reduce((m, a) => Math.max(m, a.n), 0) + 1;
			editor.draft = editor.newItem("step", { x: p.x, y: p.y, n: n, fontSize: editor.textSize });
			break;
		}
		case "text": {
			const hit = editor.hitTest(p);
			if (hit >= 0 && editor.items[hit].type === "text") editor.startText(0, 0, hit);
			else editor.startText(p.x, p.y);
			editor.press = null;
			break;
		}
		case "crop":
			editor.cropGrab = editor.cropHandleAt(p);
			editor.press.crop = editor.rectCopy(editor.cropDraft);
			break;
		case "eyedropper":
			editor.setColor(picker.color);
			editor.setTool(Screenshot.lastTool);
			editor.press = null;
			break;
		}
	}

	function pointerMoved(mouse) {
		const p = editor.toImage(mouse.x, mouse.y);
		editor.hoverPoint = p;
		const start = editor.press;
		if (!start) return;
		const mods = mouse.modifiers;
		switch (editor.tool) {
		case "select":
			if (editor.resizeGrab !== "") {
				editor.liveItem = editor.resized(start.item, start.box, editor.resizeGrab, p.x - start.x, p.y - start.y, mods);
			} else if (editor.selected >= 0) {
				editor.moveX = p.x - start.x;
				editor.moveY = p.y - start.y;
			}
			break;
		case "brush":
		case "marker": {
			const pts = editor.draft.points;
			if (editor.tool === "marker" && (mods & Qt.ShiftModifier)) {
				const end = editor.constrained(start, p, mods, "line");
				editor.draft = Object.assign({}, editor.draft, { points: [pts[0], [end.x2, end.y2]] });
				break;
			}
			const last = pts[pts.length - 1];
			const step = 1.5 / stage.scale;
			if (Math.abs(p.x - last[0]) < step && Math.abs(p.y - last[1]) < step) break;
			editor.draft = Object.assign({}, editor.draft, { points: pts.concat([[p.x, p.y]]) });
			break;
		}
		case "line":
		case "arrow":
			editor.draft = Object.assign({}, editor.draft, editor.constrained(start, p, mods, "line"));
			break;
		case "rect":
		case "ellipse":
		case "pixelate":
		case "blur":
		case "spotlight":
		case "erase":
			editor.draft = Object.assign({}, editor.draft, editor.constrained(start, p, mods, "box"));
			break;
		case "measure":
			editor.draft = Object.assign({}, editor.draft, editor.draft.box ? editor.constrained(start, p, mods & ~Qt.ControlModifier, "box") : editor.constrained(start, p, mods, "axis"));
			break;
		case "magnifier":
			editor.draft = Object.assign({}, editor.draft, { x2: p.x, y2: p.y });
			break;
		case "step":
			editor.draft = Object.assign({}, editor.draft, { x: p.x, y: p.y });
			break;
		case "crop": {
			const r = start.crop;
			const dx = p.x - start.x;
			const dy = p.y - start.y;
			const grab = editor.cropGrab;
			if (grab === "new") {
				const box = editor.constrained(start, p, mods, "box");
				editor.cropDraft = editor.clampRect(box.x1, box.y1, box.x2, box.y2);
			} else if (grab === "move") {
				const x = Math.max(0, Math.min(editor.srcW - r.width, r.x + dx));
				const y = Math.max(0, Math.min(editor.srcH - r.height, r.y + dy));
				editor.cropDraft = Qt.rect(x, y, r.width, r.height);
			} else {
				let x1 = r.x;
				let y1 = r.y;
				let x2 = r.x + r.width;
				let y2 = r.y + r.height;
				if (grab.indexOf("w") >= 0) x1 += dx;
				if (grab.indexOf("e") >= 0) x2 += dx;
				if (grab.indexOf("n") >= 0) y1 += dy;
				if (grab.indexOf("s") >= 0) y2 += dy;
				editor.cropDraft = editor.clampRect(x1, y1, x2, y2);
			}
			break;
		}
		}
	}

	function pointerReleased(mouse) {
		const start = editor.press;
		editor.press = null;
		if (!start) return;
		if (editor.tool === "select") {
			if (editor.resizeGrab !== "") {
				if (editor.liveItem && editor.selected >= 0) {
					const next = editor.items.slice();
					next[editor.selected] = editor.liveItem;
					editor.commit(next);
					editor.resampleErase(editor.selected);
				}
				editor.resizeGrab = "";
				editor.liveItem = null;
				return;
			}
			if (editor.selected >= 0 && (Math.abs(editor.moveX) > 0.5 || Math.abs(editor.moveY) > 0.5)) {
				const next = editor.items.slice();
				next[editor.selected] = editor.translated(next[editor.selected], editor.moveX, editor.moveY);
				editor.commit(next);
				editor.resampleErase(editor.selected);
			}
			editor.moveX = 0;
			editor.moveY = 0;
			return;
		}
		if (editor.tool === "crop") {
			if (editor.cropDraft.width < 4 || editor.cropDraft.height < 4) editor.cropDraft = start.crop;
			editor.cropGrab = "";
			return;
		}
		const d = editor.draft;
		editor.draft = null;
		if (!d) return;
		const moved = Math.abs(mouse.x - start.sx) > 3 || Math.abs(mouse.y - start.sy) > 3;
		const kept = d.type === "brush" || d.type === "marker" || d.type === "step" || d.type === "magnifier" || moved;
		if (!kept) return;
		if (d.type === "erase") {
			// the fill needs the colours around the box first
			const box = editor.bbox(d);
			const r = editor.clampRect(box.x, box.y, box.x + box.width, box.y + box.height);
			if (r.width < 2 || r.height < 2) return;
			const item = Object.assign({}, d, { x1: r.x, y1: r.y, x2: r.x + r.width, y2: r.y + r.height });
			editor.pendingErase = item;
			sampler.sample(r, edges => {
				editor.pendingErase = null;
				if (edges) editor.commit(editor.items.concat([Object.assign({}, item, { edges: edges })]));
			});
			return;
		}
		editor.commit(editor.items.concat([d]));
	}

	// a moved or resized erase patch takes the colours of its new place
	function resampleErase(index) {
		const a = editor.items[index];
		if (!a || a.type !== "erase") return;
		const box = editor.bbox(a);
		const r = editor.clampRect(box.x, box.y, box.x + box.width, box.y + box.height);
		if (r.width < 2 || r.height < 2) return;
		sampler.sample(r, edges => {
			const i = editor.items.indexOf(a);
			if (i < 0 || !edges) return;
			// part of the move/resize step: no extra undo entry
			const next = editor.items.slice();
			next[i] = Object.assign({}, a, { edges: edges });
			editor.items = next;
		});
	}

	// ── spotlight ─────────────────────────────────────────────────────────
	// all spotlight boxes (live while drawn, moved or resized)
	readonly property var spotlights: {
		const out = [];
		editor.items.forEach((a, i) => {
			if (a.type !== "spotlight") return;
			let s = i === editor.selected && editor.liveItem ? editor.liveItem : a;
			if (i === editor.selected && (editor.moveX !== 0 || editor.moveY !== 0)) s = editor.translated(s, editor.moveX, editor.moveY);
			out.push(s);
		});
		if (editor.draft && editor.draft.type === "spotlight") out.push(editor.draft);
		return out;
	}
	readonly property real spotDarkness: editor.spotlights.reduce((m, a) => Math.max(m, editor.darkness(a.size)), 0)

	function darkness(size) {
		return Math.max(0.3, Math.min(0.9, 0.4 + size * 0.03));
	}

	// ── export ─────────────────────────────────────────────────────────────
	function render(path, done) {
		editor.commitText();
		if (editor.tool === "crop") editor.applyCrop(true);
		editor.selected = -1;
		editor.busy = true;
		const ok = exported.grabToImage(result => {
			editor.busy = false;
			done(result.saveToFile(path));
		}, Qt.size(editor.crop.width, editor.crop.height));
		if (!ok) {
			editor.busy = false;
			done(false);
		}
	}

	function copy(stay) {
		if (editor.busy) return;
		const path = Screenshot.nextTempPath("copy");
		editor.render(path, ok => {
			if (!ok) {
				Screenshot.exportFailed();
				return;
			}
			Screenshot.copied(path);
			if (Screenshot.earlyExit && !stay) Screenshot.closeEditor();
		});
	}

	// render and float the result above all windows where it was taken
	function pin() {
		if (editor.busy || !Plugins.on("pins")) return;
		const path = Screenshot.nextTempPath("pin");
		const c = editor.rectCopy(editor.crop);
		const logical = editor.fromFrozen ? Qt.rect(c.x / editor.density, c.y / editor.density, c.width / editor.density, c.height / editor.density) : Qt.rect(0, 0, 0, 0);
		const output = Screenshot.editScreen;
		editor.render(path, ok => {
			if (!ok) {
				Screenshot.exportFailed();
				return;
			}
			Screenshot.pin(path, output, logical);
			Screenshot.closeEditor();
		});
	}

	function save(stay) {
		if (editor.busy) return;
		const path = Screenshot.nextSavePath();
		editor.render(path, ok => {
			if (!ok) {
				Screenshot.fail("Screenshot could not be saved", path);
				return;
			}
			editor.savedOnce = true;
			Screenshot.saved(path);
			if (Screenshot.earlyExit && !stay) Screenshot.closeEditor();
		});
	}

	function recognise() {
		if (editor.busy) return;
		const path = Screenshot.nextTempPath("export");
		editor.render(path, ok => {
			if (ok) Screenshot.runOcr(path, null, true);
			else Screenshot.exportFailed();
		});
	}

	// ── OCR actions, sharing, beautifier ───────────────────────────────────
	// the current crop of the source file, for tools that read the image
	function ocrArgs() {
		editor.commitText();
		if (editor.tool === "crop") editor.applyCrop(true);
		const c = editor.rectCopy(editor.crop);
		return [editor.source].concat([c.x, c.y, Math.max(1, c.width), Math.max(1, c.height)].map(v => String(Math.round(v))));
	}

	function notify(status, title, detail, icon) {
		Notifs.pushInternal(status, title, detail, { icon: icon });
	}

	// pixelate every e-mail address, IBAN, phone number, card number, IP,
	// key or token tesseract finds in the crop, as one undo step
	function redact() {
		if (editor.busy || editor.working !== "") return;
		const args = editor.ocrArgs();
		const c = editor.rectCopy(editor.crop);
		// small UI text reads far better enlarged
		const scale = c.width < 1600 ? 2 : 1;
		redactProc.origin = Qt.point(c.x, c.y);
		redactProc.scale = scale;
		redactProc.command = ["bash", Screenshot.script, "ocr-tsv"].concat(args, [String(scale)]);
		editor.working = "redact";
		redactProc.code = -1;
		redactProc.streamDone = false;
		redactProc.running = true;
	}

	function redactFound(exitCode, tsv) {
		editor.working = "";
		if (exitCode === 127) {
			Screenshot.ocrMissing();
			return;
		}
		if (exitCode !== 0) {
			Haptics.play("taskFailed");
			editor.notify("error", "Text recognition failed", "", "shield_lock_outline");
			return;
		}
		const k = redactProc.scale;
		const o = redactProc.origin;
		const covered = editor.items.filter(a => editor.surfaceTypes.indexOf(a.type) >= 0).map(a => editor.bbox(a));
		const added = [];
		for (const b of Sensitive.find(tsv)) {
			const h = b.h / k;
			const pad = Math.max(2, Math.round(h * 0.15));
			const x1 = o.x + b.x / k - pad;
			const y1 = o.y + b.y / k - pad;
			const x2 = o.x + (b.x + b.w) / k + pad;
			const y2 = o.y + (b.y + b.h) / k + pad;
			// already hidden (erased, or a second run)
			if (covered.some(r => r.x <= x1 + pad && r.y <= y1 + pad && r.x + r.width >= x2 - pad && r.y + r.height >= y2 - pad)) continue;
			added.push(editor.newItem("pixelate", { x1: x1, y1: y1, x2: x2, y2: y2, size: Math.max(3, Math.round(h / 8)), opacity: 1, fill: false }));
		}
		if (added.length === 0) {
			editor.notify("done", "Nothing sensitive found", "", "shield_lock_outline");
			return;
		}
		editor.selected = -1;
		editor.commit(editor.items.concat(added));
		Haptics.play("taskDone");
		editor.notify("done", added.length === 1 ? "1 item redacted" : `${added.length} items redacted`, "", "shield_lock_outline");
	}

	// recognise the text of the crop and translate it (German ↔ English)
	function translate() {
		if (editor.busy || editor.working !== "") return;
		translateProc.command = ["bash", Screenshot.script, "ocr"].concat(editor.ocrArgs());
		editor.working = "translate";
		translateProc.code = -1;
		translateProc.streamDone = false;
		translateProc.running = true;
	}

	function translateRecognised(exitCode, raw) {
		if (exitCode === 127) {
			editor.working = "";
			Screenshot.ocrMissing();
			return;
		}
		// lines that continue a sentence are joined, paragraphs stay
		const text = String(raw || "").replace(/\f/g, "").replace(/[ \t]+\n/g, "\n")
			.replace(/-\n(?=[a-zà-öø-ÿß])/g, "")
			.replace(/([^\n])\n(?=[a-zà-öø-ÿß(])/g, "$1 ")
			.replace(/([,;])\n(?!\n)/g, "$1 ")
			.replace(/\n{3,}/g, "\n\n").trim().slice(0, 2500);
		if (exitCode !== 0 || text === "") {
			editor.working = "";
			Haptics.play("taskFailed");
			editor.notify("error", "No text found", "", "translate");
			return;
		}
		editor.translateText = text;
		Translator.clear();
		Translator.request(text, "auto");
		translateTimeout.restart();
	}

	function translateFinished() {
		editor.working = "";
		translateTimeout.stop();
		const full = Translator.result;
		const route = `${Translator.languageName(Translator.source)} → ${Translator.languageName(Translator.resultTarget)}`;
		// the toast outlives the editor: its action holds only plain references
		const shell = Quickshell;
		const haptics = Haptics;
		const copy = ["bash", Screenshot.script, "text", full];
		Haptics.play("taskDone");
		Notifs.pushInternal("done", `Translated · ${route}`, full.length > 280 ? `${full.slice(0, 280)}…` : full, {
			icon: "translate",
			duration: 15000,
			actions: [{
				label: "Copy",
				icon: "content_copy",
				run: () => {
					shell.execDetached(copy);
					haptics.play("copied");
				}
			}]
		});
	}

	function translateFailed() {
		editor.working = "";
		translateTimeout.stop();
		Haptics.play("taskFailed");
		editor.notify("error", "Translation failed", "", "translate");
	}

	// hand the rendered image to the phone; the file goes away a bit later
	function sendToPhone() {
		if (editor.busy || !Phone.reachable) return;
		const path = `${Screenshot.tmpDir}/${Screenshot.filePrefix}${Qt.formatDateTime(new Date(), Screenshot.fileDateFormat)}.png`;
		editor.render(path, ok => {
			if (!ok) {
				Haptics.play("taskFailed");
				editor.notify("error", "Screenshot could not be rendered", "", "cellphone_arrow_down");
				return;
			}
			Phone.shareFile(path);
			Quickshell.execDetached(["sh", "-c", 'sleep 180; rm -f "$1"', "sh", path]);
		});
	}

	// hand the rendered image to the beautifier (frame, background, shadow)
	function beautify() {
		if (editor.busy) return;
		if (typeof Screenshot.beautify !== "function") {
			Haptics.play("taskFailed");
			editor.notify("error", "Beautifier not available", "", "image_frame");
			return;
		}
		const path = Screenshot.nextTempPath("beautify");
		const output = Screenshot.editScreen;
		editor.render(path, ok => {
			if (ok) Screenshot.beautify(path, output);
			else Screenshot.exportFailed();
		});
	}

	Process {
		id: redactProc

		property point origin: Qt.point(0, 0)
		property int scale: 1
		property int code: -1
		property bool streamDone: false

		function finish() {
			if (!redactProc.streamDone || redactProc.code < 0) return;
			editor.redactFound(redactProc.code, redactOut.text);
		}

		stdout: StdioCollector {
			id: redactOut

			onStreamFinished: {
				redactProc.streamDone = true;
				redactProc.finish();
			}
		}
		onExited: exitCode => {
			redactProc.code = exitCode;
			redactProc.finish();
		}
	}

	Process {
		id: translateProc

		property int code: -1
		property bool streamDone: false

		function finish() {
			if (!translateProc.streamDone || translateProc.code < 0) return;
			editor.translateRecognised(translateProc.code, translateOut.text);
		}

		stdout: StdioCollector {
			id: translateOut

			onStreamFinished: {
				translateProc.streamDone = true;
				translateProc.finish();
			}
		}
		onExited: exitCode => {
			translateProc.code = exitCode;
			translateProc.finish();
		}
	}

	Connections {
		target: Translator
		enabled: editor.working === "translate" && editor.translateText !== ""

		function onFinished() {
			if (Translator.input === editor.translateText) editor.translateFinished();
		}
		function onErrorChanged() {
			if (Translator.error !== "") editor.translateFailed();
		}
	}

	Timer {
		id: translateTimeout

		interval: 25000
		onTriggered: if (editor.working === "translate") editor.translateFailed()
	}

	function close() {
		editor.commitText();
		if (Screenshot.autoSave && !editor.savedOnce) {
			editor.save(false);
			if (!Screenshot.earlyExit) Screenshot.closeEditor();
			return;
		}
		Screenshot.closeEditor();
	}

	function back() {
		if (editor.popover) {
			editor.popover = false;
			return;
		}
		if (editor.tool === "crop") {
			editor.cancelCrop();
			return;
		}
		editor.close();
	}

	// ── keyboard ───────────────────────────────────────────────────────────
	Keys.onPressed: event => {
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
		const key = event.key;
		event.accepted = true;
		if (ctrl) {
			if (key === Qt.Key_Z) shift ? editor.redo() : editor.undo();
			else if (key === Qt.Key_Y) editor.redo();
			else if (key === Qt.Key_C) editor.copy(shift);
			else if (key === Qt.Key_S) editor.save(shift);
			else if (key === Qt.Key_P) editor.pin();
			else if (key === Qt.Key_R) editor.redact();
			else if (key === Qt.Key_T) editor.translate();
			else if (key === Qt.Key_M) editor.sendToPhone();
			else if (key === Qt.Key_F) editor.beautify();
			else if (key === Qt.Key_W) editor.close();
			else if (key === Qt.Key_B) editor.panels = !editor.panels;
			else event.accepted = false;
			return;
		}
		if (key >= Qt.Key_1 && key <= Qt.Key_8) {
			editor.setColor(editor.palette[key - Qt.Key_1]);
			return;
		}
		if (shift) {
			switch (key) {
			case Qt.Key_R:
				editor.setColor(editor.palette[0]);
				return;
			case Qt.Key_G:
				editor.setColor(editor.palette[3]);
				return;
			case Qt.Key_B:
				editor.setColor(editor.palette[4]);
				return;
			case Qt.Key_C:
				editor.setColor(Screenshot.customColor);
				return;
			case Qt.Key_T:
				editor.toggleTransparent();
				return;
			}
		}
		switch (key) {
		case Qt.Key_Tab:
		case Qt.Key_Backtab: {
			const ids = editor.tools.map(t => t.id);
			const step = key === Qt.Key_Backtab || shift ? -1 : 1;
			editor.setTool(ids[(ids.indexOf(editor.tool) + step + ids.length) % ids.length]);
			return;
		}
		case Qt.Key_Escape:
			editor.back();
			return;
		case Qt.Key_Q:
			editor.close();
			return;
		case Qt.Key_Return:
		case Qt.Key_Enter:
			if (editor.tool === "crop") editor.applyCrop(true);
			else editor.copy(shift);
			return;
		case Qt.Key_Delete:
		case Qt.Key_Backspace:
			editor.deleteSelected();
			return;
		case Qt.Key_Left:
		case Qt.Key_Right:
		case Qt.Key_Up:
		case Qt.Key_Down: {
			if (editor.selected < 0) break;
			const step = shift ? 10 : 1;
			editor.nudge(key === Qt.Key_Left ? -step : (key === Qt.Key_Right ? step : 0), key === Qt.Key_Up ? -step : (key === Qt.Key_Down ? step : 0));
			return;
		}
		case Qt.Key_Plus:
			editor.setSize(editor.currentSize + (editor.textSized ? 2 : 1));
			return;
		case Qt.Key_Minus:
			editor.setSize(editor.currentSize - (editor.textSized ? 2 : 1));
			return;
		case Qt.Key_Equal:
			editor.resetSize();
			return;
		case Qt.Key_F:
			editor.toggleFill();
			return;
		case Qt.Key_K:
			editor.clearAll();
			return;
		}
		const toolKeys = {
			[Qt.Key_V]: "select", [Qt.Key_B]: "brush", [Qt.Key_H]: "marker", [Qt.Key_L]: "line",
			[Qt.Key_A]: "arrow", [Qt.Key_R]: "rect", [Qt.Key_S]: "rect", [Qt.Key_O]: "ellipse",
			[Qt.Key_C]: "ellipse", [Qt.Key_T]: "text", [Qt.Key_E]: "text", [Qt.Key_N]: "step",
			[Qt.Key_P]: "pixelate", [Qt.Key_D]: "blur", [Qt.Key_X]: "crop", [Qt.Key_I]: "eyedropper",
			[Qt.Key_G]: "spotlight", [Qt.Key_M]: "magnifier", [Qt.Key_U]: "measure", [Qt.Key_W]: "erase"
		};
		if (toolKeys[key] !== undefined) {
			editor.setTool(toolKeys[key]);
			return;
		}
		event.accepted = false;
	}

	EdgeSampler {
		id: sampler

		x: -width - 16
		source: editor.sourceUrl
		imageWidth: editor.srcW
		imageHeight: editor.srcH
	}

	PixelReader {
		id: picker

		source: editor.tool === "eyedropper" ? editor.sourceUrl : ""
		px: Math.max(0, Math.min(editor.srcW - 1, Math.floor(editor.hoverPoint.x)))
		py: Math.max(0, Math.min(editor.srcH - 1, Math.floor(editor.hoverPoint.y)))
	}

	// ── canvas ─────────────────────────────────────────────────────────────
	RectangularShadow {
		readonly property real s: stage.scale
		x: stage.x + exported.x * s
		y: stage.y + exported.y * s
		width: exported.width * s
		height: exported.height * s
		blur: 42
		spread: 2
		offset.y: 10
		color: Qt.rgba(0, 0, 0, 0.55)
		opacity: editor.tool === "crop" ? 0 : (editor.settled ? 1 : 0)

		Behavior on opacity {
			Anim {}
		}
	}

	Item {
		id: stage

		transformOrigin: Item.TopLeft
		width: editor.srcW
		height: editor.srcH
		scale: editor.viewScale
		x: editor.fromFrozen && !editor.settled ? 0 : editor.viewOrigin(editor.viewScale, true)
		y: editor.fromFrozen && !editor.settled ? 0 : editor.viewOrigin(editor.viewScale, false)
		opacity: editor.fromFrozen || editor.settled ? 1 : 0

		Behavior on scale {
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}
		Behavior on x {
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}
		Behavior on y {
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}
		Behavior on opacity {
			Anim {}
		}

		// the whole frame, dimmed, so the crop can grow again
		Image {
			source: editor.sourceUrl
			cache: true
			smooth: true
			mipmap: true
			opacity: editor.tool === "crop" ? 0.32 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}
		}

		// what gets exported: the crop at native resolution
		Item {
			id: exported

			readonly property rect box: editor.tool === "crop" ? editor.cropDraft : editor.crop

			x: exported.box.x
			y: exported.box.y
			width: Math.max(1, exported.box.width)
			height: Math.max(1, exported.box.height)
			clip: true

			Item {
				id: content

				x: -exported.box.x
				y: -exported.box.y
				width: editor.srcW
				height: editor.srcH

				Image {
					id: base

					source: editor.sourceUrl
					asynchronous: false
					cache: true
					smooth: true
					mipmap: true
				}

				// z: 1 what replaces image content, 2 the spotlight dimming,
				// 3 everything drawn on top
				Repeater {
					model: editor.items

					delegate: Annotation {
						required property var modelData
						required property int index

						z: editor.surfaceTypes.indexOf(modelData.type) >= 0 ? 1 : 3
						spec: index === editor.selected && editor.liveItem ? editor.liveItem : modelData
						source: base
						visible: !(editor.textDraft && editor.textDraft.index === index)
						dx: index === editor.selected ? editor.moveX : 0
						dy: index === editor.selected ? editor.moveY : 0
					}
				}

				Annotation {
					z: spec && editor.surfaceTypes.indexOf(spec.type) >= 0 ? 1 : 3
					spec: editor.draft ?? editor.pendingErase
					source: base
					visible: spec !== null
				}

				// everything outside the spotlight boxes darkened
				Item {
					id: spotLayer

					z: 2
					width: editor.srcW
					height: editor.srcH
					visible: editor.spotlights.length > 0

					Item {
						id: spotHoles

						anchors.fill: parent
						visible: false
						layer.enabled: true

						Repeater {
							model: editor.spotlights

							delegate: Rectangle {
								required property var modelData
								readonly property real w: Math.abs(modelData.x2 - modelData.x1)
								readonly property real h: Math.abs(modelData.y2 - modelData.y1)

								x: Math.min(modelData.x1, modelData.x2)
								y: Math.min(modelData.y1, modelData.y2)
								width: w
								height: h
								radius: Math.min(modelData.radius ?? 10, w / 2, h / 2)
								antialiasing: true
								color: "white"
							}
						}
					}

					Rectangle {
						id: spotDim

						anchors.fill: parent
						visible: false
						color: "black"
						layer.enabled: true
					}

					MultiEffect {
						anchors.fill: parent
						source: spotDim
						maskEnabled: true
						maskInverted: true
						maskSource: spotHoles
						maskThresholdMin: 0.5
						maskSpreadAtMin: 1
						opacity: editor.spotDarkness
					}
				}

				// text being typed, rendered like the final label
				Item {
					z: 4
					readonly property var t: editor.textDraft
					readonly property real pad: t && t.fill ? Math.round(t.fontSize * 0.28) : 0

					visible: t !== null
					x: t ? t.x - pad : 0
					y: t ? t.y - pad : 0
					width: Math.max(liveText.contentWidth, 2) + pad * 2
					height: liveText.contentHeight + pad * 2
					opacity: t ? t.opacity : 1

					Rectangle {
						anchors.fill: parent
						visible: parent.t !== null && parent.t.fill
						radius: parent.pad
						color: parent.t ? parent.t.color : "transparent"
					}

					TextEdit {
						id: liveText
						objectName: "liveText"

						readonly property color tint: editor.textDraft ? editor.textDraft.color : "white"
						readonly property bool onLabel: editor.textDraft !== null && editor.textDraft.fill

						x: parent.pad
						y: parent.pad
						width: Math.max(contentWidth, 2)
						color: liveText.onLabel ? (0.2126 * tint.r + 0.7152 * tint.g + 0.0722 * tint.b > 0.6 ? "#111111" : "#ffffff") : tint
						selectionColor: Qt.alpha(Theme.primary, 0.5)
						font.family: Theme.fontFamily
						font.pixelSize: editor.textDraft ? editor.textDraft.fontSize : 20
						font.weight: Font.DemiBold
						textFormat: TextEdit.PlainText
						wrapMode: TextEdit.NoWrap
						cursorDelegate: Rectangle {
							width: Math.max(2, 2 / stage.scale)
							color: Theme.primary
						}

						Keys.onPressed: event => {
							if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
								editor.commitText();
								event.accepted = true;
							} else if (event.key === Qt.Key_Escape) {
								editor.commitText();
								event.accepted = true;
							} else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_C || event.key === Qt.Key_S)) {
								// let copy/save reach the editor while typing
								editor.commitText();
								event.accepted = false;
							}
						}
					}
				}
			}
		}

		// ── chrome (never exported) ───────────────────────────────────────
		Item {
			id: selection

			readonly property var item: editor.liveItem ?? editor.selectedItem
			readonly property bool isLine: selection.item !== null && (selection.item.type === "line" || selection.item.type === "arrow")
			readonly property rect r: editor.bbox(selection.item)
			readonly property real u: 1 / stage.scale

			visible: selection.item !== null && editor.tool === "select"

			Rectangle {
				visible: !selection.isLine
				x: selection.r.x + editor.moveX
				y: selection.r.y + editor.moveY
				width: selection.r.width
				height: selection.r.height
				color: Qt.alpha(Theme.primary, 0.06)
				border.width: 1.5 * selection.u
				border.color: Theme.primary
			}

			Repeater {
				model: editor.handlesOf(selection.item)

				delegate: Rectangle {
					required property var modelData
					readonly property bool edge: modelData.id.length === 1
					readonly property real d: (edge ? 9 : 11) * selection.u

					x: modelData.x + (modelData.fixed ? 0 : editor.moveX) - d / 2
					y: modelData.y + (modelData.fixed ? 0 : editor.moveY) - d / 2
					width: d
					height: d
					radius: selection.isLine ? d / 2 : 2.5 * selection.u
					color: editor.resizeGrab === modelData.id ? Theme.primary : "white"
					border.width: 1.5 * selection.u
					border.color: Theme.primary
				}
			}
		}

		Item {
			id: cropFrame

			readonly property real u: 1 / stage.scale

			visible: editor.tool === "crop"
			x: editor.cropDraft.x
			y: editor.cropDraft.y
			width: editor.cropDraft.width
			height: editor.cropDraft.height

			Rectangle {
				anchors.fill: parent
				anchors.margins: -cropFrame.u
				color: "transparent"
				border.width: 2 * cropFrame.u
				border.color: "white"
			}

			Repeater {
				model: 4

				delegate: Rectangle {
					required property int index
					readonly property bool vertical: index < 2
					x: vertical ? cropFrame.width * (index + 1) / 3 : 0
					y: vertical ? 0 : cropFrame.height * (index - 1) / 3
					width: vertical ? cropFrame.u : cropFrame.width
					height: vertical ? cropFrame.height : cropFrame.u
					color: Qt.rgba(1, 1, 1, 0.3)
				}
			}

			Repeater {
				model: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]]

				delegate: Rectangle {
					required property var modelData
					readonly property real d: (modelData[0] === 0.5 || modelData[1] === 0.5 ? 10 : 14) * cropFrame.u
					x: cropFrame.width * modelData[0] - d / 2
					y: cropFrame.height * modelData[1] - d / 2
					width: d
					height: d
					radius: d / 2
					color: "white"
					border.width: 2 * cropFrame.u
					border.color: Theme.primary
				}
			}

			Rectangle {
				x: cropFrame.width / 2 - width * cropFrame.u / 2
				y: cropFrame.height + 10 * cropFrame.u
				transformOrigin: Item.TopLeft
				scale: cropFrame.u
				width: cropLabel.implicitWidth + 20
				height: 26
				radius: 13
				color: Qt.alpha(Theme.base, 0.92)

				StyledText {
					id: cropLabel

					anchors.centerIn: parent
					tabular: true
					text: `${Math.round(editor.cropDraft.width)} × ${Math.round(editor.cropDraft.height)}`
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}
			}
		}
	}

	// eyedropper preview next to the pointer
	Rectangle {
		visible: editor.tool === "eyedropper" && editor.hovering
		x: pointer.mouseX + 18
		y: pointer.mouseY + 18
		width: 30
		height: 30
		radius: 15
		color: picker.color
		border.width: 3
		border.color: Theme.base
	}

	MouseArea {
		id: pointer

		anchors.fill: parent
		hoverEnabled: true
		preventStealing: true
		cursorShape: {
			switch (editor.tool) {
			case "select": {
				if (editor.resizeGrab !== "") return editor.handleCursor(editor.resizeGrab);
				const hoverHandle = editor.selected >= 0 ? editor.handleAt(editor.hoverPoint) : "";
				if (hoverHandle !== "") return editor.handleCursor(hoverHandle);
				return editor.press && editor.selected >= 0 ? Qt.ClosedHandCursor : Qt.ArrowCursor;
			}
			case "text":
				return Qt.IBeamCursor;
			case "crop":
				return Qt.CrossCursor;
			default:
				return Qt.CrossCursor;
			}
		}

		onPressed: mouse => {
			editor.forceActiveFocus();
			if (mouse.button === Qt.LeftButton) editor.pointerPressed(mouse);
		}
		onPositionChanged: mouse => editor.pointerMoved(mouse)
		onReleased: mouse => editor.pointerReleased(mouse)
		onDoubleClicked: mouse => {
			if (editor.tool !== "select") return;
			const hit = editor.hitTest(editor.toImage(mouse.x, mouse.y));
			if (hit >= 0 && editor.items[hit].type === "text") {
				editor.selected = -1;
				editor.startText(0, 0, hit);
			}
		}
		onEntered: editor.hovering = true
		onExited: editor.hovering = false
		onWheel: wheel => {
			const direction = wheel.angleDelta.y > 0 ? 1 : -1;
			editor.setSize(editor.currentSize + direction * (editor.textSized ? 2 : 1));
		}
	}

	// ── toolbars ───────────────────────────────────────────────────────────
	property Item tipAnchor: null
	property string tipText: ""

	function tip(item, text) {
		editor.tipAnchor = item;
		editor.tipText = text;
	}

	function untip(item) {
		if (editor.tipAnchor === item) editor.tipAnchor = null;
	}

	component Bar: Rectangle {
		radius: height / 2
		color: Theme.base
		height: 52

		RectangularShadow {
			anchors.fill: parent
			z: -1
			radius: parent.radius
			blur: 30
			offset.y: 8
			color: Theme.shadow
		}
	}

	component Divider: Rectangle {
		anchors.verticalCenter: parent?.verticalCenter
		width: 1
		height: 22
		color: Theme.outline
	}

	component BarButton: IconButton {
		id: barButton

		property string tipLabel: ""
		property bool busy: false

		anchors.verticalCenter: parent?.verticalCenter
		implicitWidth: 38
		implicitHeight: 38
		iconSize: 19
		onEntered: editor.tip(barButton, barButton.tipLabel)
		onExited: editor.untip(barButton)

		Spinner {
			anchors.centerIn: parent
			width: 18
			height: 18
			visible: barButton.busy
		}
	}

	Bar {
		id: toolBar

		readonly property bool present: editor.panels && editor.settled

		anchors.horizontalCenter: parent.horizontalCenter
		y: toolBar.present ? 22 : -height - 20
		width: toolRow.implicitWidth + 16
		opacity: toolBar.present ? 1 : 0

		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {}
		}

		Row {
			id: toolRow

			anchors.centerIn: parent
			spacing: 4

			Repeater {
				model: editor.tools

				delegate: Row {
					id: toolCell

					required property var modelData
					required property int index
					// a thin divider where a new group of tools starts
					readonly property bool groupStart: toolCell.index > 0 && editor.tools[toolCell.index - 1].group !== toolCell.modelData.group

					anchors.verticalCenter: parent?.verticalCenter
					spacing: 4

					Item {
						visible: toolCell.groupStart
						width: 2
						height: 1
					}

					Divider {
						visible: toolCell.groupStart
						opacity: 0.6
					}

					Item {
						visible: toolCell.groupStart
						width: 2
						height: 1
					}

					BarButton {
						icon: toolCell.modelData.icon
						checked: editor.tool === toolCell.modelData.id
						tipLabel: `${toolCell.modelData.label}  ${toolCell.modelData.key}`
						onClicked: editor.setTool(toolCell.modelData.id)
					}
				}
			}

			Item {
				width: 6
				height: 1
			}

			Divider {}

			Item {
				width: 6
				height: 1
			}

			BarButton {
				icon: "undo"
				enabled: editor.past.length > 0
				tipLabel: "Undo  Ctrl+Z"
				onClicked: editor.undo()
			}

			BarButton {
				icon: "redo"
				enabled: editor.future.length > 0
				tipLabel: "Redo  Ctrl+Y"
				onClicked: editor.redo()
			}

			BarButton {
				icon: "delete_outline"
				enabled: editor.selected >= 0 || editor.items.length > 0
				tipLabel: editor.selected >= 0 ? "Delete  Del" : "Clear all  K"
				onClicked: editor.selected >= 0 ? editor.deleteSelected() : editor.clearAll()
			}
		}
	}

	Bar {
		id: actionBar

		readonly property bool present: editor.panels && editor.settled

		anchors.horizontalCenter: parent.horizontalCenter
		y: actionBar.present ? editor.height - height - 24 : editor.height + 20
		width: actionRow.implicitWidth + 20
		opacity: actionBar.present ? 1 : 0

		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {}
		}

		Row {
			id: actionRow

			anchors.centerIn: parent
			spacing: 6

			Repeater {
				model: editor.palette

				delegate: Item {
					id: swatch

					required property var modelData
					required property int index
					readonly property bool current: Qt.colorEqual(editor.color, modelData)

					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28

					Rectangle {
						anchors.centerIn: parent
						width: swatch.current ? 28 : 22
						height: width
						radius: width / 2
						color: "transparent"
						border.width: 2
						border.color: swatch.current ? Theme.text : "transparent"

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					Rectangle {
						anchors.centerIn: parent
						width: swatchMouse.containsMouse ? 22 : 20
						height: width
						radius: width / 2
						color: swatch.modelData
						border.width: 1
						border.color: Theme.outline

						Behavior on width {
							SpatialAnim {
								duration: Motion.short
							}
						}
					}

					MouseArea {
						id: swatchMouse

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: editor.setColor(swatch.modelData)
					}
				}
			}

			// custom colour: rainbow ring around the colour, opens the picker
			Item {
				id: customSwatch

				readonly property bool current: Qt.colorEqual(editor.color, Screenshot.customColor) && !editor.palette.some(c => Qt.colorEqual(c, editor.color))

				anchors.verticalCenter: parent.verticalCenter
				width: 28
				height: 28

				Rectangle {
					anchors.centerIn: parent
					width: 26
					height: 26
					radius: 13
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop { position: 0.0; color: "#ff4d4d" }
						GradientStop { position: 0.25; color: "#ffd84d" }
						GradientStop { position: 0.5; color: "#4dff88" }
						GradientStop { position: 0.75; color: "#4db8ff" }
						GradientStop { position: 1.0; color: "#d44dff" }
					}
					rotation: 45
				}

				Rectangle {
					anchors.centerIn: parent
					width: 18
					height: 18
					radius: 9
					color: Screenshot.customColor
					border.width: 2
					border.color: Theme.base
				}

				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						editor.setColor(Screenshot.customColor);
						editor.popover = !editor.popover;
					}
					onEntered: editor.tip(customSwatch, "Custom colour  Shift+C")
					onExited: editor.untip(customSwatch)
				}
			}

			Item {
				width: 4
				height: 1
			}

			PillSlider {
				anchors.verticalCenter: parent.verticalCenter
				width: 150
				height: 34
				icon: editor.textSized ? "format_size" : "brush"
				value: (editor.currentSize - editor.sizeMin) / (editor.sizeMax - editor.sizeMin)
				stepSize: 1 / (editor.sizeMax - editor.sizeMin)
				valueText: `${editor.currentSize}`
				onMoved: value => editor.setSize(editor.sizeMin + value * (editor.sizeMax - editor.sizeMin))
			}

			BarButton {
				icon: "format_color_fill"
				checked: editor.fill
				tipLabel: "Fill  F"
				onClicked: editor.toggleFill()
			}

			BarButton {
				icon: "opacity"
				checked: editor.transparent
				tipLabel: "Transparent  Shift+T"
				onClicked: editor.toggleTransparent()
			}

			Item {
				width: 2
				height: 1
			}

			Divider {}

			Item {
				width: 2
				height: 1
			}

			BarButton {
				icon: "text_recognition"
				tipLabel: "Copy text"
				onClicked: editor.recognise()
			}

			BarButton {
				icon: editor.working === "translate" ? "" : "translate"
				busy: editor.working === "translate"
				tipLabel: "Translate  Ctrl+T"
				onClicked: editor.translate()
			}

			BarButton {
				icon: editor.working === "redact" ? "" : "shield_lock_outline"
				busy: editor.working === "redact"
				tipLabel: "Redact sensitive  Ctrl+R"
				onClicked: editor.redact()
			}

			Item {
				width: 2
				height: 1
			}

			Divider {}

			Item {
				width: 2
				height: 1
			}

			BarButton {
				icon: "image_frame"
				tipLabel: "Beautify  Ctrl+F"
				onClicked: editor.beautify()
			}

			BarButton {
				visible: Phone.reachable
				icon: "cellphone_arrow_down"
				tipLabel: `Send to ${Phone.name}  Ctrl+M`
				onClicked: editor.sendToPhone()
			}

			BarButton {
				visible: Plugins.on("pins")
				icon: "pin_outline"
				tipLabel: "Pin on top  Ctrl+P"
				onClicked: editor.pin()
			}

			BarButton {
				icon: "content_save"
				tipLabel: "Save  Ctrl+S"
				onClicked: editor.save(false)
			}

			TextButton {
				id: copyButton

				anchors.verticalCenter: parent.verticalCenter
				height: 38
				variant: "filled"
				icon: "content_copy"
				text: "Copy"
				busy: editor.busy
				onActivated: editor.copy(false)
				onEntered: editor.tip(copyButton, "Enter")
				onExited: editor.untip(copyButton)
			}

			BarButton {
				icon: "close"
				tipLabel: "Close  Esc"
				onClicked: editor.close()
			}
		}
	}

	// ── custom colour popover ──────────────────────────────────────────────
	Rectangle {
		id: colorPop

		property real hue: 0
		property real sat: 1
		property real val: 1

		function sync() {
			const c = Qt.color(Screenshot.customColor);
			colorPop.hue = Math.max(0, c.hsvHue);
			colorPop.sat = c.hsvSaturation;
			colorPop.val = c.hsvValue;
			hexInput.text = String(c).slice(1).toUpperCase();
		}

		function push() {
			const c = Qt.hsva(colorPop.hue, colorPop.sat, colorPop.val, 1);
			Screenshot.customColor = c;
			editor.setColor(c);
			if (!hexInput.activeFocus) hexInput.text = String(c).slice(1).toUpperCase();
		}

		visible: opacity > 0
		opacity: editor.popover && actionBar.present ? 1 : 0
		scale: editor.popover ? 1 : 0.92
		transformOrigin: Item.Bottom
		x: Math.max(12, Math.min(editor.width - width - 12, actionBar.x + customSwatch.mapToItem(actionBar, 0, 0).x + customSwatch.width / 2 - width / 2))
		y: actionBar.y - height - 12
		width: 236
		height: popColumn.implicitHeight + 24
		radius: Theme.radius.huge
		color: Theme.base

		onVisibleChanged: if (visible) colorPop.sync()

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		RectangularShadow {
			anchors.fill: parent
			z: -1
			radius: parent.radius
			blur: 30
			offset.y: 8
			color: Theme.shadow
		}

		Column {
			id: popColumn

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 12

			Rectangle {
				id: sv

				width: parent.width
				height: 140
				radius: Theme.radius.medium
				color: Qt.hsva(colorPop.hue, 1, 1, 1)

				Rectangle {
					anchors.fill: parent
					radius: parent.radius
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop { position: 0; color: "white" }
						GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
					}
				}

				Rectangle {
					anchors.fill: parent
					radius: parent.radius
					gradient: Gradient {
						GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
						GradientStop { position: 1; color: "black" }
					}
				}

				Rectangle {
					x: colorPop.sat * sv.width - width / 2
					y: (1 - colorPop.val) * sv.height - height / 2
					width: 16
					height: 16
					radius: 8
					color: Qt.hsva(colorPop.hue, colorPop.sat, colorPop.val, 1)
					border.width: 3
					border.color: "white"
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.CrossCursor
					preventStealing: true

					function setAt(mouse) {
						colorPop.sat = Math.max(0, Math.min(1, mouse.x / width));
						colorPop.val = 1 - Math.max(0, Math.min(1, mouse.y / height));
						colorPop.push();
					}

					onPressed: mouse => setAt(mouse)
					onPositionChanged: mouse => setAt(mouse)
				}
			}

			Rectangle {
				id: hueBar

				width: parent.width
				height: 14
				radius: 7
				gradient: Gradient {
					orientation: Gradient.Horizontal
					GradientStop { position: 0 / 6; color: "#ff0000" }
					GradientStop { position: 1 / 6; color: "#ffff00" }
					GradientStop { position: 2 / 6; color: "#00ff00" }
					GradientStop { position: 3 / 6; color: "#00ffff" }
					GradientStop { position: 4 / 6; color: "#0000ff" }
					GradientStop { position: 5 / 6; color: "#ff00ff" }
					GradientStop { position: 6 / 6; color: "#ff0000" }
				}

				Rectangle {
					x: colorPop.hue * hueBar.width - width / 2
					anchors.verticalCenter: parent.verticalCenter
					width: 18
					height: 18
					radius: 9
					color: Qt.hsva(colorPop.hue, 1, 1, 1)
					border.width: 3
					border.color: "white"
				}

				MouseArea {
					anchors.fill: parent
					anchors.margins: -6
					cursorShape: Qt.PointingHandCursor
					preventStealing: true

					function setAt(mouse) {
						colorPop.hue = Math.max(0, Math.min(0.999, (mouse.x - 6) / hueBar.width));
						colorPop.push();
					}

					onPressed: mouse => setAt(mouse)
					onPositionChanged: mouse => setAt(mouse)
				}
			}

			Rectangle {
				width: parent.width
				height: 34
				radius: 17
				color: Theme.layer2

				Row {
					anchors.fill: parent
					anchors.leftMargin: 8
					spacing: 8

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 20
						height: 20
						radius: 10
						color: Screenshot.customColor
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: "#"
						tone: Theme.textSubtle
						font.family: Theme.monoFamily
					}

					TextInput {
						id: hexInput

						anchors.verticalCenter: parent.verticalCenter
						width: 120
						color: Theme.text
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.body
						selectionColor: Qt.alpha(Theme.primary, 0.5)
						maximumLength: 6
						validator: RegularExpressionValidator {
							regularExpression: /[0-9a-fA-F]{0,6}/
						}

						onTextEdited: {
							if (hexInput.text.length !== 6) return;
							const c = Qt.color(`#${hexInput.text}`);
							colorPop.hue = Math.max(0, c.hsvHue);
							colorPop.sat = c.hsvSaturation;
							colorPop.val = c.hsvValue;
							colorPop.push();
						}
						Keys.onPressed: event => {
							if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
								editor.popover = false;
								editor.forceActiveFocus();
								event.accepted = true;
							}
						}
					}
				}
			}
		}
	}

	// ── tooltip ────────────────────────────────────────────────────────────
	Rectangle {
		id: tooltip

		readonly property bool below: editor.tipAnchor !== null && editor.tipAnchor.mapToItem(editor, 0, 0).y < editor.height / 2
		property point at: Qt.point(0, 0)

		visible: opacity > 0
		opacity: editor.tipAnchor !== null && !editor.popover ? 1 : 0
		x: Math.max(8, Math.min(editor.width - width - 8, tooltip.at.x - width / 2))
		y: tooltip.below ? tooltip.at.y + 16 : tooltip.at.y - height - 16
		width: tipLabel.implicitWidth + 20
		height: 28
		radius: 14
		color: Theme.layer3

		Connections {
			target: editor

			function onTipAnchorChanged() {
				const anchor = editor.tipAnchor;
				if (!anchor) return;
				const p = anchor.mapToItem(editor, anchor.width / 2, tooltip.below ? anchor.height : 0);
				tooltip.at = Qt.point(p.x, p.y + (tooltip.below ? 8 : -8));
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on x {
			enabled: tooltip.opacity > 0.5
			SpatialAnim {
				duration: Motion.medium
			}
		}

		StyledText {
			id: tipLabel

			anchors.centerIn: parent
			text: editor.tipText
			font.pixelSize: Theme.size.label
			font.weight: Font.Medium
		}
	}
}
