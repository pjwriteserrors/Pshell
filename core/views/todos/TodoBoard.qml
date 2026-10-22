pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views

// The task board: the groups of Tasks.md (TodoGroup), the inbox and every
// group with something open first, the ones that are all done behind a
// fold. With `filter` it is one group only. Tasks are dragged by their grip
// onto another group (here or anything else with a "todo-task" DropArea);
// reveal(key) scrolls to a task and lets it flash.
Item {
	id: root

	// the name of the one group to show, "" for all
	property string filter: ""
	// the one group without its header (a widget names it already)
	property bool headless: false
	property bool compact: false
	property real zoom: 1
	property bool draggable: true
	// the task whose actions are open
	property string selectedKey: ""
	property bool showRest: false
	readonly property alias ghost: ghost
	readonly property alias flickable: flick
	readonly property real contentHeight: content.implicitHeight
	readonly property bool empty: Todos.tasks.length === 0 && root.filter === ""
	readonly property var mainGroups: root.filter !== ""
		? [{ key: root.filter }]
		: Todos.groups.filter(group => group.name === Todos.inbox || group.open > 0).map(group => ({ key: group.name }))
	readonly property var restGroups: root.filter !== "" ? [] : Todos.groups.filter(group => group.name !== Todos.inbox && group.open === 0).map(group => ({ key: group.name }))

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	onMainGroupsChanged: mainModel.sync(root.mainGroups)
	onRestGroupsChanged: restModel.sync(root.restGroups)
	Component.onCompleted: {
		mainModel.sync(root.mainGroups);
		restModel.sync(root.restGroups);
	}

	function groupItem(name) {
		for (const list of [mainList, restList]) {
			for (let i = 0; i < list.count; i += 1) {
				const item = list.itemAtIndex(i);
				if (item && item.name === name) return item;
			}
		}
		return null;
	}

	// what stands for a task now, without opening anything: its row, else its group's header, else null
	function anchorOf(key) {
		const task = Todos.findTask(key);
		if (!task) return null;
		if (!root.showRest && root.restGroups.some(group => group.key === task.group)) return null;
		const group = root.groupItem(task.group);
		if (!group) return null;
		return group.findRow(key) ?? (root.headless ? null : group.headerItem);
	}

	function reveal(key) {
		const task = Todos.findTask(key);
		if (!task) return;
		if (root.restGroups.some(group => group.key === task.group)) root.showRest = true;
		revealer.key = key;
		revealer.tries = 0;
		revealer.restart();
	}

	Timer {
		id: revealer

		property string key: ""
		property int tries: 0

		interval: 90
		onTriggered: {
			const task = Todos.findTask(revealer.key);
			const group = task ? root.groupItem(task.group) : null;
			const row = group ? group.rowOf(revealer.key) : null;
			if (!row || row.height <= 0) {
				revealer.tries += 1;
				if (revealer.tries < 12) revealer.restart();
				return;
			}
			// once the folds have opened
			if (revealer.tries < 4) {
				revealer.tries = 4;
				revealer.restart();
				return;
			}
			const at = row.mapToItem(content, 0, 0).y;
			scroll.to = Math.max(0, Math.min(flick.contentHeight - flick.height, at - flick.height / 3));
			scroll.restart();
			root.selectedKey = revealer.key;
			row.pulse();
		}
	}

	SyncedModel {
		id: mainModel
	}

	SyncedModel {
		id: restModel
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: content.implicitHeight
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		interactive: !ghost.dragging && contentHeight > height
		ScrollBar.vertical: ThinScrollBar {}

		NumberAnimation {
			id: scroll

			target: flick
			property: "contentY"
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}

		ColumnLayout {
			id: content

			width: flick.width - (flick.contentHeight > flick.height ? root.px(6) : 0)
			spacing: root.px(root.compact ? 2 : 4)

			ListView {
				id: mainList

				Layout.fillWidth: true
				Layout.preferredHeight: contentHeight
				interactive: false
				model: mainModel
				spacing: root.px(root.compact ? 2 : 6)

				add: Transition {
					ParallelAnimation {
						Anim {
							property: "opacity"
							from: 0
							to: 1
						}
						SpatialAnim {
							property: "y"
							from: ViewTransition.destination.y + 12
						}
					}
				}
				remove: Transition {
					Anim {
						property: "opacity"
						to: 0
					}
				}
				displaced: Transition {
					SpatialAnim {
						properties: "y"
						duration: Motion.long
					}
				}

				delegate: TodoGroup {
					required property string key

					width: mainList.width
					name: key
					board: root
					compact: root.compact
					zoom: root.zoom
					headless: root.headless
				}
			}

			// the groups that are all done
			Clickable {
				Layout.fillWidth: true
				Layout.topMargin: root.px(6)
				visible: restModel.count > 0
				implicitHeight: root.px(root.compact ? 28 : 32)
				radius: Theme.radius.medium
				pressedScale: 0.99
				onClicked: root.showRest = !root.showRest

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: root.px(4)
					spacing: root.px(6)

					Glyph {
						icon: "chevron_down"
						size: root.px(16)
						color: Theme.textSubtle
						rotation: root.showRest ? 0 : -90

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					Glyph {
						icon: "checkbox_marked_circle_outline"
						size: root.px(16)
						color: Theme.textSubtle
					}

					StyledText {
						Layout.fillWidth: true
						text: `${restModel.count} groups done`
						tone: Theme.textMuted
						font.pixelSize: root.px(root.compact ? Theme.size.label : Theme.size.body)
						font.weight: Font.DemiBold
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: root.showRest ? restList.contentHeight : 0
				clip: true
				visible: Layout.preferredHeight > 0.5
				opacity: root.showRest ? 1 : 0

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.long
					}
				}

				Behavior on opacity {
					Anim {}
				}

				ListView {
					id: restList

					width: parent.width
					height: contentHeight
					interactive: false
					model: restModel
					spacing: root.px(2)

					displaced: Transition {
						SpatialAnim {
							properties: "y"
							duration: Motion.long
						}
					}

					delegate: TodoGroup {
						required property string key

						width: restList.width
						name: key
						board: root
						compact: root.compact
						zoom: root.zoom
					}
				}
			}
		}
	}

	// scrolls while a task is dragged near the top or bottom
	Timer {
		interval: 16
		repeat: true
		running: ghost.dragging
		onTriggered: {
			const at = ghost.mapToItem(flick, 0, ghost.height / 2).y;
			const edge = root.px(36);
			let step = 0;
			if (at < edge) step = -Math.ceil((edge - at) / 4);
			else if (at > flick.height - edge) step = Math.ceil((at - flick.height + edge) / 4);
			if (step !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + step));
		}
	}

	// what a dragged task looks like under the pointer
	Rectangle {
		id: ghost

		property string taskKey: ""
		property string label: ""
		property string mark: " "
		property bool dragging: false

		function prepare(task, point) {
			ghost.taskKey = task.key;
			ghost.label = task.text;
			ghost.mark = task.mark;
			ghost.x = point.x - root.px(18);
			ghost.y = point.y - ghost.height / 2;
		}

		function finish() {
			if (ghost.dragging) ghost.Drag.drop();
			ghost.dragging = false;
		}

		z: 1000
		width: Math.min(root.width - root.px(16), ghostRow.implicitWidth + root.px(28))
		height: root.px(root.compact ? 32 : 38)
		radius: height / 2
		color: Theme.layer3
		border.width: 1
		border.color: Qt.alpha(Theme.primary, 0.6)
		visible: opacity > 0.01
		opacity: ghost.dragging ? 1 : 0
		scale: ghost.dragging ? 1 : 0.85
		Drag.active: ghost.dragging
		Drag.keys: ["todo-task"]
		Drag.source: ghost
		Drag.hotSpot.x: root.px(18)
		Drag.hotSpot.y: ghost.height / 2

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		RectangularShadow {
			z: -1
			anchors.fill: parent
			radius: parent.radius
			blur: 18
			offset.y: 6
			color: Qt.alpha(Theme.shadow, 0.4)
		}

		RowLayout {
			id: ghostRow

			anchors.verticalCenter: parent.verticalCenter
			x: root.px(12)
			spacing: root.px(8)

			Glyph {
				icon: Todos.state(ghost.mark).icon
				size: root.px(17)
				color: Todos.markColor(ghost.mark)
			}

			StyledText {
				Layout.maximumWidth: root.px(260)
				text: ghost.label
				elide: Text.ElideRight
				font.pixelSize: root.px(Theme.size.body)
				font.weight: Font.Medium
			}
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.empty && Todos.tasksLoaded
		icon: "checkbox_marked_circle_outline"
		title: "No tasks"
	}
}
