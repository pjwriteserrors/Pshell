import QtQuick
import qs.style.theme
import qs.style.widgets

// A wait in milliseconds on a line: the press at the left, the moment it
// happens at the dot – drag the dot. What happens then lights up there.
Item {
	id: root

	property int value: 150
	property int maximum: 1500
	property int step: 10
	property string start: "Pressed"
	property string happens: "Shows"
	property string icon: "eye_outline"
	property bool playing: true

	signal moved(int value)

	implicitWidth: 400
	implicitHeight: 74

	readonly property real px: (width - 30) / root.maximum
	property real clock: 0

	NumberAnimation on clock {
		running: root.playing && root.visible
		from: 0
		to: root.maximum
		duration: root.maximum * 1.6 + 600
		loops: Animation.Infinite
	}

	Rectangle {
		x: 15
		y: 40
		width: parent.width - 30
		height: 3
		radius: 1.5
		color: Theme.layer3
	}

	// time passing
	Rectangle {
		x: 15
		y: 40
		width: Math.min(root.clock, root.maximum) * root.px
		height: 3
		radius: 1.5
		color: Qt.alpha(Theme.primary, 0.5)
	}

	Rectangle {
		x: 9
		y: 33
		width: 12
		height: 17
		radius: 4
		color: Theme.text
	}

	StyledText {
		x: 4
		y: 54
		text: root.start
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.tiny
	}

	Rectangle {
		id: dot

		readonly property bool reached: root.clock >= root.value

		x: 15 + root.value * root.px - width / 2
		y: 41.5 - height / 2
		width: mouse.pressed ? 22 : 18
		height: width
		radius: width / 2
		color: dot.reached ? Theme.primary : Theme.layer3
		border.width: 3
		border.color: Theme.primary

		Behavior on color {
			ColorAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			icon: root.icon
			size: 10
			color: dot.reached ? Theme.onPrimary : Theme.primary
		}
	}

	Rectangle {
		x: Math.max(0, Math.min(root.width - width, dot.x + dot.width / 2 - width / 2))
		y: 2
		width: label.implicitWidth + 16
		height: 24
		radius: 12
		color: dot.reached ? Theme.primary : Theme.layer2
		scale: dot.reached ? 1.05 : 1

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}

		StyledText {
			id: label

			anchors.centerIn: parent
			text: `${root.happens} after ${root.value} ms`
			tabular: true
			tone: dot.reached ? Theme.onPrimary : Theme.text
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		preventStealing: true
		cursorShape: Qt.SizeHorCursor
		function pick(event) {
			root.moved(Math.max(0, Math.min(root.maximum, Math.round((event.x - 15) / root.px / root.step) * root.step)));
		}
		onPressed: event => pick(event)
		onPositionChanged: event => pick(event)
	}
}
