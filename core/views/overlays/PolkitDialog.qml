pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A program asks for an administrator's password (Polkit): what it wants
// to do, who is asked, the password. Enter authenticates, Escape says no.
// It covers the focused screen and keeps the keyboard until it is answered.
PanelWindow {
	id: root

	readonly property var flow: Polkit.flow
	property real reveal: 0

	screen: Popups.focusedScreen()
	visible: true
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-polkit"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

	Component.onCompleted: {
		root.reveal = 1;
		Qt.callLater(() => password.focusInput());
	}

	Behavior on reveal {
		NumberAnimation {
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	// a wrong password: the field is emptied for the next try
	Connections {
		target: root.flow

		function onAuthenticationFailed() {
			password.text = "";
			Haptics.play("wrongPassword");
			shake.restart();
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.reveal
	}

	MouseArea {
		id: scrim

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: locked.visible ? Qt.BlankCursor : Qt.ArrowCursor
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: 440
		height: column.implicitHeight + 48
		radius: Theme.panelRadius
		color: Theme.base
		border.color: Theme.outline
		border.width: 1
		opacity: root.reveal
		scale: 0.94 + 0.06 * root.reveal

		HoverHandler {
			id: cardHover
		}

		transform: Translate {
			id: offset
		}

		SequentialAnimation {
			id: shake

			loops: 2
			NumberAnimation { target: offset; property: "x"; to: -10; duration: 45 }
			NumberAnimation { target: offset; property: "x"; to: 10; duration: 90 }
			NumberAnimation { target: offset; property: "x"; to: 0; duration: 45 }
		}

		ColumnLayout {
			id: column

			anchors.fill: parent
			anchors.margins: 24
			spacing: 14

			RowLayout {
				spacing: 12

				Glyph {
					icon: "shield_key"
					size: 30
					color: Theme.primary
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					StyledText {
						text: "Authentication required"
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					StyledText {
						Layout.fillWidth: true
						text: root.flow?.selectedIdentity?.displayName ? `as ${root.flow.selectedIdentity.displayName}` : (root.flow?.actionId ?? "")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.flow?.message ?? ""
				wrapMode: Text.Wrap
			}

			Field {
				id: password

				Layout.fillWidth: true
				password: !(root.flow?.responseVisible ?? false)
				clearable: false
				icon: "key_variant"
				placeholder: String(root.flow?.inputPrompt || "Password").replace(/:\s*$/, "")
				enabled: root.flow?.isResponseRequired ?? false
				onAccepted: Polkit.submit(password.text)
				onEscapePressed: Polkit.cancel()
			}

			StyledText {
				Layout.fillWidth: true
				visible: text !== ""
				text: root.flow?.supplementaryMessage ?? ""
				tone: root.flow?.supplementaryIsError ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.Wrap
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: Polkit.cancel()
				}

				TextButton {
					text: "Authenticate"
					variant: "filled"
					busy: !(root.flow?.isResponseRequired ?? true)
					onActivated: Polkit.submit(password.text)
				}
			}
		}
	}

	// beside the card the pointer carries a lock: nothing else is reachable
	// until this is answered
	PshellCursor {
		id: locked

		visible: scrim.containsMouse && !cardHover.hovered && CursorStyle.ready
		x: scrim.mouseX
		y: scrim.mouseY
		shape: "arrow"

		CursorBadge {
			icon: "lock"
			color: CursorStyle.danger
		}
	}
}
