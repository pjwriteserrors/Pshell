import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// "Default" – takes a setting back to what niri does without it. Pops in
// while there is something to take back.
Clickable {
	id: root

	property bool shown: false
	property string text: "Default"

	implicitHeight: 28
	implicitWidth: root.shown ? row.implicitWidth + 20 : 0
	Layout.preferredWidth: implicitWidth
	radius: height / 2
	color: Theme.layer2
	clip: true
	scale: root.shown ? 1 : 0.6
	opacity: root.shown ? 1 : 0
	visible: opacity > 0.01
	interactive: root.shown

	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 5

		Glyph {
			icon: "restore"
			size: 13
			color: Theme.textMuted
		}

		StyledText {
			text: root.text
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			font.weight: Font.Medium
		}
	}
}
