pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One entry of a day: checkbox (queue for Teamwork), description, rounded
// time span and duration. A click opens it to edit description, ticket,
// start and end (in quarter hours) and the billable state. What is in
// Teamwork already keeps its description, ticket and billable state.
Rectangle {
	id: root

	required property string entryKey
	required property var board

	readonly property string key: root.entryKey
	readonly property var entry: Tracking.entries.find(entry => Tracking.key(entry) === root.entryKey) ?? ({})
	readonly property bool pending: Tracking.isPending(root.key)
	readonly property bool running: root.entry.is_running === true
	readonly property bool synced: root.entry.teamwork_synced === true
	readonly property bool open: root.running ? root.board.closedRunning[root.key] !== true : root.board.opened[root.key] === true

	// an entry that is open when its row is made does not grow into it
	property bool ready: false

	Component.onCompleted: Qt.callLater(() => root.ready = true)

	implicitHeight: column.implicitHeight
	radius: Theme.radius.medium
	color: root.open ? Theme.base : "transparent"
	border.width: root.open ? 1 : 0
	border.color: Theme.outline
	opacity: root.pending ? 0.55 : 1
	enabled: !root.pending

	Behavior on color {
		ColorAnim {
			duration: Motion.medium
		}
	}
	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	// a row that is new comes in softly
	NumberAnimation on opacity {
		from: 0
		to: root.pending ? 0.55 : 1
		duration: Motion.medium
	}

	component Tag: Rectangle {
		id: tag

		property string text: ""
		property color tone: Theme.textMuted
		property bool shown: false

		implicitHeight: 18
		implicitWidth: tagLabel.implicitWidth + 14
		radius: 9
		color: Qt.alpha(tone, 0.14)
		visible: tag.scale > 0.01
		scale: tag.shown ? 1 : 0

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		StyledText {
			id: tagLabel

			anchors.centerIn: parent
			text: tag.text
			tone: tag.tone
			font.pixelSize: Theme.size.tiny
			font.weight: Font.DemiBold
		}
	}

	component Stepper: Rectangle {
		id: stepper

		required property var entry
		required property string edge
		readonly property string label: stepper.edge === "start" ? "Start" : "End"
		readonly property string time: stepper.edge === "start"
			? String(stepper.entry.rounded_started_label || stepper.entry.first_started_label || "--")
			: String(stepper.entry.rounded_ended_label || stepper.entry.last_ended_label || "--")
		readonly property bool shifted: Number(stepper.entry[`manual_time_${stepper.edge}_offset_minutes`] || 0) !== 0

		implicitHeight: 40
		implicitWidth: stepperRow.implicitWidth + 8
		radius: Theme.radius.medium
		color: Theme.layer1

		RowLayout {
			id: stepperRow

			anchors.centerIn: parent
			spacing: 2

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "minus"
				onClicked: Tracking.shift(stepper.entry, stepper.edge, -15)
			}

			ColumnLayout {
				Layout.minimumWidth: 52
				spacing: 0

				SectionLabel {
					Layout.alignment: Qt.AlignHCenter
					text: stepper.label
				}

				StyledText {
					id: clock

					Layout.alignment: Qt.AlignHCenter
					text: stepper.time
					onTextChanged: bump.restart()

					SequentialAnimation {
						id: bump

						Anim { target: clock; property: "scale"; to: 1.22; duration: Motion.micro }
						SpatialAnim { target: clock; property: "scale"; to: 1; duration: Motion.medium }
					}
					tone: stepper.shifted ? Theme.primary : Theme.text
					tabular: true
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}
			}

			IconButton {
				implicitWidth: 28
				implicitHeight: 28
				icon: "plus"
				onClicked: Tracking.shift(stepper.entry, stepper.edge, 15)
			}
		}
	}

	ColumnLayout {
		id: column

		width: parent.width
		spacing: 0

		Clickable {
			id: line

			Layout.fillWidth: true
			implicitHeight: 42
			radius: Theme.radius.medium
			pressedScale: 0.99
			color: line.hovered && !root.open ? Theme.layer2 : "transparent"
			onClicked: root.board.flip(root.running ? "closedRunning" : "opened", root.key)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 8
				anchors.rightMargin: 12
				spacing: 10

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: root.entry.checked ? "checkbox_marked" : "checkbox_blank_outline"
					iconSize: 19
					iconColor: root.entry.checked ? Theme.primary : Theme.textSubtle
					onClicked: Tracking.toggle(root.entry)
				}

				StyledText {
					Layout.fillWidth: true
					text: String(root.entry.description || "No description")
					tone: root.open ? Theme.text : Theme.textMuted
					font.weight: root.open ? Font.DemiBold : Font.Normal
				}

				Tag {
					shown: root.running
					text: "running"
					tone: Theme.primary
				}

				Tag {
					shown: root.synced
					text: "sent"
					tone: Theme.success
				}

				StyledText {
					text: `${root.entry.rounded_started_label || root.entry.first_started_label || "--"} – ${root.entry.rounded_ended_label || root.entry.last_ended_label || "--"}`
					tone: Theme.textSubtle
					tabular: true
					font.pixelSize: Theme.size.label
				}

				StyledText {
					Layout.minimumWidth: 58
					horizontalAlignment: Text.AlignRight
					id: length

					text: Tracking.formatMinutes(Tracking.entryMinutes(root.entry))
					tone: Theme.textMuted
					tabular: true
					font.weight: Font.DemiBold
					transformOrigin: Item.Right
					onTextChanged: lengthBump.restart()

					SequentialAnimation {
						id: lengthBump

						Anim { target: length; property: "scale"; to: 1.18; duration: Motion.micro }
						SpatialAnim { target: length; property: "scale"; to: 1; duration: Motion.medium }
					}
				}
			}
		}

		// what opens: it grows out of the line and folds back into it
		Item {
			id: detail

			property real shown: root.open ? editor.implicitHeight + 14 : 0

			Layout.fillWidth: true
			Layout.preferredHeight: detail.shown
			visible: detail.shown > 0.5
			clip: true

			Behavior on shown {
				enabled: root.ready

				SpatialAnim {
					duration: root.open ? Motion.long : Motion.medium
				}
			}

		Loader {
			id: editor

			x: 48
			width: parent.width - 62
			active: root.open || detail.shown > 0.5
			opacity: root.open ? 1 : 0

			Behavior on opacity {
				enabled: root.ready

				Anim {
					duration: root.open ? Motion.long : Motion.short
				}
			}

			sourceComponent: ColumnLayout {
				spacing: 12

				Rectangle {
					Layout.fillWidth: true
					implicitHeight: 1
					color: Theme.outline
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 5

					SectionLabel {
						text: "Description"
					}

					Field {
						id: description

						Layout.fillWidth: true
						clearable: false
						enabled: !root.synced
						opacity: enabled ? 1 : 0.6
						placeholder: "What did you work on?"
						text: String(root.entry.description || "")
						onAccepted: {
							root.board.follow(root.entry, root.entry.project, description.text.trim());
							Tracking.describe(root.entry, description.text);
						}
						onEscapePressed: description.text = String(root.entry.description || "")
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 5

					SectionLabel {
						text: "Teamwork ticket"
					}

					TicketPicker {
						Layout.fillWidth: true
						entry: root.entry
						enabled: !root.synced
						onPicked: task => {
							if (task.project_name && task.task_name) root.board.follow(root.entry, `${task.project_name} / ${task.task_name}`, root.entry.description);
							Tracking.assign(root.entry, task);
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Stepper {
						entry: root.entry
						edge: "start"
					}

					Stepper {
						entry: root.entry
						edge: "end"
					}

					Toggle {
						Layout.leftMargin: 8
						enabled: !root.synced
						checked: root.entry.teamwork_billable !== false
						onToggled: checked => Tracking.setBillable(root.entry, checked)
					}

					StyledText {
						text: "Billable"
						tone: root.synced ? Theme.textSubtle : Theme.text
						font.pixelSize: Theme.size.label
					}

					StyledText {
						Layout.fillWidth: true
						horizontalAlignment: Text.AlignRight
						text: `Actual ${root.entry.duration_label || "--"} · ${root.entry.range_label || "--"}`
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					TextButton {
						icon: "trash_can_outline"
						text: "Delete"
						variant: "danger"
						confirm: true
						onActivated: Tracking.remove(root.entry)
					}
				}
			}
		}
		}
	}
}
