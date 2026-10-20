import QtQuick
import qs.style.theme
import qs.style.widgets

// The handle an entry of a DragList is carried by.
Item {
	id: root

	// the entry's dragSource
	property Item source: null
	property bool horizontal: false

	implicitWidth: 22
	implicitHeight: 32

	Glyph {
		anchors.centerIn: parent
		icon: root.horizontal ? "drag_horizontal_variant" : "drag_vertical"
		size: 18
		color: mouse.pressed ? Theme.primary : (mouse.containsMouse ? Theme.text : Theme.textSubtle)
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		anchors.margins: -4
		hoverEnabled: true
		preventStealing: true
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
		drag.target: root.source
		drag.axis: root.horizontal ? Drag.XAxis : Drag.YAxis
		onPressed: if (root.source) root.source.held = true
		onReleased: if (root.source) root.source.finish()
		onCanceled: if (root.source) root.source.finish()
	}
}
