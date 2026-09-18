pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// The tendon: what connects two organs across empty space.
//
// It is the long ornamental run either side of the specimen plate on the bar,
// and the rule between sections inside a panel. A tendon is thickest where it
// leaves the thing it is attached to and runs out to nothing at its free end,
// with vertebrae strung where it slackens.
Item {
	id: tendon

	property color lineColor: Bio.boneFaint
	property real weight: Bio.rib
	property int facing: Qt.RightToLeft   // which end is the free one
	property bool beading: true
	property real sag: 0                  // how far the middle drops

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
			const w = tendon.weight;
			const mid = height / 2;
			const flip = tendon.facing === Qt.RightToLeft;
			// Always drawn left to right, then mirrored, so the free end is the
			// one facing away from whatever the tendon hangs off.
			ctx.save();
			if (flip) {
				ctx.translate(width, 0);
				ctx.scale(-1, 1);
			}
			ctx.fillStyle = tendon.lineColor;

			const a = { x: 0, y: mid };
			const b = { x: width * 0.34, y: mid + tendon.sag };
			const c = { x: width * 0.72, y: mid + tendon.sag * 0.4 };
			const d = { x: width, y: mid };
			Ink.ribbon(ctx, a, b, c, d, Ink.taper(w * 2.6, 1.0, 0.0, 0.18), 30);

			if (tendon.beading && width > 60) {
				// Three vertebrae where the tendon slackens, and a last small
				// one out near the tip.
				Ink.beadRun(ctx, a, b, c, d, 3, w * 1.15, 0.78, 0.55);
				const tip = Ink.point(a, b, c, d, 0.93);
				Ink.bead(ctx, tip.x, tip.y, w * 0.55, 1.0, 0);
			}
			ctx.restore();
		}
	}
}
