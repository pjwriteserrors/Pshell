import QtQuick
import qs.style.theme

// A cursor of the Pshell theme drawn by the shell, its hotspot at (0, 0):
// put it where the pointer is and hide the real one (Qt.BlankCursor). The
// base is a still of the theme ("arrow", "hand", "cross" or "" for none);
// children – a CursorBadge, a CursorRing – go on top, measured from the
// hotspot too.
Item {
	id: root

	property string shape: "arrow"
	default property alias content: extras.data

	width: 0
	height: 0

	Image {
		visible: root.shape !== "" && CursorStyle.ready
		source: root.shape !== "" ? CursorStyle.still(root.shape) : ""
		x: -CursorStyle.hotspot(root.shape).x
		y: -CursorStyle.hotspot(root.shape).y
		width: CursorStyle.canvas
		height: CursorStyle.canvas
		smooth: true
		mipmap: true
		cache: false
	}

	Item {
		id: extras
	}
}
