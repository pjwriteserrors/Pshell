pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A launcher command as a tile: what it is, what is typed for it, and on
// the right what there is to know right now (3 updates, on) or where it
// leads (a group opens).
Clickable {
	id: root

	// { command, prefix, name, status, children }
	property var command: null
	property string glyph: "console"
	property bool selected: false
	property bool dimmed: false
	property bool pinned: false

	readonly property bool group: Boolean(root.command?.children)
	readonly property string status: String(root.command?.status ?? "")

	implicitHeight: 46
	radius: Theme.radius.medium
	pressedScale: 0.97
	showHover: false
	interactive: !root.dimmed
	acceptedButtons: Qt.LeftButton | Qt.RightButton
	color: root.selected ? Theme.primaryContainer : (root.hovered ? Theme.layer2 : Theme.layer1)
	opacity: root.dimmed ? 0.24 : 1

	Behavior on opacity {
		Anim {}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 8
		anchors.rightMargin: 10
		spacing: 9

		Rectangle {
			Layout.preferredWidth: 30
			Layout.preferredHeight: 30
			radius: root.selected ? Theme.radius.small : 15
			color: root.selected ? Theme.primary : Theme.layer2

			Behavior on radius {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.glyph
				size: 16
				color: root.selected ? Theme.onPrimary : Theme.text
				animated: false
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: -1

			StyledText {
				Layout.fillWidth: true
				text: root.command?.name ?? ""
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				StyledText {
					Layout.fillWidth: true
					text: `${root.command?.prefix ?? ">"}${root.command?.command ?? ""}`
					tone: root.selected ? Theme.primary : Theme.textSubtle
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.tiny
				}

				StyledText {
					visible: root.status !== ""
					text: root.status
					tone: Theme.primary
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
					tabular: true
				}
			}
		}

		Glyph {
			visible: root.group || root.pinned
			icon: root.group ? "chevron_right" : "pin"
			size: root.group ? 16 : 12
			color: Theme.textSubtle
			animated: false
		}
	}
}
