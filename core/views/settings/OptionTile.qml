import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One of a few choices, shown as what it does: a small scene on top (the
// default children), its name below. The picked one is outlined and its
// scene plays.
Clickable {
	id: root

	property string title: ""
	property string subtitle: ""
	property bool selected: false
	default property alias scene: stage.data
	readonly property bool playing: root.selected || root.hovered

	Layout.fillWidth: true
	implicitWidth: 180
	implicitHeight: stage.height + labels.implicitHeight + 30
	radius: Theme.radius.large
	pressedScale: 0.96
	color: root.selected ? Theme.primaryContainer : (root.hovered ? Theme.layer3 : Theme.layer2)
	border.width: root.selected ? 1.5 : 0
	border.color: Theme.primary

	Item {
		id: stage

		x: 12
		y: 12
		width: parent.width - 24
		height: 76
		clip: true
	}

	ColumnLayout {
		id: labels

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: stage.bottom
		anchors.margins: 12
		anchors.topMargin: 10
		spacing: 1

		StyledText {
			Layout.fillWidth: true
			text: root.title
			tone: root.selected ? Theme.primary : Theme.text
			font.weight: Font.DemiBold
			horizontalAlignment: Text.AlignHCenter
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.subtitle !== ""
			text: root.subtitle
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.WordWrap
		}
	}
}
