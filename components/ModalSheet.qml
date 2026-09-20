pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A great conjuring: the same four movements a panel makes, at the size of the
// screen and drawn in the middle of it rather than on the horizon.
//
// The ring inscribes itself around where the work will stand, so it is a
// circle the reader is looking *down* into rather than a plate; motes gather;
// the glass condenses out of them from the middle of the ring outward; and the
// contents ignite last. There are no covers, no boards and nothing that opens
// on a hinge.
Item {
	id: sheet

	required property bool open
	property real scrimOpacity: 0.62
	property real sheetWidth: 400
	property real sheetHeight: 300

	default property alias content: container.data
	readonly property Item containerItem: container

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	readonly property real inscribed: Math.max(0, Math.min(1, openProgress / 0.36))
	readonly property real condensed: Math.max(0, Math.min(1, (openProgress - 0.26) / 0.48))
	readonly property real lit: Math.max(0, Math.min(1, (openProgress - 0.56) / 0.44))

	anchors.fill: parent

	focus: true

	Keys.onEscapePressed: event => {
		event.accepted = true;
		sheet.dismissRequested();
	}

	Behavior on openProgress {
		NumberAnimation {
			duration: sheet.open ? Arc.conjure + 120 : Arc.dispel + 60
			easing.type: Easing.Bezier
			easing.bezierCurve: sheet.open ? Arc.curveRise : Arc.curveSink
		}
	}

	onOpenChanged: {
		if (sheet.open) gatherTimer.restart();
	}

	Timer {
		id: gatherTimer
		interval: Math.round(Arc.conjure * 0.26)
		onTriggered: {
			if (sheet.open) motes.burst(motes.width / 2, motes.height / 2, 34);
		}
	}

	// The scrim is an opaque pigment with the opacity doing the work, so a
	// modal that asks for a full blackout gets one. A translucent pigment at
	// full opacity would still let a bright window read through it.
	Rectangle {
		anchors.fill: parent
		color: Qt.rgba(Arc.scrim.r, Arc.scrim.g, Arc.scrim.b, 1)
		opacity: sheet.open ? sheet.scrimOpacity : 0

		Behavior on opacity {
			NumberAnimation {
				duration: sheet.open ? Arc.draw : Arc.recoil
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: sheet.dismissRequested()
		}
	}

	// The great ring, inscribed round the work.
	Canvas {
		id: circle
		anchors.centerIn: rig
		width: Math.max(rig.width, rig.height) * 1.16
		height: width
		renderStrategy: Canvas.Cooperative

		readonly property real through: sheet.inscribed

		onThroughChanged: requestPaint()

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width < 40 || circle.through <= 0.002) return;
			const cx = width / 2, cy = height / 2, r = width / 2 - 6;
			Ink.ring(ctx, cx, cy, r, 1.6, Qt.alpha(Arc.aether, 0.55), circle.through);
			Ink.ring(ctx, cx, cy, r - 16, 1.0, Qt.alpha(Arc.gold, 0.26), circle.through);
			Ink.graduations(ctx, cx, cy, r - 2, 120, 5, 12, 10,
				Arc.ruleThin, Qt.alpha(Arc.aether, 0.34), circle.through);
			Ink.runeRing(ctx, cx, cy, r - 34, 16, 23, 17, Arc.ruleThin,
				Qt.alpha(Arc.gold, 0.22), Arc.aether, Math.round(16 * circle.through));
		}
	}

	ArcHalo {
		anchors.centerIn: rig
		width: rig.width * 1.5
		height: rig.height * 1.5
		color: Arc.aether
		strength: 0.16 * sheet.openProgress
		spread: 0.46
		flicker: true
		visible: sheet.openProgress > 0.02
	}

	ArcMotes {
		id: motes
		anchors.centerIn: rig
		width: rig.width
		height: rig.height
		color: Arc.aether
		span: 3.8
		visible: sheet.openProgress > 0.04 && sheet.openProgress < 0.97
	}

	Item {
		id: rig

		width: Math.min(sheet.sheetWidth, sheet.width - Arc.s8 * 2)
		height: Math.min(sheet.sheetHeight, sheet.height - Arc.horizon - Arc.s6 * 2)
		x: Math.round((sheet.width - width) / 2)
		y: Math.round((sheet.height - Arc.horizon - height) / 2)

		// The glass condenses out of the middle of the ring and spreads to the
		// edges of the work: clipped from the centre, never scaled.
		Item {
			id: aperture
			anchors.centerIn: parent
			width: parent.width
			height: Math.round(parent.height * sheet.condensed)
			clip: true
			opacity: Math.min(1, sheet.condensed * 1.5)

			Item {
				id: container
				width: rig.width
				height: rig.height
				y: Math.round((aperture.height - rig.height) / 2)
			}
		}
	}
}
