pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Geometry.js" as Geo
import "Recipe.js" as Recipe

// Cutting and straightening: the whole picture is shown (Stage.cropless)
// with the crop over it – corners and edges resize it, inside it moves,
// a shape keeps it to 1:1, 16:9 or a screen of this desk. Below: quarter
// turns, mirroring, the horizon (by hand or found), perspective, and a
// document's four corners (found, or put by hand).
Item {
	id: root

	required property Item stage
	property real barHeight: bar.height + 24

	readonly property Item slot: root.stage.frontSlot
	readonly property var geometry: Geo.normalised(Viewer.recipe.geometry)
	readonly property real srcW: Viewer.info?.width ?? 1
	readonly property real srcH: Viewer.info?.height ?? 1
	readonly property var full: Geo.fullSize(root.geometry, root.srcW, root.srcH)
	// 0 free, otherwise width / height
	property real aspect: 0
	property string aspectId: "free"
	// the crop being dragged, 0..1 of the full picture
	property var draft: null
	readonly property var crop: root.draft ?? root.geometry.crop
	// the document's corners by hand
	property bool corners: false
	property var quadDraft: null
	property bool finding: false

	// where the content sits on this item
	readonly property point origin: root.slot ? root.stage.mapToItem(root, root.slot.x, root.slot.y) : Qt.point(0, 0)
	readonly property real k: root.slot ? root.slot.s : 1
	readonly property real contentW: root.slot ? root.slot.content.width : 1
	readonly property real contentH: root.slot ? root.slot.content.height : 1
	readonly property rect box: Qt.rect(root.origin.x + root.crop.x * root.contentW * root.k, root.origin.y + root.crop.y * root.contentH * root.k,
		root.crop.w * root.contentW * root.k, root.crop.h * root.contentH * root.k)

	function aspects() {
		const out = [{ id: "free", label: "Free", value: 0 }, { id: "original", label: "Original", value: root.srcW / root.srcH }, { id: "1:1", label: "Square", value: 1 },
			{ id: "4:5", label: "4:5", value: 4 / 5 }, { id: "3:2", label: "3:2", value: 3 / 2 }, { id: "4:3", label: "4:3", value: 4 / 3 },
			{ id: "16:9", label: "16:9", value: 16 / 9 }, { id: "9:16", label: "9:16", value: 9 / 16 }];
		// the screens of this desk (a wallpaper that fits)
		for (const screen of Quickshell.screens) {
			const w = screen.width * (screen.devicePixelRatio || 1), h = screen.height * (screen.devicePixelRatio || 1);
			out.push({ id: `screen:${screen.name}`, label: `${screen.name} ${Math.round(w)}×${Math.round(h)}`, value: w / h, icon: "monitor" });
		}
		if (Phone.available) out.push({ id: "phone", label: Phone.name, value: 9 / 19.5, icon: "cellphone" });
		return out;
	}

	function setAspect(option) {
		root.aspectId = option.id;
		root.aspect = option.value;
		if (option.value <= 0) return;
		// the shape in the picture's pixels
		const next = Recipe.copy(Viewer.recipe);
		next.geometry.crop = Geo.cropForAspect(next.geometry, root.srcW, root.srcH, option.value);
		root.commitGeometry(next);
	}

	function commitGeometry(next) {
		next.markup.items = Geo.remapItems(Viewer.recipe.markup?.items ?? [], Viewer.recipe.geometry, next.geometry, root.srcW, root.srcH);
		Viewer.commit(next);
	}

	function previewGeometry(next) {
		next.markup.items = Geo.remapItems(Viewer.committed.markup?.items ?? [], Viewer.committed.geometry, next.geometry, root.srcW, root.srcH);
		Viewer.preview(next);
	}

	// the crop's shape in pixels, kept while turning and straightening
	function cropAspect(g) {
		const f = Geo.fullSize(g, root.srcW, root.srcH);
		return g.crop.w * f[0] / Math.max(1e-6, g.crop.h * f[1]);
	}

	function turn(quarters) {
		const next = Recipe.copy(Viewer.recipe);
		const before = root.cropAspect(next.geometry);
		next.geometry.rot = ((next.geometry.rot + quarters) % 4 + 4) % 4;
		next.geometry.quad = null;
		// the crop turns along
		const c = next.geometry.crop;
		next.geometry.crop = quarters > 0 ? { x: 1 - c.y - c.h, y: c.x, w: c.h, h: c.w } : { x: c.y, y: 1 - c.x - c.w, w: c.h, h: c.w };
		if (root.aspect > 0) root.aspect = 1 / root.aspect;
		next.geometry.crop = Geo.fitCrop(next.geometry, root.srcW, root.srcH);
		void before;
		root.commitGeometry(next);
	}

	function mirror() {
		const next = Recipe.copy(Viewer.recipe);
		next.geometry.flip = !next.geometry.flip;
		next.geometry.angle = -next.geometry.angle;
		next.geometry.horizontal = -next.geometry.horizontal;
		const c = next.geometry.crop;
		next.geometry.crop = { x: 1 - c.x - c.w, y: c.y, w: c.w, h: c.h };
		if (next.geometry.quad) next.geometry.quad = [next.geometry.quad[1], next.geometry.quad[0], next.geometry.quad[3], next.geometry.quad[2]].map(p => [1 - p[0], p[1]]);
		root.commitGeometry(next);
	}

	// straighten or tilt: the crop keeps its shape and grows as far as the picture lets it
	function shape(key, value, commit) {
		const base = commit ? Viewer.recipe : Viewer.committed;
		const next = Recipe.copy(base);
		const a = root.aspect > 0 ? root.aspect : root.cropAspect(next.geometry);
		next.geometry[key] = value;
		next.geometry.quad = null;
		next.geometry.crop = Geo.cropForAspect(next.geometry, root.srcW, root.srcH, a);
		if (commit) root.commitGeometry(next);
		else root.previewGeometry(next);
	}

	function findHorizon() {
		if (root.finding) return;
		root.finding = true;
		Viewer.request("straighten", { path: Viewer.shownPath }, (data, error) => {
			root.finding = false;
			if (error) return Viewer.fail(error);
			if (data.found === false || Math.abs(data.angle) < 0.05) return Viewer.say("The picture is level", "angle_acute");
			// the helper's angle is of the upright picture; mirrored, it turns the other way
			root.shape("angle", Math.round((root.geometry.flip ? -data.angle : data.angle) * 10) / 10, true);
		});
	}

	// the turned picture's 0..1 from the upright source's
	function turnedPoint(p) {
		const m = Geo.inverse(Geo.unturn(root.geometry));
		return Geo.apply(m, p[0], p[1]);
	}

	function findDocument() {
		if (root.finding) return;
		root.finding = true;
		Viewer.request("document", { path: Viewer.shownPath }, (data, error) => {
			root.finding = false;
			if (error) return Viewer.fail(error);
			if (!data.quad) return Viewer.say("No page or screen found in it – put the corners by hand", "file_document_outline");
			let q = data.quad.map(p => root.turnedPoint(p));
			if (root.geometry.flip) q = [q[1], q[0], q[3], q[2]];
			root.setQuad(q);
		});
	}

	function setQuad(q) {
		const next = Recipe.copy(Viewer.recipe);
		next.geometry.quad = q;
		next.geometry.angle = 0;
		next.geometry.vertical = 0;
		next.geometry.horizontal = 0;
		next.geometry.crop = { x: 0, y: 0, w: 1, h: 1 };
		root.aspectId = "free";
		root.aspect = 0;
		root.commitGeometry(next);
	}

	function startCorners() {
		const q = root.geometry.quad ?? [[0.08, 0.08], [0.92, 0.08], [0.92, 0.92], [0.08, 0.92]];
		root.quadDraft = q;
		root.corners = true;
		// the turned picture, straight, without the corners applied
		const next = Recipe.copy(Viewer.committed);
		next.geometry = Object.assign(Geo.defaults(), { rot: next.geometry.rot, flip: next.geometry.flip });
		Viewer.preview(next);
	}

	function endCorners(apply) {
		root.corners = false;
		const q = root.quadDraft;
		root.quadDraft = null;
		Viewer.preview(Viewer.committed);
		if (apply && q) root.setQuad(q);
	}

	function resetGeometry() {
		const next = Recipe.copy(Viewer.recipe);
		next.geometry = Geo.defaults();
		root.aspectId = "free";
		root.aspect = 0;
		root.commitGeometry(next);
	}

	function done() {
		if (root.corners) root.endCorners(true);
		Viewer.setMode("view");
	}

	// ── the crop by hand ───────────────────────────────────────────────────
	function valid(c) {
		const g = Object.assign({}, root.geometry, { crop: c });
		return c.w > 0.01 && c.h > 0.01 && Geo.covered(g, root.srcW, root.srcH, c.x, c.y) && Geo.covered(g, root.srcW, root.srcH, c.x + c.w, c.y)
			&& Geo.covered(g, root.srcW, root.srcH, c.x, c.y + c.h) && Geo.covered(g, root.srcW, root.srcH, c.x + c.w, c.y + c.h);
	}

	// a handle ("tl", "t", …, "move") dragged by dx, dy (0..1 of the full picture) from `start`
	function dragged(start, handle, dx, dy, keep) {
		let x1 = start.x, y1 = start.y, x2 = start.x + start.w, y2 = start.y + start.h;
		if (handle === "move") {
			const w = start.w, h = start.h;
			x1 = Math.max(0, Math.min(1 - w, x1 + dx));
			y1 = Math.max(0, Math.min(1 - h, y1 + dy));
			return { x: x1, y: y1, w: w, h: h };
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
				const cx = (start.x + start.w / 2);
				x1 = cx - w / 2;
				x2 = cx + w / 2;
			}
			if (handle.includes("t")) y1 = y2 - h;
			else if (handle.includes("b")) y2 = y1 + h;
			else {
				const cy = (start.y + start.h / 2);
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

	// dimmed around the crop
	Shape {
		anchors.fill: parent
		visible: !root.corners
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
				x: root.box.x
				y: root.box.y
				width: root.box.width
				height: root.box.height
			}
		}
	}

	Item {
		id: frame

		visible: !root.corners
		x: root.box.x
		y: root.box.y
		width: root.box.width
		height: root.box.height

		Rectangle {
			anchors.fill: parent
			color: "transparent"
			border.width: 1.5
			border.color: Qt.rgba(1, 1, 1, 0.9)
		}

		// thirds while it moves
		Repeater {
			model: 4

			delegate: Rectangle {
				required property int index
				readonly property bool across: index < 2

				x: across ? 0 : frame.width * ((index - 1) / 3)
				y: across ? frame.height * ((index + 1) / 3) : 0
				width: across ? frame.width : 1
				height: across ? 1 : frame.height
				color: Qt.rgba(1, 1, 1, 0.45)
				opacity: dragArea.pressed ? 1 : 0

				Behavior on opacity {
					Anim {}
				}
			}
		}

		Repeater {
			model: ["tl", "tr", "bl", "br"]

			delegate: Item {
				required property string modelData

				x: modelData.includes("l") ? -3 : frame.width - 25
				y: modelData.includes("t") ? -3 : frame.height - 25
				width: 28
				height: 28

				Rectangle {
					x: parent.modelData.includes("l") ? 0 : 24
					y: parent.modelData.includes("t") ? 0 : 0
					width: 4
					height: 28
					radius: 2
					color: "white"
				}

				Rectangle {
					x: 0
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
		id: dragArea

		anchors.fill: parent
		visible: !root.corners
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton
		property string handle: ""
		property var start: null
		property point pressAt: Qt.point(0, 0)

		function handleAt(x, y) {
			const b = root.box, m = 18;
			const l = Math.abs(x - b.x) < m, r = Math.abs(x - b.x - b.width) < m;
			const t = Math.abs(y - b.y) < m, bo = Math.abs(y - b.y - b.height) < m;
			const insideX = x > b.x - m && x < b.x + b.width + m, insideY = y > b.y - m && y < b.y + b.height + m;
			if (!insideX || !insideY) return "";
			const v = t ? "t" : (bo ? "b" : ""), hz = l ? "l" : (r ? "r" : "");
			if (v || hz) return v + hz;
			return x > b.x && x < b.x + b.width && y > b.y && y < b.y + b.height ? "move" : "";
		}

		cursorShape: {
			const h = dragArea.pressed ? dragArea.handle : dragArea.handleAt(mouseX, mouseY);
			if (h === "move") return dragArea.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor;
			if (h === "tl" || h === "br") return Qt.SizeFDiagCursor;
			if (h === "tr" || h === "bl") return Qt.SizeBDiagCursor;
			if (h === "t" || h === "b") return Qt.SizeVerCursor;
			if (h === "l" || h === "r") return Qt.SizeHorCursor;
			return Qt.ArrowCursor;
		}

		onPressed: event => {
			dragArea.handle = dragArea.handleAt(event.x, event.y);
			dragArea.start = root.geometry.crop;
			dragArea.pressAt = Qt.point(event.x, event.y);
			if (dragArea.handle === "") event.accepted = false;
		}
		onPositionChanged: event => {
			if (!pressed || !dragArea.start) return;
			const dx = (event.x - dragArea.pressAt.x) / (root.contentW * root.k);
			const dy = (event.y - dragArea.pressAt.y) / (root.contentH * root.k);
			const next = root.dragged(dragArea.start, dragArea.handle, dx, dy, root.aspect);
			if (root.valid(next)) root.draft = next;
		}
		onReleased: {
			if (root.draft) {
				const next = Recipe.copy(Viewer.recipe);
				next.geometry.crop = root.draft;
				root.draft = null;
				root.commitGeometry(next);
			}
			dragArea.handle = "";
		}
		onWheel: wheel => wheel.accepted = false
	}

	// ── the four corners of a document ─────────────────────────────────────
	Shape {
		anchors.fill: parent
		visible: root.corners && !!root.quadDraft
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: Theme.primary
			strokeWidth: 2
			fillColor: Qt.alpha(Theme.primary, 0.12)
			startX: root.cornerAt(0).x
			startY: root.cornerAt(0).y

			PathLine {
				x: root.cornerAt(1).x
				y: root.cornerAt(1).y
			}
			PathLine {
				x: root.cornerAt(2).x
				y: root.cornerAt(2).y
			}
			PathLine {
				x: root.cornerAt(3).x
				y: root.cornerAt(3).y
			}
			PathLine {
				x: root.cornerAt(0).x
				y: root.cornerAt(0).y
			}
		}
	}

	function cornerAt(i) {
		const q = root.quadDraft;
		if (!q) return Qt.point(0, 0);
		return Qt.point(root.origin.x + q[i][0] * root.contentW * root.k, root.origin.y + q[i][1] * root.contentH * root.k);
	}

	Repeater {
		model: root.corners ? 4 : 0

		delegate: Rectangle {
			id: corner

			required property int index
			readonly property point at: root.cornerAt(index)

			x: at.x - width / 2
			y: at.y - height / 2
			width: cornerMouse.pressed ? 26 : 20
			height: width
			radius: width / 2
			color: Theme.base
			border.width: 3
			border.color: Theme.primary

			Behavior on width {
				SpatialAnim {}
			}

			MouseArea {
				id: cornerMouse

				anchors.fill: parent
				anchors.margins: -10
				cursorShape: Qt.SizeAllCursor
				preventStealing: true
				onPositionChanged: event => {
					if (!pressed) return;
					const p = mapToItem(root, event.x, event.y);
					const q = root.quadDraft.map(v => [v[0], v[1]]);
					q[corner.index] = [Math.max(0, Math.min(1, (p.x - root.origin.x) / (root.contentW * root.k))), Math.max(0, Math.min(1, (p.y - root.origin.y) / (root.contentH * root.k)))];
					root.quadDraft = q;
				}
			}
		}
	}

	// ── the tools below ────────────────────────────────────────────────────
	Rectangle {
		id: bar

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 12
		width: Math.min(parent.width - 24, barColumn.implicitWidth + 32)
		height: barColumn.implicitHeight + 24
		radius: Theme.radius.huge
		color: Theme.glass
		border.width: 1
		border.color: Theme.outline

		Column {
			id: barColumn

			anchors.centerIn: parent
			width: Math.min(bar.parent.width - 56, implicitWidth)
			spacing: 10

			ListView {
				width: Math.min(parent.width, contentWidth)
				anchors.horizontalCenter: parent.horizontalCenter
				implicitWidth: contentWidth
				height: 32
				orientation: ListView.Horizontal
				spacing: 6
				clip: true
				visible: !root.corners
				model: root.aspects()
				boundsBehavior: Flickable.StopAtBounds

				delegate: Chip {
					required property var modelData

					text: modelData.label
					icon: modelData.icon ?? ""
					selected: root.aspectId === modelData.id
					onClicked: root.setAspect(modelData)
				}
			}

			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: 10
				visible: !root.corners

				IconButton {
					width: 38
					height: 38
					icon: "rotate_left"
					onClicked: root.turn(-1)
				}

				IconButton {
					width: 38
					height: 38
					icon: "rotate_right"
					onClicked: root.turn(1)
				}

				IconButton {
					width: 38
					height: 38
					icon: "flip_horizontal"
					checked: root.geometry.flip
					onClicked: root.mirror()
				}

				Rectangle {
					width: 1
					height: 30
					anchors.verticalCenter: parent.verticalCenter
					color: Theme.outline
				}

				TuneSlider {
					width: 230
					label: "Straighten"
					icon: "angle_acute"
					from: -1
					to: 1
					step: 0.002
					value: root.geometry.angle / 45
					onMoved: value => root.shape("angle", Math.round(value * 450) / 10, false)
					onCommitted: value => root.shape("angle", Math.round(value * 450) / 10, true)
					valueText: `${(shown * 45).toFixed(1)}°`
				}

				IconButton {
					width: 38
					height: 38
					icon: "auto_fix"
					onClicked: root.findHorizon()
				}

				TuneSlider {
					width: 180
					label: "Vertical"
					icon: "arrow_expand_vertical"
					value: root.geometry.vertical
					onMoved: value => root.shape("vertical", value, false)
					onCommitted: value => root.shape("vertical", value, true)
				}

				TuneSlider {
					width: 180
					label: "Horizontal"
					icon: "arrow_expand_horizontal"
					value: root.geometry.horizontal
					onMoved: value => root.shape("horizontal", value, false)
					onCommitted: value => root.shape("horizontal", value, true)
				}

				Rectangle {
					width: 1
					height: 30
					anchors.verticalCenter: parent.verticalCenter
					color: Theme.outline
				}

				TextButton {
					anchors.verticalCenter: parent.verticalCenter
					text: root.finding ? "Looking…" : "Page"
					icon: "file_document_outline"
					busy: root.finding
					onActivated: root.findDocument()
				}

				IconButton {
					width: 38
					height: 38
					icon: "vector_square"
					checked: !!root.geometry.quad
					onClicked: root.startCorners()
				}

				IconButton {
					width: 38
					height: 38
					icon: "backup_restore"
					enabled: !Geo.isIdentity(root.geometry)
					opacity: enabled ? 1 : 0.4
					onClicked: root.resetGeometry()
				}

				TextButton {
					anchors.verticalCenter: parent.verticalCenter
					text: "Done"
					icon: "check"
					variant: "filled"
					onActivated: root.done()
				}
			}

			// putting the corners by hand
			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: 10
				visible: root.corners

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Drag the four corners onto the page, the screen or the sign"
					tone: Theme.textMuted
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: root.endCorners(false)
				}

				TextButton {
					text: "Straighten it"
					icon: "check"
					variant: "filled"
					onActivated: root.endCorners(true)
				}
			}
		}
	}
}
