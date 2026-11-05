pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A panel that grows out of the bar underneath the button that opened it.
//
// How it opens is the user's (PopupMotion, Desktop page): classic extrudes
// downward while the neck widens, the others come out
// of the button, wobble, unroll, settle out of a blur or spring. All of them
// are one progress value (`reveal`) turned into the panel's size and its
// content's way in by PopupMotion.shape().
// Close: the shape retracts back into the bar quickly, content leaves first.
// Size changes (switching pages, lists growing) morph the silhouette.
PanelWindow {
	id: root

	required property string panelId
	property real panelWidth: 400
	property real contentHeight: 300
	property real padding: Theme.panelPadding
	property bool keyboard: true
	property bool centered: false
	readonly property real maxBodyHeight: Math.max(160, (root.screen?.height ?? 1080) - Theme.barHeight - 48)
	readonly property real targetHeight: Math.min(root.maxBodyHeight, root.contentHeight + root.padding * 2)
	readonly property real innerHeight: root.targetHeight - root.padding * 2
	readonly property real innerWidth: root.panelWidth - root.padding * 2

	default property alias content: holder.data
	// A second panel that grows out of this one's bottom edge (e.g. details of
	// a selection), with the same silhouette and motion. Its right edge sits
	// `belowInset` inside the panel's, far enough for both fillets.
	property alias below: belowHolder.data
	property bool belowOpen: false
	property real belowWidth: 360
	property real belowContentHeight: 200
	property real belowInset: Theme.panelRadius + Theme.panelFillet + 8
	readonly property real belowTargetHeight: Math.min(Math.max(0, root.height - root.targetHeight - 24), root.belowContentHeight + root.padding * 2)
	readonly property bool belowShown: root.shown && root.belowOpen
	property real belowReveal: 0
	// which way the panel below goes: set before belowReveal changes, so its
	// Behavior takes the right duration and curve
	property bool belowEntering: false
	function followBelow() {
		root.belowEntering = root.belowShown;
		root.belowReveal = root.belowShown ? 1 : 0;
	}
	onBelowShownChanged: root.followBelow()
	readonly property bool shown: Popups.current === root.panelId
	property var targetScreen: Popups.primaryScreen
	property real reveal: 0

	signal panelOpened
	signal panelClosed
	// the way in is done: the time for refreshes, external commands and
	// anything else that rebuilds content. Started in panelOpened they ran
	// in the middle of the animation and cost it every other frame.
	signal panelSettled
	property bool settling: false
	function settle() {
		if (!root.settling || root.reveal < 1) return;
		root.settling = false;
		root.panelSettled();
	}
	onRevealChanged: root.settle()

	// the panel is built when it opens (Popups.wanted): then it grows out
	// of the bar just the same. `shown` already changes while it is being
	// built, before the Behavior on reveal is live, so that is left to
	// onCompleted
	property bool built: false
	// Visible only a moment after it was built: on a reload Quickshell takes
	// over the old window of an instance that is visible from the start, and
	// moving that one to another screen (the new instance starts on the
	// primary one) crashes it in QWindow::setScreen. So the old one goes and
	// a new one is made.
	property bool alive: false
	onShownChanged: if (root.built) root.followShown()
	Component.onCompleted: {
		root.built = true;
		Qt.callLater(() => root.alive = true);
		if (root.shown) root.followShown();
		if (root.belowShown) root.followBelow();
	}

	function followShown() {
		// before reveal changes: a binding on `shown` could still hold the
		// other direction when the Behavior reads it, and closing ran with
		// the opening's duration and curve
		root.motion = root.shown ? PopupMotion.opening(PopupMotion.style) : PopupMotion.closing(PopupMotion.style);
		if (root.shown) {
			root.targetScreen = Popups.screen || Popups.primaryScreen;
			root.panelOpened();
			Qt.callLater(() => scope.forceActiveFocus());
		} else {
			root.panelClosed();
		}
		root.settling = root.shown;
		if (!root.shown || root.placed) root.reveal = root.shown ? 1 : 0;
		// opened again while it was still all there: nothing left to wait for
		root.settle();
	}

	// Closed, the window stays: a strip of one pixel that lets every click
	// through. Hidden it would be destroyed, and the next opening built a new
	// one with its whole scene, a first frame 50–140 ms late that swallowed
	// the first third of the way in.
	readonly property bool expanded: root.shown || root.reveal > 0.002
	readonly property Region passThrough: Region {}

	// the window has the screen's size only once the compositor answered;
	// until then the panel would start its way in at the left edge
	readonly property bool placed: Math.abs(root.width - (root.screen?.width ?? root.width)) < 2 && root.height > 1
	onPlacedChanged: if (root.built && root.shown && root.placed) root.reveal = 1

	property var motion: PopupMotion.opening(PopupMotion.style)

	Behavior on reveal {
		NumberAnimation {
			duration: root.motion.duration
			easing.type: root.motion.type
			easing.bezierCurve: root.motion.curve
			easing.amplitude: root.motion.amplitude ?? 1
			easing.period: root.motion.period ?? 0.3
			easing.overshoot: root.motion.overshoot ?? 1.70158
		}
	}

	Behavior on belowReveal {
		NumberAnimation {
			duration: root.belowEntering ? Motion.long : Motion.medium - 60
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.belowEntering ? Motion.spatial : Motion.accel
		}
	}

	screen: root.targetScreen
	visible: root.alive
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: root.expanded
	}
	implicitHeight: 1
	mask: root.expanded ? null : root.passThrough
	margins.top: Theme.barHeight
	exclusiveZone: 0
	WlrLayershell.namespace: `shell-${root.panelId}`
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.shown && root.keyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	MouseArea {
		anchors.fill: parent
		enabled: root.shown
		onPressed: Popups.close()
	}

	readonly property real anchorX: root.centered ? root.width / 2 : Popups.anchorFor(root.targetScreen, root.panelId)
	property real animatedHeight: root.targetHeight
	// the panel at this point of its way in or out
	readonly property var form: PopupMotion.shape(PopupMotion.style, root.reveal, root.panelWidth, root.animatedHeight, 44, root.shown)
	readonly property real bodyWidth: root.form.w

	Behavior on animatedHeight {
		enabled: root.reveal > 0.98
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RectangularShadow {
		anchors.fill: body
		anchors.topMargin: Math.min(body.height, 90)
		radius: Theme.panelRadius
		blur: 34
		spread: -4
		offset.y: 10
		color: Theme.shadow
		opacity: Math.min(1, root.reveal) * root.form.opacity
		scale: body.scale
		transformOrigin: Item.Top
	}

	Item {
		id: body

		readonly property real edge: 10
		x: Math.round(Math.max(Theme.panelFillet + body.edge, Math.min(root.width - width - Theme.panelFillet - body.edge, root.anchorX - width / 2)))
		y: 0
		width: root.bodyWidth
		height: Math.max(0, root.form.h)
		scale: root.form.scale
		opacity: root.form.opacity
		transformOrigin: Item.Top

		// when another button re-targets an open panel, it glides over; not
		// while the new window is still taking the screen's width
		Behavior on x {
			enabled: root.shown && root.reveal > 0.98 && root.placed
			SpatialAnim {
				duration: Motion.long
			}
		}

		PanelShape {
			anchors.fill: parent
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			onWheel: wheel => wheel.accepted = true
		}

		Item {
			id: inside

			// blurred or behind a curtain only while it comes in
			readonly property bool effected: root.form.blur > 0.01 || root.form.wipe < 0.999

			anchors.fill: parent
			clip: true
			layer.enabled: inside.effected
			layer.effect: MultiEffect {
				blurEnabled: root.form.blur > 0.01
				blur: root.form.blur
				blurMax: 32
				maskEnabled: root.form.wipe < 0.999
				maskSource: curtain
				// the curtain's edge: soft, a third of the panel high
				maskThresholdMin: 1 - root.form.wipe * 1.35
				maskSpreadAtMin: 0.35
			}

			FocusScope {
				id: scope

				x: (parent.width - root.innerWidth) / 2
				y: root.padding + root.form.y
				width: root.innerWidth
				height: root.innerHeight
				opacity: root.form.co
				scale: root.form.cs
				transformOrigin: Item.Top
				focus: true

				Keys.onEscapePressed: Popups.close()

				Item {
					id: holder

					anchors.fill: parent
				}
			}
		}

		// the curtain's mask: solid at the top, gone at the bottom
		Rectangle {
			id: curtain

			anchors.fill: parent
			visible: false
			layer.enabled: inside.effected && root.form.wipe < 0.999
			gradient: Gradient {
				GradientStop {
					position: 0
					color: "white"
				}
				GradientStop {
					position: 1
					color: "transparent"
				}
			}
		}

		// glass: a light sweeping across once as it settles
		Item {
			anchors.fill: parent
			clip: true
			visible: root.form.sheen >= 0

			Rectangle {
				readonly property real band: Math.max(120, parent.width * 0.35)

				x: -band * 2 + (parent.width + band * 3) * Math.max(0, root.form.sheen)
				y: -parent.height * 0.25
				width: band
				height: parent.height * 1.5
				rotation: 18
				opacity: 0.16 * Math.sin(Math.PI * Math.max(0, root.form.sheen))
				gradient: Gradient {
					orientation: Gradient.Horizontal

					GradientStop {
						position: 0
						color: "transparent"
					}
					GradientStop {
						position: 0.5
						color: "white"
					}
					GradientStop {
						position: 1
						color: "transparent"
					}
				}
			}
		}
	}

	property real belowAnimatedHeight: root.belowTargetHeight

	Behavior on belowAnimatedHeight {
		enabled: root.belowReveal > 0.98
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RectangularShadow {
		anchors.fill: belowBody
		anchors.topMargin: Math.min(belowBody.height, 60)
		radius: Theme.panelRadius
		blur: 34
		spread: -4
		offset.y: 10
		color: Theme.shadow
		opacity: Math.min(1, root.belowReveal)
		visible: belowBody.visible
	}

	Item {
		id: belowBody

		// the centre stays put while the neck widens
		readonly property real centre: body.x + body.width - root.belowInset - root.belowWidth / 2
		x: Math.round(belowBody.centre - width / 2)
		y: body.height
		width: root.belowWidth * (0.62 + 0.38 * Math.min(1.04, root.belowReveal))
		height: Math.max(0, root.belowAnimatedHeight * root.belowReveal)
		visible: height > 0.5

		PanelShape {
			anchors.fill: parent
			topOpacity: 0.96
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			onWheel: wheel => wheel.accepted = true
		}

		Item {
			anchors.fill: parent
			clip: true

			Item {
				id: belowHolder

				x: (parent.width - width) / 2
				y: root.padding - 14 * (1 - Math.min(1, root.belowReveal))
				width: root.belowWidth - root.padding * 2
				height: root.belowTargetHeight - root.padding * 2
				opacity: Math.max(0, Math.min(1, (root.belowReveal - 0.35) / 0.65))
			}
		}
	}
}
