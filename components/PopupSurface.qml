pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// Every popup the spine opens is a chamber that grows out of the node that
// owns it. Built on PanelWindow (a full-screen overlay) so text fields inside
// receive keyboard input.
//
// Choreography contract, the same for every popup:
//   open:  the chamber unseals — it comes up as a slit at the top, swells to
//          full height past its resting size by a hair, and the membrane
//          brightens; content surfaces once the chamber has room for it.
//   close: it contracts back into the slit, faster than it opened.
//
// Clicking outside emits dismissRequested(); the instance decides how to close.
PanelWindow {
	id: surface

	// wiring
	required property bool open
	required property Item barItem
	property var anchorWindow: null       // legacy, unused
	property string anchorMode: "right"   // "right" | "center" | "item"
	property Item anchorItem: null

	// sizing
	property real expandedWidth: 300
	property real contentPreferredHeight: 0
	property real fixedHeight: -1
	property real contentMargins: Bio.s4

	// style
	property color surfaceColor: Bio.membrane
	property color borderColor: "transparent"
	property real restingRadius: 0        // kept for source compatibility
	property real edgeMargin: 12
	property real barGap: 10
	property real barTopMargin: 4
	property bool wantsKeyboard: true

	default property alias content: contentSlot.data
	readonly property Item contentArea: contentSlot

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	// How far in from the frame content has to stay so the corner bones have
	// room. A constant rather than the frame's own measurement: the frame sizes
	// its bones from the chamber's height, and the height is what this feeds.
	readonly property real boneMargin: 11

	readonly property real expandedHeight: fixedHeight > 0
		? fixedHeight
		: Math.max(64, contentPreferredHeight + (contentMargins + boneMargin) * 2)
	readonly property real shellWidth: expandedWidth
	// Content only appears once the chamber has swelled past half open,
	// otherwise it is briefly wider than the thing containing it.
	readonly property real contentOpacity: Math.max(0, Math.min(1, (openProgress - 0.45) / 0.55))

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
			duration: surface.open ? Bio.swell : Bio.relax
			easing.type: surface.open ? Easing.OutBack : Easing.InCubic
			easing.overshoot: surface.open ? 1.05 : 0
		}
	}

	MouseArea {
		anchors.fill: parent
		onClicked: surface.dismissRequested()
	}

	Item {
		id: cardMotion

		// Escape closes every popup. The handler sits on the card itself, an
		// ancestor of the content, so an unhandled key from a focused field
		// inside travels up to here. focus: true only claims the keyboard while
		// nothing inside the card wants it.
		focus: true

		Keys.onEscapePressed: event => {
			event.accepted = true;
			surface.dismissRequested();
		}

		x: {
			if (surface.anchorMode === "center")
				return Math.round((parent.width - width) / 2);
			if (surface.anchorMode === "item" && surface.anchorItem) {
				const pos = surface.anchorItem.mapToItem(surface.barItem, surface.anchorItem.width / 2, 0);
				return Math.round(Math.min(
					Math.max(pos.x + surface.edgeMargin - width / 2, surface.edgeMargin),
					parent.width - width - surface.edgeMargin
				));
			}
			return Math.round(parent.width - width - surface.edgeMargin);
		}
		y: Math.round(surface.barTopMargin + surface.barItem.height + surface.barGap)

		width: surface.shellWidth
		height: surface.expandedHeight
		opacity: Math.min(1, surface.openProgress * 2.2)

		// The chamber unseals downwards: it is scaled from its top edge, so it
		// looks like it is being extruded out of the spine rather than zoomed.
		transform: Scale {
			origin.x: cardMotion.width / 2
			origin.y: 0
			xScale: 0.86 + 0.14 * Math.min(1, surface.openProgress * 1.8)
			yScale: Math.max(0.02, surface.openProgress)
		}

		Behavior on height {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
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

			Item {
				id: contentSlot
				anchors.fill: parent
				anchors.margins: surface.contentMargins + surface.boneMargin
				opacity: surface.contentOpacity
			}
		}
	}
}
