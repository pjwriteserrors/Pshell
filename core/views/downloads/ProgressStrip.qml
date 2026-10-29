import QtQuick
import qs.style.theme
import qs.style.widgets

// A download's bar the normal way: it fills from the left, a light runs
// through what is there while bytes come in; without a known size a piece
// of it swings to and fro.
Rectangle {
	id: root

	property real value: 0
	property bool known: true
	property bool running: false
	property color accent: Theme.primary

	implicitHeight: 8
	radius: height / 2
	color: Qt.alpha(root.accent, 0.14)
	clip: true

	Behavior on color {
		ColorAnim {}
	}

	Rectangle {
		id: fill

		visible: root.known
		height: parent.height
		radius: parent.radius
		width: Math.max(root.value > 0 ? height : 0, parent.width * Math.max(0, Math.min(1, root.value)))
		color: root.accent
		clip: true

		Behavior on width {
			NumberAnimation {
				duration: 950
				easing.type: Easing.OutCubic
			}
		}
		Behavior on color {
			ColorAnim {}
		}

		// the light running through
		Rectangle {
			id: shine

			visible: root.running
			width: Math.max(60, root.width * 0.25)
			height: parent.height
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop { position: 0; color: Qt.alpha("white", 0) }
				GradientStop { position: 0.5; color: Qt.alpha("white", 0.38) }
				GradientStop { position: 1; color: Qt.alpha("white", 0) }
			}

			NumberAnimation on x {
				running: root.running && root.visible
				loops: Animation.Infinite
				from: -shine.width
				to: root.width
				duration: 1600
				easing.type: Easing.InOutQuad
			}
		}
	}

	// no size: a piece that swings
	Rectangle {
		id: swing

		visible: !root.known
		width: parent.width * 0.3
		height: parent.height
		radius: parent.radius
		color: root.accent

		SequentialAnimation on x {
			running: !root.known && root.running && root.visible
			loops: Animation.Infinite
			NumberAnimation { from: 0; to: root.width - swing.width; duration: 900; easing.type: Easing.InOutCubic }
			NumberAnimation { from: root.width - swing.width; to: 0; duration: 900; easing.type: Easing.InOutCubic }
		}
	}
}
