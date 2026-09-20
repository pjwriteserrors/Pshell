pragma ComponentBehavior: Bound

import QtQuick

// Somewhere to speak.
//
// No box and no rule under it. What you are writing simply glows: a soft light
// sits behind the line while the field holds the keyboard, and the caret is a
// mote rather than a bar. Taking the keyboard draws a ley outwards from the
// middle in both directions, which is how a conjuring opens everywhere else.
Item {
	id: field

	property alias text: input.text
	property alias placeholder: ghost.text
	property alias echoMode: input.echoMode
	property alias inputItem: input
	property bool clearOnAccept: false

	signal accepted(string value)
	signal edited(string value)

	implicitHeight: 32
	implicitWidth: 160

	function take() { input.forceActiveFocus(); }

	ArcHalo {
		anchors.fill: parent
		anchors.margins: -10
		color: Arc.aether
		strength: 0.16
		spread: 0.5
		opacity: input.activeFocus ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
		}
	}

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

		// A mote for a caret, breathing rather than blinking.
		cursorDelegate: Item {
			width: 6

			Rectangle {
				anchors.centerIn: parent
				width: 5
				height: 5
				radius: 2.5
				color: Arc.aether

				SequentialAnimation on opacity {
					running: input.activeFocus
					loops: Animation.Infinite
					NumberAnimation { to: 0.3; duration: 620; easing.type: Easing.InOutSine }
					NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutSine }
				}
			}

			ArcHalo {
				anchors.centerIn: parent
				width: 26
				height: 26
				color: Arc.aether
				strength: 0.55
				spread: 0.32
				flicker: true
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

	// The ley, drawn outwards from the middle when the field is spoken into.
	Item {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Arc.rule

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			width: parent.width
			height: Arc.ruleThin
			color: Arc.goldGhost
		}

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
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
	}
}
