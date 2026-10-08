import QtQuick
import qs.style.theme
import qs.style.widgets

// A dial for a gradient's angle: drag around it, it clicks into 15° steps
// (Shift lets go of them). The arrow points where the gradient runs to.
Item {
	id: root

	property real angle: 180
	property string from: "#000000"
	property string to: "#ffffff"
	property string space: "srgb"

	signal moved(real angle)

	implicitWidth: 92
	implicitHeight: 92

	property real shown: root.angle

	Behavior on shown {
		enabled: !mouse.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RoundClip {
		anchors.fill: parent
		radius: width / 2

		GradientFill {
			anchors.fill: parent
			from: root.from
			to: root.to
			angle: root.angle
			space: root.space
		}
	}

	Rectangle {
		anchors.fill: parent
		anchors.margins: 12
		radius: width / 2
		color: Qt.alpha(Theme.layer1, 0.82)
	}

	// ticks every 45°
	Repeater {
		model: 8

		delegate: Rectangle {
			required property int index

			x: root.width / 2 - width / 2 + Math.sin(index * Math.PI / 4) * (root.width / 2 - 6)
			y: root.height / 2 - height / 2 - Math.cos(index * Math.PI / 4) * (root.height / 2 - 6)
			width: 3
			height: 3
			radius: 1.5
			color: Qt.alpha(Theme.text, 0.6)
		}
	}

	Item {
		anchors.fill: parent
		rotation: root.shown

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 18
			width: 3
			height: parent.height / 2 - 18
			radius: 1.5
			color: Theme.text
		}

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 8
			icon: "chevron_up"
			size: 18
			color: Theme.text
		}
	}

	Rectangle {
		anchors.centerIn: parent
		width: 34
		height: 20
		radius: 10
		color: Theme.layer2

		StyledText {
			anchors.centerIn: parent
			text: `${Math.round(root.angle)}°`
			tabular: true
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		preventStealing: true
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
		function pick(mouse) {
			let deg = Math.atan2(mouse.x - width / 2, -(mouse.y - height / 2)) * 180 / Math.PI;
			if (deg < 0) deg += 360;
			if (!(mouse.modifiers & Qt.ShiftModifier)) deg = Math.round(deg / 15) * 15;
			root.moved(Math.round(deg) % 360);
		}
		onPressed: mouse => pick(mouse)
		onPositionChanged: mouse => pick(mouse)
		onWheel: wheel => root.moved(((Math.round(root.angle / 15) * 15 + (wheel.angleDelta.y > 0 ? 15 : -15)) % 360 + 360) % 360)
	}
}
