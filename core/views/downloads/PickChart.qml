import QtQuick
import qs.style.theme

// Speed lines side by side on one scale, for picking connections: each
// series { values, color, width, fill }; `slots` fixes how many values fit,
// so a line grows to the right as it is measured. `marker` (0–1) is where
// the decision falls.
Canvas {
	id: root

	property var series: []
	property int slots: 0
	property real marker: -1
	property color markerColor: Theme.textSubtle

	readonly property real peak: {
		let top = 1;
		for (const one of root.series || [])
			for (const v of one.values || [])
				top = Math.max(top, Number(v) || 0);
		return top * 1.12;
	}
	property real scale_: root.peak

	antialiasing: true
	renderStrategy: Canvas.Cooperative

	onSeriesChanged: requestPaint()
	onScale_Changed: requestPaint()
	onMarkerChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	Behavior on scale_ {
		NumberAnimation {
			duration: 500
			easing.type: Easing.OutCubic
		}
	}

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		const w = width;
		const h = height - 3;
		let count = root.slots;
		for (const one of root.series || []) count = Math.max(count, (one.values || []).length);
		if (count < 2) return;
		const step = w / (count - 1);

		if (root.marker >= 0) {
			const x = Math.min(w - 1, Math.max(1, root.marker * w));
			ctx.beginPath();
			ctx.setLineDash([3, 4]);
			ctx.moveTo(x, 0);
			ctx.lineTo(x, height);
			ctx.strokeStyle = root.markerColor;
			ctx.lineWidth = 1;
			ctx.stroke();
			ctx.setLineDash([]);
		}

		for (const one of root.series || []) {
			// null where the line had not begun
			const points = [];
			(one.values || []).forEach((v, i) => {
				if (v !== null && v !== undefined) points.push({ x: i * step, y: 1.5 + h - h * Math.max(0, Math.min(1, (Number(v) || 0) / root.scale_)) });
			});
			if (points.length < 1) continue;
			if (points.length === 1) points.push({ x: points[0].x + 0.01, y: points[0].y });
			const trace = () => {
				ctx.moveTo(points[0].x, points[0].y);
				for (let i = 1; i < points.length; i += 1) {
					const prev = points[i - 1];
					const cur = points[i];
					const mid = (prev.x + cur.x) / 2;
					ctx.bezierCurveTo(mid, prev.y, mid, cur.y, cur.x, cur.y);
				}
			};
			const lineWidth = one.width ?? 2;
			if (one.fill) {
				const gradient = ctx.createLinearGradient(0, 0, 0, height);
				gradient.addColorStop(0, Qt.alpha(one.color, 0.3));
				gradient.addColorStop(1, Qt.alpha(one.color, 0));
				ctx.beginPath();
				trace();
				ctx.lineTo(points[points.length - 1].x, height);
				ctx.lineTo(points[0].x, height);
				ctx.closePath();
				ctx.fillStyle = gradient;
				ctx.fill();
			}
			ctx.beginPath();
			trace();
			ctx.strokeStyle = one.color;
			ctx.lineWidth = lineWidth;
			ctx.lineJoin = "round";
			ctx.lineCap = "round";
			ctx.stroke();
			if (one.dot) {
				const last = points[points.length - 1];
				ctx.beginPath();
				ctx.arc(Math.min(w - lineWidth * 1.6, last.x), last.y, lineWidth * 1.6, 0, Math.PI * 2);
				ctx.fillStyle = one.color;
				ctx.fill();
			}
		}
	}
}
