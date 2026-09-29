pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The last seven days, oldest first: screen time as bars, glasses below,
// and a marker above every day with a headache. `play()` grows the bars
// one after another.
Item {
	id: root

	property var days: []
	readonly property real peak: Math.max(8 * 3600, ...root.days.map(day => day.screen))

	signal replay

	function play() {
		root.replay();
	}

	implicitHeight: 176

	RowLayout {
		anchors.fill: parent
		spacing: 8

		Repeater {
			model: root.days.slice().reverse()

			delegate: ColumnLayout {
				id: column

				required property var modelData
				required property int index

				readonly property bool isToday: column.index === root.days.length - 1
				readonly property bool hurt: column.modelData.headaches.length > 0
				property real grow: 0

				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 4

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

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 22

					Glyph {
						anchors.centerIn: parent
						visible: column.hurt
						icon: "head_alert_outline"
						size: 18
						color: Theme.danger
						scale: column.grow
						rotation: (1 - column.grow) * -40
					}
				}

				Item {
					Layout.fillWidth: true
					Layout.fillHeight: true

					StyledText {
						anchors.horizontalCenter: bar.horizontalCenter
						anchors.bottom: bar.top
						anchors.bottomMargin: 4
						visible: column.modelData.screen >= 60
						opacity: column.grow
						text: column.modelData.screen >= 3600 ? `${(column.modelData.screen / 3600).toFixed(1)}h` : `${Math.round(column.modelData.screen / 60)}m`
						tone: column.isToday ? Theme.text : Theme.textSubtle
						font.pixelSize: Theme.size.tiny
						tabular: true
					}

					Rectangle {
						id: bar

						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						width: Math.min(parent.width, 26)
						height: Math.max(6, (parent.height - 18) * column.modelData.screen / root.peak * column.grow)
						radius: Math.min(width / 2, 9)
						color: column.hurt ? Theme.dangerContainer : (column.isToday ? Theme.primaryContainer : Theme.layer2)
						border.width: column.isToday ? 1.5 : 0
						border.color: Theme.primary

						// glasses of the day, as water in the bar
						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: parent.border.width
							height: (parent.height - parent.border.width * 2) * Math.min(1, column.modelData.ml / Breaks.goalMl)
							radius: parent.radius - parent.border.width
							color: Qt.alpha(Theme.primary, column.isToday ? 0.85 : 0.5)
						}
					}
				}

				Row {
					Layout.alignment: Qt.AlignHCenter
					spacing: 1

					Glyph {
						icon: "cup_water"
						size: 11
						color: column.modelData.ml >= Breaks.goalMl ? Theme.primary : Theme.textSubtle
					}

					StyledText {
						text: (column.modelData.ml / 1000).toFixed(1)
						tone: Theme.textMuted
						font.pixelSize: Theme.size.tiny
						tabular: true
					}
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: Qt.formatDate(column.modelData.date, "ddd")
					tone: column.isToday ? Theme.primary : Theme.textSubtle
					font.pixelSize: Theme.size.small
					font.weight: column.isToday ? Font.Bold : Font.Normal
				}
			}
		}
	}
}
