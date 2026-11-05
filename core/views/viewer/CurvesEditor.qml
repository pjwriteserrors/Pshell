import QtQuick
import qs.style.theme
import "Recipe.js" as Recipe

// A tone curve: a press adds a point (or takes the one near it), dragging
// moves it between its neighbours, a double-click or dragging it far out
// takes it away. `histogram` (64 values) is drawn behind.
Item {
	id: root

	property var points: [[0, 0], [1, 1]]
	property color tone: Theme.text
	property var histogram: []
	signal moved(var points)
	signal committed(var points)

	property int grabbed: -1
	property var working: null
	readonly property var shown: root.working ?? root.normalised(root.points)

	implicitWidth: 260
	implicitHeight: 260

	function normalised(p) {
		const out = (p && p.length >= 2 ? p : [[0, 0], [1, 1]]).map(q => [q[0], q[1]]);
		out.sort((a, b) => a[0] - b[0]);
		return out;
	}

	function toPoint(x, y) {
		return [Math.max(0, Math.min(1, x / root.width)), Math.max(0, Math.min(1, 1 - y / root.height))];
	}

	function nearest(x, y) {
		let best = -1, bestDistance = 14;
		root.shown.forEach((p, i) => {
			const d = Math.hypot(p[0] * root.width - x, (1 - p[1]) * root.height - y);
			if (d < bestDistance) {
				best = i;
				bestDistance = d;
			}
		});
		return best;
	}

	onShownChanged: canvas.requestPaint()
	onHistogramChanged: canvas.requestPaint()
	onToneChanged: canvas.requestPaint()

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.small
		color: Theme.layer1
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		onPaint: {
			const ctx = getContext("2d");
			const w = width, h = height;
			ctx.reset();
			// what the picture holds
			const hist = root.histogram || [];
			if (hist.length > 0) {
				ctx.fillStyle = Qt.alpha(Theme.text, 0.08);
				ctx.beginPath();
				ctx.moveTo(0, h);
				hist.forEach((v, i) => ctx.lineTo(i / (hist.length - 1) * w, h - v * h * 0.9));
				ctx.lineTo(w, h);
				ctx.closePath();
				ctx.fill();
			}
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.08);
			ctx.lineWidth = 1;
			for (let i = 1; i < 4; i += 1) {
				ctx.beginPath();
				ctx.moveTo(i * w / 4, 0);
				ctx.lineTo(i * w / 4, h);
				ctx.moveTo(0, i * h / 4);
				ctx.lineTo(w, i * h / 4);
				ctx.stroke();
			}
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.18);
			ctx.beginPath();
			ctx.moveTo(0, h);
			ctx.lineTo(w, 0);
			ctx.stroke();
			const values = Recipe.sampleCurve(root.shown);
			ctx.strokeStyle = root.tone;
			ctx.lineWidth = 2;
			ctx.beginPath();
			values.forEach((v, i) => {
				const x = i / 255 * w, y = h - v * h;
				if (i === 0) ctx.moveTo(x, y);
				else ctx.lineTo(x, y);
			});
			ctx.stroke();
		}
	}

	Repeater {
		model: root.shown

		delegate: Rectangle {
			required property var modelData
			required property int index

			x: modelData[0] * root.width - width / 2
			y: (1 - modelData[1]) * root.height - height / 2
			width: index === root.grabbed ? 14 : 10
			height: width
			radius: width / 2
			color: index === root.grabbed ? root.tone : Theme.base
			border.width: 2
			border.color: root.tone
		}
	}

	MouseArea {
		anchors.fill: parent
		preventStealing: true
		cursorShape: root.grabbed >= 0 ? Qt.ClosedHandCursor : Qt.CrossCursor

		onPressed: event => {
			const pts = root.normalised(root.points);
			let i = root.nearest(event.x, event.y);
			if (i < 0) {
				const p = root.toPoint(event.x, event.y);
				pts.push([p[0], Recipe.sampleCurve(pts)[Math.round(p[0] * 255)]]);
				pts.sort((a, b) => a[0] - b[0]);
				i = pts.findIndex(q => q[0] === p[0]);
			}
			root.working = pts;
			root.grabbed = i;
		}
		onPositionChanged: event => {
			if (root.grabbed < 0 || !root.working) return;
			const pts = root.working.map(q => [q[0], q[1]]);
			const i = root.grabbed;
			const p = root.toPoint(event.x, event.y);
			const ends = i === 0 || i === pts.length - 1;
			// a point dragged far out goes
			if (!ends && (event.y < -40 || event.y > root.height + 40)) {
				pts.splice(i, 1);
				root.grabbed = -1;
				root.working = pts;
				root.moved(pts);
				return;
			}
			const lo = i > 0 ? pts[i - 1][0] + 0.01 : 0;
			const hi = i < pts.length - 1 ? pts[i + 1][0] - 0.01 : 1;
			pts[i] = [i === 0 ? Math.min(p[0], hi) : (i === pts.length - 1 ? Math.max(p[0], lo) : Math.max(lo, Math.min(hi, p[0]))), p[1]];
			root.working = pts;
			root.moved(pts);
		}
		onReleased: {
			if (root.working) root.committed(root.working);
			root.working = null;
			root.grabbed = -1;
		}
		onDoubleClicked: event => {
			const pts = root.normalised(root.points);
			const i = root.nearest(event.x, event.y);
			if (i > 0 && i < pts.length - 1) {
				pts.splice(i, 1);
				root.working = null;
				root.grabbed = -1;
				root.committed(pts);
			}
		}
	}
}
