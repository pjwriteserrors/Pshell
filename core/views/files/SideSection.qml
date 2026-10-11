import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A titled group of the sidebar that folds away with a click on its title.
Column {
	id: root

	property string title: ""
	property string action: ""
	property bool folded: false
	default property alias content: items.data
	signal actionClicked

	spacing: 2

	Item {
		width: parent.width
		height: 28

		Text {
			x: 12
			anchors.verticalCenter: parent.verticalCenter
			text: root.title.toUpperCase()
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.tiny
			font.weight: Font.Bold
			font.letterSpacing: 0.9
		}

		Glyph {
			anchors.right: plus.visible ? plus.left : parent.right
			anchors.rightMargin: 6
			anchors.verticalCenter: parent.verticalCenter
			icon: "chevron_down"
			size: 14
			color: Theme.textSubtle
			rotation: root.folded ? -90 : 0
			opacity: fold.containsMouse ? 1 : 0.0

			Behavior on rotation {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {}
			}
		}

		MouseArea {
			id: fold

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: root.folded = !root.folded
		}

		IconButton {
			id: plus

			visible: root.action !== ""
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: 24
			height: 24
			iconSize: 14
			icon: root.action
			onClicked: root.actionClicked()
		}
	}

	Item {
		width: parent.width
		height: root.folded ? 0 : items.implicitHeight
		clip: true
		opacity: root.folded ? 0 : 1

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}

		Column {
			id: items

			width: parent.width
			spacing: 1
		}
	}
}
