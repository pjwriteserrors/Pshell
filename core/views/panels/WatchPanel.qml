pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.watch

// >watch: what the watch on the wrist measured (Watch.qml), sleep first.
// The night on top – how long, the score as a ring, from when to when, how
// it compares with the week, and its stages as a hypnogram that sweeps in –
// then the last two weeks of nights (a click on one shows it above), the
// day's goals as rings, the heart through the day, stress and blood oxygen
// by the hour. The tiles rise in one after another when the panel opens,
// the numbers count up, the rings wind, the charts draw themselves.
Drawer {
	id: root

	panelId: "watch"
	panelWidth: 680
	centered: true
	contentHeight: layout.implicitHeight

	property string selected: Watch.lastNight?.date ?? ""
	readonly property var night: Watch.night(root.selected) ?? Watch.lastNight
	readonly property var shares: Watch.shares(root.night)
	readonly property real asleep: root.night ? root.night.total : 0
	readonly property real usual: root.night ? Watch.usual(root.night.date) : 0
	readonly property bool isLast: root.night !== null && root.night === Watch.lastNight
	readonly property var fortnight: Watch.nights.slice(-14)
	readonly property var today: Watch.today
	// winds the rings and counts the numbers up when the panel opens
	property real intro: 1
	// sweeps the night in, again for every night picked
	property real reveal: 1
	property real heartDrawn: 1

	function pick(key) {
		if (key === root.selected) return;
		root.selected = key;
		sweep.restart();
	}

	onPanelOpened: {
		root.selected = Watch.lastNight?.date ?? "";
		root.intro = 0;
		root.reveal = 0;
		root.heartDrawn = 0;
		for (const tile of [sleepTile, nightsTile, stepsTile, caloriesTile, standTile, paiTile, heartTile, stressTile, oxygenTile])
			tile.appear();
		wind.restart();
		sweep.restart();
		draw.restart();
		nights.play();
		stress.play();
		oxygen.play();
	}

	SequentialAnimation {
		id: wind

		PauseAnimation {
			duration: 180
		}
		NumberAnimation {
			target: root
			property: "intro"
			to: 1
			duration: Motion.extraLong * 2.4
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	SequentialAnimation {
		id: sweep

		ScriptAction {
			script: root.reveal = 0
		}
		PauseAnimation {
			duration: 260
		}
		NumberAnimation {
			target: root
			property: "reveal"
			to: 1
			duration: 1300
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	SequentialAnimation {
		id: draw

		PauseAnimation {
			duration: 620
		}
		NumberAnimation {
			target: root
			property: "heartDrawn"
			to: 1
			duration: 1400
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	Flickable {
		anchors.fill: parent
		contentHeight: layout.implicitHeight
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		interactive: contentHeight > height

		ColumnLayout {
			id: layout

			width: parent.width
			spacing: 12

			// ── who and when ──────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.bottomMargin: 4
				spacing: 12

				Rectangle {
					Layout.preferredWidth: 40
					Layout.preferredHeight: 40
					radius: 20
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: "watch"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					spacing: 0

					StyledText {
						text: Words.of("watch.title", "Watch")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}

					StyledText {
						text: `${Watch.name} · ${Watch.syncedText}`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}
				}

				Item {
					Layout.fillWidth: true
				}

				// on the link right now: the mouse app is open
				Rectangle {
					Layout.preferredHeight: 28
					Layout.preferredWidth: linkRow.implicitWidth + 22
					radius: 14
					color: Watch.connected ? Theme.primaryContainer : Theme.layer1
					visible: Watch.paired

					Behavior on color {
						ColorAnim {}
					}

					RowLayout {
						id: linkRow

						anchors.centerIn: parent
						spacing: 7

						Rectangle {
							id: pulse

							Layout.preferredWidth: 8
							Layout.preferredHeight: 8
							radius: 4
							color: Watch.connected ? Theme.primary : Theme.textFaint

							SequentialAnimation on opacity {
								running: Watch.connected && root.shown
								loops: Animation.Infinite
								alwaysRunToEnd: true

								NumberAnimation {
									to: 0.3
									duration: 900
									easing.type: Easing.InOutSine
								}
								NumberAnimation {
									to: 1
									duration: 900
									easing.type: Easing.InOutSine
								}
							}
						}

						StyledText {
							text: Watch.mouse ? "Mouse in use" : (Watch.connected ? "On the link" : "Asleep")
							tone: Watch.connected ? Theme.primary : Theme.textMuted
							font.pixelSize: Theme.size.label
							font.weight: Font.Medium
						}
					}
				}

				Rectangle {
					Layout.preferredHeight: 28
					Layout.preferredWidth: batteryRow.implicitWidth + 22
					radius: 14
					color: Theme.layer1
					visible: Watch.battery >= 0

					RowLayout {
						id: batteryRow

						anchors.centerIn: parent
						spacing: 5

						Glyph {
							icon: `battery_${Math.max(10, Math.min(90, Math.round(Watch.battery / 10) * 10))}`
							size: 15
							color: Watch.battery <= 20 ? Theme.danger : Theme.textMuted
						}

						StyledText {
							text: `${Watch.battery} %`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							tabular: true
						}
					}
				}
			}

			EmptyState {
				Layout.fillWidth: true
				Layout.preferredHeight: 260
				visible: !Watch.known
				icon: "watch"
				title: Watch.paired ? "Nothing from the watch yet" : "No watch paired"
				subtitle: Watch.paired ? "PShell Face hands its numbers over every half hour" : "Open PShell on the watch and pair it with this PC"
			}

			// ── the night ─────────────────────────────────────────────────────
			Tile {
				id: sleepTile

				order: 0
				Layout.fillWidth: true
				implicitHeight: sleepLayout.implicitHeight + 36
				visible: Watch.known

				ColumnLayout {
					id: sleepLayout

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 18
					spacing: 16

					RowLayout {
						Layout.fillWidth: true
						spacing: 16

						ColumnLayout {
							spacing: 2

							RowLayout {
								spacing: 6

								Glyph {
									icon: "sleep"
									size: 16
									color: Theme.primary
								}

								StyledText {
									text: !root.night ? "No night yet" : (root.isLast ? "Last night" : Qt.formatDate(Watch.dateOf(root.night.date), "dddd, d MMMM"))
									tone: Theme.textMuted
									font.pixelSize: Theme.size.label
									font.weight: Font.Medium
								}
							}

							// the time asleep, counting up
							StyledText {
								id: hero

								property real shown: root.asleep * root.intro

								text: Watch.span(hero.shown)
								font.pixelSize: Theme.size.hero
								font.weight: Font.Bold
								tabular: true

								Behavior on shown {
									enabled: root.intro >= 1
									Anim {
										duration: Motion.extraLong * 1.4
										easing.bezierCurve: Motion.decel
									}
								}
							}

							RowLayout {
								spacing: 6
								visible: root.night !== null

								Glyph {
									icon: "weather_night"
									size: 14
									color: Theme.textSubtle
								}

								StyledText {
									text: root.night ? Watch.clock(root.night.bed) : ""
									tone: Theme.textMuted
									tabular: true
								}

								Glyph {
									icon: "arrow_right"
									size: 13
									color: Theme.textFaint
								}

								Glyph {
									icon: "weather_sunset_up"
									size: 14
									color: Theme.textSubtle
								}

								StyledText {
									text: root.night ? Watch.clock(root.night.wake) : ""
									tone: Theme.textMuted
									tabular: true
								}

								// against the week before
								Rectangle {
									readonly property real delta: root.asleep - root.usual

									Layout.leftMargin: 8
									Layout.preferredHeight: 22
									Layout.preferredWidth: deltaText.implicitWidth + 16
									radius: 11
									visible: root.usual > 0 && root.night !== null
									color: Math.abs(delta) < 10 ? Theme.layer2 : Qt.alpha(delta > 0 ? Theme.success : Theme.warning, 0.16)

									StyledText {
										id: deltaText

										anchors.centerIn: parent
										text: Math.abs(parent.delta) < 10 ? "as usual" : `${parent.delta > 0 ? "+" : "−"}${Watch.span(Math.abs(parent.delta))} vs your week`
										tone: Math.abs(parent.delta) < 10 ? Theme.textMuted : (parent.delta > 0 ? Theme.success : Theme.warning)
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}
								}
							}
						}

						Item {
							Layout.fillWidth: true
						}

						// the score as a ring that winds up
						Item {
							Layout.preferredWidth: 112
							Layout.preferredHeight: 112
							visible: (root.night?.score ?? 0) > 0

							Ring {
								anchors.fill: parent
								value: (root.night?.score ?? 0) / 100 * root.intro
								thickness: 10
								color: Theme.primary
								trackColor: Theme.layer2
								animated: false
							}

							Column {
								anchors.centerIn: parent
								spacing: -2

								StyledText {
									anchors.horizontalCenter: parent.horizontalCenter
									text: Math.round((root.night?.score ?? 0) * root.intro)
									font.pixelSize: Theme.size.display
									font.weight: Font.Bold
									tabular: true
								}

								StyledText {
									anchors.horizontalCenter: parent.horizontalCenter
									text: Watch.verdict(root.night?.score ?? 0)
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
								}
							}
						}
					}

					Hypnogram {
						Layout.fillWidth: true
						night: root.night
						reveal: root.reveal
					}

					// how the night was made up
					RowLayout {
						Layout.fillWidth: true
						spacing: 14

						Repeater {
							model: ["deep", "light", "rem", "wake"]

							delegate: ColumnLayout {
								id: part

								required property string modelData
								required property int index

								readonly property real minutes: root.shares[part.modelData] ?? 0
								readonly property real share: root.asleep > 0 ? part.minutes / Math.max(1, root.shares.deep + root.shares.light + root.shares.rem + root.shares.wake) : 0

								Layout.fillWidth: true
								Layout.preferredWidth: 1
								spacing: 5

								RowLayout {
									spacing: 6

									Rectangle {
										Layout.preferredWidth: 8
										Layout.preferredHeight: 8
										radius: 4
										color: Watch.tone(part.modelData)
									}

									StyledText {
										text: Watch.stages.find(s => s.id === part.modelData)?.label ?? ""
										tone: Theme.textMuted
										font.pixelSize: Theme.size.label
									}

									Item {
										Layout.fillWidth: true
									}

									StyledText {
										text: `${Math.round(part.share * 100)} %`
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.small
										tabular: true
									}
								}

								StyledText {
									text: Watch.span(part.minutes)
									font.pixelSize: Theme.size.title
									font.weight: Font.DemiBold
									tabular: true
								}

								Rectangle {
									Layout.fillWidth: true
									Layout.preferredHeight: 5
									radius: 3
									color: Theme.layer2

									Rectangle {
										width: parent.width * part.share * Math.max(0, Math.min(1, root.reveal * 1.6 - part.index * 0.15))
										height: parent.height
										radius: 3
										color: Watch.tone(part.modelData)
									}
								}
							}
						}
					}
				}
			}

			// ── the last two weeks of nights ─────────────────────────────────
			Tile {
				id: nightsTile

				order: 1
				Layout.fillWidth: true
				implicitHeight: nightsLayout.implicitHeight + 28
				visible: Watch.nights.length > 1

				ColumnLayout {
					id: nightsLayout

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 14
					anchors.leftMargin: 18
					anchors.rightMargin: 18
					spacing: 2

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							text: "Nights"
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							text: `Ø ${Watch.span(nights.average)}`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							tabular: true
						}
					}

					NightBars {
						id: nights

						Layout.fillWidth: true
						nights: root.fortnight
						selected: root.night?.date ?? ""
						onPicked: key => root.pick(key)
					}
				}
			}

			// ── the day's goals ──────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 12
				visible: Watch.known

				GoalTile {
					id: stepsTile

					order: 2
					icon: "walk"
					label: "Steps"
					value: root.today.steps ?? 0
					goal: root.today.stepsGoal ?? 0
					tone: Theme.primary
					wind: root.intro
				}

				GoalTile {
					id: caloriesTile

					order: 3
					icon: "fire"
					label: "kcal"
					value: root.today.calories ?? 0
					goal: root.today.caloriesGoal ?? 0
					tone: Theme.warning
					wind: root.intro
				}

				GoalTile {
					id: standTile

					order: 4
					icon: "human_handsup"
					label: "Stand hours"
					value: root.today.stand ?? 0
					goal: root.today.standGoal ?? 0
					tone: Theme.tertiary
					wind: root.intro
				}

				GoalTile {
					id: paiTile

					order: 5
					icon: "lightning_bolt"
					label: "PAI"
					value: root.today.pai ?? 0
					goal: 100
					tone: Theme.secondary
					wind: root.intro
				}
			}

			// ── the heart ────────────────────────────────────────────────────
			Tile {
				id: heartTile

				order: 6
				Layout.fillWidth: true
				implicitHeight: heartLayout.implicitHeight + 28
				visible: (root.today.heart ?? []).some(v => v > 0)

				ColumnLayout {
					id: heartLayout

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 14
					anchors.leftMargin: 18
					anchors.rightMargin: 18
					spacing: 8

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Glyph {
							icon: "heart_pulse"
							size: 17
							color: Theme.secondary
						}

						StyledText {
							text: "Heart today"
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							text: [
								(root.today.resting ?? 0) > 0 ? `resting ${root.today.resting}` : "",
								(root.today.max ?? 0) > 0 ? `max ${root.today.max}` : "",
								(root.today.last ?? 0) > 0 ? `now ${root.today.last}` : ""
							].filter(Boolean).join(" · ")
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							tabular: true
						}
					}

					HeartChart {
						Layout.fillWidth: true
						values: root.today.heart ?? []
						resting: root.today.resting ?? 0
						progress: root.heartDrawn
					}
				}
			}

			// ── stress and blood oxygen by the hour ──────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 12
				visible: Watch.known

				Tile {
					id: stressTile

					order: 7
					Layout.fillWidth: true
					Layout.preferredWidth: 1
					implicitHeight: stressLayout.implicitHeight + 28

					ColumnLayout {
						id: stressLayout

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 14
						spacing: 4

						RowLayout {
							Layout.fillWidth: true
							spacing: 7

							Glyph {
								icon: "head_heart_outline"
								size: 16
								color: Theme.tertiary
							}

							StyledText {
								text: "Stress"
								font.weight: Font.DemiBold
							}

							Item {
								Layout.fillWidth: true
							}

							StyledText {
								text: (root.today.stressNow ?? 0) > 0 ? `${root.today.stressNow} now` : ""
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
								tabular: true
							}
						}

						HourBars {
							id: stress

							Layout.fillWidth: true
							values: root.today.stress ?? []
							toneOf: value => value < 40 ? Theme.success : (value < 60 ? Theme.primary : (value < 80 ? Theme.warning : Theme.danger))
						}
					}
				}

				Tile {
					id: oxygenTile

					order: 8
					Layout.fillWidth: true
					Layout.preferredWidth: 1
					implicitHeight: oxygenLayout.implicitHeight + 28

					ColumnLayout {
						id: oxygenLayout

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 14
						spacing: 4

						RowLayout {
							Layout.fillWidth: true
							spacing: 7

							Glyph {
								icon: "water_percent"
								size: 16
								color: Theme.primary
							}

							StyledText {
								text: "Blood oxygen"
								font.weight: Font.DemiBold
							}

							Item {
								Layout.fillWidth: true
							}

							StyledText {
								text: (root.today.oxygenNow ?? 0) > 0 ? `${root.today.oxygenNow} %` : ""
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
								tabular: true
							}
						}

						HourBars {
							id: oxygen

							Layout.fillWidth: true
							values: root.today.oxygen ?? []
							floor: 85
							unit: " %"
							// the last 24 hours up to the sync, oldest first
							firstHour: (new Date((Watch.today.at ?? 0) * 1000).getHours() + 1) % 24
							toneOf: value => value >= 95 ? Theme.primary : (value >= 90 ? Theme.warning : Theme.danger)
						}
					}
				}
			}
		}
	}
}
