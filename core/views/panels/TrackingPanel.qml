pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.tracking

// The qtrack day board: every tracked day on the left, the chosen one on the
// right with its numbers and its entries by project. An entry opens to edit
// its description, ticket, times and billable state; the checkbox queues it
// and "Send to Teamwork" writes what is queued.
Drawer {
	id: root

	// entries opened for editing, the running one closed, projects folded away
	property var opened: ({})
	property var closedRunning: ({})
	property var folded: ({})
	// a day is coming in: its cards rise one after the other
	property bool arriving: false
	property string shownDay: ""

	panelId: "tracking"
	centered: true
	panelWidth: Math.min(1080, (root.screen?.width ?? 1920) - 80)
	contentHeight: 740

	function flip(name, key) {
		const next = Object.assign({}, root[name]);
		if (next[key]) delete next[key];
		else next[key] = true;
		root[name] = next;
	}

	// an entry that gets another description or project stays open
	function follow(entry, project, description) {
		if (!root.opened[Tracking.key(entry)]) return;
		const next = Object.assign({}, root.opened);
		next[Tmpo.taskKey(project, description)] = true;
		root.opened = next;
	}

	onPanelOpened: Tracking.show(Popups.page)

	Connections {
		target: Tracking
		function onDayChanged() {
			// the list is newest first: a later day comes in from the right
			const from = Tracking.days.findIndex(entry => entry.day === root.shownDay);
			const to = Tracking.dayIndex;
			arrive.from = from < 0 || to < 0 || from === to ? 0 : (to < from ? 36 : -36);
			root.shownDay = Tracking.day;
			root.opened = ({});
			root.closedRunning = ({});
			root.folded = ({});
			root.arriving = true;
			arrive.restart();
		}
		function onReportChanged() {
			if (Tracking.report !== null && root.arriving) arrived.restart();
		}
	}

	Timer {
		id: arrived

		interval: 500
		onTriggered: root.arriving = false
	}

	// the day slides in from the side it lies on, its name with it
	ParallelAnimation {
		id: arrive

		property real from: 0

		NumberAnimation {
			target: slide
			property: "x"
			from: arrive.from
			to: 0
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
		NumberAnimation {
			target: titleSlide
			property: "x"
			from: arrive.from / 2
			to: 0
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
		Anim {
			target: title
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.long
		}
	}

	Connections {
		target: Tmpo
		enabled: root.shown
		function onTrackingChanged() {
			Tracking.reload();
		}
		function onPausedChanged() {
			Tracking.reload();
		}
	}

	// while it is open it follows what is tracked, and the tickets of Teamwork
	Timer {
		running: root.shown
		repeat: true
		interval: 15000
		onTriggered: Tracking.reload()
	}

	Timer {
		running: root.shown
		repeat: true
		triggeredOnStart: true
		interval: 300000
		onTriggered: Tmpo.refreshTeamworkTasks()
	}

	RowLayout {
		anchors.fill: parent
		spacing: 16

		DayList {
			Layout.preferredWidth: 236
			Layout.fillHeight: true
		}

		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 14

			// ── header ────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				ColumnLayout {
					id: title

					Layout.fillWidth: true
					spacing: 0
					transform: Translate {
						id: titleSlide
					}

					StyledText {
						Layout.fillWidth: true
						text: Tracking.day === "" ? "" : Qt.formatDate(Tracking.date(Tracking.day), "dddd, d MMMM")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}

					StyledText {
						Layout.fillWidth: true
						text: [Tracking.day === "" ? "" : Qt.formatDate(Tracking.date(Tracking.day), "yyyy"), Tracking.status].filter(part => part !== "").join(" · ")
						tone: Tracking.statusError ? Theme.danger : Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					icon: "chevron_left"
					variant: "tonal"
					enabled: Tracking.dayIndex >= 0 && Tracking.dayIndex < Tracking.days.length - 1
					onClicked: Tracking.step(-1)
				}

				IconButton {
					icon: "chevron_right"
					variant: "tonal"
					enabled: Tracking.dayIndex > 0
					onClicked: Tracking.step(1)
				}

				TextButton {
					text: Tracking.queued > 0 ? `Send to Teamwork · ${Tracking.queued}` : "Send to Teamwork"
					icon: "send"
					variant: "filled"
					enabled: Tracking.queued > 0
					busy: Tracking.sending
					onActivated: Tracking.send()
				}
			}

			Flickable {
				id: scroll

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				contentHeight: board.implicitHeight
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				ColumnLayout {
					id: board

					width: scroll.width
					spacing: 14
					transform: Translate {
						id: slide
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 0
						opacity: Tracking.report !== null ? 1 : 0

						Behavior on opacity {
							Anim {
								duration: Motion.long
							}
						}

						DayStats {
							Layout.fillWidth: true
							Layout.fillHeight: true
						}

						// makes room for itself when a timer starts
						CurrentCard {
							id: current

							readonly property bool wanted: Tracking.isToday && (Tmpo.tracking || Tmpo.paused)
							property real room: current.wanted ? 294 : 0

							Layout.preferredWidth: Math.max(0, current.room - 14)
							Layout.leftMargin: Math.min(14, current.room)
							Layout.fillHeight: true
							visible: current.room > 1
							opacity: Math.min(1, current.room / 294)

							Behavior on room {
								SpatialAnim {}
							}
						}
					}

					Spinner {
						Layout.alignment: Qt.AlignHCenter
						Layout.topMargin: 80
						Layout.preferredWidth: 26
						Layout.preferredHeight: 26
						visible: Tracking.report === null && Tracking.loading && Tracking.days.length === 0
					}

					EmptyState {
						Layout.fillWidth: true
						Layout.topMargin: 60
						visible: Tracking.report !== null && Tracking.groups.length === 0
						icon: "timer_outline"
						title: "Nothing tracked on this day"
					}

					SectionLabel {
						Layout.leftMargin: 4
						visible: Tracking.groups.length > 0
						text: `Projects · ${Tracking.groups.length}`
					}

					Repeater {
						// by name, so a project that stays keeps its card
						model: ScriptModel {
							values: Tracking.groups.map(group => String(group.project || ""))
						}

						delegate: ProjectCard {
							required property string modelData

							Layout.fillWidth: true
							project: modelData
							board: root
						}
					}
				}
			}
		}
	}
}
