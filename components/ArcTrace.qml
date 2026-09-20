pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A history, plotted on ruled paper.
//
// A graticule underneath, a plain ink trace on top, a light wash under the
// trace, and a small circle where the pen is now. This is a chart that was
// drawn with a pen on a sheet, so the line is one weight all the way along and
// what varies is where it is.
Item {
	id: trace

	property var values: []
	property real ceiling: 1
	property color traceColor: Arc.aether
	property real weight: Arc.rule

	function repaint() { canvas.requestPaint(); }

	onValuesChanged: canvas.requestPaint()
	onCeilingChanged: canvas.requestPaint()
	onTraceColorChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 4 || height <= 4) return;

			// The graticule: four rules across and a tick every eighth, ruled
			// before anything was plotted on it.
			ctx.strokeStyle = Arc.giltGhost;
			ctx.lineWidth = Arc.ruleThin;
			for (let line = 0; line <= 4; line++) {
				const y = Math.round(height * line / 4) + 0.5;
				ctx.beginPath();
				ctx.moveTo(0, y);
				ctx.lineTo(width, y);
				ctx.stroke();
			}
			for (let mark = 1; mark < 8; mark++) {
				const x = Math.round(width * mark / 8) + 0.5;
				ctx.beginPath();
				ctx.moveTo(x, height - 4);
				ctx.lineTo(x, height);
				ctx.stroke();
			}

			const samples = trace.values || [];
			if (samples.length < 2) return;

			const top = trace.weight * 2;
			const floor = height - trace.weight;
			const step = width / (samples.length - 1);
			const ceiling = Math.max(1, trace.ceiling);
			const points = [];
			for (let index = 0; index < samples.length; index++) {
				const ratio = Math.max(0, Math.min(1, Number(samples[index]) / ceiling));
				points.push({ x: index * step, y: floor - (floor - top) * ratio });
			}

			const wash = ctx.createLinearGradient(0, top, 0, floor);
			wash.addColorStop(0, Qt.alpha(trace.traceColor, 0.22));
			wash.addColorStop(1, Qt.alpha(trace.traceColor, 0.0));
			ctx.fillStyle = wash;
			ctx.beginPath();
			ctx.moveTo(points[0].x, floor);
			for (const point of points) ctx.lineTo(point.x, point.y);
			ctx.lineTo(points[points.length - 1].x, floor);
			ctx.closePath();
			ctx.fill();

			Ink.cut(ctx, points, trace.weight * 1.3, trace.traceColor, false);

			const head = points[points.length - 1];
			ctx.fillStyle = trace.traceColor;
			ctx.beginPath();
			ctx.ellipse(head.x - trace.weight * 1.6, head.y - trace.weight * 1.6,
				trace.weight * 3.2, trace.weight * 3.2);
			ctx.fill();
		}
	}
}
