pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A history, traced on a field of ley lines.
//
// The graticule is drawn as hairlines with nothing on them; the trace itself is
// light, with a wash falling away underneath it and a mote where the newest
// sample sits. It reads as something being watched rather than as a chart.
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

			ctx.strokeStyle = Arc.goldGhost;
			ctx.lineWidth = Arc.ruleThin;
			for (let line = 1; line < 4; line++) {
				const y = Math.round(height * line / 4) + 0.5;
				ctx.beginPath();
				ctx.moveTo(0, y);
				ctx.lineTo(width, y);
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
			wash.addColorStop(0, Qt.alpha(trace.traceColor, 0.30));
			wash.addColorStop(1, Qt.alpha(trace.traceColor, 0.0));
			ctx.fillStyle = wash;
			ctx.beginPath();
			ctx.moveTo(points[0].x, floor);
			for (const point of points) ctx.lineTo(point.x, point.y);
			ctx.lineTo(points[points.length - 1].x, floor);
			ctx.closePath();
			ctx.fill();

			ctx.strokeStyle = trace.traceColor;
			ctx.lineWidth = trace.weight * 1.2;
			ctx.lineJoin = "round";
			Ink.polyline(ctx, points, false);
			ctx.stroke();

			const head = points[points.length - 1];
			Ink.mote(ctx, head.x - trace.weight, head.y, trace.weight * 2.0, trace.traceColor);
		}
	}
}
