pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer/Geometry.js" as Geo
import "Edit.js" as Edit

// Over the film's frame (EditorView keeps it there): the texts, arrows,
// boxes and blurred parts that show at the playhead, drawn as the export
// will have them – the texts are even made into pictures from these same
// items (renderTexts). With the Text or Blur tool they are picked, moved
// and resized here; with the Frame tool the crop's handles are here, over
// the whole picture.
Item {
	id: root

	property var editor: null
	// the crop's shape kept by its handles (width / height, 0 free; set by the Frame panel)
	property real cropAspect: 0

	readonly property var recipe: Video.recipe
	readonly property var texts: root.recipe.texts ?? []
	readonly property var blurs: root.recipe.blurs ?? []
	readonly property real now: root.editor?.playhead ?? 0
	readonly property string tool: root.editor?.tool ?? ""
	readonly property bool cropping: root.editor?.cropping ?? false
	readonly property bool picking: !root.cropping && (root.tool === "text" || root.tool === "blur")
	readonly property string selectedId: root.editor?.selectedItem?.id ?? ""
	readonly property string selectedKind: root.editor?.selectedItem?.kind ?? ""

	// ── blurred parts ──────────────────────────────────────────────────────
	Repeater {
		model: root.cropping ? 0 : root.blurs.length

		delegate: Item {
			id: blurBox

			required property int index
			readonly property var item: root.blurs[blurBox.index] ?? null
			readonly property bool selected: root.selectedKind === "blur" && root.selectedId === (blurBox.item?.id ?? "-")
			readonly property real presence: Edit.presence(blurBox.item, root.now)
			readonly property bool pixel: blurBox.item?.kind === "pixel"
			readonly property real strength: Number(blurBox.item?.strength ?? 0.6)

			x: (blurBox.item?.x ?? 0) * root.width
			y: (blurBox.item?.y ?? 0) * root.height
			width: Math.max(2, (blurBox.item?.w ?? 0) * root.width)
			height: Math.max(2, (blurBox.item?.h ?? 0) * root.height)
			visible: !!blurBox.item && (blurBox.presence > 0 || (blurBox.selected && root.tool === "blur"))
			opacity: blurBox.presence > 0 ? blurBox.presence : 0.5

			// that part of the film, small: blurred, or in blocks
			ShaderEffectSource {
				id: part

				anchors.fill: parent
				sourceItem: blurBox.visible ? (root.editor?.stage?.frame ?? null) : null
				sourceRect: Qt.rect(blurBox.x, blurBox.y, blurBox.width, blurBox.height)
				live: true
				hideSource: false
				smooth: !blurBox.pixel
				visible: blurBox.pixel
				// blocks of 1.5 … 6 % of the frame's height
				textureSize: blurBox.pixel ? Qt.size(Math.max(1, Math.round(blurBox.width / (root.height * (0.015 + 0.045 * blurBox.strength)))), Math.max(1, Math.round(blurBox.height / (root.height * (0.015 + 0.045 * blurBox.strength))))) : Qt.size(Math.max(8, blurBox.width / 3), Math.max(8, blurBox.height / 3))
			}

			MultiEffect {
				anchors.fill: parent
				visible: !blurBox.pixel
				source: part
				blurEnabled: true
				blur: 1
				blurMax: Math.round(12 + 52 * blurBox.strength)
				autoPaddingEnabled: false
			}

			Rectangle {
				anchors.fill: parent
				color: "transparent"
				border.width: 1
				border.color: Qt.rgba(1, 1, 1, 0.5)
				visible: root.tool === "blur"
				opacity: blurBox.selected ? 0 : 1
			}
		}
	}

	// faces are found only by the export
	Rectangle {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.margins: 10
		visible: !!root.recipe.faces && !root.cropping
		width: facesText.implicitWidth + 20
		height: 26
		radius: 13
		color: Qt.rgba(0, 0, 0, 0.6)

		StyledText {
			id: facesText

			anchors.centerIn: parent
			text: "Faces are blurred in the export"
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.small
		}
	}

	// ── texts, arrows, boxes ───────────────────────────────────────────────
	Repeater {
		id: shown

		model: root.cropping ? 0 : root.texts.length

		delegate: Art {
			id: art

			required property int index
			readonly property bool selected: root.selectedKind === "text" && root.selectedId === (art.item?.id ?? "-")
			readonly property real presence: Edit.presence(art.item, root.now)

			item: root.texts[art.index] ?? null
			frameW: root.width
			frameH: root.height
			visible: !!art.item && (art.presence > 0 || (art.selected && root.tool === "text"))
			opacity: art.presence > 0 ? art.presence : 0.45
		}
	}

	// ── picking, moving and resizing them ──────────────────────────────────
	// the selected one's rectangle on this item (an arrow: around its ends)
	readonly property var selected: {
		if (root.selectedKind === "text") return root.texts.find(t => t.id === root.selectedId) ?? null;
		if (root.selectedKind === "blur") return root.blurs.find(b => b.id === root.selectedId) ?? null;
		return null;
	}
	readonly property bool selectedIsArrow: root.selected?.kind === "arrow"
	readonly property rect selectedBox: !root.selected ? Qt.rect(0, 0, 0, 0) : (root.selectedIsArrow
		? Qt.rect(Math.min(root.selected.x1, root.selected.x2) * root.width, Math.min(root.selected.y1, root.selected.y2) * root.height, Math.abs(root.selected.x2 - root.selected.x1) * root.width, Math.abs(root.selected.y2 - root.selected.y1) * root.height)
		: root.drawnBox(root.selected))
	readonly property bool handlesShown: root.picking && !!root.selected && ((root.selectedKind === "text" && root.tool === "text") || (root.selectedKind === "blur" && root.tool === "blur"))

	// a text as drawn (as tall as its words when they need more than its box)
	function drawnBox(it) {
		if (root.selectedKind === "text") {
			const i = root.texts.indexOf(it);
			const art = i >= 0 ? shown.itemAt(i) : null;
			if (art) return Qt.rect(art.x, art.y, art.width, art.height);
		}
		return Qt.rect(it.x * root.width, it.y * root.height, it.w * root.width, it.h * root.height);
	}

	function listOf(kind) {
		return kind === "blur" ? root.blurs : root.texts;
	}

	function boxOf(item) {
		if (item.kind === "arrow") return { x: Math.min(item.x1, item.x2), y: Math.min(item.y1, item.y2), w: Math.abs(item.x2 - item.x1), h: Math.abs(item.y2 - item.y1) };
		return { x: item.x, y: item.y, w: item.w, h: item.h };
	}

	// the one under a point (the topmost that shows now, or the selected)
	function itemAt(x, y) {
		const kind = root.tool === "blur" ? "blur" : "text";
		const list = root.listOf(kind);
		for (let i = list.length - 1; i >= 0; i -= 1) {
			const it = list[i];
			if (Edit.presence(it, root.now) <= 0 && it.id !== root.selectedId) continue;
			if (it.kind === "arrow") {
				if (root.nearLine(x, y, it) < 14) return { kind: kind, id: it.id };
				continue;
			}
			const b = root.boxOf(it);
			if (x >= b.x * root.width - 6 && x <= (b.x + b.w) * root.width + 6 && y >= b.y * root.height - 6 && y <= (b.y + b.h) * root.height + 6) return { kind: kind, id: it.id };
		}
		return null;
	}

	function nearLine(x, y, it) {
		const ax = it.x1 * root.width, ay = it.y1 * root.height, bx = it.x2 * root.width, by = it.y2 * root.height;
		const dx = bx - ax, dy = by - ay;
		const k = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / Math.max(1, dx * dx + dy * dy)));
		return Math.hypot(x - ax - k * dx, y - ay - k * dy);
	}

	// which handle of the selected one is under a point ("tl" … "move", "p1", "p2")
	function handleAt(x, y) {
		const it = root.selected;
		if (!it) return "";
		if (it.kind === "arrow") {
			if (Math.hypot(x - it.x1 * root.width, y - it.y1 * root.height) < 16) return "p1";
			if (Math.hypot(x - it.x2 * root.width, y - it.y2 * root.height) < 16) return "p2";
			return root.nearLine(x, y, it) < 14 ? "move" : "";
		}
		const b = root.selectedBox, m = 14;
		const l = Math.abs(x - b.x) < m, r = Math.abs(x - b.x - b.width) < m;
		const t = Math.abs(y - b.y) < m, bo = Math.abs(y - b.y - b.height) < m;
		if (x < b.x - m || x > b.x + b.width + m || y < b.y - m || y > b.y + b.height + m) return "";
		const v = t ? "t" : (bo ? "b" : ""), hz = l ? "l" : (r ? "r" : "");
		if (v || hz) return v + hz;
		return "move";
	}

	// the item's new place from where it was when pressed (dx, dy 0..1 of the frame)
	function moved(start, handle, dx, dy) {
		if (start.kind === "arrow") {
			const out = {};
			const clamp = v => Math.max(0, Math.min(1, v));
			if (handle === "p1" || handle === "move") {
				out.x1 = clamp(start.x1 + dx);
				out.y1 = clamp(start.y1 + dy);
			}
			if (handle === "p2" || handle === "move") {
				out.x2 = clamp(start.x2 + dx);
				out.y2 = clamp(start.y2 + dy);
			}
			return out;
		}
		let x1 = start.x, y1 = start.y, x2 = start.x + start.w, y2 = start.y + start.h;
		if (handle === "move") {
			const nx = Math.max(0, Math.min(1 - start.w, x1 + dx)), ny = Math.max(0, Math.min(1 - start.h, y1 + dy));
			return { x: nx, y: ny };
		}
		if (handle.includes("l")) x1 = Math.max(0, Math.min(x2 - 0.02, x1 + dx));
		if (handle.includes("r")) x2 = Math.min(1, Math.max(x1 + 0.02, x2 + dx));
		if (handle.includes("t")) y1 = Math.max(0, Math.min(y2 - 0.02, y1 + dy));
		if (handle.includes("b")) y2 = Math.min(1, Math.max(y1 + 0.02, y2 + dy));
		return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
	}

	MouseArea {
		id: picker

		anchors.fill: parent
		enabled: root.picking
		hoverEnabled: true
		preventStealing: true
		property string handle: ""
		property var start: null
		property string kind: ""
		property point pressAt: Qt.point(0, 0)

		cursorShape: {
			if (!root.picking) return Qt.ArrowCursor;
			const h = picker.pressed ? picker.handle : root.handleAt(mouseX, mouseY);
			if (h === "move") return picker.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor;
			if (h === "p1" || h === "p2") return Qt.SizeAllCursor;
			if (h === "tl" || h === "br") return Qt.SizeFDiagCursor;
			if (h === "tr" || h === "bl") return Qt.SizeBDiagCursor;
			if (h === "t" || h === "b") return Qt.SizeVerCursor;
			if (h === "l" || h === "r") return Qt.SizeHorCursor;
			return root.itemAt(mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor;
		}

		onPressed: event => {
			let h = root.handlesShown ? root.handleAt(event.x, event.y) : "";
			if (h === "") {
				const hit = root.itemAt(event.x, event.y);
				if (!hit) {
					// a click beside them: nothing picked, and the film gets the click
					root.editor.selectedItem = null;
					picker.handle = "";
					event.accepted = false;
					return;
				}
				root.editor.selectedItem = hit;
				h = "move";
			}
			picker.kind = root.selectedKind;
			picker.handle = h;
			picker.start = Edit.copy(root.selected);
			picker.pressAt = Qt.point(event.x, event.y);
		}
		onPositionChanged: event => {
			if (!pressed || !picker.start || picker.handle === "") return;
			const dx = (event.x - picker.pressAt.x) / Math.max(1, root.width), dy = (event.y - picker.pressAt.y) / Math.max(1, root.height);
			if (Math.abs(dx) + Math.abs(dy) < 0.002) return;
			const changes = root.moved(picker.start, picker.handle, dx, dy);
			const id = picker.start.id, key = picker.kind === "blur" ? "blurs" : "texts";
			root.editor.drag(r => {
				const it = (r[key] || []).find(v => v.id === id);
				if (it) Object.assign(it, changes);
			});
		}
		onReleased: {
			root.editor.endDrag();
			picker.handle = "";
			picker.start = null;
		}
		onCanceled: {
			root.editor.endDrag();
			picker.handle = "";
			picker.start = null;
		}
		onWheel: wheel => wheel.accepted = false
	}

	// the selected one's frame and handles
	Item {
		visible: root.handlesShown && !root.selectedIsArrow
		x: root.selectedBox.x
		y: root.selectedBox.y
		width: root.selectedBox.width
		height: root.selectedBox.height

		Rectangle {
			anchors.fill: parent
			anchors.margins: -1
			color: "transparent"
			border.width: 1.5
			border.color: root.editor?.accent ?? Theme.primary
		}

		Repeater {
			model: ["tl", "tr", "bl", "br"]

			delegate: Rectangle {
				required property string modelData

				x: (modelData.includes("l") ? 0 : parent.width) - width / 2
				y: (modelData.includes("t") ? 0 : parent.height) - height / 2
				width: 12
				height: 12
				radius: 3
				color: "white"
				border.width: 2
				border.color: root.editor?.accent ?? Theme.primary
			}
		}
	}

	Repeater {
		model: root.handlesShown && root.selectedIsArrow ? 2 : 0

		delegate: Rectangle {
			required property int index
			readonly property real px: (index === 0 ? root.selected.x1 : root.selected.x2) * root.width
			readonly property real py: (index === 0 ? root.selected.y1 : root.selected.y2) * root.height

			x: px - width / 2
			y: py - height / 2
			width: 16
			height: 16
			radius: 8
			color: "white"
			border.width: 3
			border.color: root.editor?.accent ?? Theme.primary
		}
	}

	// ── the crop's handles, over the whole picture ─────────────────────────
	readonly property var geometry: Geo.normalised(root.recipe.geometry)
	readonly property real srcW: root.editor?.stage?.srcW ?? 1920
	readonly property real srcH: root.editor?.stage?.srcH ?? 1080
	readonly property var full: Geo.fullSize(root.geometry, root.srcW, root.srcH)
	property var draft: null
	readonly property var crop: root.draft ?? root.geometry.crop
	readonly property rect cropBox: Qt.rect(root.crop.x * root.width, root.crop.y * root.height, root.crop.w * root.width, root.crop.h * root.height)

	function validCrop(c) {
		const g = Object.assign({}, root.geometry, { crop: c });
		return c.w > 0.01 && c.h > 0.01 && Geo.covered(g, root.srcW, root.srcH, c.x, c.y) && Geo.covered(g, root.srcW, root.srcH, c.x + c.w, c.y)
			&& Geo.covered(g, root.srcW, root.srcH, c.x, c.y + c.h) && Geo.covered(g, root.srcW, root.srcH, c.x + c.w, c.y + c.h);
	}

	// a handle ("tl", "t", …, "move") dragged by dx, dy (0..1 of the full picture), the shape kept when asked (as CropTools does it)
	function croppedTo(start, handle, dx, dy, keep) {
		let x1 = start.x, y1 = start.y, x2 = start.x + start.w, y2 = start.y + start.h;
		if (handle === "move") {
			return { x: Math.max(0, Math.min(1 - start.w, x1 + dx)), y: Math.max(0, Math.min(1 - start.h, y1 + dy)), w: start.w, h: start.h };
		}
		if (handle.includes("l")) x1 += dx;
		if (handle.includes("r")) x2 += dx;
		if (handle.includes("t")) y1 += dy;
		if (handle.includes("b")) y2 += dy;
		const min = 0.02;
		if (x2 - x1 < min) handle.includes("l") ? x1 = x2 - min : x2 = x1 + min;
		if (y2 - y1 < min) handle.includes("t") ? y1 = y2 - min : y2 = y1 + min;
		const a = keep > 0 ? keep * root.full[1] / root.full[0] : 0;
		if (a > 0) {
			// the shape kept: the side dragged most leads
			let w = x2 - x1, h = y2 - y1;
			const edgeOnly = handle.length === 1;
			if (edgeOnly ? (handle === "l" || handle === "r") : w / a > h) h = w / a;
			else w = h * a;
			if (handle === "t" || handle === "b") w = h * a;
			if (handle.includes("l")) x1 = x2 - w;
			else if (handle.includes("r")) x2 = x1 + w;
			else {
				const cx = start.x + start.w / 2;
				x1 = cx - w / 2;
				x2 = cx + w / 2;
			}
			if (handle.includes("t")) y1 = y2 - h;
			else if (handle.includes("b")) y2 = y1 + h;
			else {
				const cy = start.y + start.h / 2;
				y1 = cy - h / 2;
				y2 = cy + h / 2;
			}
		}
		x1 = Math.max(0, x1);
		y1 = Math.max(0, y1);
		x2 = Math.min(1, x2);
		y2 = Math.min(1, y2);
		return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
	}

	Item {
		id: cropLayer

		anchors.fill: parent
		visible: root.cropping
		opacity: root.cropping ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		// dimmed around the crop
		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			ShapePath {
				fillColor: Qt.rgba(0, 0, 0, 0.55)
				strokeColor: "transparent"
				fillRule: ShapePath.OddEvenFill

				PathRectangle {
					x: 0
					y: 0
					width: root.width
					height: root.height
				}

				PathRectangle {
					x: root.cropBox.x
					y: root.cropBox.y
					width: root.cropBox.width
					height: root.cropBox.height
				}
			}
		}

		Item {
			id: cropFrame

			x: root.cropBox.x
			y: root.cropBox.y
			width: root.cropBox.width
			height: root.cropBox.height

			Rectangle {
				anchors.fill: parent
				color: "transparent"
				border.width: 1.5
				border.color: Qt.rgba(1, 1, 1, 0.9)
			}

			// the thirds, brighter while it moves
			Repeater {
				model: 4

				delegate: Rectangle {
					required property int index
					readonly property bool across: index < 2

					x: across ? 0 : cropFrame.width * ((index - 1) / 3)
					y: across ? cropFrame.height * ((index + 1) / 3) : 0
					width: across ? cropFrame.width : 1
					height: across ? 1 : cropFrame.height
					color: Qt.rgba(1, 1, 1, 0.45)
					opacity: cropArea.pressed ? 1 : 0.4

					Behavior on opacity {
						Anim {}
					}
				}
			}

			Repeater {
				model: ["tl", "tr", "bl", "br"]

				delegate: Item {
					required property string modelData

					x: modelData.includes("l") ? -3 : cropFrame.width - 25
					y: modelData.includes("t") ? -3 : cropFrame.height - 25
					width: 28
					height: 28

					Rectangle {
						x: parent.modelData.includes("l") ? 0 : 24
						width: 4
						height: 28
						radius: 2
						color: "white"
					}

					Rectangle {
						y: parent.modelData.includes("t") ? 0 : 24
						width: 28
						height: 4
						radius: 2
						color: "white"
					}
				}
			}
		}

		MouseArea {
			id: cropArea

			anchors.fill: parent
			enabled: root.cropping
			hoverEnabled: true
			preventStealing: true
			property string handle: ""
			property var start: null
			property point pressAt: Qt.point(0, 0)

			function handleAt(x, y) {
				const b = root.cropBox, m = 18;
				const l = Math.abs(x - b.x) < m, r = Math.abs(x - b.x - b.width) < m;
				const t = Math.abs(y - b.y) < m, bo = Math.abs(y - b.y - b.height) < m;
				if (x < b.x - m || x > b.x + b.width + m || y < b.y - m || y > b.y + b.height + m) return "";
				const v = t ? "t" : (bo ? "b" : ""), hz = l ? "l" : (r ? "r" : "");
				if (v || hz) return v + hz;
				return "move";
			}

			cursorShape: {
				const h = cropArea.pressed ? cropArea.handle : cropArea.handleAt(mouseX, mouseY);
				if (h === "move") return cropArea.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor;
				if (h === "tl" || h === "br") return Qt.SizeFDiagCursor;
				if (h === "tr" || h === "bl") return Qt.SizeBDiagCursor;
				if (h === "t" || h === "b") return Qt.SizeVerCursor;
				if (h === "l" || h === "r") return Qt.SizeHorCursor;
				return Qt.ArrowCursor;
			}

			onPressed: event => {
				cropArea.handle = cropArea.handleAt(event.x, event.y);
				cropArea.start = root.geometry.crop;
				cropArea.pressAt = Qt.point(event.x, event.y);
				if (cropArea.handle === "") event.accepted = false;
			}
			onPositionChanged: event => {
				if (!pressed || !cropArea.start) return;
				const dx = (event.x - cropArea.pressAt.x) / Math.max(1, root.width);
				const dy = (event.y - cropArea.pressAt.y) / Math.max(1, root.height);
				const next = root.croppedTo(cropArea.start, cropArea.handle, dx, dy, root.cropAspect);
				if (root.validCrop(next)) root.draft = next;
			}
			onReleased: {
				if (root.draft) {
					const c = root.draft;
					root.editor.change(r => {
						r.geometry = Geo.normalised(r.geometry);
						r.geometry.crop = c;
					});
					root.draft = null;
				}
				cropArea.handle = "";
			}
			onWheel: wheel => wheel.accepted = false
		}
	}

	// ── the texts as pictures, for the export ──────────────────────────────
	property var renderList: []
	property var renderDone: null
	readonly property string overlayDir: `${Paths.cache}/video/overlays`
	// the export's size: the source through the crop (not the stage's, which
	// leaves the crop out while it is set)
	readonly property var exportSize: Geo.outputSize(root.geometry, root.srcW, root.srcH)

	// every text, arrow and box as a PNG at the export's size; done([{ id, a, b, file, x, y, w, h, fade }])
	function renderTexts(done) {
		const list = root.texts.filter(t => t && t.b > t.a && (t.kind !== "text" || String(t.text || "").trim() !== ""));
		if (list.length === 0) return done([]);
		if (root.renderDone) return root.editor?.say("The texts are being made already", "format_text");
		root.renderDone = done;
		root.renderList = Edit.copy(list);
		makeDir.running = true;
	}

	Process {
		id: makeDir

		command: ["mkdir", "-p", root.overlayDir]
		onExited: {
			renderRoom.model = root.renderList.length;
			renderTimer.restart();
		}
	}

	// a moment for the fonts to be laid out
	Timer {
		id: renderTimer

		interval: 120
		onTriggered: root.grabNext(0, [])
	}

	function grabNext(i, out) {
		if (i >= root.renderList.length) {
			const done = root.renderDone;
			root.renderDone = null;
			renderRoom.model = 0;
			root.renderList = [];
			if (done) done(out);
			return;
		}
		const art = renderRoom.itemAt(i);
		const it = root.renderList[i];
		if (!art || art.width < 1 || art.height < 1) return root.grabNext(i + 1, out);
		const file = `${root.overlayDir}/${it.id}.png`;
		const W = root.exportSize[0], H = root.exportSize[1];
		const ok = art.grabToImage(result => {
			if (result.saveToFile(file)) out.push({ id: it.id, a: it.a, b: it.b, file: file, x: art.x / W, y: art.y / H, w: art.width / W, h: art.height / H, fade: Number(it.fade) || 0 });
			root.grabNext(i + 1, out);
		});
		if (!ok) root.grabNext(i + 1, out);
	}

	// out of sight, at the export's size
	Item {
		x: -100000
		width: root.exportSize[0]
		height: root.exportSize[1]

		Repeater {
			id: renderRoom

			model: 0

			delegate: Art {
				required property int index

				item: root.renderList[index] ?? null
				frameW: root.exportSize[0]
				frameH: root.exportSize[1]
			}
		}
	}

	// ── one text, arrow or box, at a frame's size ──────────────────────────
	// placed where it sits on a frame of frameW × frameH; a text is as tall
	// as its box or its words, whichever is more
	component Art: Item {
		id: art

		property var item: null
		property real frameW: 1
		property real frameH: 1

		readonly property string kind: art.item?.kind ?? "text"
		readonly property string look: art.item?.style ?? "plain"
		readonly property real px: Math.max(4, (Number(art.item?.size) || 0.07) * art.frameH)
		readonly property real line: Math.max(1, (Number(art.item?.stroke) || 0.008) * art.frameH)
		readonly property color colour: art.item?.color ?? "#ffffff"
		// an arrow's head, and the room around its line
		readonly property real head: art.line * 4
		readonly property real margin: art.kind === "arrow" ? art.head : (art.kind === "rect" ? art.line : 0)

		x: (art.kind === "arrow" ? Math.min(art.item?.x1 ?? 0, art.item?.x2 ?? 0) : (art.item?.x ?? 0)) * art.frameW - art.margin
		y: (art.kind === "arrow" ? Math.min(art.item?.y1 ?? 0, art.item?.y2 ?? 0) : (art.item?.y ?? 0)) * art.frameH - art.margin
		width: (art.kind === "arrow" ? Math.abs((art.item?.x2 ?? 0) - (art.item?.x1 ?? 0)) : (art.item?.w ?? 0)) * art.frameW + 2 * art.margin
		height: art.kind === "text" ? Math.max((art.item?.h ?? 0) * art.frameH, words.implicitHeight + art.px * 0.5) : (art.kind === "arrow" ? Math.abs((art.item?.y2 ?? 0) - (art.item?.y1 ?? 0)) : (art.item?.h ?? 0)) * art.frameH + 2 * art.margin

		// a title card's band, a box behind the words
		Rectangle {
			visible: art.kind === "text" && art.look === "title"
			anchors.fill: parent
			color: Qt.rgba(0, 0, 0, 0.6)
		}

		Rectangle {
			visible: art.kind === "text" && art.look === "box"
			anchors.verticalCenter: words.verticalCenter
			width: Math.min(art.width, words.contentWidth + art.px * 0.8)
			height: words.contentHeight + art.px * 0.35
			x: words.horizontalAlignment === Text.AlignLeft ? 0 : (words.horizontalAlignment === Text.AlignRight ? art.width - width : (art.width - width) / 2)
			radius: art.px * 0.22
			color: Qt.rgba(0, 0, 0, 0.62)
		}

		Text {
			id: words

			visible: art.kind === "text"
			x: art.look === "box" ? art.px * 0.4 : art.px * 0.15
			width: art.width - 2 * x
			anchors.verticalCenter: parent.verticalCenter
			text: art.item?.text ?? ""
			wrapMode: Text.Wrap
			horizontalAlignment: ({ left: Text.AlignLeft, right: Text.AlignRight })[art.item?.align ?? "center"] ?? Text.AlignHCenter
			color: art.colour
			font.family: Theme.fontFamily
			font.pixelSize: art.px
			font.weight: Number(art.item?.weight) || 600
			lineHeight: 1.05
			style: art.look === "outline" ? Text.Outline : Text.Normal
			styleColor: Qt.rgba(0, 0, 0, 0.9)
			layer.enabled: art.look === "shadow" || art.look === "title"
			layer.effect: MultiEffect {
				shadowEnabled: true
				shadowColor: "black"
				shadowOpacity: 0.75
				shadowBlur: 0.5
				shadowVerticalOffset: art.px * 0.05
				shadowHorizontalOffset: art.px * 0.03
			}
		}

		// a box's outline
		Rectangle {
			visible: art.kind === "rect"
			anchors.fill: parent
			anchors.margins: art.margin / 2
			color: "transparent"
			radius: art.line
			border.width: art.line
			border.color: art.colour
		}

		// an arrow: its line and its head, from x1 y1 to x2 y2
		Shape {
			id: arrow

			readonly property real ax: (art.item?.x1 ?? 0) * art.frameW - art.x
			readonly property real ay: (art.item?.y1 ?? 0) * art.frameH - art.y
			readonly property real bx: (art.item?.x2 ?? 0) * art.frameW - art.x
			readonly property real by: (art.item?.y2 ?? 0) * art.frameH - art.y
			readonly property real angle: Math.atan2(arrow.by - arrow.ay, arrow.bx - arrow.ax)
			// where the line stops, under the head
			readonly property real ex: arrow.bx - Math.cos(arrow.angle) * art.head * 0.8
			readonly property real ey: arrow.by - Math.sin(arrow.angle) * art.head * 0.8

			visible: art.kind === "arrow"
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			ShapePath {
				strokeColor: art.colour
				strokeWidth: art.line
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap
				startX: arrow.ax
				startY: arrow.ay

				PathLine {
					x: arrow.ex
					y: arrow.ey
				}
			}

			ShapePath {
				strokeColor: art.colour
				strokeWidth: 1
				fillColor: art.colour
				joinStyle: ShapePath.RoundJoin
				startX: arrow.bx
				startY: arrow.by

				PathLine {
					x: arrow.bx - Math.cos(arrow.angle - 0.45) * art.head
					y: arrow.by - Math.sin(arrow.angle - 0.45) * art.head
				}
				PathLine {
					x: arrow.bx - Math.cos(arrow.angle + 0.45) * art.head
					y: arrow.by - Math.sin(arrow.angle + 0.45) * art.head
				}
				PathLine {
					x: arrow.bx
					y: arrow.by
				}
			}
		}
	}
}
