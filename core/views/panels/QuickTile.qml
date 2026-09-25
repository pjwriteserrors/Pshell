import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// Quick settings tile. The body toggles, the chevron opens details.
// Active tiles fill with the accent and square their corners slightly.
Clickable {
	id: root

	property string icon: ""
	property string title: ""
	property string subtitle: ""
	property bool active: false
	property bool hasDetails: true
	signal detailsRequested

	readonly property color fg: Theme.text

	implicitHeight: 64
	radius: root.active ? Theme.radius.large : 32
	color: root.active ? Theme.primaryContainer : Theme.layer1
	tint: root.fg
	pressedScale: 0.96

	Behavior on radius {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 12
		anchors.rightMargin: root.hasDetails ? 4 : 14
		spacing: 10

		Rectangle {
			Layout.preferredWidth: 40
			Layout.preferredHeight: 40
			radius: 20
			color: root.active ? Theme.primary : Theme.layer3

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.icon
				size: 20
				color: root.active ? Theme.onPrimary : Theme.text
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: root.title
				tone: root.fg
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: root.subtitle
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		IconButton {
			visible: root.hasDetails
			Layout.preferredWidth: 30
			Layout.preferredHeight: 44
			radius: 15
			icon: "chevron_right"
			iconSize: 18
			iconColor: root.fg
			tint: root.fg
			onClicked: root.detailsRequested()
		}
	}
}
