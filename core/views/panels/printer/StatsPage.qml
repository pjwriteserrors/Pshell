pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What the printer did: the totals counting up, the last fourteen days as
// bars (the part that failed or was stopped in red, the day under the
// pointer told above it), the filament by colour as a ring and the last
// prints.
Item {
	id: root

	// the page shows: it counts up again
	property bool current: true
	readonly property var stats: Printer.stats
	property real grow: 0

	Component.onCompleted: rise.start()
	onCurrentChanged: if (root.current) rise.restart()

	NumberAnimation {
		id: rise

		target: root
		property: "grow"
		from: 0
		to: 1
		duration: 1400
		easing.type: Easing.OutCubic
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.stats.count === 0
		icon: "chart_bar"
		title: "No prints yet"
		subtitle: "Every print that ends is counted here"
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 12
		visible: root.stats.count > 0

		// ── the totals ───────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ icon: "printer_3d", label: "Prints", value: root.stats.count * root.grow, text: v => Math.round(v), color: Theme.primary },
					{ icon: "check_circle", label: "Succeeded", value: root.stats.rate * 100 * root.grow, text: v => `${Math.round(v)} %`, color: Theme.success, ring: root.stats.rate },
					{ icon: "timer_outline", label: "Printed", value: root.stats.minutes * root.grow, text: v => v >= 600 ? `${Math.round(v / 60)} h` : Printer.duration(v * 60), color: Printer.hot },
					{ icon: "weight_gram", label: "Filament", value: root.stats.grams * root.grow, text: v => Printer.grams(v), color: Theme.secondary }
				]

				delegate: Card {
					id: tile

					required property var modelData
					required property int index

					Layout.fillWidth: true
					Layout.preferredHeight: 78
					order: tile.index
					cue: root.current
					radius: Theme.radius.large

					HoverHandler {
						id: tileHover
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 14
						spacing: 12

						Item {
							Layout.preferredWidth: 44
							Layout.preferredHeight: 44

							Ring {
								anchors.fill: parent
								visible: tile.modelData.ring !== undefined
								value: (tile.modelData.ring ?? 0) * root.grow
								thickness: 3
								color: tile.modelData.color
								animated: false
							}

							Rectangle {
								anchors.centerIn: parent
								width: tile.modelData.ring !== undefined ? 34 : 42
								height: width
								radius: width / 2
								color: tile.modelData.color
								scale: tileHover.hovered ? 1.08 : 1

								Behavior on scale {
									SpatialAnim {}
								}

								Glyph {
									anchors.centerIn: parent
									icon: tile.modelData.icon
									size: tile.modelData.ring !== undefined ? 17 : 20
									color: Theme.bg
									rotation: tileHover.hovered ? -12 : 0

									Behavior on rotation {
										SpatialAnim {}
									}
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: -1

							StyledText {
								Layout.fillWidth: true
								text: tile.modelData.text(tile.modelData.value)
								font.pixelSize: 22
								font.weight: Font.Bold
								tabular: true
							}

							StyledText {
								Layout.fillWidth: true
								text: tile.modelData.label
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 12

			// ── the last fourteen days ───────────────────────────────────
			Card {
				id: chart

				readonly property real peak: Math.max(60, ...root.stats.days.map(day => day.minutes))
				// the scale's lines: a round number of hours
				readonly property real stepMinutes: chart.peak > 600 ? 240 : (chart.peak > 240 ? 120 : 60)
				property int pointed: -1

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.minimumWidth: 300
				order: 4
				cue: root.current

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 14
					spacing: 8

					RowLayout {
						Layout.fillWidth: true

						SectionLabel {
							Layout.fillWidth: true
							text: "Two weeks"
						}

						StyledText {
							text: `${root.stats.days.reduce((s, d) => s + d.count, 0)} prints · Ø ${Printer.duration(root.stats.average * 60)}`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							tabular: true
						}
					}

					Item {
						id: plot

						Layout.fillWidth: true
						Layout.fillHeight: true

						readonly property real labelRoom: 18
						readonly property real plotTop: 30
						readonly property real room: plot.height - plot.labelRoom - plot.plotTop

						// the scale
						Repeater {
							model: Math.floor(chart.peak / chart.stepMinutes)

							delegate: Item {
								id: line

								required property int index
								readonly property real minutes: (line.index + 1) * chart.stepMinutes

								width: plot.width
								height: 1
								y: plot.plotTop + plot.room * (1 - line.minutes / chart.peak)

								Rectangle {
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.leftMargin: 30
									height: 1
									color: Qt.alpha(Theme.fg, 0.06)
								}

								StyledText {
									anchors.verticalCenter: parent.verticalCenter
									text: `${Math.round(line.minutes / 60)} h`
									tone: Theme.textFaint
									font.pixelSize: Theme.size.tiny
									tabular: true
								}
							}
						}

						Row {
							id: bars

							readonly property real barWidth: (width - spacing * 13) / 14

							x: 34
							width: parent.width - 34
							height: parent.height
							spacing: 5

							Repeater {
								model: root.stats.days

								delegate: Item {
									id: bar

									required property var modelData
									required property int index
									readonly property real share: bar.modelData.minutes / chart.peak
									readonly property real reveal: Math.max(0, Math.min(1, root.grow * 2.2 - bar.index * 0.08))
									readonly property bool pointed: chart.pointed === bar.index
									readonly property bool today: bar.index === 13

									width: bars.barWidth
									height: bars.height

									// a day with nothing: a dot
									Rectangle {
										anchors.horizontalCenter: parent.horizontalCenter
										y: plot.plotTop + plot.room - height
										width: 5
										height: 5
										radius: 2.5
										visible: bar.modelData.count === 0
										color: Qt.alpha(Theme.fg, bar.pointed ? 0.3 : 0.12)
									}

									Rectangle {
										id: column

										anchors.horizontalCenter: parent.horizontalCenter
										y: plot.plotTop + plot.room - height
										width: bar.pointed ? parent.width : parent.width * 0.86
										height: Math.max(6, plot.room * bar.share * bar.reveal)
										radius: Math.min(8, width / 2)
										visible: bar.modelData.count > 0
										gradient: Gradient {
											GradientStop {
												position: 0
												color: bar.pointed ? Qt.lighter(Printer.hot, 1.15) : Qt.lighter(Theme.primary, 1.12)
											}
											GradientStop {
												position: 1
												color: bar.pointed ? Printer.hot : Qt.alpha(Theme.primary, 0.7)
											}
										}

										Behavior on width {
											SpatialAnim {}
										}

										// what did not end well, from the top
										Rectangle {
											anchors.top: parent.top
											width: parent.width
											height: bar.modelData.count > 0 ? parent.height * bar.modelData.failed / bar.modelData.count : 0
											radius: parent.radius
											color: Theme.danger
											opacity: 0.9
										}
									}

									StyledText {
										anchors.horizontalCenter: parent.horizontalCenter
										anchors.bottom: parent.bottom
										text: Qt.formatDate(new Date(bar.modelData.start), "ddd").slice(0, 2)
										visible: bar.index % 2 === 1 || bars.barWidth > 26 || bar.today
										tone: bar.today ? Theme.primary : (bar.pointed ? Theme.text : Theme.textFaint)
										font.pixelSize: Theme.size.tiny
										font.weight: bar.today || bar.pointed ? Font.Bold : Font.Normal
									}

									HoverHandler {
										onHoveredChanged: {
											if (hovered) chart.pointed = bar.index;
											else if (chart.pointed === bar.index) chart.pointed = -1;
										}
									}
								}
							}
						}

						// the day under the pointer, told above its bar
						Rectangle {
							id: tip

							readonly property var day: chart.pointed >= 0 ? root.stats.days[chart.pointed] : null
							readonly property real anchorX: bars.x + chart.pointed * (bars.barWidth + bars.spacing) + bars.barWidth / 2
							readonly property real barTop: tip.day ? plot.plotTop + plot.room - Math.max(tip.day.count > 0 ? 6 : 5, plot.room * tip.day.minutes / chart.peak) : 0

							x: Math.max(0, Math.min(plot.width - width, tip.anchorX - width / 2))
							y: Math.max(0, tip.barTop - height - 8)
							width: tipText.implicitWidth + 20
							height: 26
							radius: 13
							color: Theme.layer3
							opacity: tip.day ? 1 : 0
							scale: tip.day ? 1 : 0.85
							transformOrigin: Item.Bottom
							visible: opacity > 0.01

							Behavior on x {
								enabled: tip.opacity > 0.5
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on y {
								enabled: tip.opacity > 0.5
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
							Behavior on scale {
								SpatialAnim {}
							}

							StyledText {
								id: tipText

								anchors.centerIn: parent
								text: tip.day ? `${Qt.formatDate(new Date(tip.day.start), "ddd d MMM")} · ${tip.day.count === 0 ? "nothing" : `${tip.day.count} · ${Printer.duration(tip.day.minutes * 60)}`}${tip.day.failed > 0 ? ` · ${tip.day.failed} failed` : ""}` : ""
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								tabular: true
							}
						}
					}
				}
			}

			ColumnLayout {
				Layout.preferredWidth: 310
				Layout.maximumWidth: 310
				Layout.fillHeight: true
				spacing: 12

				// ── filament by colour, as a ring ────────────────────────
				Card {
					Layout.fillWidth: true
					Layout.preferredHeight: 132
					order: 5
					cue: root.current

					RowLayout {
						anchors.fill: parent
						anchors.margins: 14
						spacing: 14

						Item {
							id: donut

							readonly property var parts: root.stats.colours.slice(0, 6)
							readonly property real total: Math.max(1, donut.parts.reduce((sum, part) => sum + part.grams, 0))
							property int pointed: -1

							Layout.preferredWidth: 104
							Layout.preferredHeight: 104

							Repeater {
								model: donut.parts

								delegate: Shape {
									id: slice

									required property var modelData
									required property int index
									readonly property real before: donut.parts.slice(0, slice.index).reduce((sum, part) => sum + part.grams, 0) / donut.total
									readonly property real share: slice.modelData.grams / donut.total
									readonly property real gap: donut.parts.length > 1 ? 3 : 0

									anchors.fill: parent
									preferredRendererType: Shape.CurveRenderer
									scale: donut.pointed === slice.index ? 1.06 : 1

									Behavior on scale {
										SpatialAnim {}
									}

									// a rim, so a black or white spool still shows
									ShapePath {
										strokeColor: Qt.alpha(Theme.fg, 0.16)
										strokeWidth: 15
										fillColor: "transparent"
										capStyle: ShapePath.FlatCap

										PathAngleArc {
											centerX: donut.width / 2
											centerY: donut.height / 2
											radiusX: donut.width / 2 - 8
											radiusY: donut.height / 2 - 8
											startAngle: -90 + slice.before * 360 * root.grow
											sweepAngle: Math.max(0.5, slice.share * 360 * root.grow - slice.gap)
										}
									}

									ShapePath {
										strokeColor: Printer.rgb(slice.modelData.color)
										strokeWidth: 13
										fillColor: "transparent"
										capStyle: ShapePath.FlatCap

										PathAngleArc {
											centerX: donut.width / 2
											centerY: donut.height / 2
											radiusX: donut.width / 2 - 8
											radiusY: donut.height / 2 - 8
											startAngle: -90 + slice.before * 360 * root.grow
											sweepAngle: Math.max(0.5, slice.share * 360 * root.grow - slice.gap)
										}
									}
								}
							}

							Column {
								anchors.centerIn: parent
								spacing: -2

								StyledText {
									anchors.horizontalCenter: parent.horizontalCenter
									text: donut.pointed >= 0 ? Printer.grams(donut.parts[donut.pointed].grams) : Printer.grams(root.stats.grams * root.grow)
									font.pixelSize: Theme.size.title
									font.weight: Font.Bold
									tabular: true
								}

								StyledText {
									anchors.horizontalCenter: parent.horizontalCenter
									text: donut.pointed >= 0 ? donut.parts[donut.pointed].type : "in all"
									tone: Theme.textMuted
									font.pixelSize: Theme.size.tiny
								}
							}
						}

						// the legend; a line under the pointer lifts its part of the ring
						Column {
							Layout.fillWidth: true
							Layout.alignment: Qt.AlignVCenter
							spacing: 3

							SectionLabel {
								text: "Filament"
								bottomPadding: 3
							}

							Repeater {
								model: donut.parts.slice(0, 5)

								delegate: Rectangle {
									id: entry

									required property var modelData
									required property int index

									width: parent.width
									height: 18
									radius: 9
									color: donut.pointed === entry.index ? Theme.layer2 : "transparent"

									Behavior on color {
										ColorAnim {}
									}

									HoverHandler {
										onHoveredChanged: {
											if (hovered) donut.pointed = entry.index;
											else if (donut.pointed === entry.index) donut.pointed = -1;
										}
									}

									Rectangle {
										id: swatch

										anchors.left: parent.left
										anchors.leftMargin: 4
										anchors.verticalCenter: parent.verticalCenter
										width: 10
										height: 10
										radius: 5
										color: Printer.rgb(entry.modelData.color)
										border.width: 1
										border.color: Qt.alpha(Theme.fg, 0.2)
									}

									StyledText {
										anchors.left: swatch.right
										anchors.leftMargin: 6
										anchors.verticalCenter: parent.verticalCenter
										text: entry.modelData.type
										font.pixelSize: Theme.size.small
									}

									StyledText {
										anchors.right: parent.right
										anchors.rightMargin: 6
										anchors.verticalCenter: parent.verticalCenter
										text: Printer.grams(entry.modelData.grams)
										tone: Theme.textMuted
										font.pixelSize: Theme.size.small
										tabular: true
									}
								}
							}
						}
					}
				}

				// ── the last prints ──────────────────────────────────────
				Card {
					Layout.fillWidth: true
					Layout.fillHeight: true
					order: 6
					cue: root.current

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 14
						anchors.bottomMargin: 10
						spacing: 8

						SectionLabel {
							text: "Last prints"
						}

						ListView {
							id: recent

							Layout.fillWidth: true
							Layout.fillHeight: true
							clip: true
							spacing: 4
							model: Printer.history.slice().reverse().slice(0, 30)
							boundsBehavior: Flickable.StopAtBounds

							delegate: Rectangle {
								id: row

								required property var modelData
								required property int index

								width: ListView.view.width
								height: 44
								radius: Theme.radius.medium
								color: rowHover.hovered ? Theme.layer2 : "transparent"
								opacity: 0

								Behavior on color {
									ColorAnim {}
								}

								HoverHandler {
									id: rowHover
								}

								Component.onCompleted: appear.start()

								SequentialAnimation {
									id: appear

									PauseAnimation {
										duration: 260 + Math.min(row.index, 8) * 45
									}
									ParallelAnimation {
										NumberAnimation {
											target: row
											property: "opacity"
											to: 1
											duration: 260
										}
										NumberAnimation {
											target: nudge
											property: "x"
											from: 14
											to: 0
											duration: 460
											easing.type: Easing.OutBack
										}
									}
								}

								transform: Translate {
									id: nudge
								}

								HistoryRow {
									anchors.fill: parent
									anchors.leftMargin: 4
									anchors.rightMargin: 6
									item: row.modelData
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							visible: root.stats.longest !== null
							text: `Longest: ${Printer.nameOf(root.stats.longest?.name)} · ${Printer.duration(Number(root.stats.longest?.minutes ?? 0) * 60)}`
							elide: Text.ElideRight
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
		}
	}
}
