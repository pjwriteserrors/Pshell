pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What the printer did: the totals counting up, the last fourteen days as
// bars (the part that failed or was stopped in red), the filament by colour
// and the last prints.
Item {
	id: root

	readonly property var stats: Printer.stats
	// counts up when the page comes in
	property real grow: 0

	Component.onCompleted: rise.start()
	onVisibleChanged: if (visible) rise.restart()

	NumberAnimation {
		id: rise

		target: root
		property: "grow"
		from: 0
		to: 1
		duration: 1200
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
		spacing: 14
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

				delegate: Rectangle {
					id: tile

					required property var modelData
					required property int index

					Layout.fillWidth: true
					Layout.preferredHeight: 74
					radius: Theme.radius.large
					color: Theme.layer1
					border.width: 1
					border.color: Theme.outline
					opacity: Math.min(1, root.grow * 4 - tile.index * 0.5)

					transform: Translate {
						y: (1 - Math.min(1, root.grow * 3 - tile.index * 0.3)) * 14
					}

					RowLayout {
						anchors.fill: parent
						anchors.margins: 14
						spacing: 12

						Item {
							Layout.preferredWidth: 38
							Layout.preferredHeight: 38

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
								width: tile.modelData.ring !== undefined ? 28 : 38
								height: width
								radius: width / 2
								color: Qt.alpha(tile.modelData.color, 0.14)

								Glyph {
									anchors.centerIn: parent
									icon: tile.modelData.icon
									size: 16
									color: tile.modelData.color
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								text: tile.modelData.text(tile.modelData.value)
								font.pixelSize: 20
								font.weight: Font.Bold
								tabular: true
							}

							StyledText {
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
			spacing: 14

			// ── the last fourteen days ───────────────────────────────────
			Rectangle {
				id: chart

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.minimumWidth: 300
				radius: Theme.radius.large
				color: Theme.layer1
				border.width: 1
				border.color: Theme.outline

				readonly property real peak: Math.max(60, ...root.stats.days.map(day => day.minutes))
				property int pointed: -1

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
							text: {
								const day = chart.pointed >= 0 ? root.stats.days[chart.pointed] : null;
								if (!day) return `${root.stats.days.reduce((s, d) => s + d.count, 0)} prints · Ø ${Printer.duration(root.stats.average * 60)}`;
								return `${Qt.formatDate(new Date(day.start), "ddd d MMM")} · ${day.count} · ${Printer.duration(day.minutes * 60)}`;
							}
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							tabular: true
						}
					}

					Row {
						id: bars

						Layout.fillWidth: true
						Layout.fillHeight: true
						spacing: 5

						readonly property real barWidth: (width - spacing * 13) / 14

						Repeater {
							model: root.stats.days

							delegate: Item {
								id: bar

								required property var modelData
								required property int index
								readonly property real share: bar.modelData.minutes / chart.peak
								readonly property real reveal: Math.max(0, Math.min(1, root.grow * 2.2 - bar.index * 0.08))

								width: bars.barWidth
								height: bars.height

								Rectangle {
									anchors.bottom: parent.bottom
									width: parent.width
									height: Math.max(bar.modelData.count > 0 ? 4 : 2, (parent.height - 18) * bar.share * bar.reveal)
									radius: Math.min(6, width / 2)
									color: bar.modelData.count === 0 ? Qt.alpha(Theme.fg, 0.07) : (chart.pointed === bar.index ? Printer.hot : Theme.primary)
									opacity: chart.pointed < 0 || chart.pointed === bar.index ? 1 : 0.55

									Behavior on color {
										ColorAnim {}
									}
									Behavior on opacity {
										Anim {}
									}

									// what did not end well, from the top
									Rectangle {
										anchors.top: parent.top
										width: parent.width
										height: bar.modelData.count > 0 ? parent.height * bar.modelData.failed / bar.modelData.count : 0
										radius: parent.radius
										color: Theme.danger
										opacity: 0.85
									}
								}

								StyledText {
									anchors.horizontalCenter: parent.horizontalCenter
									anchors.top: parent.top
									text: Qt.formatDate(new Date(bar.modelData.start), "ddd").slice(0, 2)
									visible: bar.index % 2 === 1 || bars.barWidth > 26
									tone: Theme.textFaint
									font.pixelSize: Theme.size.tiny
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
				}
			}

			// ── filament by colour, the last prints ──────────────────────
			ColumnLayout {
				Layout.preferredWidth: 300
				Layout.maximumWidth: 300
				Layout.fillHeight: true
				spacing: 10

				SectionLabel {
					text: "Filament by colour"
				}

				// one bar, cut by colour
				Row {
					Layout.fillWidth: true
					Layout.preferredHeight: 14
					spacing: 2

					Repeater {
						model: root.stats.colours.slice(0, 6)

						delegate: Rectangle {
							required property var modelData

							width: Math.max(4, (parent.width - 10) * modelData.grams / Math.max(1, root.stats.grams) * root.grow)
							height: parent.height
							radius: 4
							color: Printer.rgb(modelData.color)
							border.width: 1
							border.color: Qt.alpha(Theme.fg, 0.15)
						}
					}
				}

				Flow {
					Layout.fillWidth: true
					spacing: 10

					Repeater {
						model: root.stats.colours.slice(0, 6)

						delegate: Row {
							required property var modelData

							spacing: 5

							Rectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: 10
								height: 10
								radius: 5
								color: Printer.rgb(modelData.color)
								border.width: 1
								border.color: Qt.alpha(Theme.fg, 0.2)
							}

							StyledText {
								text: `${modelData.type} ${Printer.grams(modelData.grams)}`
								font.pixelSize: Theme.size.small
								tone: Theme.textMuted
							}
						}
					}
				}

				SectionLabel {
					Layout.topMargin: 6
					text: "Last prints"
				}

				ListView {
					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					spacing: 8
					model: Printer.history.slice().reverse().slice(0, 30)
					boundsBehavior: Flickable.StopAtBounds

					delegate: HistoryRow {
						required property var modelData

						width: ListView.view.width
						item: modelData
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: root.stats.longest !== null
					text: `Longest: ${Printer.nameOf(root.stats.longest?.name)} · ${Printer.duration(Number(root.stats.longest?.minutes ?? 0) * 60)}`
					tone: Theme.textFaint
					font.pixelSize: Theme.size.small
				}
			}
		}
	}
}
