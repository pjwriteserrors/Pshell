pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// Every chamber the spine opens is docked to it: it stands the full height of
// the screen, immediately beside the column, and unfurls sideways out of it.
// Nothing drops, nothing floats, nothing is centred — a chamber is a drawer in
// the cabinet the spine runs down.
//
// Built on PanelWindow (a full-screen overlay) so text fields inside receive
// keyboard input.
//
// Choreography contract, the same for every chamber:
//   open:  a spur reaches out of the spine at the organ that owns the chamber,
//          the chamber unrolls horizontally from that edge, and its contents
//          surface band by band, each one sliding the last few pixels in.
//   close: it rolls back into the spine, faster than it came out.
//
// Clicking outside emits dismissRequested(); the instance decides how to close.
PanelWindow {
	id: surface

	// wiring
	required property bool open
	required property Item barItem
	// The organ this chamber belongs to: the spur leaves the column there, and
	// the chamber opens level with it.
	property Item anchorItem: null

	// The name engraved down the chamber's outer edge. Every chamber has one —
	// it is what tells you which drawer is open without reading the contents.
	property string title: ""

	// sizing
	property real expandedWidth: 300
	property real contentPreferredHeight: 0
	property real fixedHeight: -1
	property real contentMargins: Bio.s4

	// style
	property color surfaceColor: Bio.membrane
	property color borderColor: "transparent"
	property bool wantsKeyboard: true

	default property alias content: contentSlot.data
	readonly property Item contentArea: contentSlot

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	// How far in from the frame content has to stay so the corner bones have
	// room.
	readonly property real boneMargin: 11

	readonly property real shellWidth: Math.round(expandedWidth + Bio.nameColumn)
	// A chamber is as deep as what it holds, never shallower than a drawer
	// worth pulling and never deeper than the screen. It opens level with the
	// organ that owns it, so where it appears tells you what pulled it.
	readonly property real roomHeight: Math.max(120, height - Bio.dockInset * 2)
	readonly property real expandedHeight: Math.round(Math.min(
		roomHeight,
		fixedHeight > 0
			? fixedHeight
			: Math.max(260, contentPreferredHeight + (contentMargins + boneMargin) * 2)
	))
	// Contents only surface once the chamber has unrolled far enough to hold a
	// line of text without it being crushed.
	readonly property real contentOpacity: Math.max(0, Math.min(1, (openProgress - 0.55) / 0.45))

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
			duration: surface.open ? Bio.unfurl : Bio.furl
			easing.type: surface.open ? Easing.OutQuint : Easing.InCubic
		}
	}

	MouseArea {
		anchors.fill: parent
		onClicked: surface.dismissRequested()
	}

	// The spur: the short bone that reaches out of the spine at whichever organ
	// owns this chamber, so an open drawer is traceable back to the thing that
	// pulled it. Without an anchor it leaves from the middle of the column.
	Item {
		id: spur
		x: Bio.spine
		width: Bio.dockGap
		height: 2
		opacity: Math.min(1, surface.openProgress * 2.4)

		readonly property real anchorY: {
			if (!surface.anchorItem || !surface.visible)
				return -1;
			const p = surface.anchorItem.mapToItem(null, 0, surface.anchorItem.height / 2);
			return p ? p.y : -1;
		}

		y: Math.round(spur.anchorY >= 0
			? Math.max(Bio.dockInset + 12, Math.min(parent.height - Bio.dockInset - 12, spur.anchorY))
			: parent.height / 2)

		Behavior on y {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}

		Rectangle {
			anchors.fill: parent
			color: Bio.organ
			opacity: 0.8
		}

		Rectangle {
			width: 5
			height: 5
			radius: 2.5
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			color: Bio.organ
		}
	}

	Item {
		id: cardMotion

		// Escape closes every chamber. The handler sits on the card itself, an
		// ancestor of the content, so an unhandled key from a focused field
		// inside travels up to here. focus: true only claims the keyboard while
		// nothing inside the card wants it.
		focus: true

		Keys.onEscapePressed: event => {
			event.accepted = true;
			surface.dismissRequested();
		}

		x: Math.round(Bio.spine + Bio.dockGap)
		y: Math.round(Math.max(Bio.dockInset, Math.min(
			parent.height - Bio.dockInset - height,
			(spur.anchorY >= 0 ? spur.anchorY : parent.height / 2) - height / 2
		)))
		width: surface.shellWidth
		height: surface.expandedHeight

		Behavior on y {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}

		Behavior on height {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}
		opacity: Math.min(1, surface.openProgress * 2.6)

		// The chamber unrolls out of the spine: scaled from its left edge only,
		// so it reads as something being drawn out of the column rather than as
		// a window appearing.
		transform: Scale {
			origin.x: 0
			origin.y: cardMotion.height / 2
			xScale: Math.max(0.03, surface.openProgress)
			yScale: 0.985 + 0.015 * surface.openProgress
		}

		BioSurface {
			id: chamber
			anchors.fill: parent
			variant: "chamber"
			lineColor: surface.borderColor.a > 0.01 ? surface.borderColor : Bio.boneDim
			liveColor: Bio.organ
			washTop: surface.surfaceColor
			washBottom: Bio.membraneDeep
			haloStrength: 0.26 * surface.openProgress
			padding: 0

			// The name, engraved down the outer edge and read from the bottom
			// up, with a beaded hairline running out of it to the floor of the
			// chamber. This column is why a chamber can stand full height with
			// little in it and still look deliberate.
			Item {
				id: nameStrip
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				anchors.leftMargin: surface.boneMargin + Bio.s1
				anchors.topMargin: surface.boneMargin + Bio.s3
				anchors.bottomMargin: surface.boneMargin + Bio.s3
				width: Bio.nameColumn
				opacity: surface.contentOpacity

				BioText {
					id: nameText
					role: "label"
					tone: "organ"
					text: surface.title
					rotation: -90
					transformOrigin: Item.Center
					anchors.horizontalCenter: parent.horizontalCenter
					// Rotated about its own centre, so its visual top sits at
					// y + height/2 - width/2. Solve that for a flush start.
					y: Math.round(width / 2 - height / 2)
					font.letterSpacing: Bio.trackingEyebrow + 1.4
				}

				Rectangle {
					id: nameRule
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.top
					anchors.topMargin: nameText.implicitWidth + Bio.s3
					anchors.bottom: parent.bottom
					width: Bio.ribThin
					color: Bio.boneGhost
				}

				Repeater {
					model: 3
					delegate: Rectangle {
						required property int index
						anchors.horizontalCenter: parent.horizontalCenter
						y: nameRule.y + nameRule.height * (0.22 + index * 0.28)
						width: Bio.nodule
						height: Bio.nodule
						radius: Bio.nodule / 2
						color: Bio.boneFaint
					}
				}
			}

			// Contents ride in the last few pixels as they surface, so a
			// chamber opening reads as one motion instead of two.
			Item {
				id: contentSlot
				anchors.left: nameStrip.right
				anchors.leftMargin: Bio.s3
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				anchors.rightMargin: surface.contentMargins + surface.boneMargin
				anchors.topMargin: surface.contentMargins + surface.boneMargin
				anchors.bottomMargin: surface.contentMargins + surface.boneMargin
				opacity: surface.contentOpacity
				transform: Translate {
					x: (1 - surface.contentOpacity) * 26
				}
			}
		}
	}
}
