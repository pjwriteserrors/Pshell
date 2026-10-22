pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What a chat is drawn on (Messages.backdrop): nothing, the palette as slow
// light, contour lines or dots, the desktop's wallpaper or a picture of one's
// own – blurred, dimmed towards the shell's background and tinted with its
// accent as far as was asked. With motion it drifts, and moves a little
// against the chat as that is scrolled.
Item {
	id: root

	// how far down the chat is, 0 … 1
	property real scroll: 1
	// on the screen: nothing moves behind a panel that is closed
	property bool live: true
	// another look than the one that is kept, for the tiles of the picker
	property var look: Messages.backdrop
	// a tile: small, still and as it is
	property bool sample: false

	readonly property string kind: String(root.look.kind ?? "none")
	readonly property int pattern: ["aurora", "waves", "dots"].indexOf(root.kind)
	readonly property string framePath: `${Paths.home}/.local/state/quickshell-theme/current/frame.png`
	readonly property string picture: root.kind === "wallpaper" ? root.framePath : (root.kind === "image" ? String(root.look.image ?? "") : "")
	readonly property bool moving: !root.sample && root.live && (root.look.motion ?? true)
	// the picture is larger than the chat by this much, which is how far it travels
	readonly property real travel: root.sample ? 0 : Math.round(root.height * 0.08)
	readonly property real blur: root.sample ? 0 : Math.max(0, Math.min(1, Number(root.look.blur ?? 0)))
	readonly property real dim: root.kind === "none" ? 0 : Math.max(0, Math.min(1, Number(root.look.dim ?? 0)))
	readonly property real tint: Math.max(0, Math.min(1, Number(root.look.tint ?? 0)))
	// there is nothing to draw: the picture is missing
	readonly property bool missing: root.picture !== "" && image.status === Image.Error

	// follows the chat a moment late, so a jump in it is a glide here
	property real eased: root.moving ? root.scroll : 1

	Behavior on eased {
		enabled: root.moving
		SmoothedAnimation {
			velocity: 1.6
			duration: Motion.extraLong
		}
	}

	// another one comes up out of the background
	onKindChanged: if (!root.sample) arrive.restart()
	onPictureChanged: if (!root.sample) arrive.restart()

	Anim {
		id: arrive

		target: stage
		property: "opacity"
		from: 0
		to: 1
		duration: Motion.long
	}

	// a new wallpaper has the old one's path
	Connections {
		target: Theme
		enabled: root.kind === "wallpaper"
		function onBgChanged() {
			const path = image.source;
			image.source = "";
			image.source = path;
		}
	}

	Item {
		id: stage

		anchors.fill: parent

		Loader {
			anchors.fill: parent
			active: root.pattern >= 0
			sourceComponent: ShaderEffect {
				id: drawn

				property real time: 40
				readonly property real kind: root.pattern
				readonly property real shift: (1 - root.eased) * -0.08
				readonly property vector2d res: Qt.vector2d(drawn.width, drawn.height)
				readonly property color base: Theme.bg
				readonly property color first: Theme.primary
				readonly property color second: Theme.secondary
				readonly property color third: Theme.tertiary

				fragmentShader: `file://${Paths.assets}/shaders/backdrop.frag.qsb`

				// half the frames are plenty for something this slow
				Timer {
					interval: 33
					repeat: true
					running: root.moving && drawn.visible
					onTriggered: drawn.time += 0.033
				}
			}
		}

		Image {
			id: image

			x: -Math.round(root.width * 0.03)
			y: -root.travel * root.eased
			width: root.width - 2 * x
			height: root.height + root.travel
			visible: false
			source: root.picture !== "" ? `file://${root.picture}` : ""
			sourceSize.width: root.sample ? 240 : Math.max(640, Math.min(2560, Math.ceil(root.width * 1.2)))
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: root.kind !== "wallpaper"
		}

		MultiEffect {
			anchors.fill: image
			visible: root.picture !== "" && image.status === Image.Ready
			source: image
			autoPaddingEnabled: false
			blurEnabled: root.blur > 0.01
			blur: 1
			blurMax: Math.round(8 + 56 * root.blur)
			colorization: root.tint
			colorizationColor: Theme.primary
		}

		Rectangle {
			anchors.fill: parent
			visible: root.pattern >= 0 && root.tint > 0.01
			color: Qt.alpha(Theme.primary, root.tint * 0.3)
		}

		Rectangle {
			anchors.fill: parent
			color: Qt.alpha(Theme.bg, root.dim)
		}
	}
}
