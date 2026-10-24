import QtQuick
import qs.style.theme
import "../mouse/Waves.js" as Waves

// A haptic pattern drawn small; play() runs a light along it.
Canvas {
	id: root

	property string waveform: ""
	property color color: Theme.text
	property color glow: Theme.primary
	property real lineWidth: 1.6
	property real played: 0
	readonly property var samples: Waves.sample(root.waveform, 40)

	function play() {
		run.restart();
	}

	implicitWidth: 38
	implicitHeight: 16
	renderStrategy: Canvas.Cooperative
	onSamplesChanged: requestPaint()
	onColorChanged: requestPaint()
	onPlayedChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	NumberAnimation {
		id: run

		target: root
		property: "played"
		from: 0
		to: 1
		duration: 480
		onFinished: root.played = 0
	}

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		const n = root.samples.length;
		const width_ = root.width;
		const mid = height / 2;
		const amp = height / 2 - 1.5;
		const draw = (until, color, width) => {
			ctx.beginPath();
			for (let i = 0; i < n; i += 1) {
				const x = i / (n - 1) * width_;
				if (x > until) break;
				const y = mid - root.samples[i] * amp;
				if (i === 0) ctx.moveTo(x, y);
				else ctx.lineTo(x, y);
			}
			ctx.strokeStyle = color;
			ctx.lineWidth = width;
			ctx.lineJoin = "round";
			ctx.lineCap = "round";
			ctx.stroke();
		};
		draw(width_, root.color, root.lineWidth);
		if (root.played > 0) draw(root.played * width_, root.glow, root.lineWidth + 0.8);
	}
}
