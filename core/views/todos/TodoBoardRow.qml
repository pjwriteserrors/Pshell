pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A task of the board (a row of TodoGroup's lists, SyncedModel): the task
// with its actions on Tasks.md, and a grip at the right to drag it into
// another group.
Item {
	id: root

	required property string key
	required property string json
	required property Item board
	property bool compact: false
	property real zoom: 1
	readonly property var task: JSON.parse(root.json)

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	function pulse() {
		row.pulse();
	}

	implicitHeight: row.implicitHeight
	height: implicitHeight
	opacity: root.board.ghost.dragging && root.board.ghost.taskKey === root.key ? 0.35 : 1

	Behavior on opacity {
		Anim {}
	}

	HoverHandler {
		id: hover
	}

	TodoTaskRow {
		id: row

		width: root.width
		entry: root.task
		board: true
		compact: root.compact
		zoom: root.zoom
		categories: Todos.findGroup(root.task.group)?.categories ?? []
		classifying: Todos.isClassifying(root.key) && Todos.aiQueue.length >= 0
		trailing: root.board.draggable ? root.px(16) : 0
		expanded: root.board.selectedKey === root.key
		onExpandRequested: root.board.selectedKey = row.expanded ? "" : root.key
		onToggleRequested: Todos.toggleTask(root.key)
		onMarkPicked: mark => Todos.setMark(root.key, mark)
		onPriorityPicked: level => Todos.setPriority(root.key, level)
		onContentEdited: (title, description) => Todos.setContent(root.key, title, description)
		onNoteRequested: Todos.createNoteFor(root.key)
		onMoveRequested: group => Todos.moveTask(root.key, group)
		onDeleteRequested: Todos.deleteTask(root.key)
		onCategoryPicked: name => Todos.setCategory(root.key, name)
		onClassifyRequested: Todos.classify(root.key)
	}

	Item {
		visible: root.board.draggable && !row.editing
		anchors.right: parent.right
		anchors.top: parent.top
		width: root.px(18)
		height: Math.min(parent.height, root.px(root.compact ? 26 : 32))
		opacity: hover.hovered || grip.pressed ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		Glyph {
			anchors.centerIn: parent
			icon: "drag_vertical"
			size: root.px(15)
			color: grip.pressed ? Theme.primary : Theme.textSubtle
		}

		MouseArea {
			id: grip

			anchors.fill: parent
			cursorShape: grip.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
			preventStealing: true
			drag.target: root.board.ghost
			drag.threshold: 3
			onPressed: mouse => root.board.ghost.prepare(root.task, grip.mapToItem(root.board.ghost.parent, mouse.x, mouse.y))
			onReleased: root.board.ghost.finish()
			onCanceled: root.board.ghost.finish()
		}

		Connections {
			target: grip.drag

			function onActiveChanged() {
				if (grip.drag.active) root.board.ghost.dragging = true;
			}
		}
	}
}
