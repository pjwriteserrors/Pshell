import QtQuick
import qs.style.theme
import qs.style.widgets

// Pointer acceleration as a curve: how far the pointer goes (up) for how
// fast the hand moves (right). Flat is a straight line; adaptive bends up
// for fast moves. Drag the curve up or down for the speed.
Item {
	id: root

	property real speed: 0
	property bool flat: false

	signal moved(real speed)

	implicitWidth: 220
	implicitHeight: 150

	property real shown: root.speed
	property real bend: root.flat ? 0 : 1

	Behavior on shown {
		enabled: !mouse.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on bend {
		SpatialAnim {
			duration: Motion.long
		}
	}

	onShownChanged: canvas.requestPaint()
	onBendChanged: canvas.requestPaint()

	function gain(x) {
		// x in 0…1: hand speed; the result: pointer speed, 0…1.4
		const base = 0.55 + root.shown * 0.4;
		return x * base * (1 + root.bend * x * (0.9 + root.shown * 0.6));
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: Theme.layer2
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		anchors.margins: 14
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const w = width, h = height;
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.12);
			ctx.lineWidth = 1;
			ctx.beginPath();
			ctx.moveTo(0, h);
			ctx.lineTo(w, 0);
			ctx.stroke();
			ctx.strokeStyle = Theme.primary;
			ctx.lineWidth = 3;
			ctx.lineCap = "round";
			ctx.beginPath();
			for (let i = 0; i <= 40; i++) {
				const x = i / 40;
				const y = Math.min(1.5, root.gain(x)) / 1.5;
				if (i === 0) ctx.moveTo(x * w, h - y * h);
				else ctx.lineTo(x * w, h - y * h);
			}
			ctx.stroke();
		}
	}

	StyledText {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.margins: 8
		text: "hand →"
		tone: Theme.textFaint
		font.pixelSize: Theme.size.tiny
	}

	StyledText {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.margins: 8
		text: "↑ pointer"
		tone: Theme.textFaint
		font.pixelSize: Theme.size.tiny
	}

	Rectangle {
		readonly property real y0: 14 + (canvas.height - Math.min(1.5, root.gain(0.6)) / 1.5 * canvas.height)

		x: 14 + canvas.width * 0.6 - width / 2
		y: y0 - height / 2
		width: mouse.pressed ? 20 : 16
		height: width
		radius: width / 2
		color: Theme.primary
		border.width: 3
		border.color: Theme.layer2

		Behavior on width {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	StyledText {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 8
		text: (root.speed >= 0 ? "+" : "") + root.speed.toFixed(2)
		tabular: true
		tone: Theme.primary
		font.weight: Font.DemiBold
		font.pixelSize: Theme.size.small
	}

	MouseArea {
		id: mouse

		property real startY
		property real startSpeed

		anchors.fill: parent
		preventStealing: true
		cursorShape: Qt.SizeVerCursor
		onPressed: event => {
			mouse.startY = event.y;
			mouse.startSpeed = root.speed;
		}
		onPositionChanged: event => {
			if (!pressed) return;
			const next = Math.max(-1, Math.min(1, mouse.startSpeed - (event.y - mouse.startY) / (height * 0.6)));
			root.moved(Math.round(next * 20) / 20);
		}
		onDoubleClicked: root.moved(0)
	}
}
