pragma ComponentBehavior: Bound

import QtQuick

// Somewhere to write. No box: the text sits on a ruled line, and taking the
// keyboard draws an ink line over the rule from the left at the speed a nib
// travels, with a blot where the nib was set down. Losing the keyboard lifts
// the nib and the line is taken back the way it came.
Item {
	id: field

	property alias text: input.text
	property alias placeholder: ghost.text
	property alias echoMode: input.echoMode
	property alias inputItem: input
	property bool clearOnAccept: false

	signal accepted(string value)
	signal edited(string value)

	implicitHeight: 30
	implicitWidth: 160

	function take() { input.forceActiveFocus(); }

	TextInput {
		id: input
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.bottomMargin: Arc.s2
		verticalAlignment: TextInput.AlignVCenter
		font.family: Arc.book
		font.pixelSize: Arc.sizeBody
		color: Arc.ink
		selectionColor: Qt.alpha(Arc.aether, 0.32)
		selectedTextColor: Arc.ink
		selectByMouse: true
		clip: true

		// The nib, not a block caret: a wedge that is wide where it touches the
		// line and narrow at the top, and that stops blinking while you write.
		cursorDelegate: Canvas {
			id: nib
			width: 4
			renderStrategy: Canvas.Cooperative

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				ctx.fillStyle = Arc.aether;
				ctx.beginPath();
				ctx.moveTo(width * 0.5, 0);
				ctx.lineTo(width, height - 2);
				ctx.lineTo(width * 0.5, height);
				ctx.lineTo(0, height - 2);
				ctx.closePath();
				ctx.fill();
			}

			SequentialAnimation on opacity {
				running: input.activeFocus
				loops: Animation.Infinite
				NumberAnimation { to: 0.25; duration: 520; easing.type: Easing.InOutSine }
				NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
			}
		}

		onTextChanged: field.edited(text)
		onAccepted: {
			field.accepted(text);
			if (field.clearOnAccept) text = "";
		}
	}

	ArcText {
		id: ghost
		anchors.left: input.left
		anchors.verticalCenter: input.verticalCenter
		role: "hand"
		tone: "faint"
		font.pixelSize: Arc.sizeBody
		visible: input.text === ""
	}

	// The rule the writing sits on.
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Arc.ruleThin
		color: Arc.giltFaint
	}

	// The ink line drawn over it while the field has the keyboard.
	Rectangle {
		id: stroke
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		width: input.activeFocus ? parent.width : 0
		height: Arc.rule
		color: Arc.aether

		Behavior on width {
			NumberAnimation {
				duration: Arc.draw
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveInk
			}
		}
	}

	// The blot where the nib was set down.
	Rectangle {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.bottomMargin: -1
		width: 3
		height: 3
		rotation: 45
		color: Arc.aether
		opacity: input.activeFocus ? 1 : 0

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}
	}
}
