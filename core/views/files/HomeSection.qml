import QtQuick
import qs.style.theme
import qs.style.widgets

// A section of the home page: a title, maybe a line under it and a link on
// the right, then its content. Sections rise in one after another.
Column {
	id: root

	property int order: 0
	property string title: ""
	property string subtitle: ""
	property string action: ""
	default property alias content: holder.data
	signal actionClicked

	// the home page's step of its entrance, found up the tree
	readonly property int stage: {
		for (let p = root.parent; p; p = p.parent)
			if (p.introStep !== undefined) return p.introStep;
		return 99;
	}
	readonly property bool shown: root.stage >= root.order

	// as wide as the page unless told otherwise (the halves of a row)
	width: parent ? parent.width : implicitWidth
	spacing: 12
	opacity: root.shown ? 1 : 0

	transform: Translate {
		y: root.shown ? 0 : 22

		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
	}

	Behavior on opacity {
		Anim {
			duration: Motion.medium
		}
	}

	Item {
		visible: root.title !== ""
		width: root.width
		height: root.subtitle !== "" ? 40 : 24

		Text {
			id: heading

			text: root.title
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.heading
			font.weight: Font.DemiBold
		}

		Text {
			visible: root.subtitle !== ""
			anchors.top: heading.bottom
			anchors.topMargin: 1
			text: root.subtitle
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.small
		}

		TextButton {
			visible: root.action !== ""
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.topMargin: -4
			height: 28
			variant: "ghost"
			text: root.action
			icon: "arrow_right"
			onClicked: root.actionClicked()
		}
	}

	Item {
		id: holder

		width: childrenRect.width
		height: childrenRect.height
	}
}
