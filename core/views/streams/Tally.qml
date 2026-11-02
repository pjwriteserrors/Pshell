import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A number that jumps when it changes, over what it counts.
ColumnLayout {
	id: root

	property int value: 0
	property string label: ""
	property color tone: Theme.text

	spacing: 0

	onValueChanged: bump.restart()

	StyledText {
		id: number

		text: root.value
		font.pixelSize: Theme.size.display
		font.weight: Font.Bold
		color: root.tone
		tabular: true
		transformOrigin: Item.Left
	}
	StyledText {
		text: root.label
		font.pixelSize: Theme.size.small
		tone: Theme.textMuted
	}

	SequentialAnimation {
		id: bump

		NumberAnimation {
			target: number
			property: "scale"
			to: 1.22
			duration: 90
			easing.type: Easing.OutCubic
		}
		SpatialAnim {
			target: number
			property: "scale"
			to: 1
			duration: Motion.medium
		}
	}
}
