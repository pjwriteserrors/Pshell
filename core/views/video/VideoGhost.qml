pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A video opened from a spot of the screen (its card in Files, Quick Look's
// picture as it stood) grows from there to the middle, where the window
// comes up below it, and fades into it. Its picture is the one the spot
// showed (origin.image), else a dark frame. Over everything, takes no
// input; there only while it flies.
PanelWindow {
	id: root

	readonly property var origin: Video.origin
	screen: Popups.screenByName(root.origin?.screen) ?? Popups.focusedScreen()

	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	color: "transparent"
	WlrLayershell.namespace: "shell-video-ghost"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	// where the film will sit: the window takes the film's shape on 72 % of
	// the screen's width, at most 78 % of its height (VideoWindow.size), in the
	// middle. Before the file is read the spot's own shape stands in.
	readonly property real aspect: {
		const shape = Video.meta ? Video.aspect : (root.origin?.w ?? 16) / Math.max(1, root.origin?.h ?? 9);
		return Math.max(0.5, Math.min(2.6, shape));
	}
	readonly property rect target: {
		let w = root.width * 0.72, h = w / root.aspect;
		if (h > root.height * 0.78) {
			h = root.height * 0.78;
			w = h * root.aspect;
		}
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
			duration: 120
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
			script: Video.origin = null
		}
	}

	Rectangle {
		readonly property var o: root.origin ?? ({ x: root.width / 2, y: root.height / 2, w: 1, h: 1 })
		readonly property real t: root.t

		x: o.x + (root.target.x - o.x) * t
		y: o.y + (root.target.y - o.y) * t
		width: o.w + (root.target.width - o.w) * t
		height: o.h + (root.target.height - o.h) * t
		// the card's corners square off on the way, as the window has none
		radius: Theme.radius.medium * (1 - t)
		color: "black"
		clip: true
		opacity: root.fade * Math.min(1, root.t * 4 + 0.6)

		Image {
			anchors.fill: parent
			source: root.origin?.image ?? ""
			sourceSize: Qt.size(1024, 1024)
			fillMode: Image.PreserveAspectCrop
			asynchronous: false
			smooth: true
		}
	}
}
