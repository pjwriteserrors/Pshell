pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// A history, drawn as a pulse rather than a chart.
//
// The trace is one ribbon: thin where the signal was quiet, swelling where it
// spiked, with a vertebra at the head where the newest sample sits. Under it a
// wash of the same colour falls away to nothing, which is the only fill in this
// style that is not a membrane.
Item {
	id: pulse

	property var values: []
	property real ceiling: 1
	property color traceColor: Bio.organ
	property real weight: Bio.rib

	function repaint() { canvas.requestPaint(); }

	onValuesChanged: canvas.requestPaint()
	onCeilingChanged: canvas.requestPaint()
	onTraceColorChanged: canvas.requestPaint()

	// The floor the trace runs along, so an idle link still shows a line.
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Bio.ribThin
		color: Bio.boneGhost
	}

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const samples = pulse.values || [];
			if (samples.length < 2 || width <= 4 || height <= 4) return;

			const top = pulse.weight * 2;
			const floor = height - pulse.weight;
			const step = width / (samples.length - 1);
			const ceiling = Math.max(1, pulse.ceiling);
			const points = [];
			for (let index = 0; index < samples.length; index++) {
				const ratio = Math.max(0, Math.min(1, Number(samples[index]) / ceiling));
				points.push({ x: index * step, y: floor - (floor - top) * ratio });
			}

			// the wash under the trace
			const wash = ctx.createLinearGradient(0, top, 0, floor);
			wash.addColorStop(0, Qt.alpha(pulse.traceColor, 0.26));
			wash.addColorStop(1, Qt.alpha(pulse.traceColor, 0.0));
			ctx.fillStyle = wash;
			ctx.beginPath();
			ctx.moveTo(points[0].x, floor);
			for (const point of points) ctx.lineTo(point.x, point.y);
			ctx.lineTo(points[points.length - 1].x, floor);
			ctx.closePath();
			ctx.fill();

			// the trace itself, one ribbon per pair of samples so the width can
			// follow the signal rather than the position along the axis
			ctx.fillStyle = pulse.traceColor;
			for (let index = 0; index + 1 < points.length; index++) {
				const a = points[index], b = points[index + 1];
				const heightAt = value => Math.max(0.25, (floor - value) / Math.max(1, floor - top));
				Ink.ribbon(ctx, a,
					{ x: a.x + step / 3, y: a.y },
					{ x: b.x - step / 3, y: b.y },
					b,
					t => pulse.weight * (1.1 + 1.5 * (heightAt(a.y) * (1 - t) + heightAt(b.y) * t)),
					6);
			}

			const head = points[points.length - 1];
			Ink.bead(ctx, head.x - pulse.weight, head.y, pulse.weight * 1.4, 1.0, 0);
		}
	}
}
