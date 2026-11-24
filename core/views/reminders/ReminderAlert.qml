pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A fullscreen reminder on one screen (Reminders.overlayOpen): only Done or a
// snooze close it. While the screen is shared it shows no content.
PanelWindow {
	id: root

	required property var modelData
	readonly property var alert: Reminders.screenAlerts[0] ?? null
	readonly property int more: Math.max(0, Reminders.screenAlerts.length - 1)
	readonly property bool hidden: Notifs.sharing
	readonly property bool focusedHere: String(Popups.focusedScreen()?.name ?? "") === String(root.modelData.name)
	property real reveal: 0

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-reminder"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.focusedHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

	Component.onCompleted: root.reveal = 1

	Behavior on reveal {
		Anim {
			duration: Motion.medium
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, 0.84)
		opacity: root.reveal
	}

	// clicks stop here
	MouseArea {
		anchors.fill: parent
	}

	Item {
		anchors.fill: parent
		focus: true
		opacity: root.reveal

		Keys.onPressed: event => {
			event.accepted = true;
			if (root.alert && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) Reminders.done(root.alert.uid);
		}

		ColumnLayout {
			anchors.centerIn: parent
			width: Math.min(parent.width - 64, 640)
			spacing: 22

			Rectangle {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 120
				Layout.preferredHeight: 120
				radius: 60
				color: Qt.alpha(root.alert?.escalated ? Theme.danger : Theme.primary, 0.16)

				SequentialAnimation on scale {
					running: root.visible
					loops: Animation.Infinite

					NumberAnimation {
						to: 1.08
						duration: 900
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						to: 1
						duration: 900
						easing.type: Easing.InOutSine
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: root.hidden ? "bell_ring_outline" : (root.alert?.icon || "bell_ring_outline")
					size: 56
					color: root.alert?.escalated ? Theme.danger : "white"
					surface: "transparent"
				}
			}

			StyledText {
				Layout.fillWidth: true
				horizontalAlignment: Text.AlignHCenter
				text: root.hidden ? "Reminder" : (root.alert?.title ?? "")
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.display
				font.weight: Font.DemiBold
				wrapMode: Text.Wrap
				maximumLineCount: 3
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				visible: !root.hidden && (root.alert?.body ?? "") !== ""
				horizontalAlignment: Text.AlignHCenter
				text: root.alert?.body ?? ""
				tone: Qt.rgba(1, 1, 1, 0.7)
				surface: "transparent"
				font.pixelSize: Theme.size.title
				wrapMode: Text.Wrap
				maximumLineCount: 4
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.more > 0
				horizontalAlignment: Text.AlignHCenter
				text: `+${root.more}`
				tone: Qt.rgba(1, 1, 1, 0.5)
				surface: "transparent"
				font.pixelSize: Theme.size.body
			}

			Flow {
				Layout.alignment: Qt.AlignHCenter
				Layout.maximumWidth: parent.width
				Layout.topMargin: 10
				spacing: 10

				Repeater {
					model: root.hidden ? [] : (root.alert?.actions ?? [])

					delegate: TextButton {
						required property var modelData

						text: modelData.label
						icon: modelData.icon ?? ""
						onActivated: {
							const uid = root.alert.uid;
							modelData.run();
							Reminders.drop(uid);
						}
					}
				}

				TextButton {
					text: "5 min"
					icon: "timer_outline"
					onActivated: Reminders.snooze(root.alert.uid, 5)
				}

				TextButton {
					text: "1 h"
					icon: "timer_outline"
					onActivated: Reminders.snooze(root.alert.uid, 60)
				}

				TextButton {
					text: "When back"
					icon: "lock_open_outline"
					onActivated: Reminders.snooze(root.alert.uid, "back")
				}

				TextButton {
					variant: "filled"
					text: "Done"
					icon: "check"
					onActivated: Reminders.done(root.alert.uid)
				}
			}
		}
	}
}
