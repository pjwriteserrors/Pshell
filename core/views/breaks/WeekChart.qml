pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// This work week, Monday to Friday: screen time and water as a pair of
// bars that share one goal line (8 h, the day's water goal), a marker above
// every day with a headache. Values show for today and under the pointer.
// The days stay put while their numbers change; `play()` grows the bars
// one day after another.
Item {
	id: root

	property var days: []
	readonly property real screenPeak: Math.max(8 * 3600, ...root.days.map(day => day.screen)) * 1.1
	// the goal line sits where 8 h would reach
	readonly property real goalAt: 8 * 3600 / root.screenPeak

	signal replay

	function play() {
		root.replay();
	}

	implicitHeight: 196

	RowLayout {
		id: legend

		anchors.right: parent.right
		anchors.top: parent.top
		spacing: 12

		Repeater {
			model: [
				{ icon: "monitor", color: Theme.tertiary },
				{ icon: "cup_water", color: Theme.primary }
			]

			delegate: Row {
				id: key

				required property var modelData

				spacing: 4

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: 8
					height: 8
					radius: 4
					color: key.modelData.color
				}

				Glyph {
					icon: key.modelData.icon
					size: 13
					color: Theme.textSubtle
				}
			}
		}
	}

	Item {
		id: plot

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: legend.bottom
		anchors.topMargin: 6
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 20

		// bars grow from here
		readonly property real barTop: 34
		readonly property real barArea: plot.height - plot.barTop

		// goal line
		Row {
			x: 0
			y: plot.barTop + plot.barArea * (1 - root.goalAt)
			width: plot.width
			spacing: 4

			Repeater {
				model: Math.max(0, Math.ceil(plot.width / 8))

				delegate: Rectangle {
					width: 4
					height: 1
					color: Theme.textFaint
				}
			}
		}

		RowLayout {
			anchors.fill: parent
			spacing: 4

			Repeater {
				model: root.days.length

				delegate: Item {
					id: column

					required property int index

					readonly property var day: root.days[column.index] || ({ key: "", screen: 0, ml: 0, headaches: [], ahead: true })
					readonly property bool isToday: column.day.key === Breaks.today
					readonly property bool hurt: column.day.headaches.length > 0
					readonly property bool empty: column.day.ahead || (column.day.screen < 60 && column.day.ml === 0)
					readonly property bool labelled: !column.empty && (column.isToday || hover.hovered)
					property real grow: 1

					Layout.fillWidth: true
					Layout.fillHeight: true

					HoverHandler {
						id: hover
					}

					// weekday, under its own bars
					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.bottom
						anchors.topMargin: 4
						text: column.day.date ? Qt.formatDate(column.day.date, "ddd") : ""
						tone: column.isToday ? Theme.primary : (column.day.ahead ? Theme.textFaint : Theme.textSubtle)
						font.pixelSize: Theme.size.small
						font.weight: column.isToday ? Font.Bold : Font.Normal
					}

					Connections {
						target: root
						function onReplay() {
							column.grow = 0;
							growIn.restart();
						}
					}

					SequentialAnimation {
						id: growIn

						PauseAnimation {
							duration: 60 + column.index * 55
						}
						SpatialAnim {
							target: column
							property: "grow"
							to: 1
							duration: Motion.extraLong + 200
						}
					}

					Rectangle {
						anchors.fill: parent
						anchors.topMargin: -4
						radius: Theme.radius.medium
						color: hover.hovered && !column.empty ? Theme.layer2 : "transparent"

						Behavior on color {
							ColorAnim {}
						}
					}

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 0
						visible: column.hurt
						icon: "head_alert_outline"
						size: 16
						color: Theme.danger
						scale: column.grow
						rotation: (1 - column.grow) * -40
					}

					// values
					Column {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: bars.top
						anchors.bottomMargin: 4
						opacity: column.labelled ? column.grow : 0

						Behavior on opacity {
							Anim {}
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							text: column.day.screen >= 3600 ? `${(column.day.screen / 3600).toFixed(1)}h` : `${Math.round(column.day.screen / 60)}m`
							tone: Theme.tertiary
							font.pixelSize: Theme.size.tiny
							tabular: true
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							text: `${(column.day.ml / 1000).toFixed(1)}L`
							tone: Theme.primary
							font.pixelSize: Theme.size.tiny
							tabular: true
						}
					}

					Row {
						id: bars

						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						height: Math.max(screenBar.height, waterBar.height)
						spacing: 3

						Rectangle {
							id: screenBar

							anchors.bottom: parent.bottom
							width: 12
							height: column.empty ? 3 : Math.max(3, plot.barArea * column.day.screen / root.screenPeak * column.grow)
							radius: 4
							color: column.empty ? Theme.layer2 : (column.hurt ? Theme.danger : Theme.tertiary)
							opacity: column.isToday || column.hurt || hover.hovered ? 1 : 0.55
						}

						Rectangle {
							id: waterBar

							anchors.bottom: parent.bottom
							width: 12
							// the goal reaches the goal line
							height: column.empty ? 3 : Math.max(3, plot.barArea * root.goalAt * Math.min(1 / root.goalAt, column.day.ml / Breaks.goalMl) * column.grow)
							radius: 4
							color: column.empty ? Theme.layer2 : Theme.primary
							opacity: column.isToday || hover.hovered ? 1 : 0.55
						}
					}
				}
			}
		}
	}
}
