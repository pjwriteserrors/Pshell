import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A button that fires only when held: a fill runs across it while it is
// pressed and it fires when the fill is through; let go before and the
// fill springs back. A plain click wiggles it and says to hold. What starts
// a print or stops one is never one stray click away.
Rectangle {
	id: root

	property string text: ""
	property string holdText: "Keep holding…"
	property string icon: ""
	// the colour of the fill and of the label on it
	property color accent: Theme.primary
	property color onAccent: Theme.onPrimary
	// filled: the accent from the start (the fill lightens it); else tonal
	property bool filled: true
	property int hold: 700
	property bool busy: false
	readonly property bool holding: area.pressed && root.enabled && !root.busy
	readonly property real progress: fill.progress
	signal activated

	implicitHeight: 42
	implicitWidth: row.implicitWidth + 36
	radius: height / 2
	color: root.filled ? root.accent : Qt.alpha(root.accent, area.containsMouse ? 0.18 : 0.12)
	opacity: root.enabled ? 1 : 0.4
	scale: root.holding ? 0.97 : 1

	Behavior on scale {
		SpatialAnim {}
	}
	Behavior on color {
		ColorAnim {}
	}
	Behavior on opacity {
		Anim {}
	}

	// the fill, from the left
	Rectangle {
		id: fill

		property real progress: 0

		// a pill that grows from the left end
		width: root.height + (root.width - root.height) * fill.progress
		height: root.height
		radius: root.radius
		color: root.filled ? Qt.lighter(root.accent, 1.25) : root.accent
		opacity: Math.min(1, fill.progress * 8)

		NumberAnimation {
			id: charge

			target: fill
			property: "progress"
			to: 1
			duration: root.hold * (1 - fill.progress)
			easing.type: Easing.InQuad
			onFinished: if (fill.progress >= 1) root.fire()
		}

		SpringAnimation {
			id: release

			target: fill
			property: "progress"
			to: 0
			spring: 4
			damping: 0.35
			epsilon: 0.005
		}
	}

	// a flash when it fired
	Rectangle {
		id: flash

		anchors.fill: parent
		radius: root.radius
		color: "white"
		opacity: 0
	}

	SequentialAnimation {
		id: fired

		NumberAnimation {
			target: flash
			property: "opacity"
			from: 0.45
			to: 0
			duration: 420
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: fill
			property: "progress"
			to: 0
			duration: 260
		}
	}

	// a click is not enough: a little shake
	SequentialAnimation {
		id: wiggle

		NumberAnimation { target: nudge; property: "x"; to: -5; duration: 50 }
		NumberAnimation { target: nudge; property: "x"; to: 5; duration: 80 }
		NumberAnimation { target: nudge; property: "x"; to: -3; duration: 70 }
		NumberAnimation { target: nudge; property: "x"; to: 0; duration: 60 }
	}

	property bool hinted: false
	Timer {
		id: unhint

		interval: 1600
		onTriggered: root.hinted = false
	}

	function fire() {
		Sounds.play("click");
		fired.restart();
		root.activated();
	}

	transform: Translate {
		id: nudge
	}

	// the label twice: in the accent on the button, and over the fill on the
	// accent – a clip as wide as the fill shows the second one
	component Label: RowLayout {
		id: label

		property color tone: root.accent

		spacing: 8

		Spinner {
			visible: root.busy
			Layout.preferredWidth: 15
			Layout.preferredHeight: 15
			color: label.tone
		}

		Glyph {
			visible: root.icon !== "" && !root.busy
			icon: root.icon
			size: 16
			color: label.tone
			rotation: fill.progress * 360
		}

		StyledText {
			text: root.holding || root.hinted ? root.holdText : root.text
			tone: label.tone
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}
	}

	Label {
		id: row

		anchors.centerIn: parent
		tone: root.filled ? root.onAccent : root.accent
	}

	Item {
		width: fill.opacity > 0 ? fill.width : 0
		height: root.height
		clip: true
		visible: !root.filled

		Label {
			x: row.x
			y: row.y
			tone: root.onAccent
		}
	}

	MouseArea {
		id: area

		anchors.fill: parent
		hoverEnabled: true
		enabled: root.enabled && !root.busy
		cursorShape: Qt.PointingHandCursor
		onPressed: {
			release.stop();
			fired.stop();
			charge.restart();
		}
		onReleased: {
			if (fill.progress >= 1) return;
			charge.stop();
			if (fill.progress < 0.18) {
				root.hinted = true;
				unhint.restart();
				wiggle.restart();
			}
			release.restart();
		}
		onCanceled: {
			charge.stop();
			release.restart();
		}
	}
}
