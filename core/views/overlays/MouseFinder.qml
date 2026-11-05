pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The grown pointer of FindMouse on one screen: the cursor theme's own
// arrow, as big as the shake has made it, shrinking back into the real one
// as soon as the shaking stops. The screen takes the pointer for as long as
// that, to learn where it is; a click ends it at once.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	// the pointer is on this screen
	readonly property bool here: FindMouse.output === root.name
	property real size: FindMouse.active && FindMouse.output !== "" ? FindMouse.size : 1
	// held until the arrow has shrunk back, or the real one would show beside it
	readonly property bool catching: FindMouse.active || root.size > 1.02

	Behavior on size {
		NumberAnimation {
			duration: FindMouse.active ? Motion.medium : Motion.short
			easing.type: Easing.BezierSpline
			easing.bezierCurve: FindMouse.active ? Motion.decel : Motion.standard
		}
	}

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	visible: root.catching
	WlrLayershell.namespace: "shell-find-mouse"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	mask: Region {
		regions: root.catching ? [everywhere] : []
	}

	Region {
		id: everywhere

		item: catcher
	}

	MouseArea {
		id: catcher

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.AllButtons
		cursorShape: grown.visible ? Qt.BlankCursor : Qt.ArrowCursor
		onPositionChanged: mouse => FindMouse.at(root.name, mouse.x, mouse.y)
		onEntered: FindMouse.at(root.name, catcher.mouseX, catcher.mouseY)
		onPressed: FindMouse.hide()
		onWheel: FindMouse.hide()
	}

	// drawn from the large still, so it stays sharp when grown
	Item {
		id: grown

		visible: root.here && CursorStyle.ready
		x: FindMouse.x
		y: FindMouse.y
		scale: root.size
		transformOrigin: Item.TopLeft

		Image {
			source: CursorStyle.large("arrow")
			x: -CursorStyle.hotspot("arrow").x
			y: -CursorStyle.hotspot("arrow").y
			width: CursorStyle.canvas
			height: CursorStyle.canvas
			smooth: true
			mipmap: true
			cache: false
		}
	}
}
