import QtQuick
import qs.style.theme
import qs.style.widgets

// A rhyme or a word: its syllables small beside it. It comes in a moment
// after the one before it (`order`), so a list of them ripples in.
Clickable {
	id: chip

	property string text: ""
	property int syllables: 0
	property int order: 0
	property color accent: Theme.primary
	property bool strong: false

	acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
	implicitWidth: label.implicitWidth + (count.visible ? count.implicitWidth + 6 : 0) + 22
	implicitHeight: 30
	radius: height / 2
	color: chip.strong ? Qt.alpha(chip.accent, 0.18) : Theme.layer1
	tint: chip.accent
	sound: ""
	opacity: 0
	transform: Translate {
		id: shift

		y: 8
	}

	Component.onCompleted: arrive.start()

	SequentialAnimation {
		id: arrive

		PauseAnimation {
			duration: Math.min(chip.order, 24) * 14
		}

		ParallelAnimation {
			Anim {
				target: chip
				property: "opacity"
				to: 1
			}

			SpatialAnim {
				target: shift
				property: "y"
				to: 0
			}
		}
	}

	Row {
		anchors.centerIn: parent
		spacing: 6

		StyledText {
			id: label

			anchors.verticalCenter: parent.verticalCenter
			text: chip.text
			font.pixelSize: Theme.size.body
			tone: chip.strong ? chip.accent : Theme.text
		}

		StyledText {
			id: count

			anchors.verticalCenter: parent.verticalCenter
			visible: chip.syllables > 0
			text: String(chip.syllables)
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
		}
	}
}
