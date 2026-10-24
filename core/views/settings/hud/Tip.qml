import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets

// A word about what is under the pointer, after a moment of hovering: fills
// its parent and floats above everything, clipping or not.
Item {
	id: root

	property string text: ""
	// above (default) or below its parent
	property bool below: false

	anchors.fill: parent

	HoverHandler {
		id: hover

		onHoveredChanged: {
			if (hover.hovered && root.text !== "") wait.restart();
			else {
				wait.stop();
				bubble.close();
			}
		}
	}

	Timer {
		id: wait

		interval: 520
		onTriggered: if (hover.hovered) bubble.open()
	}

	Popup {
		id: bubble

		x: Math.round((root.width - bubble.width) / 2)
		y: root.below ? root.height + 6 : -bubble.height - 6
		padding: 0
		modal: false
		focus: false
		closePolicy: Popup.NoAutoClose
		width: tipText.implicitWidth + 18
		height: tipText.implicitHeight + 10

		enter: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.short
				}
				NumberAnimation {
					property: "scale"
					from: 0.85
					to: 1
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatialFast
				}
			}
		}
		exit: Transition {
			NumberAnimation {
				property: "opacity"
				to: 0
				duration: Motion.micro
			}
		}

		background: Rectangle {
			radius: 8
			color: Theme.layer3
			border.width: 1
			border.color: Theme.outline
		}

		contentItem: StyledText {
			id: tipText

			text: root.text
			font.pixelSize: Theme.size.small
			font.weight: Font.Medium
			horizontalAlignment: Text.AlignHCenter
		}
	}
}
