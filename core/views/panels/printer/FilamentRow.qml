pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One filament of the file and the ACE slot it is printed from: the colour
// and material the slicer had in mind on the left, the spools of the ACE on
// the right. A spool of another material is marked.
RowLayout {
	id: root

	required property var filament
	property int picked: -1
	signal pick(int slot)

	readonly property var slot: Printer.slot(root.picked)
	readonly property bool mismatch: root.slot !== null && String(root.slot.type).toLowerCase().split(" ")[0] !== String(root.filament.type).toLowerCase().split(" ")[0]

	spacing: 10

	Rectangle {
		Layout.preferredWidth: 22
		Layout.preferredHeight: 22
		radius: 11
		color: Printer.rgb(root.filament.color)
		border.width: 1
		border.color: Theme.outline
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 0

		StyledText {
			Layout.fillWidth: true
			text: root.filament.type || "Filament"
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}

		StyledText {
			Layout.fillWidth: true
			text: root.mismatch ? `Slot is ${root.slot.type}` : `${root.filament.grams} g`
			tone: root.mismatch ? Theme.warning : Theme.textMuted
			font.pixelSize: Theme.size.small
			elide: Text.ElideRight
		}
	}

	Glyph {
		icon: "arrow_right"
		size: 14
		color: Theme.textFaint
	}

	Repeater {
		model: Printer.slots

		delegate: Clickable {
			id: spool

			required property var modelData
			readonly property bool empty: spool.modelData.type === ""
			readonly property bool chosen: spool.modelData.slot === root.picked

			Layout.preferredWidth: 30
			Layout.preferredHeight: 30
			radius: 15
			interactive: !spool.empty
			onClicked: root.pick(spool.modelData.slot)

			Rectangle {
				anchors.centerIn: parent
				width: spool.chosen ? 30 : 24
				height: width
				radius: width / 2
				color: "transparent"
				border.width: spool.chosen ? 2 : 0
				border.color: Theme.primary

				Behavior on width {
					SpatialAnim {}
				}
			}

			Rectangle {
				anchors.centerIn: parent
				width: 22
				height: 22
				radius: 11
				color: spool.empty ? "transparent" : Printer.rgb(spool.modelData.color)
				border.width: 1
				border.color: spool.empty ? Theme.textFaint : Theme.outline
				opacity: spool.empty ? 0.5 : 1

				StyledText {
					anchors.centerIn: parent
					text: spool.modelData.slot + 1
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
					tone: spool.empty ? Theme.textFaint : Theme.text
				}
			}
		}
	}
}
