pragma ComponentBehavior: Bound

import QtQuick

// A named block inside a panel: the name engraved on the left, a tendon running
// out from it to the edge, and whatever the section holds underneath. The
// tendon is what tells you the heading belongs to what follows it.
Column {
	id: section

	property string title: ""
	property string trailing: ""
	property color tendonColor: Bio.boneFaint

	spacing: Bio.s3

	Item {
		width: parent.width
		height: Math.max(heading.implicitHeight, 12)
		visible: section.title !== ""

		BioText {
			id: heading
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			role: "label"
			tone: "muted"
			text: section.title
		}

		BioTendon {
			anchors.left: heading.right
			anchors.right: trailingLabel.visible ? trailingLabel.left : parent.right
			anchors.leftMargin: Bio.s3
			anchors.rightMargin: Bio.s3
			anchors.verticalCenter: parent.verticalCenter
			height: 10
			lineColor: section.tendonColor
			facing: Qt.LeftToRight
			visible: width > 24
		}

		BioText {
			id: trailingLabel
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			role: "caption"
			tone: "faint"
			text: section.trailing
			visible: section.trailing !== ""
		}
	}
}
