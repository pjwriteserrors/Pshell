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
		Layout.preferredWidth: 24
		Layout.preferredHeight: 24
		radius: 12
		color: Printer.rgb(root.filament.color)
		border.width: 1
		border.color: Qt.alpha(Theme.fg, 0.18)
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 0

		StyledText {
			Layout.fillWidth: true
			text: root.filament.type || "Filament"
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
		}

		StyledText {
			Layout.fillWidth: true
			text: root.mismatch ? `Slot holds ${root.slot.type}` : (root.slot ? `${root.filament.grams} g · from slot ${root.slot.slot + 1}` : `${root.filament.grams} g`)
			tone: root.mismatch ? Theme.warning : Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	Repeater {
		model: Printer.slots

		delegate: Item {
			id: holder

			required property var modelData
			readonly property bool empty: holder.modelData.type === ""

			Layout.preferredWidth: 30
			Layout.preferredHeight: 30

			Spool {
				anchors.fill: parent
				slot: holder.modelData
				chosen: holder.modelData.slot === root.picked
				scale: mouse.pressed ? 0.88 : (mouse.containsMouse && !holder.empty ? 1.1 : 1)
				opacity: holder.empty ? 0.5 : 1

				Behavior on scale {
					SpatialAnim {}
				}
			}

			MouseArea {
				id: mouse

				anchors.fill: parent
				hoverEnabled: true
				enabled: !holder.empty
				cursorShape: Qt.PointingHandCursor
				onClicked: root.pick(holder.modelData.slot)
			}
		}
	}
}
