pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A picture opened from a spot of the screen (a thumbnail of the file
// manager, a notification, a chat) grows from there to the middle, where
// the window comes up below it, and fades into it. Over everything, takes
// no input; there only while it flies.
PanelWindow {
	id: root

	readonly property var origin: Viewer.origin
	screen: Popups.screenByName(root.origin?.screen) ?? Popups.focusedScreen()

	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	color: "transparent"
	WlrLayershell.namespace: "shell-viewer-ghost"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	// where the picture will sit in the window (it floats in the middle at
	// 84 % × 86 % of the screen, the picture fitted with a margin)
	readonly property real aspect: (Viewer.info?.width ?? 0) > 0 ? Viewer.info.width / Viewer.info.height : (root.origin?.w ?? 1) / Math.max(1, root.origin?.h ?? 1)
	readonly property rect target: {
		const ww = root.width * 0.84 - 48, wh = root.height * 0.86 - 48;
		const w = Math.min(ww, wh * root.aspect), h = w / root.aspect;
		return Qt.rect((root.width - w) / 2, (root.height - h) / 2, w, h);
	}
	property real t: 0
	property real fade: 1

	Component.onCompleted: fly.start()

	SequentialAnimation {
		id: fly

		NumberAnimation {
			target: root
			property: "t"
			from: 0
			to: 1
			duration: Motion.long + 60
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
		PauseAnimation {
			duration: 90
		}
		NumberAnimation {
			target: root
			property: "fade"
			to: 0
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.standard
		}
		ScriptAction {
			script: Viewer.origin = null
		}
	}

	Image {
		readonly property var o: root.origin ?? ({ x: root.width / 2, y: root.height / 2, w: 1, h: 1 })
		readonly property real t: root.t

		x: o.x + (root.target.x - o.x) * t
		y: o.y + (root.target.y - o.y) * t
		width: o.w + (root.target.width - o.w) * t
		height: o.h + (root.target.height - o.h) * t
		source: Viewer.path ? "file://" + Viewer.path : ""
		sourceSize: Qt.size(1024, 1024)
		fillMode: Image.PreserveAspectCrop
		asynchronous: false
		autoTransform: true
		smooth: true
		opacity: root.fade * Math.min(1, root.t * 4 + 0.6)
	}
}
