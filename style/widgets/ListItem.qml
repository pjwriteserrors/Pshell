import QtQuick
import QtQuick.Layouts
import qs.style.theme

// Two-line row with a leading tile and a trailing slot. Hover lifts it onto
// a tinted surface; `selected` keeps it there with an accent edge.
Clickable {
	id: root

	property string icon: ""
	property string title: ""
	property string subtitle: ""
	property bool selected: false
	property color accent: Theme.primary
	property color iconColor: root.selected ? Theme.onPrimary : Theme.text
	property color iconBackground: root.selected ? root.accent : Theme.layer2
	property Component leading: null
	default property alias trailing: trailingRow.data

	implicitHeight: 52
	radius: Theme.radius.medium
	pressedScale: 0.98
	color: root.selected ? Qt.alpha(root.accent, 0.14) : (root.hovered ? Theme.layer1 : "transparent")

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 8
		anchors.rightMargin: 10
		spacing: 12

		Rectangle {
			visible: root.icon !== "" || root.leading !== null
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			radius: root.selected ? Theme.radius.medium : 18
			color: root.iconBackground

			Behavior on radius {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				visible: root.leading === null
				anchors.centerIn: parent
				icon: root.icon
				size: 18
				color: root.iconColor
			}

			Loader {
				anchors.fill: parent
				active: root.leading !== null
				sourceComponent: root.leading
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.title
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.subtitle !== ""
				text: root.subtitle
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		RowLayout {
			id: trailingRow

			spacing: 4
		}
	}
}
