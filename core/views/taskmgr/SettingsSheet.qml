pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the task manager shows and when it speaks up, over the window.
Item {
	id: root

	property bool shown: false
	visible: scrim.opacity > 0.01

	Keys.onEscapePressed: root.shown = false

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.shown ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.shown = false
		}
	}

	Rectangle {
		id: sheet

		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.margins: 12
		width: Math.min(420, parent.width - 24)
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		transform: Translate {
			x: root.shown ? 0 : sheet.width + 24

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		Flickable {
			anchors.fill: parent
			contentHeight: body.implicitHeight + 40
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: body

				x: 22
				y: 20
				width: parent.width - 44
				spacing: 10

				RowLayout {
					Layout.fillWidth: true

					StyledText {
						Layout.fillWidth: true
						text: "Task manager"
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}

					IconButton {
						icon: "close"
						onClicked: root.shown = false
					}
				}

				SectionLabel {
					Layout.topMargin: 8
					text: "Columns"
				}

				Repeater {
					model: [["cpu", "CPU"], ["mem", "Memory"], ["io", "Disk"], ["gpu", "GPU"]]

					Switch_ {
						required property var modelData

						label: modelData[1]
						checked: TaskManager.settings.columns?.[modelData[0]] !== false
						onToggled: on => TaskManager.setSetting("columns", Object.assign({}, TaskManager.settings.columns, { [modelData[0]]: on }))
					}
				}

				Switch_ {
					label: "Kernel threads"
					checked: TaskManager.showKernel
					onToggled: on => {
						TaskManager.showKernel = on;
						TaskManager.saveSettings();
					}
				}

				SectionLabel {
					Layout.topMargin: 12
					text: "Tell me when"
					visible: Plugins.on("task-manager-alerts")
				}

				Repeater {
					model: Plugins.on("task-manager-alerts") ? [
						["leak", "An app keeps taking memory"],
						["busy", "Something keeps a core busy in the background"],
						["heat", "The processor gets too hot"],
						["memory", "Memory runs out"],
						["oom", "Something was ended for lack of memory"]
					] : []

					Switch_ {
						required property var modelData

						label: modelData[1]
						checked: TaskManager.settings.alerts?.[modelData[0]] !== false
						onToggled: on => TaskManager.setSetting("alerts", Object.assign({}, TaskManager.settings.alerts, { [modelData[0]]: on }))
					}
				}

				SectionLabel {
					Layout.topMargin: 12
					text: "Offers"
				}

				Switch_ {
					visible: Plugins.on("game-mode")
					label: "Pause background work while playing"
					checked: TaskManager.settings.gameOffer !== false
					onToggled: on => TaskManager.setSetting("gameOffer", on)
				}

				Switch_ {
					visible: Plugins.on("power-profiles")
					label: "Performance profile under long load"
					checked: TaskManager.settings.powerOffer !== false
					onToggled: on => TaskManager.setSetting("powerOffer", on)
				}

				Switch_ {
					visible: Plugins.on("agents")
					label: "Servers an agent left running"
					checked: TaskManager.settings.agentPorts !== false
					onToggled: on => TaskManager.setSetting("agentPorts", on)
				}

				Switch_ {
					visible: Plugins.on("keep-awake")
					label: "Stay awake while a watched process runs"
					checked: TaskManager.settings.keepAwake !== false
					onToggled: on => TaskManager.setSetting("keepAwake", on)
				}

				SectionLabel {
					Layout.topMargin: 12
					text: "History"
				}

				Switch_ {
					label: "Keep the day's history"
					checked: TaskManager.settings.background !== false
					onToggled: on => TaskManager.setSetting("background", on)
				}

				SectionLabel {
					Layout.topMargin: 12
					text: "Not again"
					visible: (TaskManager.settings.ignore ?? []).length > 0
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: TaskManager.settings.ignore ?? []

						Chip {
							required property string modelData

							text: modelData.replace(/^[a-z]+:/, "")
							icon: "close"
							onClicked: TaskManager.setSetting("ignore", (TaskManager.settings.ignore ?? []).filter(key => key !== modelData))
						}
					}
				}
			}
		}
	}

	component Switch_: RowLayout {
		id: row

		property string label
		property bool checked
		signal toggled(bool on)

		Layout.fillWidth: true
		spacing: 12

		StyledText {
			Layout.fillWidth: true
			text: row.label
			wrapMode: Text.WordWrap
		}

		Toggle {
			checked: row.checked
			onToggled: on => row.toggled(on)
		}
	}
}
