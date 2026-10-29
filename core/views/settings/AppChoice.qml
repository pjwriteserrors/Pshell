import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One program to pick (Default apps): its icon and name, outlined with a
// check when it is the one; a spinner while it is being set.
Clickable {
	id: root

	// { id, name, icon, executable, hidden, command }
	required property var app
	property bool selected: false
	property bool working: false
	property string note: ""

	readonly property string source: AppIcons.forEntry({ icon: root.app?.icon ?? "", id: root.app?.id ?? "" })

	implicitWidth: 132
	implicitHeight: 104
	radius: Theme.radius.large
	pressedScale: 0.95
	color: root.selected ? Theme.primaryContainer : (root.hovered ? Theme.layer3 : Theme.layer2)
	border.width: root.selected ? 1.5 : 0
	border.color: Theme.primary

	Behavior on color {
		ColorAnim {}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 10
		spacing: 6

		Item {
			Layout.alignment: Qt.AlignHCenter
			Layout.preferredWidth: 40
			Layout.preferredHeight: 40
			scale: root.selected ? 1.08 : (root.hovered ? 1.04 : 1)

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Image {
				id: picture

				anchors.fill: parent
				source: root.source
				sourceSize: Qt.size(80, 80)
				smooth: true
				asynchronous: true
				visible: status === Image.Ready
			}

			Glyph {
				anchors.centerIn: parent
				visible: picture.status !== Image.Ready
				icon: root.app?.hidden ? "console" : "application_outline"
				size: 28
				color: Theme.textMuted
			}

			Spinner {
				anchors.fill: parent
				anchors.margins: -4
				visible: root.working
				color: Theme.primary
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: DefaultApps.nameOf(root.app)
			horizontalAlignment: Text.AlignHCenter
			elide: Text.ElideRight
			font.pixelSize: Theme.size.small
			font.weight: root.selected ? Font.DemiBold : Font.Normal
			tone: root.selected ? Theme.primary : Theme.text
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.note !== ""
			text: root.note
			horizontalAlignment: Text.AlignHCenter
			elide: Text.ElideRight
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
		}
	}

	// the check in the corner
	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 7
		width: 18
		height: 18
		radius: 9
		color: Theme.primary
		scale: root.selected ? 1 : 0
		visible: scale > 0.01

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Glyph {
			anchors.centerIn: parent
			icon: "check_bold"
			size: 11
			color: Theme.onPrimary
		}
	}
}
