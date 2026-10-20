pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The wallpaper of one screen (Wallpaper), on the background layer. A new
// one fades in over the old while it settles from a slight zoom; until then
// the old one stays. Decoded at the screen's size, nothing more.
PanelWindow {
	id: root

	required property var modelData
	readonly property real longest: Math.ceil(Math.max(root.width, root.height) * (root.devicePixelRatio || 1))
	// the one that shows, and the one coming
	property Image front: one
	property Image back: two

	screen: root.modelData
	color: "black"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-wallpaper"
	WlrLayershell.layer: WlrLayer.Background
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	// clicks go to the desktop beneath (the niri overview, the bar's)
	mask: Region {}

	readonly property string wanted: Wallpaper.image === "" ? "" : `file://${Wallpaper.image}?${Wallpaper.serial}`

	function follow() {
		if (root.wanted === "" || root.wanted === root.front.source.toString()) return;
		root.back.source = root.wanted;
	}

	onWantedChanged: root.follow()
	onLongestChanged: if (root.longest > 0) root.follow()

	function arrived(image) {
		if (image !== root.back || image.status !== Image.Ready || image.source.toString() !== root.wanted) return;
		fade.stop();
		image.z = 1;
		root.front.z = 0;
		fade.target = image;
		zoom.target = image;
		fade.start();
		zoom.start();
	}

	function settled() {
		const old = root.front;
		root.front = root.back;
		root.back = old;
		old.source = "";
		old.opacity = 0;
	}

	component Layer: Image {
		anchors.fill: parent
		sourceSize: Qt.size(root.longest, root.longest)
		fillMode: Image.PreserveAspectCrop
		asynchronous: true
		cache: false
		smooth: true
		opacity: 0
		onStatusChanged: root.arrived(this)
	}

	Layer {
		id: one
	}

	Layer {
		id: two
	}

	NumberAnimation {
		id: fade

		property: "opacity"
		from: 0
		to: 1
		duration: Motion.extraLong * 1.6
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
		onFinished: root.settled()
	}

	NumberAnimation {
		id: zoom

		property: "scale"
		from: 1.04
		to: 1
		duration: Motion.extraLong * 2
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}
}
