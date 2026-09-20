pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A ley line: the hairline that carries the eye from a name to the edge of a
// panel, with a single mote sitting on it. It is what finishes a heading and
// what shows two things to be connected. There is no ornament on it beyond the
// one light, because one light is the point.
Item {
	id: flourish

	property color lineColor: Arc.goldFaint
	property real weight: Arc.rule
	property int facing: Qt.RightToLeft   // which end the light sits nearer
	property bool beading: true
	property real sag: 0

	implicitHeight: 10

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
			if (width <= 6 || height <= 1) return;
			const mid = height / 2;
			const at = flourish.facing === Qt.RightToLeft ? 0.76 : 0.24;
			Ink.ley(ctx, 0, mid, width, mid, flourish.weight * 0.8,
				flourish.lineColor, flourish.beading ? Arc.aether : null,
				flourish.beading && width > 30 ? at : -1);
		}
	}
}
