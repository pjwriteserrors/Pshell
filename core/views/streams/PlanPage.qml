pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// This week, Monday to Sunday, a column a day like a TV guide: what streamed
// (seen live, or learned afterwards while the PC was off: "Missed"), what runs
// now, what is announced and (fainter) what the past makes likely, with what to
// catch up on first.
Flickable {
	id: root

	readonly property var days: {
		const out = [];
		const today = new Date();
		today.setHours(0, 0, 0, 0);
		// the week starts on Monday
		const start = new Date(today.getTime());
		start.setDate(today.getDate() - (today.getDay() + 6) % 7);
		for (let i = 0; i < 7; i += 1) {
			const from = new Date(start.getTime());
			from.setDate(start.getDate() + i);
			const to = new Date(from.getTime());
			to.setDate(from.getDate() + 1);
			const offset = Math.round((from.getTime() - today.getTime()) / 86400000);
			out.push({
				label: offset === 0 ? "Today" : (offset === 1 ? "Tomorrow" : (offset === -1 ? "Yesterday" : Qt.formatDate(from, "dddd"))),
				date: Qt.formatDate(from, "d MMM"),
				today: offset === 0,
				past: offset < 0,
				entries: Streams.plan.filter(entry => entry.starts * 1000 >= from.getTime() && entry.starts * 1000 < to.getTime())
			});
		}
		return out;
	}

	signal openSeries(string id)

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 20

		Item {
			Layout.preferredHeight: 64
		}

		Text {
			text: "This week"
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: 40
			font.weight: Font.Black
		}

		StyledText {
			Layout.fillWidth: true
			visible: Streams.plan.length === 0
			text: "Nothing streamed or announced this week yet. Past Twitch streams appear here even when this PC was off, schedules as they are announced, and regular hours once a channel streamed at the same time three times."
			tone: Theme.textMuted
			font.pixelSize: Theme.size.title
			wrapMode: Text.Wrap
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: root.days

				ColumnLayout {
					id: day

					required property var modelData
					required property int index

					Layout.fillWidth: true
					Layout.preferredWidth: 1
					Layout.alignment: Qt.AlignTop
					spacing: 8

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: day.modelData.label
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
							tone: (day.modelData.today || day.modelData.entries.length > 0) && !day.modelData.past ? Theme.text : Theme.textSubtle
							elide: Text.ElideRight
						}
						StyledText {
							text: day.modelData.date
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
						}
					}
					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 3
						radius: 2
						color: day.modelData.today ? Theme.primary : Theme.outline
					}

					Repeater {
						model: day.modelData.entries

						Clickable {
							id: entry

							required property var modelData

							Layout.fillWidth: true
							implicitHeight: entryColumn.implicitHeight + 22
							radius: Theme.radius.large
							color: Qt.tint(Theme.layer1, Qt.alpha(Streams.accent(entry.modelData.colors), entry.hovered ? 0.3 : 0.14))
							// guesses and what is over step back
							opacity: !entry.modelData.sure ? 0.7 : (entry.modelData.past && !entry.modelData.missed ? 0.8 : 1)
							scale: entry.hovered ? 1.03 : 1
							pressedScale: 0.98
							onClicked: Browser.open(entry.modelData.url)

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on color {
								ColorAnim {}
							}

							ColumnLayout {
								id: entryColumn

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 11
								spacing: 5

								RowLayout {
									spacing: 8
									Avatar {
										Layout.preferredWidth: 28
										Layout.preferredHeight: 28
										source: entry.modelData.avatar
										name: entry.modelData.name
										colors: entry.modelData.colors
									}
									StyledText {
										Layout.fillWidth: true
										// over: from when to when, as far as it is known
										text: Qt.formatTime(new Date(entry.modelData.starts * 1000), "HH:mm") + (entry.modelData.past && entry.modelData.ends ? `–${Qt.formatTime(new Date(entry.modelData.ends * 1000), "HH:mm")}` : "")
										font.pixelSize: entry.modelData.past && entry.modelData.ends ? Theme.size.label : Theme.size.title
										font.weight: Font.Black
										tabular: true
										elide: Text.ElideRight
									}
								}
								// what it is now: running, or over and not seen
								Rectangle {
									visible: !!entry.modelData.live || !!entry.modelData.missed
									implicitWidth: badgeText.implicitWidth + 14
									implicitHeight: 20
									radius: 10
									color: entry.modelData.live ? Theme.danger : Qt.alpha(Theme.warning, 0.2)

									StyledText {
										id: badgeText

										anchors.centerIn: parent
										text: entry.modelData.live ? "Live now" : "Missed"
										font.pixelSize: Theme.size.tiny
										font.weight: Font.Bold
										color: entry.modelData.live ? "white" : Theme.warning
									}
								}
								StyledText {
									Layout.fillWidth: true
									text: entry.modelData.name
									font.pixelSize: Theme.size.label
									font.weight: Font.Bold
									elide: Text.ElideRight
								}
								StyledText {
									Layout.fillWidth: true
									text: entry.modelData.sure ? [entry.modelData.title, entry.modelData.category].filter(part => !!part).join(" · ") : "Likely, by habit"
									font.pixelSize: Theme.size.small
									tone: Theme.textMuted
									wrapMode: Text.Wrap
									maximumLineCount: 3
									elide: Text.ElideRight
								}
								Clickable {
									Layout.fillWidth: true
									visible: !!entry.modelData.behind
									implicitHeight: 26
									radius: 8
									color: Qt.alpha(Theme.warning, 0.18)
									onClicked: root.openSeries(entry.modelData.behind.series)

									StyledText {
										anchors.centerIn: parent
										width: parent.width - 10
										horizontalAlignment: Text.AlignHCenter
										text: entry.modelData.behind ? `${entry.modelData.behind.left} to catch up` : ""
										font.pixelSize: Theme.size.tiny
										font.weight: Font.Bold
										color: Theme.warning
										elide: Text.ElideRight
									}
								}
							}
						}
					}
				}
			}
		}
	}
}
