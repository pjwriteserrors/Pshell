pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// Everything in the instrument that holds something is one of these, and which
// of the three materials it is made of is decided here rather than at the call
// site.
//
//   chamber  a sheet of vellum hanging off a roller: a head rail across the
//            top, a torn foot, and brass corner mounts pinning it flat
//   plate    a brass plate: corners chamfered rather than rounded, the border
//            cut in as a groove, a rivet in each cut corner
//   capsule  a channel: a tube with a grooved rim, for anything a reading runs
//            along
//   field    a square field with registration marks overshooting its corners —
//            what a cell gets when its fill is already square and a chamfer
//            would have nothing to cut into
//
// Two canvases on purpose. The brass is painted once per resize and never
// again; the live layer traces the same fittings in the aether colour and is
// only faded, so touching a plate animates an opacity and not a repaint.
Item {
	id: plate

	property string variant: "chamber"

	property color lineColor: Arc.giltDim
	property color liveColor: Arc.aether
	property color fillTop: "transparent"
	property color fillBottom: "transparent"
	property real weight: Arc.rule
	property real inset: 2

	// 0 at rest, 1 when the plate is live. Only ever an opacity.
	property real intensity: 0
	// The head rail a sheet hangs from. A sheet without one is a rectangle.
	property bool crest: variant === "chamber"
	// The rivets and the graduations. Off for anything too small to hold them.
	property bool beading: true

	// How far the corner chamfer cuts in, and how far content has to keep
	// clear of it.
	readonly property real chamfer: {
		const room = Math.min(width, height) / 2 - inset;
		if (variant === "capsule") return Math.max(3, room);
		if (variant === "field") return 0;
		return Math.max(4, Math.min(variant === "chamber" ? 16 : 9, room));
	}
	readonly property real railHeight: variant === "chamber" && crest ? 9 : 0
	readonly property real innerMargin: inset + chamfer * 0.55 + railHeight * 0.4

	onLineColorChanged: brassLayer.requestPaint()
	onFillTopChanged: brassLayer.requestPaint()
	onFillBottomChanged: brassLayer.requestPaint()
	onLiveColorChanged: liveLayer.requestPaint()
	onWeightChanged: repaint()
	onVariantChanged: repaint()
	onCrestChanged: repaint()
	onBeadingChanged: repaint()

	function repaint() {
		brassLayer.requestPaint();
		liveLayer.requestPaint();
	}

	// The silhouette: a rectangle with its corners cut off. One decision, and
	// it is the one that makes the whole shell look machined.
	function outline(w, h, p, c) {
		return [
			{ x: p + c, y: p },
			{ x: w - p - c, y: p },
			{ x: w - p, y: p + c },
			{ x: w - p, y: h - p - c },
			{ x: w - p - c, y: h - p },
			{ x: p + c, y: h - p },
			{ x: p, y: h - p - c },
			{ x: p, y: p + c }
		];
	}

	function capsuleOutline(w, h, p) {
		const radius = Math.max(2, (h - p * 2) / 2);
		const left = p + radius, right = w - p - radius;
		return Ink.arcPoints(right, h / 2, radius, -Math.PI / 2, Math.PI / 2, 10)
			.concat(Ink.arcPoints(left, h / 2, radius, Math.PI / 2, Math.PI * 1.5, 10));
	}

	function paintFittings(ctx, w, h, color, weight) {
		const p = plate.inset + weight;
		const c = plate.chamfer;
		const shadow = Qt.alpha(Qt.darker(color, 2.2), 0.55);
		const highlight = Qt.alpha(Qt.lighter(color, 1.7), 0.5);

		if (plate.variant === "capsule") {
			Ink.groove(ctx, plate.capsuleOutline(w, h, p), weight, color, highlight, shadow, true);
			return;
		}

		if (plate.variant === "field") {
			const x0 = p, y0 = p, x1 = w - p, y1 = h - p;
			Ink.cut(ctx, [{ x: x0, y: y0 }, { x: x1, y: y0 }, { x: x1, y: y1 }, { x: x0, y: y1 }],
				weight * 0.8, Qt.alpha(color, 0.55), true);
			if (!plate.beading || Math.min(w, h) < 22) return;
			// Registration marks: the corner ticks an engraver cuts to line one
			// plate up with the next. They overshoot the corner on purpose.
			const reach = Math.min(9, Math.min(w, h) * 0.2);
			const over = weight * 2.2;
			for (const mark of [{ x: x0, y: y0, dx: 1, dy: 1 }, { x: x1, y: y0, dx: -1, dy: 1 },
				{ x: x1, y: y1, dx: -1, dy: -1 }, { x: x0, y: y1, dx: 1, dy: -1 }]) {
				Ink.cut(ctx, [{ x: mark.x - mark.dx * over, y: mark.y }, { x: mark.x + mark.dx * reach, y: mark.y }],
					weight, color, false);
				Ink.cut(ctx, [{ x: mark.x, y: mark.y - mark.dy * over }, { x: mark.x, y: mark.y + mark.dy * reach }],
					weight, color, false);
			}
			return;
		}

		if (plate.variant === "plate") {
			Ink.groove(ctx, plate.outline(w, h, p, c), weight, color, highlight, shadow, true);
			// A second cut just inside the first, which is what an engraved
			// border actually is — one line is a border, two are a plate.
			if (w > 44 && h > 26)
				Ink.cut(ctx, plate.outline(w, h, p + weight * 2.6, Math.max(2, c - weight * 2.6)),
					weight * 0.7, Qt.alpha(color, 0.42), true);
			if (plate.beading && Math.min(w, h) >= 26) {
				const r = Math.max(1.1, weight * 1.05);
				for (const corner of [{ x: p + c * 0.5, y: p + c * 0.5 },
					{ x: w - p - c * 0.5, y: p + c * 0.5 },
					{ x: w - p - c * 0.5, y: h - p - c * 0.5 },
					{ x: p + c * 0.5, y: h - p - c * 0.5 }])
					Ink.rivet(ctx, corner.x, corner.y, r, color, highlight, shadow);
			}
			return;
		}

		// A sheet. Only the mounts are brass; the sheet itself is held by them
		// and by the rail it hangs from.
		const rail = plate.railHeight;
		if (rail > 0) {
			Ink.groove(ctx, [{ x: p + c * 0.4, y: p + rail }, { x: w - p - c * 0.4, y: p + rail }],
				weight * 1.5, color, highlight, shadow, false);
			if (plate.beading) {
				const r = Math.max(1.4, weight * 1.35);
				Ink.rivet(ctx, p + c * 0.4, p + rail, r, color, highlight, shadow);
				Ink.rivet(ctx, w - p - c * 0.4, p + rail, r, color, highlight, shadow);
			}
		}

		Ink.cut(ctx, plate.outline(w, h, p, c), weight * 0.8, Qt.alpha(color, 0.5), true);

		// The corner mounts: short angle brackets pinning the sheet to the
		// instrument. They are the reason a page reads as mounted rather than
		// as floating.
		const reach = Math.min(26, Math.min(w, h) * 0.22);
		for (const mount of [
			{ x: p, y: p + c, dx: 0, dy: 1, ax: 1, ay: -1, cx: p + c, cy: p },
			{ x: w - p, y: p + c, dx: 0, dy: 1, ax: -1, ay: -1, cx: w - p - c, cy: p },
			{ x: w - p, y: h - p - c, dx: 0, dy: -1, ax: -1, ay: 1, cx: w - p - c, cy: h - p },
			{ x: p, y: h - p - c, dx: 0, dy: -1, ax: 1, ay: 1, cx: p + c, cy: h - p }
		]) {
			Ink.groove(ctx, [
				{ x: mount.x, y: mount.y + mount.dy * reach },
				{ x: mount.x, y: mount.y },
				{ x: mount.cx, y: mount.cy },
				{ x: mount.cx + mount.ax * reach, y: mount.cy }
			], weight * 1.2, color, highlight, shadow, false);
		}
	}

	Canvas {
		id: brassLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 4 || height <= 4) return;

			if (plate.fillTop.a > 0.004 || plate.fillBottom.a > 0.004) {
				const p = plate.inset + plate.weight;
				Ink.polyline(ctx, plate.variant === "capsule"
					? plate.capsuleOutline(width, height, p)
					: plate.outline(width, height, p, plate.chamfer), true);
				const sheet = ctx.createLinearGradient(0, 0, 0, height);
				sheet.addColorStop(0, plate.fillTop);
				sheet.addColorStop(1, plate.fillBottom);
				ctx.fillStyle = sheet;
				ctx.fill();
			}

			plate.paintFittings(ctx, width, height, plate.lineColor, plate.weight);
		}
	}

	Canvas {
		id: liveLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		opacity: plate.intensity
		visible: opacity > 0.004

		Behavior on opacity {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 4 || height <= 4) return;
			plate.paintFittings(ctx, width, height, plate.liveColor, plate.weight * 1.1);
		}
	}
}
