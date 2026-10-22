pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A day by the hour: a slim bar each, coloured by what the value means
// (toneOf), empty hours as dots. The pointer on one names the hour and its
// value; `play()` grows them in from the left.
Item {
	id: root

	property var values: []
	// the scale: what an empty bar and a full one stand for
	property real floor: 0
	property real ceiling: 100
	property string unit: ""
	// value → colour
	property var toneOf: value => Theme.primary
	// the hour of values[0] (0 for today's 24 hours, or the hour 24 h ago)
	property int firstHour: 0

	signal replay

	function play() {
		root.replay();
	}

	implicitHeight: 96

	RowLayout {
		id: row

		anchors.fill: parent
		anchors.topMargin: 20
		anchors.bottomMargin: 16
		spacing: 3

		Repeater {
			model: 24

			delegate: Item {
				id: hour

				required property int index

				readonly property real value: root.values[hour.index] ?? 0
				readonly property bool empty: hour.value <= root.floor
				property real grow: 1

				Layout.fillWidth: true
				Layout.fillHeight: true

				Connections {
					target: root
					function onReplay() {
						hour.grow = 0;
						growIn.restart();
					}
				}

				SequentialAnimation {
					id: growIn

					PauseAnimation {
						duration: 100 + hour.index * 18
					}
					SpatialAnim {
						target: hour
						property: "grow"
						to: 1
						duration: Motion.extraLong
					}
				}

				HoverHandler {
					id: hover
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					width: Math.min(9, parent.width)
					height: hour.empty ? width : Math.max(width, parent.height * Math.min(1, (hour.value - root.floor) / (root.ceiling - root.floor)) * hour.grow)
					radius: width / 2
					color: hour.empty ? Theme.layer2 : root.toneOf(hour.value)
					opacity: hover.hovered || hour.empty ? 1 : 0.82
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					y: -20
					z: 2
					width: tip.implicitWidth + 14
					height: 20
					radius: 10
					color: Theme.layer3
					opacity: hover.hovered && !hour.empty ? 1 : 0
					visible: opacity > 0

					Behavior on opacity {
						Anim {}
					}

					StyledText {
						id: tip

						anchors.centerIn: parent
						text: `${String((root.firstHour + hour.index) % 24).padStart(2, "0")}h · ${Math.round(hour.value)}${root.unit}`
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						tabular: true
					}
				}
			}
		}
	}

	Repeater {
		model: 5

		delegate: StyledText {
			required property int index

			x: row.x + row.width * index / 4 - implicitWidth / 2 * (index / 4) * 2
			anchors.bottom: parent.bottom
			text: String((root.firstHour + index * 6) % 24).padStart(2, "0")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny
			tabular: true
		}
	}
}
