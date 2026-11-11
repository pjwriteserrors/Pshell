pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Which Floorp workspace each niri workspace brings up (FloorpWorkspaces,
// plugin browser-workspaces), and whether Floorp follows niri at all.
ColumnLayout {
	id: root

	readonly property var niriWorkspaces: Niri.workspaces.slice().sort((a, b) => String(a.output).localeCompare(String(b.output)) || a.idx - b.idx)
	readonly property var entries: [{ value: "", label: "None" }].concat(FloorpWorkspaces.workspaces.map(ws => ({ value: ws.id, label: ws.name, detail: ws.isSelected ? "now" : "" })))

	spacing: 8

	Component.onCompleted: FloorpWorkspaces.refresh()

	RowLayout {
		Layout.fillWidth: true
		spacing: 12

		StyledText {
			Layout.fillWidth: true
			text: "Follow niri"
			font.pixelSize: Theme.size.body
		}

		Toggle {
			checked: FloorpWorkspaces.follow
			onToggled: checked => FloorpWorkspaces.setFollow(checked)
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: FloorpWorkspaces.error !== ""
		text: FloorpWorkspaces.error
		tone: Theme.danger
		font.pixelSize: Theme.size.small
	}

	Repeater {
		model: root.niriWorkspaces

		delegate: Rectangle {
			id: row

			required property var modelData
			readonly property string key: FloorpWorkspaces.niriKey(row.modelData)
			readonly property string target: FloorpWorkspaces.map[row.key] ?? ""
			readonly property var targetWorkspace: FloorpWorkspaces.workspaces.find(ws => ws.id === row.target) ?? null

			Layout.fillWidth: true
			implicitHeight: 44
			radius: Theme.radius.medium
			color: row.modelData.is_focused ? Theme.layer2 : Theme.layer1

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 14
				anchors.rightMargin: 6
				spacing: 10

				Glyph {
					icon: "monitor_dashboard"
					size: 16
					color: row.modelData.is_focused ? Theme.primary : Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: FloorpWorkspaces.niriLabel(row.key)
					font.pixelSize: Theme.size.body
				}

				TextButton {
					id: chooser

					implicitHeight: 32
					variant: row.target !== "" ? "tonal" : "ghost"
					text: row.targetWorkspace ? row.targetWorkspace.name : (row.target !== "" ? row.target : "None")
					onActivated: menu.open()

					PickList {
						id: menu

						y: parent.height + 4
						current: row.target
						entries: root.entries
						onPicked: value => FloorpWorkspaces.assign(row.key, String(value))
					}
				}
			}
		}
	}
}
