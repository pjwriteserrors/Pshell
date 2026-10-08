import QtQuick
import qs.style.theme

// Smooth area chart for short histories (throughput, cpu load …). A history
// that moved on by one value slides to the left while the new value comes in
// from the right, and the scale follows the peak instead of jumping to it.
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
	// the peak the chart is drawn to
	property real scale_: root.peak
	// the history before the last value, while it slides out
	property var before: null
	property var last: []
	// 0 the history before, 1 the one that is there now
	property real slide: 1

	implicitHeight: 64
	antialiasing: true
	renderStrategy: Canvas.Cooperative

	onValuesChanged: {
		const now = root.values || [];
		const old = root.last;
		root.last = now;
		// moved on by one value?
		let moved = root.visible && old.length > 1 && now.length === old.length;
		for (let i = 0; moved && i < now.length - 1; i += 1) moved = now[i] === old[i + 1];
		if (moved) {
			root.before = old;
			slider.restart();
		} else {
			slider.stop();
			root.before = null;
			root.slide = 1;
		}
		requestPaint();
	}
	onSlideChanged: requestPaint()
	onScale_Changed: requestPaint()
	onColorChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	Behavior on scale_ {
		NumberAnimation {
			duration: 600
			easing.type: Easing.OutCubic
		}
	}

	NumberAnimation {
		id: slider

		target: root
		property: "slide"
		from: 0
		to: 1
		duration: 700
		easing.type: Easing.InOutCubic
		onFinished: root.before = null
	}

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		const now = root.values || [];
		if (now.length < 2)
			return;

		// while it slides: the history before, and the new value behind its end
		const sliding = root.before !== null && root.slide < 1;
		const values = sliding ? root.before.concat([now[now.length - 1]]) : now;
		const offset = sliding ? root.slide : 0;
		const w = width;
		const h = height - root.lineWidth;
		const step = w / (now.length - 1);
		const points = values.map((v, i) => ({
			x: (i - offset) * step,
			y: root.lineWidth / 2 + h - h * Math.max(0, Math.min(1, (Number(v) || 0) / root.scale_))
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

		// where the line meets the right edge
		const edge = points[points.length - 1];
		let end = edge.y;
		if (sliding) {
			const prev = points[points.length - 2];
			const part = (w - prev.x) / step;
			let low = 0;
			let high = 1;
			for (let i = 0; i < 12; i += 1) {
				const t = (low + high) / 2;
				if (1.5 * t * (1 - t) + t * t * t < part) low = t;
				else high = t;
			}
			const t = (low + high) / 2;
			const rise = 3 * (1 - t) * t * t + t * t * t;
			end = prev.y + (edge.y - prev.y) * rise;
		}

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

		const last = { x: w, y: end };
		ctx.beginPath();
		ctx.arc(last.x - root.lineWidth, last.y, root.lineWidth * 1.6, 0, Math.PI * 2);
		ctx.fillStyle = root.color;
		ctx.fill();
	}
}
