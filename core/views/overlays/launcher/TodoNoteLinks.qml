pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The tasks a note belongs to, as pills: the state icon ticks the task off,
// the rest goes to it (its pinned board on the desktop, else the launcher).
Flow {
	id: root

	// the note's name
	required property string name
	property real zoom: 1
	property bool compact: false
	readonly property var tasks: Todos.tasksOf(root.name)

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	spacing: root.px(6)
	visible: root.tasks.length > 0

	onTasksChanged: links.sync(root.tasks)
	Component.onCompleted: links.sync(root.tasks)

	SyncedModel {
		id: links
	}

	Repeater {
		model: links

		delegate: Clickable {
			id: pill

			required property string json
			required property int index
			readonly property var modelData: JSON.parse(pill.json)

			implicitHeight: root.px(root.compact ? 26 : 30)
			implicitWidth: Math.min(root.width, pillRow.implicitWidth + root.px(18))
			radius: height / 2
			pressedScale: 0.95
			color: pill.hovered ? Theme.layer3 : Theme.layer2
			scale: 0.7
			opacity: 0
			onClicked: Todos.openTask(pill.modelData.key)

			Component.onCompleted: pillIn.start()

			ParallelAnimation {
				id: pillIn

				SpatialAnim {
					target: pill
					property: "scale"
					to: 1
					duration: Motion.long + pill.index * 40
				}
				Anim {
					target: pill
					property: "opacity"
					to: 1
				}
			}

			Behavior on color {
				ColorAnim {}
			}

			RowLayout {
				id: pillRow

				anchors.verticalCenter: parent.verticalCenter
				x: root.px(8)
				width: pill.width - root.px(16)
				spacing: root.px(6)

				Glyph {
					icon: Todos.state(pill.modelData.mark).icon
					size: root.px(root.compact ? 15 : 17)
					color: Todos.markColor(pill.modelData.mark)

					MouseArea {
						anchors.fill: parent
						anchors.margins: -4
						cursorShape: Qt.PointingHandCursor
						onClicked: Todos.toggleTask(pill.modelData.key)
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: pill.modelData.text
					elide: Text.ElideRight
					tone: pill.modelData.closed ? Theme.textSubtle : Theme.text
					font.strikeout: pill.modelData.closed
					font.pixelSize: root.px(root.compact ? Theme.size.label : Theme.size.body)
					font.weight: Font.Medium
				}

				StyledText {
					text: pill.modelData.group
					tone: Theme.textSubtle
					font.pixelSize: root.px(Theme.size.small)
				}
			}
		}
	}
}
