pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The wallpaper of one screen (Wallpaper), on the background layer. A new
// one blooms out of the bar (assets/shaders/wallpaper_reveal.frag) or fades
// in, as Wallpaper.transition says; until it has loaded the old one stays.
// Decoded at the screen's size, nothing more.
//
// `backdrop`: the copy niri shows in the overview and between workspaces
// (namespace shell-wallpaper-backdrop, placed there by a layer-rule in
// dotfiles/niri/pshell.kdl), sharp, blurred or dimmed. It changes with a
// plain fade: nobody watches it while it happens.
PanelWindow {
	id: root

	required property var modelData
	property bool backdrop: false
	// a blurred copy loses nothing at a third of the size: less to decode and keep
	readonly property real detail: root.backdrop && Wallpaper.backdrop === "blur" ? 0.35 : 1
	readonly property real longest: Math.ceil(Math.max(root.width, root.height) * (root.devicePixelRatio || 1) * root.detail)
	// the one that shows, and the one coming
	property Image front: one
	property Image back: two
	readonly property string transition: root.backdrop ? "fade" : Wallpaper.transition

	screen: root.modelData
	color: "black"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: root.backdrop ? "shell-wallpaper-backdrop" : "shell-wallpaper"
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
		zoom.stop();
		bloom.stop();
		// the first picture of a session just appears
		if (root.front.status !== Image.Ready || root.transition === "none") {
			root.settled();
			return;
		}
		if (root.transition === "bloom") {
			reveal.from = root.front;
			reveal.to = image;
			reveal.seed = Math.random() * 100;
			reveal.progress = 0;
			reveal.visible = true;
			bloom.start();
			return;
		}
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
		root.front.opacity = 1;
		root.front.scale = 1;
		root.front.z = 1;
		reveal.visible = false;
		old.z = 0;
		old.opacity = 0;
		old.source = "";
	}

	// how much of its texture the cropped picture shows, per axis
	function cropOf(image) {
		const w = image?.implicitWidth ?? 0;
		const h = image?.implicitHeight ?? 0;
		if (w <= 0 || h <= 0 || root.width <= 0 || root.height <= 0) return Qt.vector2d(1, 1);
		const screen = root.width / root.height;
		const picture = w / h;
		return picture > screen ? Qt.vector2d(screen / picture, 1) : Qt.vector2d(1, picture / screen);
	}

	Item {
		id: stage

		anchors.fill: parent
		layer.enabled: root.backdrop && Wallpaper.backdrop !== "sharp"
		layer.effect: MultiEffect {
			autoPaddingEnabled: false
			blurEnabled: Wallpaper.backdrop === "blur"
			blur: 1
			blurMax: 64
			brightness: Wallpaper.backdrop === "dim" ? -0.35 : -0.1
		}

		Layer {
			id: one
		}

		Layer {
			id: two
		}

		ShaderEffect {
			id: reveal

			// always some texture, or the first frame of a bloom is black
			property Image from: one
			property Image to: two
			property real progress: 0
			property real seed: 0
			readonly property real aspect: root.height > 0 ? root.width / root.height : 1
			// out of the middle of the bar
			readonly property point origin: Qt.point(0.5, 0)
			readonly property vector2d fromScale: root.cropOf(reveal.from)
			readonly property vector2d toScale: root.cropOf(reveal.to)
			readonly property color accent: Theme.primary

			anchors.fill: parent
			z: 2
			visible: false
			fragmentShader: `file://${Paths.assets}/shaders/wallpaper_reveal.frag.qsb`
		}
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

	NumberAnimation {
		id: bloom

		target: reveal
		property: "progress"
		from: 0
		to: 1
		duration: Motion.extraLong * 3.6
		onFinished: root.settled()
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
