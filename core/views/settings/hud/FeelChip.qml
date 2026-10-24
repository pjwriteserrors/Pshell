import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../mouse/Waves.js" as Waves

// The pattern a reaction plays: its drawing and its name; a click opens
// every pattern, the little play button plays this one.
Clickable {
	id: root

	property string feel: ""
	property color accent: Theme.primary

	signal picked(string value)

	implicitHeight: 30
	implicitWidth: row.implicitWidth + 12
	radius: 15
	pressedScale: 0.95
	color: picker.opened ? Qt.alpha(root.accent, 0.22) : (root.hovered ? Qt.alpha(root.accent, 0.16) : Qt.alpha(root.accent, 0.09))
	onClicked: picker.open()

	Behavior on color {
		ColorAnim {}
	}

	RowLayout {
		id: row

		anchors.verticalCenter: parent.verticalCenter
		x: 4
		spacing: 6

		// play
		Clickable {
			Layout.preferredWidth: 22
			Layout.preferredHeight: 22
			radius: 11
			color: hovered ? root.accent : Qt.alpha(root.accent, 0.2)
			pressedScale: 0.85
			sound: ""
			onClicked: {
				Mouse.play(root.feel);
				miniWave.play();
			}

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				anchors.horizontalCenterOffset: 1
				icon: "play"
				size: 12
				color: parent.hovered ? Theme.onPrimary : root.accent
			}
		}

		MiniWave {
			id: miniWave

			Layout.preferredWidth: 34
			Layout.preferredHeight: 14
			waveform: root.feel
			color: Qt.alpha(root.accent, 0.8)
			glow: Theme.text
		}

		StyledText {
			Layout.rightMargin: 4
			text: Waves.names[root.feel] ?? root.feel.toLowerCase()
			tone: Theme.text
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}
	}

	FeelPicker {
		id: picker

		y: root.height + 4
		current: root.feel
		onPicked: value => {
			miniWave.play();
			root.picked(value);
		}
	}
}
