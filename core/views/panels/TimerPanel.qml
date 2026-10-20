pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// qtrack. The hero shows the running clock inside a ring that fills over the
// 8h of a day and a morphing play/pause button. Below: resume one of today's tasks
// or pick a Teamwork task from an inline, searchable list and start fresh.
Drawer {
	id: root

	property string tab: "new"
	property string search: ""

	panelId: "timer"
	panelWidth: 470
	contentHeight: layout.implicitHeight

	readonly property var todayTasks: Array.isArray(QtrackTimer.todayTasks) ? QtrackTimer.todayTasks : []
	readonly property var teamwork: (Array.isArray(QtrackTimer.teamworkTasks) ? QtrackTimer.teamworkTasks : []).filter(task => root.matches(task, root.search))
	readonly property bool hasSelectedToday: QtrackTimer.findTodayTaskByKey(QtrackTimer.selectedTodayTaskKey) !== null
	readonly property bool canPrimary: QtrackTimer.tracking || QtrackTimer.canResume || root.hasSelectedToday || QtrackTimer.canStart

	function label(task) {
		return String(task.label || task.task_name || task.name || "Teamwork task");
	}

	function heading(task) {
		const parts = root.label(task).split("/").map(part => part.trim()).filter(part => part !== "");
		return parts.length > 0 ? parts[0] : String(task.project_name || "Teamwork");
	}

	function title(task) {
		const parts = root.label(task).split("/").map(part => part.trim()).filter(part => part !== "");
		return parts.length > 1 ? parts[parts.length - 1] : String(task.task_name || task.name || root.label(task));
	}

	function matches(task, query) {
		const needle = String(query || "").trim().toLowerCase();
		if (needle === "") return true;
		return [root.label(task), task.project_name, task.tasklist_name, task.task_name, task.name, task.task_id, task.id]
			.filter(value => value !== undefined && value !== null).join(" ").toLowerCase().includes(needle);
	}

	function primaryAction() {
		if (QtrackTimer.tracking) QtrackTimer.pause();
		else if (root.tab === "new" && QtrackTimer.canStart && !root.hasSelectedToday) QtrackTimer.start();
		else if (root.hasSelectedToday || QtrackTimer.canResume) QtrackTimer.resume();
		else if (QtrackTimer.canStart) QtrackTimer.start();
	}

	Connections {
		target: QtrackTimer
		function onDraftDescriptionChanged() {
			if (!description.focused && description.text !== QtrackTimer.draftDescription) description.text = QtrackTimer.draftDescription;
		}
	}

	onPanelOpened: {
		QtrackTimer.seedDraft(false);
		QtrackTimer.refresh();
		root.tab = root.hasSelectedToday || (QtrackTimer.paused && root.todayTasks.length > 0) ? "today" : "new";
		if (root.tab === "new") Qt.callLater(() => description.focusInput());
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 16

		// ── hero ──────────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 16

			Item {
				Layout.preferredWidth: 92
				Layout.preferredHeight: 92

				Ring {
					anchors.fill: parent
					thickness: 7
					value: Math.min(1, QtrackTimer.todayLive / (8 * 3600))
					color: QtrackTimer.tracking ? Theme.primary : Theme.textSubtle
					trackColor: Theme.layer2
				}

				Clickable {
					id: fab

					anchors.centerIn: parent
					width: 62
					height: 62
					radius: QtrackTimer.tracking ? 20 : 31
					color: root.canPrimary ? (QtrackTimer.tracking ? Theme.primary : Theme.primaryContainer) : Theme.layer2
					tint: QtrackTimer.tracking ? Theme.onPrimary : Theme.text
					interactive: root.canPrimary && !QtrackTimer.actionRunning
					pressedScale: 0.86
					onClicked: root.primaryAction()

					Behavior on radius {
						SpatialAnim {
							duration: Motion.long
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: QtrackTimer.actionRunning ? "sync" : (QtrackTimer.tracking ? "pause" : "play")
						size: 30
						color: QtrackTimer.tracking ? Theme.onPrimary : (root.canPrimary ? Theme.primary : Theme.textSubtle)
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				RowLayout {
					spacing: 8

					Rectangle {
						Layout.preferredHeight: 22
						Layout.preferredWidth: statusLabel.implicitWidth + 18
						radius: 11
						color: QtrackTimer.tracking ? Theme.primary : Theme.layer2

						StyledText {
							id: statusLabel

							anchors.centerIn: parent
							text: QtrackTimer.tracking ? "TRACKING" : (QtrackTimer.paused ? "PAUSED" : "READY")
							tone: QtrackTimer.tracking ? Theme.onPrimary : Theme.textMuted
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
							font.letterSpacing: 1
						}
					}

					StyledText {
						visible: QtrackTimer.started !== ""
						text: `since ${QtrackTimer.started}`
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}

				StyledText {
					text: QtrackTimer.tracking || QtrackTimer.paused ? (QtrackTimer.duration || "--") : QtrackTimer.todayTotal
					font.family: Theme.monoFamily
					font.pixelSize: 38
					font.weight: Font.Bold
					tabular: true
				}

				StyledText {
					Layout.fillWidth: true
					text: QtrackTimer.tracking || QtrackTimer.paused
						? (QtrackTimer.project || "No project")
						: "today in total"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					visible: (QtrackTimer.tracking || QtrackTimer.paused) && QtrackTimer.description !== ""
					text: QtrackTimer.description
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			current: root.tab
			options: [
				{ value: "today", label: `Today · ${root.todayTasks.length}`, icon: "history" },
				{ value: "new", label: "New timer", icon: "plus" }
			]
			onSelected: value => root.tab = value
		}

		// ── today ─────────────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.tab === "today"
			spacing: 4

			EmptyState {
				Layout.fillWidth: true
				Layout.topMargin: 12
				Layout.bottomMargin: 12
				visible: root.todayTasks.length === 0
				icon: "timer_outline"
				title: Words.of("timer.empty", "Nothing tracked today")
				subtitle: "Start a new timer — it will show up here to resume later."
			}

			ListView {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(contentHeight, 290)
				visible: root.todayTasks.length > 0
				clip: true
				spacing: 2
				model: root.todayTasks
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				delegate: ListItem {
					id: todayRow

					required property var modelData
					readonly property string key: QtrackTimer.taskKey(todayRow.modelData.project, todayRow.modelData.description)
					readonly property bool isCurrent: (QtrackTimer.tracking || QtrackTimer.paused) && key === QtrackTimer.taskKey(QtrackTimer.project, QtrackTimer.description)

					width: ListView.view.width
					icon: todayRow.isCurrent && QtrackTimer.tracking ? "progress_clock" : "clock_outline"
					title: String(todayRow.modelData.description || "No description")
					subtitle: [String(todayRow.modelData.project || ""), String(todayRow.modelData.duration_label || todayRow.modelData.total_label || "")].filter(v => v !== "").join(" · ")
					selected: QtrackTimer.selectedTodayTaskKey === todayRow.key
					onClicked: QtrackTimer.selectTodayTask(todayRow.modelData.project, todayRow.modelData.description)

					IconButton {
						visible: !(todayRow.isCurrent && QtrackTimer.tracking)
						icon: "play"
						variant: todayRow.selected ? "filled" : "tonal"
						opacity: todayRow.hovered || todayRow.selected ? 1 : 0
						onClicked: {
							QtrackTimer.selectTodayTask(todayRow.modelData.project, todayRow.modelData.description);
							QtrackTimer.resume();
						}

						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}
					}
				}
			}
		}

		// ── new timer ─────────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.tab === "new"
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				SectionLabel {
					Layout.fillWidth: true
					text: QtrackTimer.teamworkStatus
				}

				IconButton {
					Layout.preferredWidth: 28
					Layout.preferredHeight: 28
					icon: "refresh"
					iconSize: 16
					enabled: !QtrackTimer.teamworkRefreshing
					onClicked: QtrackTimer.refreshTeamworkTasks()

					RotationAnimator on rotation {
						running: QtrackTimer.teamworkRefreshing
						loops: Animation.Infinite
						from: 0
						to: 360
						duration: 900
					}
				}
			}

			Field {
				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Search Teamwork tickets"
				text: root.search
				onEdited: text => root.search = text
				onDownPressed: taskList.incrementCurrentIndex()
				onUpPressed: taskList.decrementCurrentIndex()
				onAccepted: {
					const task = root.teamwork[taskList.currentIndex];
					if (task) QtrackTimer.selectTeamworkTask(String(task.task_id || task.id || ""));
					description.focusInput();
				}
			}

			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(taskList.contentHeight + 12, 212)
				radius: Theme.radius.large
				color: Theme.layer1
				visible: root.teamwork.length > 0

				ListView {
					id: taskList

					anchors.fill: parent
					anchors.margins: 6
					clip: true
					spacing: 2
					model: root.teamwork
					highlightMoveDuration: Motion.short
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					delegate: Clickable {
						id: taskRow

						required property var modelData
						required property int index
						readonly property string taskId: String(taskRow.modelData.task_id || taskRow.modelData.id || "")
						readonly property bool picked: taskRow.taskId === QtrackTimer.selectedTeamworkTaskId

						width: ListView.view.width
						implicitHeight: 46
						radius: Theme.radius.medium
						pressedScale: 0.98
						color: taskRow.picked ? Theme.primaryContainer : (taskRow.hovered || taskList.currentIndex === taskRow.index ? Theme.layer2 : "transparent")
						onClicked: {
							QtrackTimer.selectTeamworkTask(taskRow.taskId);
							description.focusInput();
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 12
							anchors.rightMargin: 12
							spacing: 10

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: root.heading(taskRow.modelData)
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.tiny
									font.weight: Font.Bold
								}

								StyledText {
									Layout.fillWidth: true
									text: root.title(taskRow.modelData)
									font.pixelSize: Theme.size.label
									font.weight: taskRow.picked ? Font.Bold : Font.Medium
								}
							}

							Glyph {
								icon: "check_circle"
								size: 18
								color: Theme.primary
								scale: taskRow.picked ? 1 : 0

								Behavior on scale {
									SpatialAnim {
										duration: Motion.medium
									}
								}
							}
						}
					}
				}
			}

			AreaField {
				id: description

				Layout.fillWidth: true
				Layout.preferredHeight: 84
				placeholder: "What are you working on?"
				text: QtrackTimer.draftDescription
				onEdited: text => {
					if (text !== QtrackTimer.draftDescription) QtrackTimer.editDescription(text);
				}
			}

			TextButton {
				Layout.fillWidth: true
				implicitHeight: 42
				text: QtrackTimer.tracking ? "Pause the running timer first" : "Start timer"
				icon: "play"
				variant: "filled"
				enabled: QtrackTimer.canStart
				busy: QtrackTimer.actionRunning
				onActivated: QtrackTimer.start()
			}
		}

		// ── footer ────────────────────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: footer.implicitHeight + 20
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: footer

				x: 14
				y: 10
				width: parent.width - 28
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 16

					ColumnLayout {
						spacing: 0
						SectionLabel { text: Words.of("timer.today", "Today") }
						StyledText {
							text: QtrackTimer.todayTotal
							tabular: true
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}
					}

					ColumnLayout {
						spacing: 0
						SectionLabel { text: Words.of("timer.tasks", "Tasks") }
						StyledText {
							text: QtrackTimer.todayEntries
							tabular: true
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}
					}

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: "All days"
						icon: "calendar_month"
						onActivated: Popups.open("tracking", root.targetScreen)
					}
				}
			}
		}
	}
}
