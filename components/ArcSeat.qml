pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A seat: one fitting on the chain. A brass limb, a mark inside it, and a lamp
// behind it that is only alight when the seat is doing something.
//
// Brass turns. Under the hand the limb rotates a few degrees and arrests
// against a detent — overshooting the stop by a hair and settling back into it,
// which is what the curve in `Arc.curveDetent` is for. Pressing does not shrink
// the seat: it seats it, one pixel deeper into the chain, and the limb snaps
// straight. While a seat's panel is open its limb turns slowly and never stops,
// which is the only idle motion on the chain.
Item {
	id: seat

	property string iconSource: ""
	property real iconSize: Math.round(size * 0.44)
	property color iconColor: seat.lit ? Arc.aether : Arc.ink
	property color ringColor: Arc.giltDim
	property color liveColor: Arc.aether
	property real size: Arc.seat
	property bool lit: false          // the panel this seat owns is open
	property int seed: 0
	property real progress: -1
	property string badge: ""
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons

	default property alias inner: content.data

	signal clicked(var event)

	implicitWidth: size
	implicitHeight: size

	readonly property real turnTo: touch.pressed ? 0 : touch.containsMouse ? (seat.seed % 2 === 0 ? 11 : -11) : 0

	// Seated: pressing pushes the fitting into the chain rather than scaling it.
	transform: Translate {
		y: touch.pressed ? 1.5 : 0

		Behavior on y {
			NumberAnimation { duration: Arc.tick }
		}
	}

	ArcHalo {
		anchors.centerIn: parent
		width: seat.size * 2.2
		height: seat.size * 2.2
		color: seat.liveColor
		strength: 0.32
		spread: 0.33
		flicker: true
		opacity: Math.max(touch.live, seat.lit ? 0.85 : 0)
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}
	}

	ArcDial {
		id: limb
		anchors.fill: parent
		lineColor: seat.ringColor
		liveColor: seat.liveColor
		intensity: Math.max(touch.live, seat.lit ? 0.9 : 0)
		seed: seat.seed
		progress: seat.progress

		rotation: seat.turnTo

		Behavior on rotation {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		// The only thing on the chain that moves while nothing is happening,
		// and only on the one seat whose panel is open.
		RotationAnimation on rotation {
			running: seat.lit && !touch.containsMouse
			loops: Animation.Infinite
			from: 0
			to: 360
			duration: 42000
		}
	}

	Item {
		id: content
		anchors.fill: parent

		QQCImpl.IconImage {
			anchors.centerIn: parent
			width: seat.iconSize
			height: seat.iconSize
			visible: seat.iconSource !== ""
			source: seat.iconSource
			sourceSize: Qt.size(width, height)
			color: seat.iconColor

			Behavior on color {
				ColorAnimation { duration: Arc.tick }
			}
		}
	}

	// A count is struck on a small lozenge pinned to the seat, not a chip.
	Item {
		id: tally
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.rightMargin: -Arc.s2
		anchors.topMargin: -Arc.s1
		width: Math.max(13, count.implicitWidth + 7)
		height: 13
		visible: seat.badge !== ""
		scale: seat.badge !== "" ? 1 : 0

		Behavior on scale {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		Canvas {
			anchors.fill: parent
			renderStrategy: Canvas.Cooperative
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const c = height / 2;
				ctx.fillStyle = Arc.aether;
				ctx.beginPath();
				ctx.moveTo(c, 0);
				ctx.lineTo(width - c, 0);
				ctx.lineTo(width, c);
				ctx.lineTo(width - c, height);
				ctx.lineTo(c, height);
				ctx.lineTo(0, c);
				ctx.closePath();
				ctx.fill();
			}
		}

		ArcText {
			id: count
			anchors.centerIn: parent
			role: "mono"
			font.pixelSize: 9
			color: Arc.onAether
			text: seat.badge
		}
	}

	ArcTouch {
		id: touch
		lit: seat.lit
		onClicked: event => seat.clicked(event)
	}
}
