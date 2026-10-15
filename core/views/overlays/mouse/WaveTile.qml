import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Waves.js" as Waves

// One haptic waveform: how it goes, drawn, and a click plays it on the mouse
// while a light runs along the drawing.
Clickable {
	id: root

	property string waveform: ""
	property bool chosen: false
	property real played: 0
	readonly property var samples: Waves.sample(root.waveform, 64)

	implicitHeight: 92
	radius: Theme.radius.large
	color: root.chosen ? Theme.primaryContainer : (root.hovered ? Theme.layer2 : Theme.layer1)
	border.width: root.chosen ? 1.5 : 0
	border.color: Theme.primary
	sound: ""
	onClicked: {
		Mouse.play(root.waveform);
		playAnim.restart();
	}

	onPlayedChanged: wave.requestPaint()

	NumberAnimation {
		id: playAnim

		target: root
		property: "played"
		from: 0
		to: 1
		duration: 520
		easing.type: Easing.Linear
		onFinished: root.played = 0
	}

	Canvas {
		id: wave

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		height: 42
		renderStrategy: Canvas.Cooperative
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const n = root.samples.length;
			const mid = height / 2;
			const amp = height / 2 - 3;
			const draw = (until, color, width) => {
				ctx.beginPath();
				for (let i = 0; i < n; i += 1) {
					const x = i / (n - 1) * wave.width;
					if (x > until) break;
					const y = mid - root.samples[i] * amp * (1 + (root.played > 0 ? 0.15 * Math.sin(root.played * Math.PI) : 0));
					if (i === 0) ctx.moveTo(x, y);
					else ctx.lineTo(x, y);
				}
				ctx.strokeStyle = color;
				ctx.lineWidth = width;
				ctx.lineJoin = "round";
				ctx.lineCap = "round";
				ctx.stroke();
			};
			draw(wave.width, Qt.alpha(Theme.text, 0.3), 1.6);
			if (root.played > 0) draw(root.played * wave.width, Theme.primary, 2.4);
		}

		Connections {
			target: Theme

			function onPrimaryChanged() {
				wave.requestPaint();
			}
		}
	}

	// the light running along
	Rectangle {
		visible: root.played > 0
		x: 12 + root.played * wave.width - 1
		y: wave.y
		width: 2
		height: wave.height
		radius: 1
		color: Theme.primary
	}

	StyledText {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 12
		anchors.bottomMargin: 10
		text: Waves.names[root.waveform] ?? root.waveform.toLowerCase()
		tone: root.chosen ? Theme.primary : Theme.text
		font.weight: Font.Medium
		font.pixelSize: Theme.size.label
		elide: Text.ElideRight
	}
}
