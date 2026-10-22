pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A week, Monday to Sunday, a bar a day. The picked day wears the accent,
// its value and that of the day under the pointer stand above the bar; the
// dashed line is the week's average. `play()` grows the bars one after
// another.
Item {
	id: root

	// [{ key, date, total, ahead }]
	property var days: []
	property string selected: ""
	property real average: 0
	readonly property real peak: Math.max(3600, ...root.days.map(day => day.total)) * 1.08

	signal picked(string key)
	signal replay

	function play() {
		root.replay();
	}

	implicitHeight: 132

	Item {
		id: plot

		anchors.fill: parent
		anchors.topMargin: 20
		anchors.bottomMargin: 20

		Row {
			y: Math.round(plot.height * (1 - root.average / root.peak))
			width: plot.width
			visible: root.average > 0
			spacing: 4

			Behavior on y {
				SpatialAnim {}
			}

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
			spacing: 6

			Repeater {
				model: 7

				delegate: Item {
					id: column

					required property int index

					readonly property var day: root.days[column.index] || ({ key: "", date: null, total: 0, ahead: true })
					readonly property bool isSelected: column.day.key === root.selected
					readonly property bool isToday: column.day.key === Screentime.today
					readonly property bool empty: column.day.total < 60
					property real grow: 1
					property real level: column.day.total / root.peak

					Layout.fillWidth: true
					Layout.fillHeight: true

					Behavior on level {
						SpatialAnim {
							duration: Motion.extraLong
						}
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
							duration: 120 + column.index * 50
						}
						SpatialAnim {
							target: column
							property: "grow"
							to: 1
							duration: Motion.extraLong + 200
						}
					}

					HoverHandler {
						id: hover

						cursorShape: column.day.ahead ? Qt.ArrowCursor : Qt.PointingHandCursor
					}

					TapHandler {
						enabled: !column.day.ahead
						onTapped: root.picked(column.day.key)
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: bar.top
						anchors.bottomMargin: 4
						opacity: !column.empty && (column.isSelected || hover.hovered) ? column.grow : 0
						text: Screentime.format(column.day.total)
						tone: column.isSelected ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						tabular: true

						Behavior on opacity {
							Anim {}
						}
					}

					Rectangle {
						id: bar

						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						width: Math.min(34, parent.width)
						height: column.empty ? 4 : Math.max(4, plot.height * column.level * column.grow)
						radius: Math.min(8, height / 2)
						color: column.empty ? Theme.layer2 : (column.isSelected ? Theme.primary : Qt.alpha(Theme.primary, hover.hovered ? 0.6 : 0.34))

						Behavior on color {
							ColorAnim {}
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.bottom
						anchors.topMargin: 5
						text: column.day.date ? Qt.formatDate(column.day.date, "ddd") : ""
						tone: column.isSelected ? Theme.primary : (column.day.ahead ? Theme.textFaint : (column.isToday ? Theme.text : Theme.textSubtle))
						font.pixelSize: Theme.size.small
						font.weight: column.isSelected || column.isToday ? Font.Bold : Font.Normal
					}
				}
			}
		}
	}
}
