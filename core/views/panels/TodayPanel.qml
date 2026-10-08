pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.calendar
import qs.core.views.panels.asteroids

// Hangs from the clock: notification center on the left, date, calendar,
// the day's Microsoft events and weather on the right. A picked event opens
// a panel that grows out of this one's bottom edge. The weather card turns
// into the asteroid radar and back.
Drawer {
	id: root

	panelId: "today"
	readonly property bool hasNotifications: Plugins.on("notifications")
	readonly property bool hasSide: Plugins.on("calendar") || Plugins.on("weather")

	panelWidth: root.hasNotifications && root.hasSide ? 790 : (root.hasSide ? 360 : 450)
	contentHeight: root.hasSide ? Math.max(side.implicitHeight, 420) : 420

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	onPanelOpened: {
		// opened from a reminder: show that event's day
		const event = Outlook.selected;
		calendar.reset();
		if (event) {
			calendar.shown = new Date(event.start);
			calendar.selected = new Date(event.start);
			Outlook.selected = event;
		}
		Outlook.refresh();
	}
	onPanelClosed: {
		Outlook.selected = null;
		sky.radar = false;
	}

	belowOpen: Outlook.selected !== null
	belowContentHeight: details.implicitHeight
	below: EventDetails {
		id: details

		anchors.fill: parent
		event: Outlook.selected
	}

	RowLayout {
		anchors.fill: parent
		spacing: 20

		// notifications
		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.hasNotifications
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					text: Words.of("today.title", "Notifications")
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				Badge {
					count: Notifs.count
				}

				Item {
					Layout.fillWidth: true
				}

				IconButton {
					visible: Plugins.on("dnd")
					icon: Notifs.dnd ? "bell_sleep" : "bell_sleep_outline"
					checked: Notifs.dnd
					variant: "tonal"
					onClicked: Notifs.toggleDnd()
				}

				TextButton {
					visible: Notifs.count > 0
					text: "Clear all"
					icon: "broom"
					variant: "ghost"
					confirm: Notifs.count > 3
					confirmText: "Clear all?"
					onActivated: Notifs.dismissAll()
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				EmptyState {
					anchors.centerIn: parent
					visible: Notifs.count === 0
					icon: "bell_sleep"
					title: Words.of("today.empty", "All caught up")
					subtitle: "New notifications land here. Swipe one sideways to dismiss it."
				}

				ListView {
					id: list

					anchors.fill: parent
					visible: Notifs.count > 0
					clip: true
					spacing: 8
					model: Notifs.groups
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					add: Transition {
						ParallelAnimation {
							Anim {
								property: "opacity"
								from: 0
								to: 1
							}
							SpatialAnim {
								property: "y"
								from: -30
							}
						}
					}
					displaced: Transition {
						SpatialAnim {
							property: "y"
						}
					}

					delegate: NotificationCard {
						required property var modelData
						width: ListView.view.width
						group: modelData
					}
				}
			}
		}

		Rectangle {
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			visible: root.hasNotifications && root.hasSide
			color: Theme.outline
		}

		// date, calendar, weather
		ColumnLayout {
			id: side

			Layout.preferredWidth: 320
			Layout.alignment: Qt.AlignTop
			visible: root.hasSide
			spacing: 14

			ColumnLayout {
				visible: Plugins.on("calendar")
				spacing: 0

				StyledText {
					text: Qt.formatDateTime(clock.date, "dddd")
					tone: Theme.primary
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
				}

				StyledText {
					text: Qt.formatDateTime(clock.date, "d. MMMM")
					font.pixelSize: Theme.size.display
					font.weight: Font.Bold
				}
			}

			CalendarView {
				id: calendar
				Layout.fillWidth: true
				visible: Plugins.on("calendar")
				onSelectedChanged: {
					if (Outlook.selected && !Outlook.selected.days.includes(Outlook.dayKey(calendar.selected)))
						Outlook.selected = null;
				}
			}

			Agenda {
				Layout.fillWidth: true
				visible: Plugins.on("microsoft-calendar")
				day: calendar.selected
			}

			Rectangle {
				id: sky

				// the asteroid radar instead of the weather
				property bool radar: false
				readonly property bool turned: sky.radar && Asteroids.ready

				Layout.fillWidth: true
				implicitHeight: sky.turned ? asteroids.implicitHeight : weather.implicitHeight
				visible: Plugins.on("weather") && Weather.available
				radius: Theme.radius.huge
				color: Theme.layer1

				WeatherCard {
					id: weather

					width: parent.width
					color: "transparent"
					visible: opacity > 0
					opacity: sky.turned ? 0 : 1
					scale: sky.turned ? 0.96 : 1
					transformOrigin: Item.Top
					onAsteroidsPicked: sky.radar = true

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				AsteroidCard {
					id: asteroids

					width: parent.width
					color: "transparent"
					shown: root.shown && sky.turned
					visible: opacity > 0
					opacity: sky.turned ? 1 : 0
					scale: sky.turned ? 1 : 0.96
					transformOrigin: Item.Top
					onClosed: sky.radar = false

					Behavior on opacity {
						Anim {}
					}
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
