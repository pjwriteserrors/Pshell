pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A node: one organ of the column. A grown ring, an icon inside it, and a halo
// that comes up when it is live. Everything on the spine that can be pressed is
// one of these, which is why the column reads as a colony rather than a
// toolbar.
//
// Touched, an organ twitches: it turns a few degrees against its own ring and
// swells, and settles back when you leave it. Nothing here slides or fades on
// its own — live things move by contracting.
Item {
	id: node

	property string iconSource: ""
	property real iconSize: Math.round(size * 0.46)
	property color iconColor: node.lit ? Bio.organ : Bio.text
	property color ringColor: Bio.boneDim
	property color liveColor: Bio.organ
	property real size: Bio.nodeSize
	property bool lit: false          // the popup this node owns is open
	property int seed: 0
	property real progress: -1
	property string badge: ""
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons

	default property alias inner: content.data

	signal clicked(var event)

	implicitWidth: size
	implicitHeight: size

	// The twitch. The whole node turns, so the ring's own asymmetry is what
	// reads as movement rather than a scale on a circle.
	transform: [
		Rotation {
			origin.x: node.width / 2
			origin.y: node.height / 2
			angle: touch.live * (node.seed % 2 === 0 ? 6 : -6)

			Behavior on angle {
				NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
			}
		},
		Scale {
			origin.x: node.width / 2
			origin.y: node.height / 2
			xScale: 1 + touch.live * 0.08
			yScale: 1 + touch.live * 0.08

			Behavior on xScale {
				NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
			}
			Behavior on yScale {
				NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
			}
		}
	]

	BioGlow {
		anchors.centerIn: parent
		width: node.size * 2.1
		height: node.size * 2.1
		color: node.liveColor
		strength: 0.30
		spread: 0.34
		opacity: touch.live
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}
	}

	BioRing {
		id: ring
		anchors.fill: parent
		lineColor: node.ringColor
		liveColor: node.liveColor
		intensity: touch.live
		seed: node.seed
		progress: node.progress
	}

	Item {
		id: content
		anchors.fill: parent

		QQCImpl.IconImage {
			anchors.centerIn: parent
			width: node.iconSize
			height: node.iconSize
			visible: node.iconSource !== ""
			source: node.iconSource
			sourceSize: Qt.size(width, height)
			color: node.iconColor

			Behavior on color {
				ColorAnimation { duration: Bio.twitch }
			}
		}
	}

	// A count sits on the node like a growth, not like a chip.
	Item {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.rightMargin: -Bio.s2
		anchors.topMargin: -Bio.s1
		width: Math.max(12, count.implicitWidth + 6)
		height: 12
		visible: node.badge !== ""
		scale: node.badge !== "" ? 1 : 0

		Behavior on scale {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack }
		}

		Canvas {
			anchors.fill: parent
			renderStrategy: Canvas.Cooperative
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				ctx.fillStyle = Bio.organ;
				ctx.beginPath();
				ctx.ellipse(0, 0, width, height);
				ctx.fill();
			}
		}

		BioText {
			id: count
			anchors.centerIn: parent
			role: "mono"
			font.pixelSize: 8
			color: Bio.onOrgan
			text: node.badge
		}
	}

	BioTouch {
		id: touch
		lit: node.lit
		onClicked: event => node.clicked(event)
	}
}
