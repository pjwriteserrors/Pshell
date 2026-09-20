pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A sigil: one of the shell's functions, standing in the void.
//
// At rest it is a mark and nothing else — no ring, no plate, no circle drawn
// round it. That absence is deliberate: a row of marks in circles is a row of
// buttons, and the sanctum has no buttons in it.
//
// Touched, it kindles: light comes up behind it, the mark warms to the live
// colour and its name writes itself beside it. Pressed, it throws a ring
// outward, once. While the thing it opens is open, a ring of runes is
// inscribed around it and turns slowly — the only sigil on the screen that is
// moving, so you can always see which one is answering.
Item {
	id: seat

	property string iconSource: ""
	property real iconSize: Math.round(size * 0.58)
	property color iconColor: seat.lit ? Arc.aether : Arc.ink
	property color ringColor: Arc.goldDim
	property color liveColor: Arc.aether
	property real size: Arc.sigilSize
	property bool lit: false
	property int seed: 0
	property real progress: -1
	property string badge: ""
	// The name that writes itself under the mark when it is touched. Empty
	// means the mark is its own explanation.
	property string label: ""
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons

	default property alias inner: content.data

	signal clicked(var event)

	implicitWidth: size
	implicitHeight: size

	readonly property real live: Math.max(touch.live, seat.lit ? 0.9 : 0)

	ArcHalo {
		anchors.centerIn: parent
		width: seat.size * 2.6
		height: seat.size * 2.6
		color: seat.liveColor
		strength: 0.36
		spread: 0.32
		flicker: true
		opacity: seat.live
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}
	}

	// The ring, inscribed only while this sigil's panel is open.
	ArcDial {
		id: warding
		anchors.centerIn: parent
		width: seat.size * 1.55
		height: seat.size * 1.55
		lineColor: Qt.alpha(seat.liveColor, 0.55)
		liveColor: seat.liveColor
		weight: Arc.ruleThin
		seed: seat.seed
		beading: false
		progress: seat.progress
		visible: seat.lit || warding.drawn > 0.01
		drawn: seat.lit ? 1 : 0

		Behavior on drawn {
			NumberAnimation {
				duration: seat.lit ? Arc.draw : Arc.recoil
				easing.type: Easing.Bezier
				easing.bezierCurve: seat.lit ? Arc.curveInk : Arc.curveSink
			}
		}

		RotationAnimation on rotation {
			running: seat.lit
			loops: Animation.Infinite
			from: 0
			to: 360
			duration: 26000
		}
	}

	// The shock a press sends out. One ring, once, and gone.
	Rectangle {
		id: shock
		anchors.centerIn: parent
		width: seat.size * 1.2
		height: width
		radius: width / 2
		color: "transparent"
		border.width: Arc.rule
		border.color: seat.liveColor
		opacity: 0
		scale: 1

		ParallelAnimation {
			id: shockwave
			NumberAnimation { target: shock; property: "scale"; from: 0.5; to: 2.4; duration: 520; easing.type: Easing.OutCubic }
			SequentialAnimation {
				NumberAnimation { target: shock; property: "opacity"; to: 0.75; duration: 60 }
				NumberAnimation { target: shock; property: "opacity"; to: 0; duration: 460; easing.type: Easing.OutCubic }
			}
		}

		Connections {
			target: touch
			function onPressed() { shockwave.restart(); }
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
			color: seat.live > 0.25 ? seat.liveColor : seat.iconColor

			Behavior on color {
				ColorAnimation { duration: Arc.tick }
			}
		}
	}

	// The name, written under the mark while it is touched. It is not a
	// tooltip: it is on the same plane as everything else and it belongs to
	// the sigil, so it arrives by being written rather than by popping up.
	ArcText {
		id: naming
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: parent.bottom
		anchors.topMargin: 2
		role: "label"
		tone: "aether"
		font.pixelSize: 9
		text: seat.label
		visible: seat.label !== ""
		opacity: touch.containsMouse ? 1 : 0

		transform: Translate {
			y: touch.containsMouse ? 0 : -4

			Behavior on y {
				NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSnap }
			}
		}

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}
	}

	// A count is a mote with a number in it, set off the mark.
	Item {
		id: tally
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.rightMargin: -6
		anchors.topMargin: -4
		width: Math.max(14, count.implicitWidth + 6)
		height: 14
		visible: seat.badge !== ""
		scale: seat.badge !== "" ? 1 : 0

		Behavior on scale {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveSnap
			}
		}

		ArcHalo {
			anchors.centerIn: parent
			width: 34
			height: 34
			color: Arc.aether
			strength: 0.5
			spread: 0.3
			flicker: true
		}

		ArcText {
			id: count
			anchors.centerIn: parent
			role: "mono"
			font.pixelSize: 9
			color: Arc.aether
			text: seat.badge
		}
	}

	ArcTouch {
		id: touch
		lit: seat.lit
		onClicked: event => seat.clicked(event)
	}
}
