pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The concave fillets of the bar for the lower screen corners, without a
// bar between them. With a thickness (Corners.frame) they sit on a frame
// along the lower edge or all around the screen, where the bar is its upper
// edge. Only drawn here, clicks pass through; FrameSpace keeps the windows
// out of it.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	readonly property int frame: Corners.frame
	readonly property bool all: Corners.all
	readonly property int side: root.all ? root.frame : 0
	// where the frame starts below the upper edge
	readonly property int head: Plugins.on("bar") ? Theme.barHeight : root.frame

	anchors {
		top: root.all
		bottom: true
		left: true
		right: true
	}
	implicitHeight: root.frame + Theme.screenCorner
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-corners"
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	mask: Region {}

	Rectangle {
		y: root.height - root.frame
		width: root.width
		height: root.frame
		color: Theme.glass
	}

	Fillet {
		x: root.side
		y: root.height - root.frame - height
		corner: "bottomLeft"
	}

	Fillet {
		x: root.width - root.side - width
		y: root.height - root.frame - height
		corner: "bottomRight"
	}

	Item {
		anchors.fill: parent
		visible: root.all

		Rectangle {
			visible: !Plugins.on("bar")
			width: root.width
			height: root.frame
			color: Theme.glass
		}

		Rectangle {
			y: root.head
			width: root.frame
			height: root.height - root.frame - root.head
			color: Theme.glass
		}

		Rectangle {
			x: root.width - root.frame
			y: root.head
			width: root.frame
			height: root.height - root.frame - root.head
			color: Theme.glass
		}

		Fillet {
			x: root.side
			y: root.head
			corner: "topLeft"
		}

		Fillet {
			x: root.width - root.side - width
			y: root.head
			corner: "topRight"
		}
	}
}
