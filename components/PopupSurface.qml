pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// THE STRUCTURAL IDEA, and the file that owns it.
//
// The shell hangs from a brass chain strung across the top of the screen,
// fixed at both corners and sagging to its lowest point in the middle. Every
// panel in the instrument is a scroll hung off that chain, directly under the
// seat that owns it — so where a panel appears tells you what opened it, and
// because the chain sags, no two panels start at the same height.
//
// Nothing in this shell appears. A scroll is *let down*:
//
//   open   the roller slides out of the chain, the cords drop, and the sheet
//          unrolls downward under the weight of the dowel at its foot — the
//          sheet is revealed from the top as the dowel travels, never scaled.
//          It overruns its rest length and swings, and the swing is a real
//          damped oscillator, not an overshoot curve. Contents are written on
//          the sheet band by band behind the dowel, each band arriving a beat
//          after the one above it.
//   close  the roller takes it back up, faster than it came down, and the
//          cords go last.
//
// Built on PanelWindow (a full-screen overlay) so text fields inside receive
// keyboard input. Clicking outside emits dismissRequested().
PanelWindow {
	id: surface

	// wiring
	required property bool open
	required property Item barItem
	// The seat this scroll hangs under. Without one it hangs from the middle
	// of the chain, which is where the horologe is.
	property Item anchorItem: null

	// The name struck into the scroll's head rail. Every scroll has one — it is
	// what tells you which one is down without reading the contents.
	property string title: ""

	// sizing
	property real expandedWidth: 300
	property real contentPreferredHeight: 0
	property real fixedHeight: -1
	property real contentMargins: Arc.s4

	// style
	property color surfaceColor: Arc.wash
	property color borderColor: "transparent"
	property bool wantsKeyboard: true

	default property alias content: contentSlot.data
	readonly property Item contentArea: contentSlot

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	// How far in from the fittings content has to stay.
	readonly property real mountMargin: 10
	readonly property real headRail: 24

	readonly property real shellWidth: Math.round(expandedWidth)
	readonly property real roomHeight: height - Arc.gantryDepth - Arc.dropInset
	readonly property real expandedHeight: Math.round(Math.min(
		roomHeight,
		fixedHeight > 0
			? fixedHeight
			: Math.max(220, contentPreferredHeight + headRail + (contentMargins + mountMargin) * 2)
	))

	// Where on the chain this scroll hangs from, and how far down the chain is
	// at that point. Clamped so a scroll hung off a seat near the screen edge
	// still lands on the screen.
	readonly property real anchorX: {
		if (!surface.anchorItem || !surface.visible) return surface.width / 2;
		const p = surface.anchorItem.mapToItem(null, surface.anchorItem.width / 2, 0);
		return p ? p.x : surface.width / 2;
	}
	readonly property real cradleX: Math.round(Math.max(Arc.s4,
		Math.min(surface.width - surface.shellWidth - Arc.s4, surface.anchorX - surface.shellWidth / 2)))
	readonly property real cradleY: Math.round(
		Arc.chainY(surface.anchorX / Math.max(1, surface.width)) + Arc.seat / 2 + Arc.dropGap)

	// The sheet is written on behind the dowel: nothing surfaces until the
	// roller has let down enough of it to hold a line of text.
	readonly property real contentOpacity: Math.max(0, Math.min(1, (openProgress - 0.34) / 0.42))

	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}

	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.keyboardFocus: visible && wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	Behavior on openProgress {
		NumberAnimation {
			duration: surface.open ? Arc.unroll : Arc.reroll
			easing.type: Easing.Bezier
			easing.bezierCurve: surface.open ? Arc.curveUnroll : Arc.curveReroll
		}
	}

	// The swing. A scroll that has just been let down is a weight on two cords,
	// so it rocks and is damped by the cords rather than by an easing curve.
	// Integrated at 16 ms and stopped dead once it is below a tenth of a degree.
	property real swing: 0
	property real swingVelocity: 0

	onOpenChanged: {
		if (surface.open) {
			surface.swing = 0;
			surface.swingVelocity = 0;
			swingKick.restart();
		} else {
			swingClock.running = false;
			surface.swing = 0;
		}
	}

	Timer {
		id: swingKick
		interval: Math.round(Arc.unroll * 0.62)
		onTriggered: {
			// The kick is the dowel arriving at the end of its travel.
			surface.swingVelocity = 0.30;
			swingClock.running = true;
		}
	}

	Timer {
		id: swingClock
		interval: 16
		repeat: true
		onTriggered: {
			surface.swingVelocity += -surface.swing * 0.16;
			surface.swingVelocity *= 0.90;
			surface.swing += surface.swingVelocity;
			if (Math.abs(surface.swing) < 0.01 && Math.abs(surface.swingVelocity) < 0.01) {
				surface.swing = 0;
				swingClock.running = false;
			}
		}
	}

	// Clicking off a scroll rolls it up — but not while it is still coming
	// down. A scroll is let down under the pointer that pulled it, and a press
	// still travelling when the window maps would otherwise land here.
	MouseArea {
		anchors.fill: parent
		enabled: surface.openProgress > 0.75
		onClicked: surface.dismissRequested()
	}

	Item {
		id: rig

		x: surface.cradleX
		y: surface.cradleY
		width: surface.shellWidth
		height: surface.expandedHeight

		Behavior on x {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveDetent }
		}
		Behavior on height {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveUnroll }
		}

		// Everything below the roller hangs off it, so the swing pivots where
		// the cords meet the chain and not in the middle of the sheet.
		transform: Rotation {
			origin.x: rig.width / 2
			origin.y: -Arc.dropGap
			angle: surface.swing
		}

		// Escape rolls every scroll up. The handler sits on the rig, an
		// ancestor of the content, so an unhandled key from a focused field
		// inside travels up to here.
		focus: true

		Keys.onEscapePressed: event => {
			event.accepted = true;
			surface.dismissRequested();
		}

		// The cords: the two lines the scroll hangs on, dropped from the chain
		// before anything else moves.
		Repeater {
			model: 2
			delegate: Rectangle {
				required property int index
				x: index === 0 ? Arc.s4 : rig.width - Arc.s4
				y: -Arc.dropGap
				width: Arc.ruleThin
				height: Arc.dropGap * Math.min(1, surface.openProgress * 5)
				color: Arc.giltDim
			}
		}

		// The roller: the brass rod the sheet is wound on. It comes out of the
		// chain sideways, which is the first thing that happens.
		Rectangle {
			id: roller
			anchors.horizontalCenter: parent.horizontalCenter
			y: 0
			width: rig.width * Math.min(1, surface.openProgress * 4.5)
			height: 4
			color: Arc.gilt

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				anchors.left: parent.left
				anchors.leftMargin: -2
				width: 5
				height: 8
				color: Arc.giltDim
			}

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				anchors.right: parent.right
				anchors.rightMargin: -2
				width: 5
				height: 8
				color: Arc.giltDim
			}
		}

		// The let-down sheet. Clipped, so what you see is the sheet being
		// revealed from the top as the dowel travels — not a rectangle being
		// scaled into existence.
		Item {
			id: window
			anchors.top: roller.bottom
			anchors.left: parent.left
			anchors.right: parent.right
			height: Math.max(0, (rig.height - roller.height) * surface.openProgress)
			clip: true

			ArcLeaf {
				id: sheet
				y: 0
				width: window.width
				height: rig.height - roller.height
				variant: "chamber"
				crest: true
				lineColor: surface.borderColor.a > 0.01 ? surface.borderColor : Arc.giltDim
				liveColor: Arc.aether
				washTop: surface.surfaceColor
				washBottom: Arc.washDeep
				haloStrength: 0.22 * surface.openProgress
				padding: 0

				// The name, struck into the head rail across the top of the
				// sheet. This is why a scroll standing half empty still looks
				// like a made object.
				ArcText {
					id: nameText
					anchors.left: parent.left
					anchors.top: parent.top
					anchors.leftMargin: surface.mountMargin + Arc.s4
					anchors.topMargin: surface.mountMargin - 1
					role: "label"
					tone: "aether"
					text: surface.title
					opacity: surface.contentOpacity
					font.letterSpacing: Arc.trackingRubric + 1.2
				}

				ArcFlourish {
					anchors.left: nameText.right
					anchors.right: parent.right
					anchors.leftMargin: Arc.s3
					anchors.rightMargin: surface.mountMargin + Arc.s4
					anchors.verticalCenter: nameText.verticalCenter
					height: 10
					lineColor: Arc.giltFaint
					facing: Qt.LeftToRight
					opacity: surface.contentOpacity
					visible: width > 34
				}

				Item {
					id: contentSlot
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					anchors.leftMargin: surface.contentMargins + surface.mountMargin
					anchors.rightMargin: surface.contentMargins + surface.mountMargin
					anchors.topMargin: surface.contentMargins + surface.mountMargin + surface.headRail
					anchors.bottomMargin: surface.contentMargins + surface.mountMargin
					opacity: surface.contentOpacity

					// Writing follows the dowel down, so the page is written as
					// it is uncovered rather than after it has arrived.
					transform: Translate {
						y: (1 - surface.contentOpacity) * -18
					}
				}
			}

			// The curl at the leading edge, and the shade the turn throws onto
			// the sheet behind it. It rides the bottom of what has been let
			// down, which is what makes the motion read as unrolling.
			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: 14
				visible: surface.openProgress > 0.02 && surface.openProgress < 0.995

				gradient: Gradient {
					GradientStop { position: 0.0; color: "transparent" }
					GradientStop { position: 0.55; color: Qt.alpha(Arc.well, 0.7) }
					GradientStop { position: 0.92; color: Qt.alpha(Arc.gilt, 0.22) }
					GradientStop { position: 1.0; color: Qt.alpha(Arc.well, 0.5) }
				}
			}
		}

		// The dowel: the weight at the foot of the sheet. It is what the sheet
		// is falling behind, so it is always at the bottom of what is showing.
		Rectangle {
			anchors.top: window.bottom
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.leftMargin: -2
			anchors.rightMargin: -2
			height: 3
			color: Arc.gilt
			opacity: Math.min(1, surface.openProgress * 6)
		}
	}
}
