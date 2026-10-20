import QtQuick
import qs.style.theme
import qs.style.widgets

// One key, drawn as a keycap: a face on a slightly darker base, so it reads
// as something to press. `lit` fills it with the accent (a key held down
// while recording) and pushes the face down onto its base.
Item {
	id: root

	property string text: ""
	property real size: 26
	property bool lit: false
	property bool faint: false

	readonly property real depth: Math.max(2, Math.round(root.size * 0.09))
	readonly property real press: root.lit ? root.depth * 0.6 : 0

	implicitHeight: root.size + root.depth
	implicitWidth: Math.max(root.size, label.implicitWidth + root.size * 0.62)

	Rectangle {
		id: base

		anchors.fill: parent
		anchors.topMargin: root.depth
		radius: Math.round(root.size * 0.28)
		color: root.lit ? Qt.darker(Theme.primary, 1.45) : Theme.layer3
		opacity: root.faint ? 0.5 : 1

		Behavior on color {
			ColorAnim {}
		}
	}

	Rectangle {
		id: face

		width: parent.width
		height: root.size
		y: root.press
		radius: base.radius
		color: root.lit ? Theme.primary : (root.faint ? Theme.layer1 : Theme.layer2)
		border.width: 1
		border.color: root.lit ? Qt.lighter(Theme.primary, 1.15) : Theme.outline

		Behavior on color {
			ColorAnim {}
		}
		Behavior on y {
			SpatialAnim {
				duration: Motion.short
			}
		}

		StyledText {
			id: label

			anchors.centerIn: parent
			text: root.text
			tone: root.lit ? Theme.onPrimary : (root.faint ? Theme.textSubtle : Theme.text)
			surface: face.color
			font.pixelSize: Math.round(root.size * (root.text.length > 6 ? 0.36 : 0.44))
			font.weight: Font.DemiBold
		}
	}
}
