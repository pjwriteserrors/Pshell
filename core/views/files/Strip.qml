import QtQuick
import qs.style.theme
import qs.style.widgets

// A row of cards that goes on to the right: a touchpad swipes it, arrows
// at its ends turn it a page at a time, its edges fade.
Item {
	id: root

	default property alias content: row.data
	readonly property bool more: flick.contentX + flick.width < flick.contentWidth - 2
	readonly property bool less: flick.contentX > 2

	height: row.height

	function turn(direction) {
		const max = Math.max(0, flick.contentWidth - flick.width);
		slide.to = Math.max(0, Math.min(max, flick.contentX + direction * flick.width * 0.8));
		slide.restart();
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentWidth: row.width
		contentHeight: row.height
		interactive: false
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		Row {
			id: row

			spacing: 12
		}
	}

	NumberAnimation {
		id: slide

		target: flick
		property: "contentX"
		duration: Motion.long
		easing.type: Easing.OutCubic
	}

	MouseArea {
		id: hover

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onWheel: wheel => {
			const dx = wheel.pixelDelta.x !== 0 ? -wheel.pixelDelta.x : (wheel.modifiers & Qt.ShiftModifier ? -wheel.angleDelta.y : -wheel.angleDelta.x);
			if (dx === 0) {
				wheel.accepted = false;
				return;
			}
			slide.stop();
			flick.contentX = Math.max(0, Math.min(Math.max(0, flick.contentWidth - flick.width), flick.contentX + dx));
		}
	}

	// the edges fade where there is more
	Rectangle {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: 36
		visible: root.less
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Theme.base
			}
			GradientStop {
				position: 1
				color: Qt.alpha(Theme.base, 0)
			}
		}
	}

	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: 36
		visible: root.more
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Qt.alpha(Theme.base, 0)
			}
			GradientStop {
				position: 1
				color: Theme.base
			}
		}
	}

	IconButton {
		anchors.left: parent.left
		anchors.leftMargin: 4
		anchors.verticalCenter: parent.verticalCenter
		width: 34
		height: 34
		variant: "tonal"
		icon: "chevron_left"
		opacity: root.less && hover.containsMouse ? 1 : 0
		visible: opacity > 0
		onClicked: root.turn(-1)

		Behavior on opacity {
			Anim {}
		}
	}

	IconButton {
		anchors.right: parent.right
		anchors.rightMargin: 4
		anchors.verticalCenter: parent.verticalCenter
		width: 34
		height: 34
		variant: "tonal"
		icon: "chevron_right"
		opacity: root.more && hover.containsMouse ? 1 : 0
		visible: opacity > 0
		onClicked: root.turn(1)

		Behavior on opacity {
			Anim {}
		}
	}
}
