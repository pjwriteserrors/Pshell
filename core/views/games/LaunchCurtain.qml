pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A game being started: its cover flies from the shelf to the middle, rings
// of the accent go out from it while it starts, a burst when it did. A
// launch that failed shakes the cover and says why.
Item {
	id: root

	property var game: null
	// "" | "starting" | "started" | "failed"
	property string phase: ""
	property string via: ""
	property string error: ""
	// where the cover starts from, in this item's coordinates
	property rect from: Qt.rect(0, 0, 0, 0)

	readonly property bool up: root.phase !== ""
	property real fly: 0
	property real burst: 0
	property real shake: 0

	signal retry
	signal back

	function begin(game, from) {
		root.game = game;
		root.from = from;
		root.via = "";
		root.error = "";
		root.burst = 0;
		root.phase = "starting";
		flying.restart();
	}

	function succeed(via) {
		root.via = via;
		root.phase = "started";
		bursting.restart();
	}

	function failWith(message) {
		root.error = message;
		root.phase = "failed";
		shaking.restart();
	}

	function reset() {
		root.phase = "";
		root.fly = 0;
	}

	anchors.fill: parent
	visible: veil.opacity > 0.01
	z: 60

	NumberAnimation {
		id: flying

		target: root
		property: "fly"
		from: 0
		to: 1
		duration: 620
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.spatial
	}

	NumberAnimation {
		id: bursting

		target: root
		property: "burst"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	SequentialAnimation {
		id: shaking

		NumberAnimation {
			target: root
			property: "shake"
			to: 1
			duration: 60
		}
		NumberAnimation {
			target: root
			property: "shake"
			to: -1
			duration: 90
		}
		NumberAnimation {
			target: root
			property: "shake"
			to: 0.6
			duration: 80
		}
		NumberAnimation {
			target: root
			property: "shake"
			to: -0.3
			duration: 70
		}
		NumberAnimation {
			target: root
			property: "shake"
			to: 0
			duration: 60
		}
	}

	Rectangle {
		id: veil

		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, 0.72)
		opacity: root.up ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		MouseArea {
			anchors.fill: parent
			enabled: root.up
		}
	}

	// the cover's own picture, large and soft, behind it
	Image {
		anchors.fill: parent
		source: root.game?.art?.hero ? `file://${root.game.art.hero}` : ""
		sourceSize: Qt.size(Math.ceil(Math.max(width, height)), Math.ceil(Math.max(width, height)))
		fillMode: Image.PreserveAspectCrop
		asynchronous: true
		opacity: (root.up ? 0.35 : 0) * root.fly
		scale: 1.15 - 0.1 * root.fly + 0.05 * root.burst
	}

	readonly property real coverW: 260
	readonly property real coverH: 390
	readonly property real centerX: root.width / 2
	readonly property real centerY: root.height / 2 - 60

	// rings that go out while it starts
	Repeater {
		model: 3

		delegate: Rectangle {
			id: ring

			required property int index
			property real grow: 0

			x: root.centerX - width / 2
			y: root.centerY - height / 2
			width: 280 + 520 * ring.grow
			height: width
			radius: width / 2
			color: "transparent"
			border.width: 3
			border.color: root.phase === "failed" ? Theme.danger : Theme.primary
			opacity: (1 - ring.grow) * 0.7 * root.fly * (root.phase === "starting" ? 1 : 0)
			visible: root.up

			SequentialAnimation on grow {
				running: root.phase === "starting"
				loops: Animation.Infinite

				PauseAnimation {
					duration: ring.index * 500
				}
				NumberAnimation {
					from: 0
					to: 1
					duration: 1500
					easing.type: Easing.OutCubic
				}
			}
		}
	}

	// the burst once it started
	Rectangle {
		x: root.centerX - width / 2
		y: root.centerY - height / 2
		width: 260 + 1400 * root.burst
		height: width
		radius: width / 2
		color: "transparent"
		border.width: 40 * (1 - root.burst) + 2
		border.color: Theme.primary
		opacity: (1 - root.burst) * (root.phase === "started" ? 0.8 : 0)
	}

	// ── the cover ──────────────────────────────────────────────────────────
	Item {
		id: flyer

		readonly property real startScale: root.from.width > 0 ? root.from.width / root.coverW : 0.6

		x: (root.from.x + root.from.width / 2) * (1 - root.fly) + root.centerX * root.fly - root.coverW / 2 + root.shake * 18
		y: (root.from.y + root.from.height / 2) * (1 - root.fly) + root.centerY * root.fly - root.coverH / 2
		width: root.coverW
		height: root.coverH
		scale: (flyer.startScale + (1 - flyer.startScale) * root.fly) * (1 + 0.06 * Math.sin(root.burst * Math.PI))
		visible: root.up

		RectangularShadow {
			anchors.fill: parent
			radius: Theme.radius.huge
			blur: 70
			spread: 4
			offset.y: 20
			color: Qt.alpha(root.phase === "failed" ? Theme.danger : Theme.primary, 0.6)
		}

		CoverArt {
			id: cover

			anchors.fill: parent
			game: root.game
			radius: Theme.radius.huge
			sheen: 0.4
			light: Qt.point(-1 + 2 * root.burst, -1)
		}

		// it breathes while it starts
		SequentialAnimation on rotation {
			running: root.phase === "starting"
			loops: Animation.Infinite
			onRunningChanged: if (!running) flyer.rotation = 0

			NumberAnimation {
				to: 1.5
				duration: 900
				easing.type: Easing.InOutSine
			}
			NumberAnimation {
				to: -1.5
				duration: 900
				easing.type: Easing.InOutSine
			}
		}
	}

	// ── what happens ───────────────────────────────────────────────────────
	ColumnLayout {
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.centerY + root.coverH / 2 + 36
		width: Math.min(parent.width - 80, 720)
		spacing: 8
		opacity: root.fly
		visible: root.up

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: root.phase === "failed" ? "Did not start" : (root.phase === "started" ? "Have fun" : "Starting")
			tone: root.phase === "failed" ? Theme.danger : Theme.primary
			surface: "transparent"
			font.pixelSize: Theme.size.small
			font.weight: Font.Black
			font.letterSpacing: 2.4
			font.capitalization: Font.AllUppercase
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			Layout.maximumWidth: parent.width
			text: root.game?.name ?? ""
			tone: "white"
			surface: "transparent"
			elide: Text.ElideRight
			font.pixelSize: 38
			font.weight: Font.Black
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			Layout.maximumWidth: parent.width
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.WordWrap
			text: root.phase === "failed" ? root.error : (root.via !== "" ? `with ${root.via}` : " ")
			tone: root.phase === "failed" ? Qt.rgba(1, 1, 1, 0.8) : Qt.rgba(1, 1, 1, 0.6)
			surface: "transparent"
			font.pixelSize: Theme.size.title
		}

		RowLayout {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 14
			visible: root.phase === "failed"
			spacing: 10

			TextButton {
				variant: "ghost"
				text: "Back"
				icon: "arrow_left"
				onClicked: root.back()
			}

			TextButton {
				variant: "filled"
				text: "Try again"
				icon: "refresh"
				onClicked: root.retry()
			}
		}
	}
}
