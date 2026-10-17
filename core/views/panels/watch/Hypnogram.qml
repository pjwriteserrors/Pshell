pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A night as its stages: four lanes, awake on top and deep at the bottom,
// a block for every stretch in its stage's colour, thin steps between them.
// `reveal` (0…1) sweeps the night in from the left – each block pops into
// its lane as the sweep reaches it. The pointer on the plot shows the time
// and the stage under it.
Item {
	id: root

	// { bed, wake, stages: [[kind, from, to]] } (minutes from bed)
	property var night: null
	property real reveal: 1

	readonly property var stages: root.night?.stages ?? []
	readonly property real length: Math.max(1, root.night ? (root.night.wake - root.night.bed) / 60 : 1)
	readonly property real lane: plot.height / 4
	readonly property var lanes: ({ wake: 0, rem: 1, light: 2, deep: 3 })

	implicitHeight: 168

	// the lanes' names
	Column {
		id: names

		anchors.left: parent.left
		anchors.top: parent.top
		width: 46

		Repeater {
			model: Watch.stages

			delegate: Item {
				required property var modelData

				width: names.width
				height: root.lane

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: parent.modelData.label
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	Item {
		id: plot

		anchors.left: names.right
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 22

		readonly property real sweep: plot.width * root.reveal

		// the lanes, faint
		Repeater {
			model: 4

			delegate: Rectangle {
				required property int index

				y: index * root.lane + root.lane / 2
				width: plot.width
				height: 1
				color: Qt.alpha(Theme.fg, 0.05)
			}
		}

		// the steps from one stage to the next
		Repeater {
			model: root.stages.length > 1 ? root.stages.length - 1 : 0

			delegate: Rectangle {
				id: step

				required property int index

				readonly property var before: root.stages[step.index]
				readonly property var after: root.stages[step.index + 1]
				readonly property real upper: Math.min(root.lanes[step.before[0]], root.lanes[step.after[0]])
				readonly property real lower: Math.max(root.lanes[step.before[0]], root.lanes[step.after[0]])

				x: Math.round(plot.width * step.after[1] / root.length) - 1
				y: step.upper * root.lane + root.lane / 2
				width: 2
				height: (step.lower - step.upper) * root.lane
				radius: 1
				color: Qt.alpha(Theme.fg, 0.16)
				visible: plot.sweep >= step.x
			}
		}

		// the stretches
		Repeater {
			model: root.stages

			delegate: Rectangle {
				id: block

				required property var modelData
				required property int index

				readonly property real start: plot.width * block.modelData[1] / root.length
				readonly property real full: Math.max(2, plot.width * (block.modelData[2] - block.modelData[1]) / root.length)
				readonly property bool reached: plot.sweep > block.start
				readonly property bool pointed: hover.hovered && hover.point.position.x >= block.start && hover.point.position.x < block.start + block.full

				x: block.start
				y: root.lanes[block.modelData[0]] * root.lane + 3
				width: Math.max(0, Math.min(block.full, plot.sweep - block.start))
				height: root.lane - 6
				radius: Math.min(5, height / 2, width / 2)
				color: Watch.tone(block.modelData[0])
				opacity: block.reached ? (hover.hovered && !block.pointed ? 0.55 : 1) : 0
				transformOrigin: Item.Center
				scale: block.reached ? 1 : 0.4

				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}

				Behavior on scale {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}
		}

		// the pointer: a line, and what is under it
		HoverHandler {
			id: hover
		}

		readonly property real pointer: Math.max(0, Math.min(plot.width, hover.point.position.x))
		readonly property real minute: plot.pointer / Math.max(1, plot.width) * root.length
		readonly property var under: root.stages.find(stage => plot.minute >= stage[1] && plot.minute < stage[2]) ?? null

		Rectangle {
			x: plot.pointer
			width: 1
			height: plot.height
			color: Theme.textMuted
			opacity: hover.hovered && root.night ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		Rectangle {
			id: bubble

			readonly property string words: plot.under ? `${Qt.formatTime(new Date((root.night.bed + plot.minute * 60) * 1000), "HH:mm")} · ${Watch.stages.find(s => s.id === plot.under[0])?.label ?? ""} · ${Watch.span(plot.under[2] - plot.under[1])}` : ""

			x: Math.max(0, Math.min(plot.width - width, plot.pointer - width / 2))
			y: -height - 4
			width: label.implicitWidth + 18
			height: 24
			radius: 12
			color: Theme.layer3
			opacity: hover.hovered && plot.under ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}

			StyledText {
				id: label

				anchors.centerIn: parent
				text: bubble.words
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tabular: true
			}
		}
	}

	// the hours along the bottom, at full hours
	Item {
		anchors.left: plot.left
		anchors.right: plot.right
		anchors.bottom: parent.bottom
		height: 16

		readonly property real first: root.night ? (60 - new Date(root.night.bed * 1000).getMinutes()) % 60 : 0
		readonly property int every: root.length / 60 > 9 ? 2 : 1

		Repeater {
			model: root.night ? Math.floor((root.length - parent.first) / 60) + 1 : 0

			delegate: StyledText {
				required property int index

				readonly property real minute: parent.first + index * 60
				readonly property date stamp: new Date((root.night.bed + minute * 60) * 1000)

				x: Math.round(plot.width * minute / root.length - implicitWidth / 2)
				visible: stamp.getHours() % parent.every === 0 && x > -4 && x + implicitWidth < plot.width + 4
				text: Qt.formatTime(stamp, "HH")
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.tiny
				tabular: true
			}
		}
	}
}
