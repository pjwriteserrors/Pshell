pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// The chamber: one grown outline with a membrane inside it.
//
// Everything in this style that holds something — a panel, a button, a bar
// cell, a card — is this component. The outline is not a border: each corner is
// a bone that swells through the turn and runs out to a point along both edges,
// the crook of it fills with vertebrae, and the straight runs between corners
// are thin ribs that never touch the corner bone. That is what makes the frame
// read as grown rather than drawn around a rectangle.
//
// Two canvases, on purpose. The bone layer is painted once per resize and never
// again; the living layer traces the same skeleton in the organ colour and is
// only faded in and out, so hovering a cell animates an opacity, not a repaint.
Item {
	id: frame

	// "chamber"  a panel: long corner bones, clawed base, a crest
	// "plate"    a cell or button: short corners, beaded ends
	// "capsule"  a pill: beads running the length of both arcs
	property string variant: "chamber"

	property color lineColor: Bio.boneDim
	property color liveColor: Bio.organ
	property color fillTop: "transparent"
	property color fillBottom: "transparent"
	property real weight: Bio.rib
	property real inset: 2

	// 0 at rest, 1 when the chamber is live. Only ever an opacity.
	property real intensity: 0
	property bool crest: variant === "chamber"
	property bool beading: true

	readonly property real shoulder: {
		const room = Math.min(width, height) / 2 - inset;
		if (variant === "capsule") return Math.max(4, room);
		const wanted = variant === "chamber"
			? Math.min(34, Math.min(width, height) * 0.30)
			: Math.min(15, Math.min(width, height) * 0.38);
		return Math.max(5, Math.min(wanted, room));
	}
	// Where content may start without running into the corner bones.
	readonly property real innerMargin: inset + shoulder * 0.42

	onLineColorChanged: boneLayer.requestPaint()
	onFillTopChanged: boneLayer.requestPaint()
	onFillBottomChanged: boneLayer.requestPaint()
	onLiveColorChanged: liveLayer.requestPaint()
	onWeightChanged: repaint()
	onVariantChanged: repaint()
	onCrestChanged: repaint()
	onBeadingChanged: repaint()

	function repaint() {
		boneLayer.requestPaint();
		liveLayer.requestPaint();
	}

	// The silhouette the membrane is poured into: the outline the bones imply,
	// without the bones themselves.
	function traceBody(ctx, w, h, p, s) {
		const left = p, right = w - p, top = p, bottom = h - p;
		const bulge = frame.variant === "capsule" ? 0 : Math.min(2.4, (bottom - top) * 0.04);
		ctx.beginPath();
		ctx.moveTo(left + s, top);
		ctx.lineTo(right - s, top);
		ctx.bezierCurveTo(right - s * 0.3, top, right, top + s * 0.3, right, top + s);
		ctx.bezierCurveTo(right + bulge, top + (bottom - top) * 0.4, right + bulge, bottom - (bottom - top) * 0.4, right, bottom - s);
		ctx.bezierCurveTo(right, bottom - s * 0.3, right - s * 0.3, bottom, right - s, bottom);
		ctx.lineTo(left + s, bottom);
		ctx.bezierCurveTo(left + s * 0.3, bottom, left, bottom - s * 0.3, left, bottom - s);
		ctx.bezierCurveTo(left - bulge, bottom - (bottom - top) * 0.4, left - bulge, top + (bottom - top) * 0.4, left, top + s);
		ctx.bezierCurveTo(left, top + s * 0.3, left + s * 0.3, top, left + s, top);
		ctx.closePath();
	}

	// One corner, drawn in the corner's own coordinate system: the origin sits
	// at the corner, dx/dy point inwards along the two edges.
	//
	// Three parts, always in this order: the heavy outer bone that carries the
	// turn, a lighter one running inside it, and the vertebrae that fill the
	// gap between them. A corner with only the outer bone is a rounded
	// rectangle; it is the second line and the beads that make it anatomy.
	function paintCorner(ctx, x, y, dx, dy, s, w, deep) {
		const reach = s * (deep ? 1.9 : 1.35);   // how far along each edge it runs
		const turn = s * 0.30;                   // how late the bone leaves the edge

		Ink.ribbon(ctx,
			{ x: x + dx * reach, y: y },
			{ x: x + dx * turn, y: y },
			{ x: x, y: y + dy * turn },
			{ x: x, y: y + dy * reach },
			Ink.taper(w * 2.8, 0.05, 0.05, 0.5), 22);

		const gap = w * 3.4;
		if (deep) {
			Ink.ribbon(ctx,
				{ x: x + dx * reach * 0.66, y: y + dy * gap },
				{ x: x + dx * (turn * 0.7 + gap), y: y + dy * gap },
				{ x: x + dx * gap, y: y + dy * (turn * 0.7 + gap) },
				{ x: x + dx * gap, y: y + dy * reach * 0.66 },
				Ink.taper(w * 1.4, 0.0, 0.0, 0.5), 18);
		}

		// A blade lying along the inside of each edge, picking up where the
		// outer bone thins out. It runs with the edge; nothing stabs inwards.
		for (const lie of [{ ax: dx, ay: 0, bx: 0, by: dy }, { ax: 0, ay: dy, bx: dx, by: 0 }]) {
			Ink.ribbon(ctx,
				{ x: x + lie.ax * reach * 0.45 + lie.bx * gap * 0.9, y: y + lie.ay * reach * 0.45 + lie.by * gap * 0.9 },
				{ x: x + lie.ax * reach * 0.80 + lie.bx * gap * 1.5, y: y + lie.ay * reach * 0.80 + lie.by * gap * 1.5 },
				{ x: x + lie.ax * reach * 1.05 + lie.bx * gap * 1.1, y: y + lie.ay * reach * 1.05 + lie.by * gap * 1.1 },
				{ x: x + lie.ax * reach * 1.12 + lie.bx * gap * 0.25, y: y + lie.ay * reach * 1.12 + lie.by * gap * 0.25 },
				Ink.taper(w * 1.5, 0.0, 0.0, 0.42), 16);
		}

		if (!frame.beading) return;

		// Vertebrae down the diagonal, largest at the joint.
		const count = deep ? 4 : 2;
		for (let index = 0; index < count; index++) {
			const along = gap * 1.55 + index * w * 3.1;
			Ink.bead(ctx, x + dx * along, y + dy * along,
				w * (1.25 - index * 0.24), 1.15, dx * dy > 0 ? Math.PI / 4 : -Math.PI / 4);
		}
	}

	function paintSkeleton(ctx, w, h, color, weight) {
		const p = frame.inset + weight;
		const s = frame.shoulder;
		const left = p, right = w - p, top = p, bottom = h - p;
		const deep = frame.variant === "chamber";
		ctx.fillStyle = color;

		if (frame.variant === "capsule") {
			paintCapsule(ctx, w, h, weight);
			return;
		}

		paintCorner(ctx, left, top, 1, 1, s, weight, deep);
		paintCorner(ctx, right, top, -1, 1, s, weight, deep);
		paintCorner(ctx, right, bottom, -1, -1, s, weight, deep);
		paintCorner(ctx, left, bottom, 1, -1, s, weight, deep);

		// The ribs: thin runs between the corner bones, bowed a hair outwards so
		// the chamber looks under pressure from the inside.
		const reach = s * (deep ? 1.9 : 1.35);
		const bow = deep ? 0.8 : 0.5;
		// The rib leaves the corner bone at the width the corner bone ended on,
		// so an edge reads as one continuous line and not as three pieces.
		const rib = Ink.taper(weight * 1.05, 0.42, 0.42, 0.5);
		if (right - left > reach * 2.2) {
			const cx = (left + right) / 2;
			ribRun(ctx, left + reach * 0.96, top, right - reach * 0.96, top, -bow, rib);
			ribRun(ctx, left + reach * 0.96, bottom, right - reach * 0.96, bottom, bow, rib);
			if (frame.crest) paintCrest(ctx, cx, top, bottom, weight, deep);
		}
		if (bottom - top > reach * 2.2) {
			const cy = (top + bottom) / 2;
			ribRun(ctx, left, top + reach * 0.96, left, bottom - reach * 0.96, -bow, rib);
			ribRun(ctx, right, top + reach * 0.96, right, bottom - reach * 0.96, bow, rib);
			// A joint at the waist of each flank: two vertebrae pinching the
			// rib. It is the one thing that stops a tall chamber reading as a
			// rounded rectangle with decorated corners.
			if (deep && frame.beading && bottom - top > reach * 3.4) {
				for (const flank of [left, right]) {
					Ink.bead(ctx, flank, cy - weight * 3.4, weight * 1.0, 1.5, 0);
					Ink.bead(ctx, flank, cy + weight * 3.4, weight * 1.0, 1.5, 0);
					Ink.bead(ctx, flank, cy, weight * 1.5, 0.85, 0);
				}
			}
		}
	}

	// A rib between two joints, bowed along its own normal.
	function ribRun(ctx, x0, y0, x1, y1, bow, widthAt) {
		const nx = -(y1 - y0), ny = x1 - x0;
		const length = Math.sqrt(nx * nx + ny * ny) || 1;
		const ox = nx / length * bow, oy = ny / length * bow;
		Ink.ribbon(ctx,
			{ x: x0, y: y0 },
			{ x: x0 + (x1 - x0) / 3 + ox, y: y0 + (y1 - y0) / 3 + oy },
			{ x: x0 + (x1 - x0) * 2 / 3 + ox, y: y0 + (y1 - y0) * 2 / 3 + oy },
			{ x: x1, y: y1 },
			widthAt, 16);
	}

	// The crest: the bead on the top edge that tells you which way up the
	// organism is, and the matching swallow of beads under the floor.
	function paintCrest(ctx, cx, top, bottom, weight, deep) {
		Ink.bead(ctx, cx, top, weight * 2.2, 0.75, 0);
		Ink.bead(ctx, cx - weight * 4.4, top, weight * 0.8, 1.0, 0);
		Ink.bead(ctx, cx + weight * 4.4, top, weight * 0.8, 1.0, 0);
		if (!deep || !frame.beading) return;
		for (let index = -2; index <= 2; index++) {
			Ink.bead(ctx, cx + index * weight * 3.2, bottom, weight * (1.25 - Math.abs(index) * 0.26), 0.8, 0);
		}
	}

	// A pill whose two arcs are strung with vertebrae — the reference's beaded
	// capsule button, used here for anything small and round-ended.
	function paintCapsule(ctx, w, h, weight) {
		const p = frame.inset + weight;
		const radius = Math.max(3, (h - p * 2) / 2);
		const left = p + radius, right = w - p - radius;
		const top = p, bottom = h - p;
		const rib = Ink.taper(weight * 1.3, 0.35, 0.35, 0.5);
		ribRun(ctx, left, top, right, top, 0, rib);
		ribRun(ctx, left, bottom, right, bottom, 0, rib);
		// the two end arcs
		for (const side of [{ x: left, dir: -1 }, { x: right, dir: 1 }]) {
			Ink.chain(ctx, [
				{ x: side.x, y: top },
				{ x: side.x + side.dir * radius * 0.56, y: top },
				{ x: side.x + side.dir * radius, y: top + radius * 0.44 },
				{ x: side.x + side.dir * radius, y: (top + bottom) / 2 },
				{ x: side.x + side.dir * radius, y: bottom - radius * 0.44 },
				{ x: side.x + side.dir * radius * 0.56, y: bottom },
				{ x: side.x, y: bottom }
			], Ink.taper(weight * 1.9, 0.5, 0.5, 0.5), 16);
		}
		if (!frame.beading || right - left < weight * 6) return;
		const span = right - left;
		const count = Math.max(2, Math.round(span / (weight * 7)));
		for (let index = 0; index <= count; index++) {
			const x = left + span * index / count;
			Ink.bead(ctx, x, top, weight * 0.9, 0.85, 0);
			Ink.bead(ctx, x, bottom, weight * 0.9, 0.85, 0);
		}
	}

	Canvas {
		id: boneLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 4 || height <= 4) return;

			if (frame.fillTop.a > 0.004 || frame.fillBottom.a > 0.004) {
				frame.traceBody(ctx, width, height, frame.inset + frame.weight, frame.shoulder);
				const wash = ctx.createLinearGradient(0, 0, 0, height);
				wash.addColorStop(0, frame.fillTop);
				wash.addColorStop(1, frame.fillBottom);
				ctx.fillStyle = wash;
				ctx.fill();
			}

			frame.paintSkeleton(ctx, width, height, frame.lineColor, frame.weight);
		}
	}

	Canvas {
		id: liveLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		opacity: frame.intensity
		visible: opacity > 0.004

		Behavior on opacity {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 4 || height <= 4) return;
			frame.paintSkeleton(ctx, width, height, frame.liveColor, frame.weight * 1.12);
		}
	}
}
