pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A rune: the mark the instrument gives a thing that has no icon of its own —
// the launcher, a locked session, an empty page, a track with no artwork.
//
// Cut, not drawn: a stave down the middle with arms struck off it at right
// angles and half angles, on a lattice. Grown from `seed`, so a thing always
// keeps the same mark and two things never share one.
Item {
	id: rune

	property color lineColor: Arc.gilt
	property int seed: 1
	property real weight: Arc.rule
	property real detail: 1.0

	implicitWidth: 44
	implicitHeight: 44

	onLineColorChanged: canvas.requestPaint()
	onSeedChanged: canvas.requestPaint()
	onWeightChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const size = Math.min(width, height);
			if (size <= 8) return;
			const marks = rune.detail > 0.75 ? 2 : 1;
			for (let index = 0; index < marks; index++) {
				const span = size * (0.78 - index * 0.3);
				Ink.rune(ctx, width / 2, height / 2, span, rune.seed * 31 + index * 7,
					rune.weight * (1.5 - index * 0.4),
					index === 0 ? rune.lineColor : Qt.alpha(rune.lineColor, 0.5));
			}
		}
	}
}
