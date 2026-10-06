pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Every day with tracked work, newest first, under its month. A day shows
// what was tracked and how many of its entries are in Teamwork. The mark of
// the chosen day glides to the next one.
Rectangle {
	id: root

	readonly property var byDay: {
		const out = {};
		for (const day of Tracking.days) out[day.day] = day;
		return out;
	}
	// the days ("2026-10-06") with their month ("2026-10") in front of its first
	readonly property var rows: {
		const out = [];
		let month = "";
		for (const day of Tracking.days) {
			const key = String(day.day).slice(0, 7);
			if (key !== month) {
				month = key;
				out.push(key);
			}
			out.push(String(day.day));
		}
		return out;
	}

	radius: Theme.radius.large
	color: Theme.layer1

	ListView {
		id: list

		anchors.fill: parent
		anchors.margins: 6
		clip: true
		spacing: 2
		// rows that stay keep their place, so the list holds still under an action
		model: ScriptModel {
			values: root.rows
		}
		currentIndex: root.rows.indexOf(Tracking.day)
		highlightMoveDuration: Motion.long
		highlightMoveVelocity: -1
		highlightResizeDuration: 0
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		highlight: Rectangle {
			radius: Theme.radius.medium
			color: Theme.primaryContainer
		}

		add: Transition {
			Anim {
				property: "opacity"
				from: 0
				to: 1
			}
		}
		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}

		delegate: Item {
			id: row

			required property string modelData
			readonly property bool header: row.modelData.length === 7
			readonly property var day: root.byDay[row.modelData] ?? ({})
			readonly property bool current: !row.header && row.modelData === Tracking.day
			readonly property int count: Number(row.day.task_count) || 0
			readonly property int sent: Number(row.day.sent_count) || 0

			width: ListView.view.width
			height: row.header ? 30 : 38

			SectionLabel {
				visible: row.header
				x: 10
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 5
				text: row.header ? Qt.formatDate(Tracking.date(`${row.modelData}-01`), "MMMM yyyy") : ""
			}

			Clickable {
				id: button

				anchors.fill: parent
				visible: !row.header
				radius: Theme.radius.medium
				pressedScale: 0.97
				color: button.hovered && !row.current ? Theme.layer2 : "transparent"
				onClicked: Tracking.show(row.modelData)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 10
					spacing: 8

					StyledText {
						Layout.fillWidth: true
						text: row.header ? "" : (row.modelData === Tracking.today ? "Today" : Qt.formatDate(Tracking.date(row.modelData), "ddd d."))
						font.pixelSize: Theme.size.label
						font.weight: row.current ? Font.Bold : Font.Medium
					}

					StyledText {
						text: Tracking.formatMinutes(row.day.tracking_minutes)
						tone: Theme.textMuted
						tabular: true
						font.pixelSize: Theme.size.label
					}

					Item {
						Layout.preferredWidth: 26
						Layout.fillHeight: true

						Glyph {
							anchors.centerIn: parent
							icon: "check_all"
							size: 15
							color: Theme.success
							scale: row.count > 0 && row.sent === row.count ? 1 : 0

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}

						StyledText {
							anchors.centerIn: parent
							visible: row.count > 0 && row.sent < row.count
							text: `${row.sent}/${row.count}`
							tone: Theme.textSubtle
							tabular: true
							font.pixelSize: Theme.size.tiny
						}
					}
				}
			}
		}
	}
}
