pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../lib/GameText.js" as GameText

// A game's landing page, over the library (I, or the chart button): how far
// along it is – the play time against how long it takes to beat
// (HowLongToBeat: the story, with extras, everything; the goal is picked
// here) and Steam's achievements –, the play of the last four weeks a bar a
// day, and the sessions. Numbers count up and bars rise as it opens.
FocusScope {
	id: root

	property var game: null
	property bool open: false
	readonly property var stats: root.game ? (Games.stats[root.game.id] ?? null) : null
	readonly property bool loading: root.game !== null && Games.statsLoading === root.game?.id && root.stats === null
	readonly property real hours: (root.stats?.playtime ?? root.game?.playtime ?? 0) / 60
	readonly property var hltb: root.stats?.hltb ?? null
	readonly property string goal: root.stats?.goal || "main"
	readonly property real target: root.goal === "done" ? 0 : (root.hltb ? (root.hltb[root.goal] || root.hltb.main || 0) : 0)
	readonly property real progress: root.goal === "done" ? 1 : (root.target > 0 ? Math.min(1, root.hours / root.target) : (root.trophies ? root.trophies.got / root.trophies.total : 0))
	readonly property var trophies: root.stats?.achievements ?? null
	readonly property var days: root.stats?.days ?? []
	readonly property real dayMax: Math.max(60, ...root.days)
	// 0 → 1 as it opens: everything that rises follows this
	property real rise: 0

	signal closed

	function show(game) {
		root.game = game;
		root.open = true;
		Games.loadStats(game.id);
		root.forceActiveFocus();
		riseAnim.restart();
	}

	function hide() {
		if (!root.open) return;
		root.open = false;
		root.closed();
	}

	function hoursText(value) {
		if (value <= 0) return "–";
		if (value < 1) return `${Math.round(value * 60)} min`;
		return value < 10 ? `${value.toFixed(1)} h` : `${Math.round(value)} h`;
	}

	anchors.fill: parent
	visible: card.opacity > 0.01
	Keys.onEscapePressed: root.hide()
	Keys.onPressed: event => {
		if (event.key === Qt.Key_I) {
			root.hide();
			event.accepted = true;
		}
	}

	NumberAnimation {
		id: riseAnim

		target: root
		property: "rise"
		from: 0
		to: 1
		duration: 1100
		easing.type: Easing.OutCubic
	}

	// a click beside the page closes it
	MouseArea {
		anchors.fill: parent
		enabled: root.open
		onClicked: root.hide()
	}

	Rectangle {
		anchors.fill: parent
		color: "black"
		opacity: root.open ? 0.45 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
	}

	Rectangle {
		id: card

		anchors.right: parent.right
		anchors.rightMargin: 28
		anchors.verticalCenter: parent.verticalCenter
		width: Math.min(parent.width * 0.46, 760)
		height: Math.min(parent.height - 56, column.implicitHeight + 56)
		radius: 28
		color: Qt.rgba(0.06, 0.06, 0.08, 0.86)
		border.width: 1
		border.color: Qt.rgba(1, 1, 1, 0.08)
		opacity: root.open ? 1 : 0
		transform: Translate {
			x: root.open ? 0 : 80
			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		Flickable {
			anchors.fill: parent
			anchors.margins: 28
			contentHeight: column.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			ColumnLayout {
				id: column

				width: parent.width
				spacing: 22

				// ── the head: name and the ring ─────────────────────────────
				RowLayout {
					Layout.fillWidth: true
					spacing: 22

					Item {
						Layout.preferredWidth: 150
						Layout.preferredHeight: 150

						Canvas {
							id: ring

							readonly property real shown: root.progress * root.rise

							anchors.fill: parent
							onShownChanged: requestPaint()
							onPaint: {
								const ctx = getContext("2d");
								ctx.reset();
								const c = width / 2;
								const r = c - 9;
								ctx.lineCap = "round";
								ctx.lineWidth = 12;
								ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.08);
								ctx.beginPath();
								ctx.arc(c, c, r, 0, Math.PI * 2);
								ctx.stroke();
								if (ring.shown <= 0) return;
								const gradient = ctx.createLinearGradient(0, 0, width, height);
								gradient.addColorStop(0, Theme.primary);
								gradient.addColorStop(1, Theme.tertiary);
								ctx.strokeStyle = gradient;
								ctx.beginPath();
								ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ring.shown);
								ctx.stroke();
							}
						}

						ColumnLayout {
							anchors.centerIn: parent
							spacing: -2

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: root.loading ? "…" : `${Math.round(root.progress * root.rise * 100)}%`
								tone: "white"
								surface: "transparent"
								tabular: true
								font.pixelSize: 36
								font.weight: Font.Black
							}

							StyledText {
								Layout.alignment: Qt.AlignHCenter
								text: root.goal === "done" ? "beaten" : (root.target > 0 ? ({ main: "of the story", plus: "with extras", full: "of everything" })[root.goal] : (root.trophies ? "achievements" : "no time known"))
								tone: Qt.rgba(1, 1, 1, 0.6)
								surface: "transparent"
								font.pixelSize: Theme.size.small
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							text: root.game?.name ?? ""
							tone: "white"
							surface: "transparent"
							font.pixelSize: 30
							font.weight: Font.Black
							wrapMode: Text.WordWrap
							maximumLineCount: 2
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								if (root.loading) return "Looking it up…";
								if (root.goal === "done") return "Marked as beaten.";
								if (root.target <= 0) return "How long it takes is not known.";
								const left = root.target - root.hours;
								return left > 0 ? `About ${root.hoursText(left)} to go.` : `Past it by ${root.hoursText(-left)} – still going.`;
							}
							tone: Qt.rgba(1, 1, 1, 0.7)
							surface: "transparent"
							font.pixelSize: Theme.size.body
							wrapMode: Text.WordWrap
						}

						// what beaten means for this one
						Row {
							Layout.topMargin: 6
							spacing: 6

							Repeater {
								model: [{ id: "main", label: "Story" }, { id: "plus", label: "+ Extras" }, { id: "full", label: "100 %" }, { id: "done", label: "Beaten" }]

								delegate: Clickable {
									id: goalChip

									required property var modelData
									readonly property bool chosen: root.goal === goalChip.modelData.id

									width: goalLabel.implicitWidth + 24
									height: 30
									radius: 15
									color: goalChip.chosen ? Theme.primary : Qt.rgba(1, 1, 1, goalChip.hovered ? 0.14 : 0.08)
									onClicked: if (root.game) Games.setGoal(root.game.id, goalChip.modelData.id === "main" ? "" : goalChip.modelData.id)

									Behavior on color {
										ColorAnim {}
									}

									StyledText {
										id: goalLabel

										anchors.centerIn: parent
										text: goalChip.modelData.label
										tone: goalChip.chosen ? Theme.onPrimary : "white"
										surface: "transparent"
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}
								}
							}
						}
					}
				}

				// ── the numbers ────────────────────────────────────────────
				GridLayout {
					Layout.fillWidth: true
					columns: 4
					columnSpacing: 10
					rowSpacing: 10

					Repeater {
						model: [
							{ icon: "clock_outline", label: "Played", value: root.hoursText(root.hours * root.rise) },
							{ icon: "history", label: "Last played", value: GameText.ago(root.stats?.lastPlayed ?? root.game?.lastPlayed ?? 0) || "Never" },
							{ icon: "play_circle", label: "Sessions", value: root.stats?.sessions ? String(Math.round(root.stats.sessions * root.rise)) : "–" },
							{ icon: "timer_outline", label: "Longest", value: root.stats?.longest ? root.hoursText(root.stats.longest / 60) : "–" }
						]

						delegate: Rectangle {
							id: tile

							required property var modelData
							required property int index

							Layout.fillWidth: true
							Layout.preferredHeight: 84
							radius: Theme.radius.large
							color: Qt.rgba(1, 1, 1, 0.06)
							opacity: Math.max(0, Math.min(1, root.rise * 3 - tile.index * 0.3))
							transform: Translate {
								y: 14 * (1 - tile.opacity)
							}

							ColumnLayout {
								anchors.fill: parent
								anchors.margins: 14
								spacing: 4

								Glyph {
									icon: tile.modelData.icon
									size: 18
									color: Theme.primary
									surface: "transparent"
								}

								Item {
									Layout.fillHeight: true
								}

								StyledText {
									text: tile.modelData.value
									tone: "white"
									surface: "transparent"
									tabular: true
									font.pixelSize: 20
									font.weight: Font.Bold
								}

								StyledText {
									text: tile.modelData.label
									tone: Qt.rgba(1, 1, 1, 0.55)
									surface: "transparent"
									font.pixelSize: Theme.size.small
								}
							}
						}
					}
				}

				// ── how long to beat ──────────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.hltb !== null
					spacing: 10

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							Layout.fillWidth: true
							text: "How long to beat"
							tone: "white"
							surface: "transparent"
							font.pixelSize: 17
							font.weight: Font.Bold
						}

						StyledText {
							text: root.hltb && root.hltb.name !== root.game?.name ? `as “${root.hltb.name}” on HowLongToBeat` : "HowLongToBeat"
							tone: Qt.rgba(1, 1, 1, 0.45)
							surface: "transparent"
							font.pixelSize: Theme.size.tiny
						}
					}

					Repeater {
						model: root.hltb ? [{ id: "main", label: "Story", hours: root.hltb.main }, { id: "plus", label: "Story + extras", hours: root.hltb.plus }, { id: "full", label: "Everything", hours: root.hltb.full }].filter(row => row.hours > 0) : []

						delegate: Item {
							id: bar

							required property var modelData
							required property int index
							readonly property real longest: Math.max(root.hltb?.full || 0, root.hltb?.plus || 0, root.hltb?.main || 0, root.hours)
							readonly property real filled: Math.min(1, root.hours / bar.modelData.hours)
							readonly property bool chosen: root.goal === bar.modelData.id

							Layout.fillWidth: true
							Layout.preferredHeight: 38

							StyledText {
								id: barLabel

								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: 120
								text: bar.modelData.label
								tone: bar.chosen ? "white" : Qt.rgba(1, 1, 1, 0.65)
								surface: "transparent"
								font.weight: bar.chosen ? Font.Bold : Font.Normal
								font.pixelSize: Theme.size.body
							}

							Rectangle {
								id: track

								anchors.left: barLabel.right
								anchors.right: hoursLabel.left
								anchors.rightMargin: 12
								anchors.verticalCenter: parent.verticalCenter
								height: 12
								radius: 6
								color: Qt.rgba(1, 1, 1, 0.08)

								// the time it takes, on one scale with the others
								Rectangle {
									width: track.width * bar.modelData.hours / bar.longest
									height: parent.height
									radius: 6
									color: Qt.rgba(1, 1, 1, bar.chosen ? 0.14 : 0.07)
								}

								// how far along
								Rectangle {
									width: track.width * Math.min(root.hours, bar.modelData.hours) / bar.longest * Math.max(0, Math.min(1, root.rise * 1.4 - bar.index * 0.15))
									height: parent.height
									radius: 6
									gradient: Gradient {
										orientation: Gradient.Horizontal
										GradientStop {
											position: 0
											color: Theme.primary
										}
										GradientStop {
											position: 1
											color: bar.filled >= 1 ? Theme.success : Theme.tertiary
										}
									}
								}
							}

							StyledText {
								id: hoursLabel

								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: 96
								horizontalAlignment: Text.AlignRight
								text: bar.filled >= 1 ? `✓ ${root.hoursText(bar.modelData.hours)}` : root.hoursText(bar.modelData.hours)
								tone: bar.filled >= 1 ? Theme.success : Qt.rgba(1, 1, 1, 0.75)
								surface: "transparent"
								tabular: true
								font.pixelSize: Theme.size.body
								font.weight: Font.DemiBold
							}
						}
					}
				}

				// ── the last four weeks ───────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 10

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							Layout.fillWidth: true
							text: "Last four weeks"
							tone: "white"
							surface: "transparent"
							font.pixelSize: 17
							font.weight: Font.Bold
						}

						StyledText {
							readonly property real total: root.days.reduce((sum, minutes) => sum + minutes, 0)

							text: total > 0 ? `${root.hoursText(total / 60)} · ${root.stats?.average ? `about ${root.hoursText(root.stats.average / 60)} a session` : ""}` : "Not played lately"
							tone: Qt.rgba(1, 1, 1, 0.5)
							surface: "transparent"
							font.pixelSize: Theme.size.small
						}
					}

					Row {
						id: chart

						Layout.fillWidth: true
						Layout.preferredHeight: 96
						spacing: 4

						Repeater {
							model: root.days.length > 0 ? root.days : new Array(28).fill(0)

							delegate: Item {
								id: day

								required property var modelData
								required property int index
								readonly property real share: day.modelData / root.dayMax

								width: (chart.width - chart.spacing * 27) / 28
								height: chart.height

								Rectangle {
									anchors.bottom: parent.bottom
									width: parent.width
									radius: Math.min(4, width / 2)
									height: Math.max(3, (parent.height - 4) * day.share * Math.max(0, Math.min(1, root.rise * 2 - day.index / 40)))
									color: day.modelData > 0 ? Qt.alpha(day.index === 27 ? Theme.tertiary : Theme.primary, 0.5 + 0.5 * day.share) : Qt.rgba(1, 1, 1, 0.07)

									HoverHandler {
										id: dayHover
									}

									StyledText {
										anchors.bottom: parent.top
										anchors.bottomMargin: 4
										anchors.horizontalCenter: parent.horizontalCenter
										visible: dayHover.hovered && day.modelData > 0
										text: root.hoursText(day.modelData / 60)
										tone: "white"
										surface: "transparent"
										font.pixelSize: Theme.size.tiny
									}
								}
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							text: "4 weeks ago"
							tone: Qt.rgba(1, 1, 1, 0.35)
							surface: "transparent"
							font.pixelSize: Theme.size.tiny
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							text: "today"
							tone: Qt.rgba(1, 1, 1, 0.35)
							surface: "transparent"
							font.pixelSize: Theme.size.tiny
						}
					}
				}

				// ── achievements ──────────────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.trophies !== null
					spacing: 10

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							Layout.fillWidth: true
							text: "Achievements"
							tone: "white"
							surface: "transparent"
							font.pixelSize: 17
							font.weight: Font.Bold
						}

						StyledText {
							text: root.trophies ? `${Math.round(root.trophies.got * root.rise)} of ${root.trophies.total}` : ""
							tone: Qt.rgba(1, 1, 1, 0.7)
							surface: "transparent"
							tabular: true
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
						}
					}

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 10
						radius: 5
						color: Qt.rgba(1, 1, 1, 0.08)

						Rectangle {
							width: parent.width * (root.trophies ? root.trophies.got / root.trophies.total : 0) * root.rise
							height: parent.height
							radius: 5
							color: Theme.warning
						}
					}

					Repeater {
						model: root.trophies?.recent ?? []

						delegate: RowLayout {
							id: trophy

							required property var modelData
							required property int index

							Layout.fillWidth: true
							spacing: 12
							opacity: Math.max(0, Math.min(1, root.rise * 3 - 1 - trophy.index * 0.25))

							Rectangle {
								Layout.preferredWidth: 40
								Layout.preferredHeight: 40
								radius: 8
								color: Qt.rgba(1, 1, 1, 0.08)
								clip: true

								Image {
									anchors.fill: parent
									source: trophy.modelData.icon
									sourceSize: Qt.size(80, 80)
									asynchronous: true
									fillMode: Image.PreserveAspectCrop
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: trophy.modelData.name
									tone: "white"
									surface: "transparent"
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}

								StyledText {
									Layout.fillWidth: true
									text: trophy.modelData.desc
									tone: Qt.rgba(1, 1, 1, 0.55)
									surface: "transparent"
									font.pixelSize: Theme.size.small
									elide: Text.ElideRight
								}
							}

							StyledText {
								text: GameText.ago(trophy.modelData.time)
								tone: Qt.rgba(1, 1, 1, 0.4)
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
							}
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: !root.loading && root.hltb === null && root.trophies === null
					text: "HowLongToBeat does not know this one (or was not reachable), and it has no Steam achievements."
					tone: Qt.rgba(1, 1, 1, 0.5)
					surface: "transparent"
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}
	}
}
