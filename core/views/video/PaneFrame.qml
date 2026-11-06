pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets

// A pane of the video window (and of the editor): its name, a cross, and
// what it holds scrolling below.
Item {
	id: root

	property string title: ""
	property string subtitle: ""
	property color accent: Theme.primary
	property bool closable: true
	default property alias content: body.data
	readonly property real bodyWidth: body.width
	readonly property alias flick: flick

	signal close

	StyledText {
		id: heading

		x: 18
		y: 16
		width: parent.width - 70
		text: root.title
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	StyledText {
		id: sub

		anchors.left: heading.left
		anchors.top: heading.bottom
		anchors.topMargin: 2
		width: heading.width
		visible: root.subtitle !== ""
		text: root.subtitle
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
	}

	IconButton {
		anchors.right: parent.right
		anchors.rightMargin: 10
		y: 10
		visible: root.closable
		icon: "close"
		onClicked: root.close()
	}

	Flickable {
		id: flick

		anchors.fill: parent
		anchors.topMargin: (root.subtitle !== "" ? sub.y + sub.height : heading.y + heading.height) + 14
		contentHeight: body.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: body

			x: 14
			width: flick.width - 28
			spacing: 14
		}
	}
}
