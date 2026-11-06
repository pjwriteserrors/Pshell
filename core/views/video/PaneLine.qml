import QtQuick
import qs.style.theme
import qs.style.widgets

// A setting in a pane: what it is, a word about it, its control on the right.
Item {
	id: line

	property string label: ""
	property string detail: ""
	default property alias control: holder.data

	width: parent?.width ?? 300
	implicitHeight: Math.max(words.implicitHeight, holder.childrenRect.height)

	Column {
		id: words

		anchors.left: parent.left
		anchors.right: holder.left
		anchors.rightMargin: 12
		anchors.verticalCenter: parent.verticalCenter
		spacing: 2

		StyledText {
			width: parent.width
			text: line.label
			wrapMode: Text.WordWrap
			font.weight: Font.DemiBold
		}

		StyledText {
			width: parent.width
			visible: line.detail !== ""
			text: line.detail
			wrapMode: Text.WordWrap
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	Item {
		id: holder

		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		width: childrenRect.width
		height: childrenRect.height
	}
}
