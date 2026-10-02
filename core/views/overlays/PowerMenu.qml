pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Session menu. Lock fires on click; logout, reboot and shutdown must be
// held until the ring closes (Enter on the keyboard confirms instantly).
ModalWindow {
	id: root

	property int selection: 0
	property string userName: ""
	property string kernel: ""
	property string uptime: ""

	readonly property var actions: [
		{ id: "lock", label: Words.of("power.lock", "Lock"), icon: "lock", hold: false, shown: Plugins.on("lock-screen") },
		{ id: "logout", label: Words.of("power.logout", "Log out"), icon: "logout", hold: true },
		{ id: "reboot", label: Words.of("power.reboot", "Restart"), icon: "restart", hold: true },
		{ id: "shutdown", label: Words.of("power.shutdown", "Shut down"), icon: "power", hold: true }
	].filter(action => action.shown !== false)

	modalId: "power"
	scrimColor: Qt.rgba(0, 0, 0, 0.62)

	onModalOpened: {
		root.selection = 0;
		info.running = true;
	}

	Process {
		id: info
		command: ["sh", "-lc", `printf '%s|%s|%s' "$USER" "$(uname -r)" "$(uptime -p | sed 's/^up //')"`]
		stdout: StdioCollector {
			onStreamFinished: {
				const parts = String(text || "").split("|");
				root.userName = parts[0] || "";
				root.kernel = parts[1] || "";
				root.uptime = parts[2] || "";
			}
		}
	}

	Item {
		anchors.fill: parent
		focus: true

		Keys.onLeftPressed: root.selection = (root.selection + root.actions.length - 1) % root.actions.length
		Keys.onRightPressed: root.selection = (root.selection + 1) % root.actions.length
		Keys.onTabPressed: root.selection = (root.selection + 1) % root.actions.length
		Keys.onReturnPressed: Session.run(root.actions[root.selection].id)
		Keys.onEnterPressed: Session.run(root.actions[root.selection].id)

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 36

			ColumnLayout {
				Layout.alignment: Qt.AlignHCenter
				spacing: 4

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: root.userName !== "" ? `See you, ${root.userName}` : "Session"
					font.pixelSize: 34
					font.weight: Font.Bold
					tone: "white"
					surface: "transparent"
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: [root.uptime !== "" ? `up ${root.uptime}` : "", root.kernel].filter(v => v !== "").join("  ·  ")
					tone: Qt.rgba(1, 1, 1, 0.7)
					surface: "transparent"
					font.pixelSize: Theme.size.body
				}
			}

			Row {
				Layout.alignment: Qt.AlignHCenter
				spacing: 22

				Repeater {
					model: root.actions

					delegate: Item {
						id: action

						required property var modelData
						required property int index
						readonly property bool selected: root.selection === action.index
						property real hold: 0

						width: 128
						height: 156

						NumberAnimation {
							id: holdAnim

							target: action
							property: "hold"
							to: 1
							duration: 750 * (1 - action.hold)
							onFinished: if (action.hold >= 1) Session.run(action.modelData.id)
						}

						NumberAnimation {
							id: releaseAnim

							target: action
							property: "hold"
							to: 0
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}

						Item {
							id: disc

							width: 116
							height: 116
							anchors.horizontalCenter: parent.horizontalCenter
							y: action.selected ? -6 : 0

							Behavior on y {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Rectangle {
								anchors.fill: parent
								anchors.margins: 8
								radius: action.selected ? 30 : width / 2
								color: action.selected ? (action.modelData.id === "lock" ? Theme.primary : Theme.danger) : Theme.base
								scale: mouse.pressed ? 0.9 : 1

								Behavior on radius {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on color {
									ColorAnim {
										duration: Motion.medium
									}
								}
								Behavior on scale {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Glyph {
									anchors.centerIn: parent
									icon: action.modelData.icon
									size: 40
									color: action.selected ? (action.modelData.id === "lock" ? Theme.onPrimary : Theme.bg) : Theme.text
									spin: action.selected && action.modelData.id === "reboot" ? 360 : 0

									Behavior on spin {
										SpatialAnim {
											duration: Motion.extraLong
										}
									}
								}
							}

							Ring {
								anchors.fill: parent
								visible: action.hold > 0
								value: action.hold
								animated: false
								thickness: 5
								color: "white"
								trackColor: Qt.rgba(1, 1, 1, 0.15)
							}

							MouseArea {
								id: mouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onEntered: root.selection = action.index
								onPressed: {
									if (!action.modelData.hold) return;
									releaseAnim.stop();
									holdAnim.restart();
								}
								onReleased: {
									if (!action.modelData.hold) {
										if (containsMouse) Session.run(action.modelData.id);
										return;
									}
									if (action.hold < 1) {
										holdAnim.stop();
										releaseAnim.restart();
									}
								}
							}
						}

						ColumnLayout {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: parent.bottom
							spacing: 1

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: action.modelData.label
								tone: "white"
								surface: "transparent"
								font.pixelSize: Theme.size.title
								font.weight: action.selected ? Font.Bold : Font.Medium
							}

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: action.modelData.hold ? "hold" : "click"
								tone: Qt.rgba(1, 1, 1, action.selected ? 0.6 : 0)
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
								font.letterSpacing: 1.2
								font.capitalization: Font.AllUppercase
							}
						}
					}
				}
			}
		}
	}
}
