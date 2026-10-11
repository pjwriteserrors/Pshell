import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// An entry of the sidebar: a place, a tag, a collection, a drive. The one
// the pane shows is lit; files dropped on it go there (or get the tag, or
// join the collection).
Clickable {
	id: root

	property string icon: ""
	property color iconColor: Theme.textMuted
	property string label: ""
	property string detail: ""
	property bool active: false
	// a drive's fill, 0…1; -1 for none
	property real fill: -1
	property bool dropEnabled: false
	property bool busy: false
	property string trailing: ""
	signal dropped(var drop)
	signal trailingClicked
	signal menu(real x, real y)

	readonly property bool dropping: drop.containsDrag

	implicitHeight: 34
	radius: Theme.radius.medium
	acceptedButtons: Qt.LeftButton | Qt.RightButton
	pressedScale: 0.97
	color: root.dropping ? Theme.primarySoft : (root.active ? Qt.tint(Theme.layer1, Qt.alpha(Theme.primary, 0.16)) : Qt.alpha(Theme.layer1, 0))
	scale: root.dropping ? 1.03 : (root.pressed ? root.pressedScale : 1)
	onRightClicked: mouse => root.menu(mouse.x, mouse.y)

	// the lit one has a bar at its side
	Rectangle {
		x: 0
		anchors.verticalCenter: parent.verticalCenter
		width: 3
		height: root.active ? 16 : 0
		radius: 2
		color: Theme.primary

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	Glyph {
		id: glyph

		x: 12
		anchors.verticalCenter: parent.verticalCenter
		icon: root.icon
		size: 17
		color: root.active || root.dropping ? Theme.primary : root.iconColor
		animated: false
	}

	Text {
		anchors.left: parent.left
		anchors.leftMargin: 38
		anchors.right: tail.left
		anchors.rightMargin: 6
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: root.fill >= 0 ? -4 : 0
		text: root.label
		color: root.active ? Theme.text : Qt.alpha(Theme.text, 0.86)
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.body
		font.weight: root.active ? Font.DemiBold : Font.Normal
		elide: Text.ElideRight
	}

	Rectangle {
		visible: root.fill >= 0
		anchors.left: parent.left
		anchors.leftMargin: 38
		anchors.right: tail.left
		anchors.rightMargin: 6
		anchors.verticalCenter: parent.verticalCenter
		anchors.verticalCenterOffset: 9
		height: 3
		radius: 2
		color: Theme.layer3

		Rectangle {
			width: parent.width * Math.max(0, root.fill)
			height: parent.height
			radius: 2
			color: root.fill > 0.9 ? Theme.danger : (root.fill > 0.75 ? Theme.warning : Qt.alpha(Theme.primary, 0.8))
		}
	}

	Item {
		id: tail

		anchors.right: parent.right
		anchors.rightMargin: 6
		anchors.verticalCenter: parent.verticalCenter
		width: root.trailing !== "" ? 26 : (count.text !== "" ? count.implicitWidth + 6 : (root.busy ? 16 : 0))
		height: 26

		Text {
			id: count

			visible: root.trailing === "" && !root.busy
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: root.detail
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.small
		}

		Spinner {
			visible: root.busy
			anchors.centerIn: parent
			width: 13
			height: 13
		}

		IconButton {
			visible: root.trailing !== "" && !root.busy
			anchors.fill: parent
			icon: root.trailing
			iconSize: 14
			opacity: root.hovered ? 1 : 0.55
			onClicked: root.trailingClicked()
		}
	}

	DropArea {
		id: drop

		anchors.fill: parent
		enabled: root.dropEnabled
		onDropped: event => {
			event.acceptProposedAction();
			root.dropped(event);
		}
	}
}
