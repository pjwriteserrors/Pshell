pragma ComponentBehavior: Bound

import QtQuick

// A heading. A rune, the name in small capitals, a ley line out to the edge,
// and whatever count belongs at the end of it. Nothing is boxed and nothing is
// underlined; the ley is what says the heading owns what follows.
Column {
	id: section

	property string title: ""
	property string trailing: ""
	property color tendonColor: Arc.goldFaint

	spacing: Arc.s3

	Item {
		width: parent.width
		height: Math.max(heading.implicitHeight, 14)
		visible: section.title !== ""

		ArcRune {
			id: sigil
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			width: 9
			height: 13
			seed: 5
			weight: Arc.ruleThin
			lineColor: Arc.aether
		}

		ArcText {
			id: heading
			anchors.left: sigil.right
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
