pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "../viewer/Geometry.js" as Geo

// The frame: cut to a shape (a phone's 9:16, a square, the cinema's 21:9),
// turned, mirrored, straightened; black bars found and cut away; a shaky
// hand steadied. While this panel is open the whole picture is shown with
// the crop's handles over it (EditOverlay).
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property bool shown: !!root.editor && root.editor.tool === "frame"
	readonly property var geometry: Geo.normalised(Video.recipe.geometry)
	readonly property real srcW: root.editor?.stage?.srcW ?? 1920
	readonly property real srcH: root.editor?.stage?.srcH ?? 1080
	readonly property var full: Geo.fullSize(root.geometry, root.srcW, root.srcH)
	readonly property bool cropped: root.geometry.crop.x > 1e-5 || root.geometry.crop.y > 1e-5 || root.geometry.crop.w < 1 - 1e-5 || root.geometry.crop.h < 1 - 1e-5
	// 0 free, otherwise width / height; the overlay's handles keep it
	property string aspectId: "free"
	property real aspect: 0
	property bool finding: false

	readonly property var aspects: [
		{ id: "free", label: "Free", value: 0 },
		{ id: "video", label: "As the video", value: root.full[0] / Math.max(1, root.full[1]) },
		{ id: "16:9", label: "16:9", value: 16 / 9 },
		{ id: "9:16", label: "9:16 phones, Shorts", value: 9 / 16, icon: "cellphone" },
		{ id: "1:1", label: "1:1", value: 1 },
		{ id: "4:5", label: "4:5", value: 4 / 5 },
		{ id: "21:9", label: "21:9", value: 21 / 9 }
	]

	title: "Frame"
	subtitle: root.cropped ? `${Math.round(Geo.outputSize(root.geometry, root.srcW, root.srcH)[0])} × ${Math.round(Geo.outputSize(root.geometry, root.srcW, root.srcH)[1])} after the crop` : `${Math.round(root.full[0])} × ${Math.round(root.full[1])}`
	closable: false

	// the handles are there while this panel is
	onShownChanged: root.syncCropping()
	onEditorChanged: root.syncCropping()
	onAspectChanged: if (root.editor?.overlay) root.editor.overlay.cropAspect = root.aspect
	Component.onDestruction: if (root.editor && root.shown) root.editor.cropping = false

	function syncCropping() {
		if (!root.editor) return;
		root.editor.cropping = root.shown;
		if (root.editor.overlay) root.editor.overlay.cropAspect = root.aspect;
	}

	function setAspect(option) {
		root.aspectId = option.id;
		root.aspect = option.value;
		if (option.value <= 0) return;
		root.editor.change(r => {
			r.geometry = Geo.normalised(r.geometry);
			r.geometry.crop = Geo.cropForAspect(r.geometry, root.srcW, root.srcH, option.value);
		});
	}

	function cropAspect(g) {
		const f = Geo.fullSize(g, root.srcW, root.srcH);
		return g.crop.w * f[0] / Math.max(1e-6, g.crop.h * f[1]);
	}

	// a quarter turn: the crop turns along
	function turn(quarters) {
		root.editor.change(r => {
			const g = Geo.normalised(r.geometry);
			g.rot = ((g.rot + quarters) % 4 + 4) % 4;
			const c = g.crop;
			g.crop = quarters > 0 ? { x: 1 - c.y - c.h, y: c.x, w: c.h, h: c.w } : { x: c.y, y: 1 - c.x - c.w, w: c.h, h: c.w };
			g.crop = Geo.fitCrop(g, root.srcW, root.srcH);
			r.geometry = g;
		});
		if (root.aspect > 0 && root.aspectId !== "video") root.aspect = 1 / root.aspect;
	}

	function mirror() {
		root.editor.change(r => {
			const g = Geo.normalised(r.geometry);
			g.flip = !g.flip;
			g.angle = -g.angle;
			g.horizontal = -g.horizontal;
			const c = g.crop;
			g.crop = { x: 1 - c.x - c.w, y: c.y, w: c.w, h: c.h };
			r.geometry = g;
		});
	}

	// straightened: the crop keeps its shape and grows as far as the picture lets it
	function straighten(angle, live) {
		const a = root.aspect > 0 ? root.aspect : root.cropAspect(root.geometry);
		const fn = r => {
			const g = Geo.normalised(r.geometry);
			g.angle = angle;
			g.crop = Geo.cropForAspect(g, root.srcW, root.srcH, a);
			r.geometry = g;
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	// the black bars of a film in a wider or taller frame: found, cut away
	function findBars() {
		if (root.finding) return;
		root.finding = true;
		const path = Video.path;
		Video.request("blackbars", { path: path }, (data, error) => {
			root.finding = false;
			if (Video.path !== path) return;
			if (error) return root.editor.say(error, "alert_circle_outline");
			const c = data?.crop;
			if (!c || (c.w > 0.995 && c.h > 0.995)) return root.editor.say("No black bars in it", "crop_free");
			// the helper's crop is of the upright film: into the turned picture
			const m = Geo.inverse(Geo.unturn(root.geometry));
			const corners = [[c.x, c.y], [c.x + c.w, c.y], [c.x, c.y + c.h], [c.x + c.w, c.y + c.h]].map(p => Geo.apply(m, p[0], p[1]));
			const xs = corners.map(p => p[0]), ys = corners.map(p => p[1]);
			const x = Math.max(0, Math.min(...xs)), y = Math.max(0, Math.min(...ys));
			root.aspectId = "free";
			root.aspect = 0;
			root.editor.change(r => {
				const g = Geo.normalised(r.geometry);
				g.angle = 0;
				g.vertical = 0;
				g.horizontal = 0;
				g.quad = null;
				g.crop = { x: x, y: y, w: Math.min(1 - x, Math.max(...xs) - x), h: Math.min(1 - y, Math.max(...ys) - y) };
				r.geometry = g;
			});
			root.editor.say("The black bars are cut away", "crop");
		});
	}

	function uncrop() {
		root.aspectId = "free";
		root.aspect = 0;
		root.editor.change(r => {
			r.geometry = Geo.normalised(r.geometry);
			r.geometry.crop = { x: 0, y: 0, w: 1, h: 1 };
		});
	}

	function resetFrame() {
		root.aspectId = "free";
		root.aspect = 0;
		root.editor.change(r => {
			r.geometry = Geo.defaults();
		});
	}

	// ── the shape ──────────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Shape"
		changed: root.cropped
		onReverted: root.uncrop()
	}

	Flow {
		width: parent.width
		spacing: 6

		Repeater {
			model: root.aspects

			delegate: Chip {
				required property var modelData

				text: modelData.label
				icon: modelData.icon ?? ""
				accent: root.accent
				selected: root.aspectId === modelData.id
				onClicked: root.setAspect(modelData)
			}
		}
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		text: "Drag the corners and edges on the picture; inside the crop moves it"
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	TextButton {
		text: root.finding ? "Looking…" : "Find black bars"
		icon: "crop_free"
		busy: root.finding
		onActivated: root.findBars()
	}

	// ── turning ────────────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Turn"
		changed: root.geometry.rot !== 0 || root.geometry.flip || Math.abs(root.geometry.angle) > 1e-4
		onReverted: root.editor.change(r => {
			const g = Geo.normalised(r.geometry);
			g.rot = 0;
			g.flip = false;
			g.angle = 0;
			g.crop = { x: 0, y: 0, w: 1, h: 1 };
			r.geometry = g;
		})
	}

	Row {
		spacing: 8

		IconButton {
			width: 38
			height: 38
			icon: "rotate_left"
			variant: "tonal"
			onClicked: root.turn(-1)
		}

		IconButton {
			width: 38
			height: 38
			icon: "rotate_right"
			variant: "tonal"
			onClicked: root.turn(1)
		}

		IconButton {
			width: 38
			height: 38
			icon: "flip_horizontal"
			variant: "tonal"
			checked: root.geometry.flip
			onClicked: root.mirror()
		}

		StyledText {
			anchors.verticalCenter: parent.verticalCenter
			leftPadding: 4
			text: [root.geometry.rot ? `${root.geometry.rot * 90}°` : "", root.geometry.flip ? "mirrored" : ""].filter(v => v).join(", ")
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
		}
	}

	TuneSlider {
		width: parent.width
		label: "Straighten"
		icon: "angle_acute"
		accent: root.accent
		from: -1
		to: 1
		step: 0.002
		value: root.geometry.angle / 45
		valueText: `${(shown * 45).toFixed(1)}°`
		onMoved: value => root.straighten(Math.round(value * 450) / 10, true)
		onCommitted: value => {
			root.straighten(Math.round(value * 450) / 10, true);
			root.editor.endDrag();
		}
	}

	// ── steadying ──────────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Steady"
		changed: (Number(Video.recipe.stabilize) || 0) > 0
		onReverted: root.editor.change(r => r.stabilize = 0)
	}

	TuneSlider {
		width: parent.width
		label: "Steady a shaky hand"
		icon: "vector_curve"
		accent: root.accent
		from: 0
		to: 1
		value: Number(Video.recipe.stabilize) || 0
		valueText: shown > 0 ? `${Math.round(shown * 100)}` : "Off"
		onMoved: value => root.editor.drag(r => r.stabilize = Math.round(value * 100) / 100)
		onCommitted: root.editor.endDrag()
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		text: "Done in the export (it looks through the film twice) – the preview stays as it was filmed. The edges get cut a little more the stronger it is."
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	TextButton {
		text: "Start the frame over"
		icon: "backup_restore"
		variant: "ghost"
		enabled: !Geo.isIdentity(root.geometry)
		onActivated: root.resetFrame()
	}
}
