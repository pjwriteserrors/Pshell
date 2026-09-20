pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// The flourish: the engraved run that carries the eye from a heading to the
// edge of the page, or fills the space a rule would otherwise leave empty.
//
// It is a hairline with a lozenge on it and a taper at the free end — the mark
// a printer puts at the end of a line so the line is finished rather than
// merely stopped.
Item {
	id: flourish

	property color lineColor: Arc.giltFaint
	property real weight: Arc.rule
	property int facing: Qt.RightToLeft   // which end is the free one
	property bool beading: true
	property real sag: 0                  // kept: how far the run bows

	implicitHeight: 12

	onLineColorChanged: canvas.requestPaint()
	onWeightChanged: canvas.requestPaint()
	onFacingChanged: canvas.requestPaint()
	onSagChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 8 || height <= 2) return;
			const mid = height / 2;
			ctx.save();
			if (flourish.facing === Qt.RightToLeft) {
				ctx.translate(width, 0);
				ctx.scale(-1, 1);
			}

			// The run, bowed by `sag` so a long flourish is never a straight
			// line pretending to be decoration.
			const run = [];
			for (let index = 0; index <= 16; index++) {
				const t = index / 16;
				run.push({ x: width * t, y: mid + Math.sin(t * Math.PI) * flourish.sag });
			}
			Ink.cut(ctx, run, flourish.weight * 0.85, flourish.lineColor, false);

			if (!flourish.beading || width < 40) {
				ctx.restore();
				return;
			}

			// The lozenge, a third of the way along, and a pair of ticks past
			// it. Small, and the only ornament the style repeats.
			const at = width * 0.28, y = mid + Math.sin(0.28 * Math.PI) * flourish.sag;
			const r = Math.max(1.8, flourish.weight * 1.9);
			ctx.fillStyle = flourish.lineColor;
			ctx.beginPath();
			ctx.moveTo(at, y - r);
			ctx.lineTo(at + r * 0.62, y);
			ctx.lineTo(at, y + r);
			ctx.lineTo(at - r * 0.62, y);
			ctx.closePath();
			ctx.fill();

			for (const tick of [0.56, 0.68]) {
				const tx = width * tick;
				const ty = mid + Math.sin(tick * Math.PI) * flourish.sag;
				Ink.cut(ctx, [{ x: tx, y: ty - r * 0.7 }, { x: tx, y: ty + r * 0.7 }],
					flourish.weight * 0.7, Qt.alpha(flourish.lineColor, 0.7), false);
			}
			ctx.restore();
		}
	}
}
