pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.breaks

// Breaks against headaches. The glass fills with the day's water (click:
// one more), the rings run towards the next eye rest, glass and break, the
// week shows screen time, water and headaches side by side, and the days
// with a headache are compared with the others.
Drawer {
	id: root

	panelId: "breaks"
	panelWidth: 560
	centered: true
	contentHeight: layout.implicitHeight

	readonly property var reminders: [
		{ key: "move", icon: "walk", title: "Break", since: Breaks.sinceMove, every: Breaks.moveSeconds, color: Theme.primary },
		{ key: "water", icon: "cup_water", title: "Water", since: Breaks.sinceWater, every: Breaks.waterSeconds, color: Theme.secondary },
		{ key: "eyes", icon: "eye_outline", title: "Eyes", since: Breaks.sinceEyes, every: Breaks.eyesSeconds, color: Theme.tertiary }
	]

	function remaining(reminder) {
		if (!Breaks.enabled) return "Off";
		const minutes = Math.ceil(Math.max(0, reminder.every - reminder.since) / 60);
		return minutes <= 0 ? "now" : `in ${minutes} min`;
	}

	onPanelOpened: chart.play()

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 18

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			ColumnLayout {
				spacing: 0

				StyledText {
					text: Words.of("breaks.title", "Breaks")
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				RowLayout {
					spacing: 6

					StyledText {
						text: `${Breaks.formatDuration(Breaks.screenSeconds)} screen · ${Breaks.todayEntry.breaks} breaks today`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}

					StyledText {
						visible: Breaks.pressureNow !== null
						text: "·"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}

					Glyph {
						visible: Breaks.pressureNow !== null
						icon: Breaks.pressureChange3h <= -1 ? "arrow_bottom_right" : (Breaks.pressureChange3h >= 1 ? "arrow_top_right" : "arrow_right")
						size: 13
						color: Breaks.pressureChange3h <= -3 ? Theme.warning : Theme.textMuted
					}

					StyledText {
						visible: Breaks.pressureNow !== null
						text: Breaks.pressureNow ? `${Math.round(Breaks.pressureNow.hPa)} hPa` : ""
						tone: Breaks.pressureChange3h <= -3 ? Theme.warning : Theme.textMuted
						font.pixelSize: Theme.size.label
						tabular: true
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Toggle {
				checked: Breaks.enabled
				onToggled: on => Breaks.setEnabled(on)
			}
		}

		// ── hero ──────────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 22

			ColumnLayout {
				spacing: 8

				WaterBottle {
					id: bottle

					Layout.alignment: Qt.AlignHCenter
					remaining: root.shown ? Breaks.bottleLeft : 0
					size: Breaks.bottleSize
					running: root.shown
					onLevelSet: remaining => {
						const drunk = Breaks.setBottleLevel(remaining);
						if (drunk > 0) bottle.drank(drunk);
					}
				}

				RowLayout {
					Layout.alignment: Qt.AlignHCenter
					spacing: 4

					IconButton {
						icon: "refresh"
						interactive: Breaks.bottleLeft < Breaks.bottleSize
						onClicked: Breaks.refill()
					}

					IconButton {
						visible: Breaks.glasses > 0
						icon: "water_minus_outline"
						onClicked: Breaks.removeGlass()
					}

					IconButton {
						icon: "water_plus_outline"
						variant: "tonal"
						onClicked: Breaks.drinkGlass()
					}
				}
			}

			Item {
				Layout.preferredWidth: 158
				Layout.preferredHeight: 158

				Repeater {
					model: root.reminders

					delegate: Ring {
						required property var modelData
						required property int index

						anchors.centerIn: parent
						width: 158 - index * 38
						height: width
						thickness: 13
						value: root.shown ? modelData.since / modelData.every : 0
						color: Breaks.enabled ? modelData.color : Theme.textFaint
						trackColor: Qt.alpha(modelData.color, 0.14)
						animated: false

						Behavior on value {
							SequentialAnimation {
								PauseAnimation {
									duration: 120 + index * 110
								}
								SpatialAnim {
									duration: Motion.extraLong * 2
								}
							}
						}
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: Breaks.enabled ? "head_outline" : "bell_sleep_outline"
					size: 26
					color: Theme.textMuted
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 12

				Repeater {
					model: root.reminders

					delegate: RowLayout {
						id: reminder

						required property var modelData
						required property int index

						spacing: 10
						opacity: root.shown ? 1 : 0

						HoverHandler {
							enabled: reminder.modelData.key === "eyes"
							cursorShape: Qt.PointingHandCursor
						}

						TapHandler {
							enabled: reminder.modelData.key === "eyes"
							onTapped: Breaks.startEyeRest()
						}
						transform: Translate {
							x: root.shown ? 0 : 16

							Behavior on x {
								SpatialAnim {
									duration: Motion.extraLong + reminder.index * 90
								}
							}
						}

						Behavior on opacity {
							Anim {
								duration: Motion.long + reminder.index * 90
							}
						}

						Rectangle {
							Layout.preferredWidth: 34
							Layout.preferredHeight: 34
							radius: 17
							color: Qt.alpha(reminder.modelData.color, 0.18)

							Glyph {
								anchors.centerIn: parent
								icon: reminder.modelData.icon
								size: 18
								color: reminder.modelData.color
							}
						}

						ColumnLayout {
							spacing: 0

							StyledText {
								text: reminder.modelData.title
								font.weight: Font.DemiBold
							}

							StyledText {
								text: root.remaining(reminder.modelData)
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
								tabular: true
							}
						}
					}
				}
			}
		}

		// the day's water: one segment per bottle up to the goal
		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Glyph {
				icon: "cup_water"
				size: 20
				color: Breaks.waterMl >= Breaks.goalMl ? Theme.primary : Theme.textMuted
			}

			Row {
				spacing: 4

				StyledText {
					text: Breaks.formatLitres(Breaks.waterMl)
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
					tabular: true
				}

				StyledText {
					anchors.baseline: parent.children[0].baseline
					text: `/ ${Breaks.formatLitres(Breaks.goalMl)}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.label
					tabular: true
				}
			}

			TextButton {
				visible: Breaks.canUncount
				icon: "undo"
				text: "Don't count"
				variant: "ghost"
				onActivated: Breaks.uncount()
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 5

				Repeater {
					model: Math.max(Math.ceil(Breaks.goalMl / Breaks.bottleSize), Math.ceil(Breaks.waterMl / Breaks.bottleSize))

					delegate: Rectangle {
						id: segment

						required property int index

						readonly property real fill: Math.max(0, Math.min(1, (Breaks.waterMl - segment.index * Breaks.bottleSize) / Breaks.bottleSize))
						property real shownFill: root.shown ? segment.fill : 0

						Layout.fillWidth: true
						implicitHeight: 10
						radius: 5
						color: Theme.layer2

						Behavior on shownFill {
							SequentialAnimation {
								PauseAnimation {
									duration: segment.index * 120
								}
								SpatialAnim {
									duration: Motion.extraLong + 150
								}
							}
						}

						Rectangle {
							width: parent.width * segment.shownFill
							height: parent.height
							radius: parent.radius
							color: segment.index * Breaks.bottleSize >= Breaks.goalMl ? Theme.secondary : Theme.primary
							visible: width > 1
						}
					}
				}
			}
		}

		TextButton {
			Layout.fillWidth: true
			icon: "head_alert_outline"
			text: "Headache"
			onActivated: Breaks.logHeadache()
		}

		// ── week ──────────────────────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: chart.implicitHeight + 28
			radius: Theme.radius.large
			color: Theme.layer1

			WeekChart {
				id: chart

				anchors.fill: parent
				anchors.margins: 14
				days: Breaks.recent
			}
		}

		// ── headache days vs. the others ──────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: Breaks.insights.headache.days > 0 && Breaks.insights.other.days > 0
			spacing: 10

			Repeater {
				model: [
					{ title: "With headache", side: Breaks.insights.headache, tone: Theme.danger, fill: Theme.dangerContainer },
					{ title: "Without", side: Breaks.insights.other, tone: Theme.primary, fill: Theme.layer1 }
				]

				delegate: Rectangle {
					id: card

					required property var modelData

					Layout.fillWidth: true
					implicitHeight: cardLayout.implicitHeight + 24
					radius: Theme.radius.large
					color: card.modelData.fill

					ColumnLayout {
						id: cardLayout

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 12
						spacing: 6

						StyledText {
							text: `${card.modelData.title} · ${card.modelData.side.days} ${card.modelData.side.days === 1 ? "day" : "days"}`
							tone: card.modelData.tone
							font.pixelSize: Theme.size.label
							font.weight: Font.Bold
						}

						Repeater {
							model: [
								{ icon: "cup_water", text: `Ø ${Breaks.formatLitres(Math.round(card.modelData.side.ml / 50) * 50)}` },
								{ icon: "monitor", text: `Ø ${Breaks.formatDuration(card.modelData.side.screen)} screen` },
								{ icon: "walk", text: `Ø ${card.modelData.side.breaks.toFixed(1)} breaks` },
								{ icon: "weather_windy", text: `Ø ${card.modelData.side.swing.toFixed(1)} hPa swing`, shown: card.modelData.side.swingDays > 0 }
							].filter(row => row.shown !== false)

							delegate: RowLayout {
								required property var modelData

								spacing: 8

								Glyph {
									icon: parent.modelData.icon
									size: 15
									color: Theme.textMuted
								}

								StyledText {
									text: parent.modelData.text
									tabular: true
								}
							}
						}
					}
				}
			}
		}
	}
}
