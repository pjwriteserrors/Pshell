pragma ComponentBehavior: Bound

import QtQuick

// A rubric: the heading a scribe put in the margin in red before writing the
// block it belongs to. The name is cut, a flourish carries the eye from it to
// the edge of the page, and whatever the section holds follows underneath.
Column {
	id: section

	property string title: ""
	property string trailing: ""
	property color tendonColor: Arc.giltFaint

	spacing: Arc.s3

	Item {
		width: parent.width
		height: Math.max(heading.implicitHeight, 13)
		visible: section.title !== ""

		// The rubric mark: the paragraph sign a scribe struck before a heading.
		Rectangle {
			id: pilcrow
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			width: 4
			height: 4
			rotation: 45
			color: Arc.aether
			opacity: 0.85
		}

		ArcText {
			id: heading
			anchors.left: pilcrow.right
			anchors.leftMargin: Arc.s2
			anchors.verticalCenter: parent.verticalCenter
			role: "label"
			tone: "muted"
			text: section.title
		}

		ArcFlourish {
			anchors.left: heading.right
			anchors.right: trailingLabel.visible ? trailingLabel.left : parent.right
			anchors.leftMargin: Arc.s3
			anchors.rightMargin: Arc.s3
			anchors.verticalCenter: parent.verticalCenter
			height: 10
			lineColor: section.tendonColor
			facing: Qt.LeftToRight
			visible: width > 30
		}

		ArcText {
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
