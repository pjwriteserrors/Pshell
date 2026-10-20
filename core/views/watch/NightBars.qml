pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The last nights side by side: a bar each, its height the time asleep,
// stacked from deep at the bottom to awake on top in the stages' colours.
// The picked night stands out, the pointer on one shows its length; the
// dashed line is their average. `play()` grows the bars one after another.
Item {
	id: root

	// [{ date, total, stages }]
	property var nights: []
	property string selected: ""
	readonly property real peak: Math.max(9 * 60, ...root.nights.map(n => n.total)) * 1.1
	readonly property real average: root.nights.length > 1 ? root.nights.reduce((sum, n) => sum + n.total, 0) / root.nights.length : 0

	signal picked(string key)
	signal replay

	function play() {
		root.replay();
	}

	implicitHeight: 150

	Item {
		id: plot

		anchors.fill: parent
		anchors.topMargin: 18
		anchors.bottomMargin: 30

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
				model: root.nights

				delegate: Item {
					id: column

					required property var modelData
					required property int index

					readonly property bool isSelected: column.modelData.date === root.selected
					readonly property var shares: Watch.shares(column.modelData)
					readonly property real sum: Math.max(1, column.shares.deep + column.shares.light + column.shares.rem + column.shares.wake)
					property real grow: 1

					Layout.fillWidth: true
					Layout.fillHeight: true

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
							duration: 140 + column.index * 38
						}
						SpatialAnim {
							target: column
							property: "grow"
							to: 1
							duration: Motion.extraLong + 160
						}
					}

					HoverHandler {
						id: hover

						cursorShape: Qt.PointingHandCursor
					}

					TapHandler {
						onTapped: root.picked(column.modelData.date)
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: stack.top
						anchors.bottomMargin: 4
						opacity: (column.isSelected || hover.hovered) ? column.grow : 0
						text: Watch.span(column.modelData.total).replace(" min", "′").replace(" h ", ":")
						tone: column.isSelected ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						tabular: true

						Behavior on opacity {
							Anim {}
						}
					}

					// the stages, deep at the bottom
					Item {
						id: stack

						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						width: Math.min(26, parent.width)
						height: Math.max(4, plot.height * column.modelData.total / root.peak * column.grow)
						opacity: column.isSelected || hover.hovered ? 1 : 0.5
						clip: true

						Behavior on opacity {
							Anim {}
						}

						Rectangle {
							anchors.fill: parent
							radius: Math.min(7, width / 2)
							color: "transparent"
							clip: true

							Column {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom

								Repeater {
									model: ["wake", "rem", "light", "deep"]

									delegate: Rectangle {
										required property string modelData

										width: stack.width
										height: stack.height * (column.shares[modelData] ?? 0) / column.sum
										color: Watch.tone(modelData)
										radius: 2
									}
								}
							}
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.bottom
						anchors.topMargin: 5
						text: Qt.formatDate(Watch.dateOf(column.modelData.date), "ddd").slice(0, 2)
						tone: column.isSelected ? Theme.primary : Theme.textSubtle
						font.pixelSize: Theme.size.small
						font.weight: column.isSelected ? Font.Bold : Font.Normal
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.bottom
						anchors.topMargin: 18
						text: Qt.formatDate(Watch.dateOf(column.modelData.date), "d")
						tone: Theme.textFaint
						font.pixelSize: Theme.size.tiny
						tabular: true
					}
				}
			}
		}
	}
}
