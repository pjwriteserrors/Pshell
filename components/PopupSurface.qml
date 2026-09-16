pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// Shared shell for every bar-anchored popup: a detached floating card
// below the bar. Built on PanelWindow (full-screen overlay) so text
// fields inside popups receive keyboard input (WlrKeyboardFocus).
//
// Choreography contract (identical for every popup):
//   open:  card pops in — slides down a few px, scales up from 0.94
//          with a slight overshoot, fades in; content fade trails.
//   close: card shrinks/fades out crisply, no bounce.
//
// Clicking outside the card emits dismissRequested(); the instance
// decides how to close (usually its root.closeXPopup()).
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
	property real contentMargins: 14

	// style
	property color surfaceColor
	property color borderColor: "transparent"
	property real restingRadius: ThemeEngine.radiusMedium
	property real edgeMargin: 10 + ThemeEngine.shadowRenderMargin
	property real barGap: 6
	property real barTopMargin: 6
	property bool wantsKeyboard: true

	default property alias content: contentSlot.data
	readonly property Item contentArea: contentSlot

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	readonly property real expandedHeight: fixedHeight > 0
		? fixedHeight
		: Math.max(52, contentPreferredHeight + contentMargins * 2)
	readonly property real shellWidth: expandedWidth
	readonly property real contentOpacity: Math.max(0, Math.min(1,
		(openProgress - ThemeEngine.popupContentRevealStart)
		/ Math.max(0.01, 1 - ThemeEngine.popupContentRevealStart)))

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
			duration: surface.open ? Motion.popupOpen : Motion.popupClose
			easing.type: surface.open ? ThemeEngine.popupOpenEasing : ThemeEngine.exitEasing
			easing.overshoot: surface.open ? Motion.popupOvershoot : 0
			easing.amplitude: ThemeEngine.elasticAmplitude
			easing.period: ThemeEngine.elasticPeriod
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
		// inside travels up to here. focus: true only claims the keyboard
		// while nothing inside the card wants it.
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
		opacity: Math.min(1, surface.openProgress * ThemeEngine.popupOpacityMultiplier)
		scale: ThemeEngine.popupStartScale + (1 - ThemeEngine.popupStartScale) * surface.openProgress
		transformOrigin: Item.Top

		transform: Translate {
				y: ThemeEngine.popupTravel * (1 - surface.openProgress)
		}

		Behavior on height {
			Anim {}
		}

		NeumorphicShadow {
			anchors.fill: parent
			surfaceColor: surface.surfaceColor
			cornerRadius: card.radius
			depth: surface.openProgress * ThemeEngine.popupShadowDepth
			animateDepth: false
		}

		Rectangle {
			id: card

			anchors.fill: parent
			radius: surface.restingRadius
			color: ThemeEngine.solidSurfaces
				? ThemeEngine.solidColor(surface.surfaceColor)
				: surface.surfaceColor
			border.width: Math.max(1, ThemeEngine.outlineWidth)
			border.color: surface.borderColor.a > 0.01
				? surface.borderColor
				: ThemeEngine.contrastEdge(surface.surfaceColor)
			clip: true

			ThemeOrnament {
				anchors.fill: parent
				surfaceColor: card.color
				cornerRadius: card.radius
			}

			Behavior on radius {
				NumberAnimation {
					duration: Motion.normal
					easing.type: ThemeEngine.standardEasing
				}
			}

			Item {
				id: contentSlot

				anchors.fill: parent
				anchors.margins: surface.contentMargins
				opacity: surface.contentOpacity
			}
		}
	}
}
