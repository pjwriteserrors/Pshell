pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A PDF opened from a spot of the screen (its tile in Files, Quick Look's
// page as it stood) grows from there to where its first page will sit in the
// window that comes up below it, and fades into it. Its picture is the one
// the spot showed (origin.image), else a white sheet. Over everything, takes
// no input; there only while it flies.
PanelWindow {
	id: root

	readonly property var origin: Pdf.origin
	screen: Popups.screenByName(root.origin?.screen) ?? Popups.focusedScreen()

	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	color: "transparent"
	WlrLayershell.namespace: "shell-pdf-ghost"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	// the window's place (PdfWindow.size, in the middle), and in it the page fitted to the width under the bar
	readonly property real aspect: {
		const s = Pdf.sizes?.a?.[0];
		const shape = s ? s[1] / Math.max(1, s[0]) : (root.origin?.h ?? 297) / Math.max(1, root.origin?.w ?? 210);
		return Math.max(0.3, Math.min(3, shape));
	}
	readonly property rect target: {
		const wh = Math.round(root.height * 0.86);
		const ww = Math.round(Math.min(root.width * 0.8, Math.max(900, wh * 0.92)));
		const wx = (root.width - ww) / 2, wy = (root.height - wh) / 2;
		const top = 60 + 16;
		let w = ww - 56, h = w * root.aspect;
		if (Pdf.fit === "page" || h > wh - top) {
			h = Math.min(h, wh - top - 16);
			w = h / root.aspect;
		}
		return Qt.rect(wx + (ww - w) / 2, wy + top, w, h);
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
			duration: Motion.long + 80
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
		PauseAnimation {
			duration: 140
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
			script: Pdf.origin = null
		}
	}

	Rectangle {
		readonly property var o: root.origin ?? ({ x: root.width / 2, y: root.height / 2, w: 1, h: 1 })
		readonly property real t: root.t

		x: o.x + (root.target.x - o.x) * t
		y: o.y + (root.target.y - o.y) * t
		width: o.w + (root.target.width - o.w) * t
		height: o.h + (root.target.height - o.h) * t
		radius: Theme.radius.small * (1 - t) + 3
		color: "white"
		clip: true
		opacity: root.fade * Math.min(1, root.t * 4 + 0.6)

		Image {
			anchors.fill: parent
			source: root.origin?.image ?? ""
			sourceSize: Qt.size(1024, 1024)
			fillMode: Image.PreserveAspectCrop
			verticalAlignment: Image.AlignTop
			asynchronous: false
			smooth: true
		}
	}
}
