import QtQuick
import qs.style.theme
import qs.style.widgets

// The battery over the last days: [[unix seconds, percent, status]], a line
// that is drawn from left to right when it first shows; charging stretches
// are shaded.
Item {
	id: root

	property var log: []
	property real drawn: 0

	readonly property var points: {
		const now = Date.now() / 1000;
		const span = 7 * 86400;
		return (root.log ?? []).filter(p => p[0] > now - span).map(p => ({ x: 1 - (now - p[0]) / span, y: p[1] / 100, charging: p[2] !== "discharging" }));
	}

	onPointsChanged: canvas.requestPaint()
	onDrawnChanged: canvas.requestPaint()
	Component.onCompleted: grow.start()

	NumberAnimation {
		id: grow

		target: root
		property: "drawn"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		anchors.bottomMargin: 16
		renderStrategy: Canvas.Cooperative
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const w = width;
			const h = height;
			// guides at 25 % steps
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.06);
			ctx.lineWidth = 1;
			for (const g of [0.25, 0.5, 0.75]) {
				ctx.beginPath();
				ctx.moveTo(0, h - g * h);
				ctx.lineTo(w, h - g * h);
				ctx.stroke();
			}
			const pts = root.points;
			if (pts.length === 0) return;
			const limit = root.drawn * w;
			// charging, shaded
			ctx.fillStyle = Qt.alpha(Theme.success, 0.12);
			for (let i = 0; i < pts.length; i += 1) {
				if (!pts[i].charging) continue;
				const x0 = pts[i].x * w;
				const x1 = (i + 1 < pts.length ? pts[i + 1].x : 1) * w;
				ctx.fillRect(x0, 0, Math.min(x1, limit) - x0, h);
			}
			// the level, held until it changes
			ctx.beginPath();
			let started = false;
			for (let i = 0; i < pts.length; i += 1) {
				const x = Math.min(pts[i].x * w, limit);
				const y = h - pts[i].y * h;
				if (!started) {
					ctx.moveTo(x, y);
					started = true;
				} else {
					ctx.lineTo(x, h - pts[i - 1].y * h);
					ctx.lineTo(x, y);
				}
				if (pts[i].x * w > limit) break;
			}
			const last = pts[pts.length - 1];
			ctx.lineTo(limit, h - last.y * h);
			ctx.strokeStyle = Theme.primary;
			ctx.lineWidth = 2;
			ctx.lineJoin = "round";
			ctx.stroke();
			ctx.lineTo(limit, h);
			ctx.lineTo(pts[0].x * w, h);
			ctx.closePath();
			ctx.fillStyle = Qt.alpha(Theme.primary, 0.1);
			ctx.fill();
		}
	}

	StyledText {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		text: "7 days ago"
		tone: Theme.textFaint
		font.pixelSize: Theme.size.tiny
	}

	StyledText {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		text: "now"
		tone: Theme.textFaint
		font.pixelSize: Theme.size.tiny
	}

	StyledText {
		anchors.centerIn: canvas
		visible: root.points.length < 2
		text: "The line grows as the battery goes"
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
	}
}
