import QtQuick
import qs.style.theme

// How the result's tones are spread: red, green and blue over each other,
// the light in front. Values grow into their new shape.
Item {
	id: root

	// { r, g, b, l: [values 0..1], clipLow, clipHigh }
	property var values: null
	property real morph: 1
	property var from: null
	property var to: null

	implicitHeight: 84

	onValuesChanged: {
		root.from = root.blend();
		root.to = root.values;
		morphAnim.restart();
	}

	function blend() {
		if (!root.to) return null;
		if (!root.from || root.morph >= 1) return root.to;
		const t = root.morph;
		const mix = (a, b) => (b || []).map((v, i) => (a?.[i] ?? 0) * (1 - t) + v * t);
		return { r: mix(root.from.r, root.to.r), g: mix(root.from.g, root.to.g), b: mix(root.from.b, root.to.b), l: mix(root.from.l, root.to.l) };
	}

	NumberAnimation {
		id: morphAnim

		target: root
		property: "morph"
		from: 0
		to: 1
		duration: Motion.medium
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.spatial
	}

	onMorphChanged: canvas.requestPaint()

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.small
		color: Theme.layer1
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		anchors.margins: 6
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const d = root.blend();
			if (!d) return;
			const w = width, h = height;
			const series = [["r", "#ff4d5e"], ["g", "#3ddc84"], ["b", "#4d8dff"]];
			ctx.globalCompositeOperation = "lighter";
			for (const [key, colour] of series) {
				const values = d[key] || [];
				if (values.length < 2) continue;
				ctx.fillStyle = Qt.alpha(colour, 0.42);
				ctx.beginPath();
				ctx.moveTo(0, h);
				values.forEach((v, i) => ctx.lineTo(i / (values.length - 1) * w, h - Math.min(1, v) * h));
				ctx.lineTo(w, h);
				ctx.closePath();
				ctx.fill();
			}
			ctx.globalCompositeOperation = "source-over";
			const light = d.l || [];
			if (light.length > 1) {
				ctx.strokeStyle = Qt.alpha(Theme.text, 0.7);
				ctx.lineWidth = 1.2;
				ctx.beginPath();
				light.forEach((v, i) => {
					const x = i / (light.length - 1) * w, y = h - Math.min(1, v) * h;
					if (i === 0) ctx.moveTo(x, y);
					else ctx.lineTo(x, y);
				});
				ctx.stroke();
			}
		}
	}

	// clipped ends light up
	Rectangle {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.margins: 4
		width: 6
		height: 6
		radius: 3
		color: "#4d8dff"
		opacity: (root.values?.clipLow ?? 0) > 0.01 ? 1 : 0
	}

	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 4
		width: 6
		height: 6
		radius: 3
		color: "#ff4d5e"
		opacity: (root.values?.clipHigh ?? 0) > 0.01 ? 1 : 0
	}
}
