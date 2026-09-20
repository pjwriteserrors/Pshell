pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "ArcInk.js" as Ink

// THE CONJURING, and the file that owns it.
//
// Nothing in this shell appears, slides, unrolls or scales. A panel is called
// up out of the floor of the sanctum, and it is called in four movements that
// happen in this order every single time:
//
//   1  a ring inscribes itself on the horizon under the sigil that was
//      touched, drawn once round from the twelve at the speed a hand moves
//   2  motes gather off that ring and are thrown upward
//   3  the glass precipitates out of them, condensing from the ring upward —
//      revealed bottom to top, never scaled and never faded from nowhere
//   4  what is written on it ignites band by band, from the top down
//
// Dismissing runs it backwards and twice as fast: the writing goes out, the
// glass comes apart into motes that fall back into the ring, and the ring
// un-draws itself.
//
// Because the ring is on the horizon under the sigil, where a panel stands
// tells you what called it, and everything in the sanctum moves in the same
// direction — up out of the floor, and back down into it.
PanelWindow {
	id: surface

	required property bool open
	required property Item barItem
	// The sigil this was called by. Without one it rises from the middle.
	property Item anchorItem: null

	property string title: ""

	// sizing
	property real expandedWidth: 300
	property real contentPreferredHeight: 0
	property real fixedHeight: -1
	property real contentMargins: Arc.s4

	property color surfaceColor: Arc.haze
	property color borderColor: "transparent"
	property bool wantsKeyboard: true

	default property alias content: contentSlot.data
	readonly property Item contentArea: contentSlot

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	readonly property real mountMargin: Arc.s3
	readonly property real headRail: 26

	// The four movements, cut out of one progress value so they can never get
	// out of order.
	readonly property real inscribed: Math.max(0, Math.min(1, openProgress / 0.34))
	readonly property real gathered: Math.max(0, Math.min(1, (openProgress - 0.18) / 0.34))
	readonly property real condensed: Math.max(0, Math.min(1, (openProgress - 0.30) / 0.45))
	readonly property real contentOpacity: Math.max(0, Math.min(1, (openProgress - 0.58) / 0.42))

	readonly property real shellWidth: Math.round(expandedWidth)
	readonly property real roomHeight: height - Arc.horizon - Arc.riseInset
	readonly property real expandedHeight: Math.round(Math.min(
		roomHeight,
		fixedHeight > 0
			? fixedHeight
			: Math.max(200, contentPreferredHeight + headRail + (contentMargins + mountMargin) * 2)
	))

	// Where on the horizon this was called from.
	readonly property real anchorX: {
		if (!surface.anchorItem || !surface.visible) return surface.width / 2;
		const p = surface.anchorItem.mapToItem(null, surface.anchorItem.width / 2, 0);
		return p ? p.x : surface.width / 2;
	}
	readonly property real riseX: Math.round(Math.max(Arc.s5,
		Math.min(surface.width - surface.shellWidth - Arc.s5, surface.anchorX - surface.shellWidth / 2)))
	readonly property real floorY: Math.round(surface.height - Arc.horizon + Arc.riseGap)

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
			duration: surface.open ? Arc.conjure : Arc.dispel
			easing.type: Easing.Bezier
			easing.bezierCurve: surface.open ? Arc.curveRise : Arc.curveSink
		}
	}

	onOpenChanged: {
		if (surface.open) gatherTimer.restart();
	}

	Timer {
		id: gatherTimer
		interval: Math.round(Arc.conjure * 0.24)
		onTriggered: {
			if (surface.open && motes.visible)
				motes.burst(motes.width / 2, motes.height - 4, 22);
		}
	}

	// Clicking off dismisses — but not while it is still being called. A panel
	// arrives under the pointer that called it, and a press still travelling
	// when the window maps would otherwise land here.
	MouseArea {
		anchors.fill: parent
		enabled: surface.openProgress > 0.8
		onClicked: surface.dismissRequested()
	}

	Item {
		id: rig

		x: surface.riseX
		width: surface.shellWidth
		height: surface.expandedHeight
		y: Math.round(surface.floorY - height)

		Behavior on x {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSnap }
		}
		Behavior on height {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveRise }
		}

		focus: true

		Keys.onEscapePressed: event => {
			event.accepted = true;
			surface.dismissRequested();
		}

		// 1 — the ring, inscribed on the horizon under the sigil.
		Canvas {
			id: circle
			anchors.horizontalCenter: parent.horizontalCenter
			y: rig.height - Arc.riseGap - height / 2
			width: Math.min(rig.width * 1.05, 420)
			height: width * 0.30
			renderStrategy: Canvas.Cooperative
			opacity: surface.openProgress > 0.02 ? 1 : 0

			readonly property real through: surface.inscribed

			onThroughChanged: requestPaint()

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				if (width < 12 || circle.through <= 0.002) return;
				const cx = width / 2, cy = height / 2;
				// Seen at a raking angle, so it lies on the floor rather than
				// standing up facing the reader.
				ctx.save();
				ctx.translate(cx, cy);
				ctx.scale(1, height / width);
				Ink.ring(ctx, 0, 0, width / 2 - 3, 2.2, Arc.aether, circle.through);
				Ink.graduations(ctx, 0, 0, width / 2 - 5, 48, 4, 9, 4,
					Arc.ruleThin, Qt.alpha(Arc.aether, 0.5), circle.through);
				Ink.runeRing(ctx, 0, 0, width / 2 - 16, 9, 7, 13, Arc.ruleThin,
					Qt.alpha(Arc.gold, 0.22), Arc.aether,
					Math.round(9 * circle.through));
				ctx.restore();
			}
		}

		ArcHalo {
			anchors.centerIn: circle
			width: circle.width * 1.5
			height: circle.height * 4
			color: Arc.aether
			strength: 0.30 * surface.inscribed * (1.1 - surface.condensed * 0.5)
			spread: 0.42
			flicker: true
		}

		// 2 — the motes thrown off the ring while the glass is condensing.
		ArcMotes {
			id: motes
			anchors.fill: parent
			color: Arc.aether
			span: 3.4
			visible: surface.openProgress > 0.05 && surface.openProgress < 0.97
		}

		// 3 — the glass, condensing upward out of the ring. Clipped from the
		// bottom, so it is revealed rather than scaled.
		Item {
			id: window
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Arc.riseGap
			height: Math.max(0, (rig.height - Arc.riseGap) * surface.condensed)
			clip: true
			opacity: Math.min(1, surface.condensed * 1.6)

			ArcLeaf {
				id: pane
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: rig.height - Arc.riseGap
				variant: "chamber"
				crest: true
				lineColor: surface.borderColor.a > 0.01 ? surface.borderColor : Arc.goldDim
				liveColor: Arc.aether
				washTop: surface.surfaceColor
				washBottom: Arc.hazeDeep
				haloStrength: 0.16 * surface.condensed
				padding: 0

				// The name, written across the head with a ley out to the edge.
				ArcText {
					id: nameText
					anchors.left: parent.left
					anchors.top: parent.top
					anchors.leftMargin: surface.mountMargin + Arc.s4
					anchors.topMargin: surface.mountMargin + Arc.s3
					role: "label"
					tone: "aether"
					text: surface.title
					opacity: surface.contentOpacity
					font.letterSpacing: Arc.trackingRubric + 1.6
				}

				ArcFlourish {
					anchors.left: nameText.right
					anchors.right: parent.right
					anchors.leftMargin: Arc.s3
					anchors.rightMargin: surface.mountMargin + Arc.s4
					anchors.verticalCenter: nameText.verticalCenter
					height: 10
					lineColor: Arc.goldGhost
					facing: Qt.LeftToRight
					opacity: surface.contentOpacity
					visible: width > 30
				}

				// 4 — what is written on it, arriving after the glass has set.
				Item {
					id: contentSlot
					anchors.fill: parent
					anchors.leftMargin: surface.contentMargins + surface.mountMargin
					anchors.rightMargin: surface.contentMargins + surface.mountMargin
					anchors.topMargin: surface.contentMargins + surface.mountMargin + surface.headRail
					anchors.bottomMargin: surface.contentMargins + surface.mountMargin
					opacity: surface.contentOpacity

					// It settles down into place rather than fading up: the
					// writing arrives from the light above it.
					transform: Translate {
						y: (1 - surface.contentOpacity) * -10
					}
				}
			}
		}
	}
}
