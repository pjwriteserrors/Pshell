pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// A lantern hung from the wire. Every bar popup is one of these.
//
// Choreography: the stem grows down out of the bead first, then the body
// unfolds from the stem on the spring, then the contents surface band by
// band (each band reads `reveal`). Closing folds the body back up the stem
// and the stem retracts into the bead; nothing fades in from nowhere.
//
// The window is a full-screen overlay so a click beside the lantern
// dismisses it and text fields inside receive the keyboard.
PanelWindow {
	id: lantern

	required property bool open
	// Screen x of the bead this lantern hangs from. Negative: hang at the right edge.
	property real anchorX: -1
	property real lanternWidth: 320
	property real contentHeight: 0
	property real fixedHeight: -1
	property real margin: Filament.pad
	property real edgeMargin: 10
	property bool wantsKeyboard: true
	property bool stemVisible: true

	default property alias content: slot.data
	readonly property Item contentArea: slot
	readonly property real reveal: bodyP
	readonly property real bodyHeight: fixedHeight > 0 ? fixedHeight : Math.max(48, contentHeight + margin * 2)
	readonly property real bodyX: {
		if (anchorX < 0) return Math.round(width - lanternWidth - edgeMargin);
		return Math.round(Math.min(Math.max(anchorX - lanternWidth / 2, edgeMargin), width - lanternWidth - edgeMargin));
	}
	readonly property real stemX: anchorX < 0 ? bodyX + lanternWidth - 24 : Math.round(anchorX)
	readonly property real stemTop: Filament.barHeight - 6
	readonly property real bodyTop: Filament.barHeight + Filament.stemLength

	signal dismissRequested()

	property real stemP: 0
	property real bodyP: 0

	anchors { left: true; right: true; top: true; bottom: true }
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.keyboardFocus: visible && wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	onOpenChanged: {
		openSeq.stop();
		closeSeq.stop();
		if (open) openSeq.start(); else closeSeq.start();
	}

	SequentialAnimation {
		id: openSeq
		NumberAnimation { target: lantern; property: "stemP"; to: 1; duration: 90; easing.type: Easing.OutCubic }
		NumberAnimation { target: lantern; property: "bodyP"; to: 1; duration: Filament.unfold; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeUnfold }
	}

	SequentialAnimation {
		id: closeSeq
		NumberAnimation { target: lantern; property: "bodyP"; to: 0; duration: Filament.fold; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeFold }
		NumberAnimation { target: lantern; property: "stemP"; to: 0; duration: 70; easing.type: Easing.InCubic }
	}

	MouseArea {
		anchors.fill: parent
		onClicked: lantern.dismissRequested()
	}

	Wire {
		visible: lantern.stemVisible
		vertical: true
		x: lantern.stemX - 1
		y: lantern.stemTop
		width: 2
		height: Math.round((lantern.bodyTop - lantern.stemTop) * lantern.stemP)
		lit: 1
		animateLit: false
		glow: false
		hot: Filament.charge
	}

	Item {
		id: fold
		x: lantern.bodyX
		y: lantern.bodyTop
		width: lantern.lanternWidth
		height: Math.round(lantern.bodyHeight * Math.min(1.08, lantern.bodyP))
		clip: true
		opacity: Math.min(1, lantern.bodyP * 1.6)

		// Escape closes the lantern from anywhere inside it; a focused field
		// inside gets first refusal because the handler sits on an ancestor.
		focus: true
		Keys.onEscapePressed: event => { event.accepted = true; lantern.dismissRequested(); }

		Rectangle {
			id: plane
			width: parent.width
			height: lantern.bodyHeight
			radius: Filament.radius
			color: Filament.plane
			border.width: 1
			border.color: Filament.wireDim

			Behavior on height { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }

			// The hook: where the stem meets the plane, a short lit stretch.
			Wire {
				x: lantern.stemX - lantern.bodyX - 18
				y: 0
				width: 36
				height: 2
				lit: lantern.bodyP
				animateLit: false
				hot: Filament.charge
				cold: "transparent"
				glow: true
				visible: lantern.stemVisible
			}

			MouseArea {
				anchors.fill: parent
				// eats the click so it does not reach the dismiss layer
			}

			Item {
				id: slot
				anchors.fill: parent
				anchors.margins: lantern.margin
			}
		}
	}
}
