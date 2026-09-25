pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets

// Month grid. Scroll over it (or use the arrows) to flip months; the grid
// slides in the direction you flipped. Clicking the title jumps back to today.
ColumnLayout {
	id: root

	property date shown: new Date()
	property int direction: 1
	readonly property var weekdays: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	function shift(offset) {
		root.direction = offset > 0 ? 1 : -1;
		root.shown = new Date(root.shown.getFullYear(), root.shown.getMonth() + offset, 1);
		slide.restart();
	}

	function reset() {
		root.shown = new Date();
	}

	function offset() {
		return (new Date(root.shown.getFullYear(), root.shown.getMonth(), 1).getDay() + 6) % 7;
	}

	function cell(index) {
		const first = new Date(root.shown.getFullYear(), root.shown.getMonth(), 1);
		return new Date(first.getFullYear(), first.getMonth(), 1 + index - root.offset());
	}

	spacing: 10

	RowLayout {
		Layout.fillWidth: true
		spacing: 4

		Clickable {
			Layout.fillWidth: true
			implicitHeight: 34
			radius: 10
			pressedScale: 0.98
			onClicked: root.reset()

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				x: 6
				text: Qt.formatDateTime(root.shown, "MMMM yyyy")
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}
		}

		IconButton {
			icon: "chevron_left"
			onClicked: root.shift(-1)
		}

		IconButton {
			icon: "chevron_right"
			onClicked: root.shift(1)
		}
	}

	GridLayout {
		id: grid

		Layout.fillWidth: true
		columns: 7
		columnSpacing: 2
		rowSpacing: 2

		Repeater {
			model: root.weekdays

			delegate: StyledText {
				required property string modelData
				required property int index

				Layout.fillWidth: true
				Layout.preferredHeight: 22
				horizontalAlignment: Text.AlignHCenter
				text: modelData
				tone: index >= 5 ? Theme.secondary : Theme.textSubtle
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}

		Repeater {
			model: 42

			delegate: Item {
				id: day

				required property int index
				readonly property date date: root.cell(index)
				readonly property bool inMonth: day.date.getMonth() === root.shown.getMonth()
				readonly property bool today: day.date.toDateString() === clock.date.toDateString()

				Layout.fillWidth: true
				Layout.preferredHeight: 34
				opacity: day.inMonth ? 1 : 0.3

				Rectangle {
					anchors.centerIn: parent
					width: 32
					height: 32
					radius: day.today ? 11 : 16
					color: day.today ? Theme.primary : (dayHover.containsMouse ? Theme.layer2 : "transparent")
					scale: dayHover.containsMouse && !day.today ? 1.08 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}
					Behavior on color {
						ColorAnim {}
					}
				}

				StyledText {
					anchors.centerIn: parent
					text: day.date.getDate()
					tabular: true
					tone: day.today ? Theme.onPrimary : Theme.text
					surface: day.today ? Theme.primary : Theme.surfaceBehind(day)
					font.pixelSize: Theme.size.label
					font.weight: day.today ? Font.Bold : Font.Medium
				}

				MouseArea {
					id: dayHover
					anchors.fill: parent
					hoverEnabled: true
				}
			}
		}

		transform: Translate {
			id: gridShift
		}
	}

	SequentialAnimation {
		id: slide

		ParallelAnimation {
			NumberAnimation {
				target: gridShift
				property: "x"
				from: 36 * root.direction
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
			NumberAnimation {
				target: grid
				property: "opacity"
				from: 0.2
				to: 1
				duration: Motion.medium
			}
		}
	}

	WheelHandler {
		onWheel: event => root.shift((event.angleDelta.y || -event.angleDelta.x) > 0 ? -1 : 1)
	}
}
