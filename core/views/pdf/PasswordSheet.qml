pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A locked PDF asks for its password here: the file itself (Pdf.locked) or
// one being put into it (Pdf.passwordWanted). A wrong one shakes the field.
Item {
	id: root

	// "" for the open file, else the path of one asked for
	property string asking: ""
	property bool asked: false
	readonly property bool open: root.asked || (Pdf.locked && Pdf.current)
	signal done()

	function ask(path) {
		root.asking = path;
		root.asked = true;
		field.text = "";
		field.input.forceActiveFocus();
	}

	function submit() {
		if (field.text === "") return;
		if (root.asked) {
			Pdf.answerPassword(root.asking, field.text);
			root.asked = false;
			root.asking = "";
		} else Pdf.unlockWith(field.text);
		field.text = "";
		root.done();
	}

	function cancel() {
		if (root.asked) {
			Pdf.answerPassword(root.asking, "");
			root.asked = false;
		} else Pdf.close();
		root.done();
	}

	visible: scrim.opacity > 0.01
	onOpenChanged: if (root.open) field.input.forceActiveFocus()

	Connections {
		target: Pdf

		function onWrongPasswordChanged() {
			if (Pdf.wrongPassword) shake.restart();
		}
	}

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: Math.min(parent.width - 32, 380)
		height: column.implicitHeight + 40
		radius: Theme.radius.huge
		color: Theme.bg
		border.color: Theme.outline
		opacity: root.open ? 1 : 0
		scale: root.open ? 1 : 0.94

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		Column {
			id: column

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 20
			spacing: 12

			Glyph {
				anchors.horizontalCenter: parent.horizontalCenter
				icon: "lock_outline"
				size: 36
				color: Theme.primary
			}

			StyledText {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				wrapMode: Text.WordWrap
				text: `${Pdf.nameOf(root.asked ? root.asking : Pdf.path)} is locked`
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				text: !root.asked && Pdf.wrongPassword ? "That was not it – try again" : "Its password opens it"
				tone: !root.asked && Pdf.wrongPassword ? Theme.danger : Theme.textMuted
			}

			Field {
				id: field

				width: parent.width
				height: 40
				password: true
				icon: "key_outline"
				placeholder: "Password"
				onAccepted: root.submit()
				onEscapePressed: root.cancel()

				transform: Translate {
					id: shakeX
				}

				SequentialAnimation {
					id: shake

					loops: 2
					NumberAnimation {
						target: shakeX
						property: "x"
						to: -8
						duration: 50
					}
					NumberAnimation {
						target: shakeX
						property: "x"
						to: 8
						duration: 90
					}
					NumberAnimation {
						target: shakeX
						property: "x"
						to: 0
						duration: 50
					}
				}
			}

			Row {
				anchors.right: parent.right
				spacing: 8

				TextButton {
					text: root.asked ? "Leave it" : "Close"
					variant: "ghost"
					onActivated: root.cancel()
				}
				TextButton {
					text: "Open"
					icon: "lock_open_outline"
					variant: "filled"
					enabled: field.text !== ""
					onActivated: root.submit()
				}
			}
		}
	}
}
