pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// A reading, drawn as a vein: a thin bone track with something running through
// it. The filled part swells behind its own head and the head is a vertebra, so
// a busy CPU looks like a vessel under pressure instead of a progress bar.
Item {
	id: meter

	property real value: 0            // 0..1
	property color trackColor: Bio.boneGhost
	property color fillColor: Bio.organ
	property real weight: Bio.rib
	property bool vertical: false

	implicitHeight: vertical ? 40 : 6
	implicitWidth: vertical ? 6 : 60

	onValueChanged: canvas.requestPaint()
	onFillColorChanged: canvas.requestPaint()
	onTrackColorChanged: canvas.requestPaint()

	Behavior on value {
		NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
	}

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 2 || height <= 2) return;
			const w = meter.weight;
			const filled = Math.max(0, Math.min(1, meter.value));
			// Vertical meters fill upwards; horizontal ones to the right.
			const from = meter.vertical ? { x: width / 2, y: height - w } : { x: w, y: height / 2 };
			const to = meter.vertical ? { x: width / 2, y: w } : { x: width - w, y: height / 2 };
			const at = {
				x: from.x + (to.x - from.x) * filled,
				y: from.y + (to.y - from.y) * filled
			};
			const bend = meter.vertical ? { x: w * 0.55, y: 0 } : { x: 0, y: -w * 0.55 };

			const lerp = (a, b, t) => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });

			if (meter.trackColor.a > 0.004) {
				ctx.fillStyle = meter.trackColor;
				Ink.ribbon(ctx, from,
					{ x: lerp(from, to, 0.33).x + bend.x, y: lerp(from, to, 0.33).y + bend.y },
					{ x: lerp(from, to, 0.66).x - bend.x, y: lerp(from, to, 0.66).y - bend.y },
					to, Ink.taper(w * 1.1, 0.5, 0.5, 0.5), 16);
			}

			if (filled <= 0.005) return;
			ctx.fillStyle = meter.fillColor;
			Ink.ribbon(ctx, from,
				{ x: lerp(from, at, 0.33).x + bend.x * filled, y: lerp(from, at, 0.33).y + bend.y * filled },
				{ x: lerp(from, at, 0.66).x - bend.x * filled, y: lerp(from, at, 0.66).y - bend.y * filled },
				at, Ink.taper(w * 2.2, 0.35, 0.95, 0.85), 16);
			Ink.bead(ctx, at.x, at.y, w * 1.25, 1.0, 0);
		}
	}
}
