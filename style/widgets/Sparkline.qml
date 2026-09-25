import QtQuick
import qs.style.theme

// Smooth area chart for short histories (throughput, cpu load …).
Canvas {
	id: root

	property var values: []
	property real maximum: 0
	property color color: Theme.primary
	property real lineWidth: 2

	readonly property real peak: {
		let top = root.maximum > 0 ? root.maximum : 0;
		for (const v of root.values || [])
			top = Math.max(top, Number(v) || 0);
		return Math.max(top, 1e-9);
	}

	implicitHeight: 64
	antialiasing: true
	renderStrategy: Canvas.Cooperative

	onValuesChanged: requestPaint()
	onPeakChanged: requestPaint()
	onColorChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		const values = root.values || [];
		if (values.length < 2)
			return;

		const w = width;
		const h = height - root.lineWidth;
		const step = w / (values.length - 1);
		const points = values.map((v, i) => ({
			x: i * step,
			y: root.lineWidth / 2 + h - h * Math.max(0, Math.min(1, (Number(v) || 0) / root.peak))
		}));

		const trace = () => {
			ctx.moveTo(points[0].x, points[0].y);
			for (let i = 1; i < points.length; i += 1) {
				const prev = points[i - 1];
				const cur = points[i];
				const mid = (prev.x + cur.x) / 2;
				ctx.bezierCurveTo(mid, prev.y, mid, cur.y, cur.x, cur.y);
			}
		};

		const gradient = ctx.createLinearGradient(0, 0, 0, height);
		gradient.addColorStop(0, Qt.alpha(root.color, 0.32));
		gradient.addColorStop(1, Qt.alpha(root.color, 0));
		ctx.beginPath();
		trace();
		ctx.lineTo(w, height);
		ctx.lineTo(0, height);
		ctx.closePath();
		ctx.fillStyle = gradient;
		ctx.fill();

		ctx.beginPath();
		trace();
		ctx.strokeStyle = root.color;
		ctx.lineWidth = root.lineWidth;
		ctx.lineJoin = "round";
		ctx.lineCap = "round";
		ctx.stroke();

		const last = points[points.length - 1];
		ctx.beginPath();
		ctx.arc(last.x - root.lineWidth, last.y, root.lineWidth * 1.6, 0, Math.PI * 2);
		ctx.fillStyle = root.color;
		ctx.fill();
	}
}
