import QtQuick
import qs.style.theme

// Single-line input. Focus lights the leading glyph and draws an accent
// ring; the placeholder drifts away as you type; a clear button pops in.
Rectangle {
	id: root

	property alias text: input.text
	property alias input: input
	property string placeholder: ""
	property string icon: ""
	property bool password: false
	property bool clearable: true
	property int fontSize: Theme.size.body
	readonly property bool focused: input.activeFocus

	signal accepted
	signal edited(string text)
	signal escapePressed
	signal upPressed
	signal downPressed
	signal tabPressed
	signal deletePressed

	function focusInput() {
		input.forceActiveFocus();
	}

	implicitHeight: 40
	implicitWidth: 240
	radius: Math.min(Theme.radius.large, height / 2)
	color: root.focused ? Theme.layer2 : Theme.layer1
	border.width: root.focused ? 1.5 : 0
	border.color: Qt.alpha(Theme.primary, 0.85)

	Behavior on color {
		ColorAnim {}
	}

	Glyph {
		id: lead

		visible: root.icon !== ""
		x: 13
		anchors.verticalCenter: parent.verticalCenter
		icon: root.icon
		size: 17
		color: root.focused ? Theme.primary : Theme.textSubtle
		scale: root.focused ? 1.08 : 1

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	TextInput {
		id: input

		anchors.left: parent.left
		anchors.leftMargin: root.icon !== "" ? 40 : 14
		anchors.right: clear.left
		anchors.rightMargin: 6
		anchors.verticalCenter: parent.verticalCenter
		color: Theme.text
		selectionColor: Qt.alpha(Theme.primary, 0.4)
		selectedTextColor: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: root.fontSize
		echoMode: root.password ? TextInput.Password : TextInput.Normal
		passwordCharacter: "•"
		selectByMouse: true
		clip: true

		onTextEdited: root.edited(text)
		onAccepted: root.accepted()
		Keys.onEscapePressed: event => {
			root.escapePressed();
			event.accepted = false;
		}
		Keys.onUpPressed: root.upPressed()
		Keys.onDownPressed: root.downPressed()
		Keys.onDeletePressed: event => {
			if (input.text.length === 0) root.deletePressed();
			else event.accepted = false;
		}
		Keys.onTabPressed: event => {
			root.tabPressed();
			event.accepted = false;
		}

		StyledText {
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width
			text: root.placeholder
			tone: Theme.textSubtle
			font.pixelSize: root.fontSize
			opacity: input.text.length === 0 ? 1 : 0
			x: input.text.length === 0 ? 0 : 18

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
			Behavior on x {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}
	}

	IconButton {
		id: clear

		anchors.right: parent.right
		anchors.rightMargin: 6
		anchors.verticalCenter: parent.verticalCenter
		width: visible ? 26 : 0
		height: 26
		visible: root.clearable
		icon: "close"
		iconSize: 14
		scale: input.text.length > 0 ? 1 : 0
		opacity: input.text.length > 0 ? 1 : 0
		onClicked: {
			input.text = "";
			root.edited("");
			input.forceActiveFocus();
		}

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		z: -1
		cursorShape: Qt.IBeamCursor
		onClicked: input.forceActiveFocus()
	}
}
