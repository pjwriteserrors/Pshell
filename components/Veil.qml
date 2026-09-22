pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// The modal layer: a wash over the desktop with one thing hung in it.
//
//   mode "hang"   the thing hangs from the wire at the top on a stem, and
//                 unfolds downward like a lantern (launcher, Studio)
//   mode "float"  the thing sits mid-screen and grows out of a point of
//                 light (the power thread)
PanelWindow {
	id: veil

	required property bool open
	property string mode: "hang"
	property real sheetWidth: 600
	property real sheetHeight: 400
	property real hangX: -1        // screen x the stem hangs from; -1 = centre
	property real topGap: Filament.barHeight + Filament.stemLength
	property real washOpacity: 1
	default property alias content: slot.data
	readonly property real reveal: bodyP
	readonly property Item sheetItem: sheet

	signal dismissRequested()

	property real stemP: 0
	property real bodyP: 0

	anchors { left: true; right: true; top: true; bottom: true }
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	onOpenChanged: {
		openSeq.stop();
		closeSeq.stop();
		if (open) openSeq.start(); else closeSeq.start();
	}

	SequentialAnimation {
		id: openSeq
		NumberAnimation { target: veil; property: "stemP"; to: 1; duration: veil.mode === "hang" ? 110 : 1; easing.type: Easing.OutCubic }
		NumberAnimation { target: veil; property: "bodyP"; to: 1; duration: Filament.unfold + 60; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeUnfold }
	}

	SequentialAnimation {
		id: closeSeq
		NumberAnimation { target: veil; property: "bodyP"; to: 0; duration: Filament.fold; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeFold }
		NumberAnimation { target: veil; property: "stemP"; to: 0; duration: 80; easing.type: Easing.InCubic }
	}

	Rectangle {
		anchors.fill: parent
		color: Filament.scrim
		opacity: Math.max(veil.stemP, veil.bodyP) * veil.washOpacity
		MouseArea {
			anchors.fill: parent
			onClicked: veil.dismissRequested()
		}
	}

	readonly property real stemX: hangX < 0 ? Math.round(width / 2) : Math.round(hangX)

	Wire {
		visible: veil.mode === "hang"
		vertical: true
		x: veil.stemX - 1
		y: Filament.barHeight - 6
		width: 2
		height: Math.round((veil.topGap - (Filament.barHeight - 6)) * veil.stemP)
		lit: 1
		animateLit: false
		glow: false
	}

	Item {
		id: sheet
		width: veil.sheetWidth
		height: veil.sheetHeight
		x: veil.mode === "hang"
			? Math.round(Math.min(Math.max(veil.stemX - width / 2, 16), veil.width - width - 16))
			: Math.round((veil.width - width) / 2)
		y: veil.mode === "hang" ? veil.topGap : Math.round((veil.height - height) / 2)
		focus: true
		Keys.onEscapePressed: event => { event.accepted = true; veil.dismissRequested(); }

		Item {
			id: unfoldClip
			width: parent.width
			height: veil.mode === "hang" ? Math.round(parent.height * Math.min(1.06, veil.bodyP)) : parent.height
			clip: veil.mode === "hang"
			opacity: veil.mode === "hang" ? Math.min(1, veil.bodyP * 1.5) : veil.bodyP
			scale: veil.mode === "hang" ? 1 : 0.9 + 0.1 * veil.bodyP

			Rectangle {
				id: plane
				width: parent.width
				height: sheet.height
				radius: Filament.radius + 2
				color: Filament.plane
				border.width: 1
				border.color: Filament.wireDim

				Wire {
					visible: veil.mode === "hang"
					x: veil.stemX - sheet.x - 24
					y: 0
					width: 48
					height: 2
					lit: veil.bodyP
					animateLit: false
					cold: "transparent"
				}

				MouseArea { anchors.fill: parent }

				Item {
					id: slot
					anchors.fill: parent
				}
			}
		}
	}
}
