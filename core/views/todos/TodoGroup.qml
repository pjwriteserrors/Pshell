pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views

// One group of the task board: a header that folds it (remembered in
// Todos.folds), its open tasks by priority, a line to add one, and its done
// ones behind a fold of their own. Tasks dropped on it move here; lists
// animate what comes, goes and moves.
Item {
	id: root

	required property string name
	// the board it is on (TodoBoard): selection, drag ghost
	required property Item board
	property bool compact: false
	property real zoom: 1
	// in a widget: the group stands alone, without a header to fold it
	property bool headless: false
	readonly property var group: Todos.findGroup(root.name)
	readonly property bool folded: !root.headless && Todos.isFolded(Todos.tasksPath, `group:${root.name}`)
	property bool showClosed: false
	property bool adding: false
	property bool renaming: false
	// the list of categories (and the model that sorts into them) is open
	property bool sorting: false
	// the category whose name is being changed
	property string renamingCategory: ""
	property bool confirmDelete: false
	readonly property int openCount: root.group?.open ?? 0
	readonly property int closedCount: Todos.closedOf(root.group).length

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	function startAdding() {
		root.adding = true;
		if (root.folded) Todos.toggleFold(Todos.tasksPath, `group:${root.name}`);
		addField.focusInput();
	}

	// the row of a task, unfolded (null: not in this group)
	function rowOf(key) {
		const task = Todos.findTask(key);
		if (!task || task.group !== root.name) return null;
		if (root.folded) Todos.toggleFold(Todos.tasksPath, `group:${root.name}`);
		if (task.closed) root.showClosed = true;
		const list = task.closed ? closedList : openList;
		const model = task.closed ? closedModel : openModel;
		for (let i = 0; i < model.count; i += 1) {
			if (model.get(i).key === key) return list.itemAtIndex(i);
		}
		return null;
	}

	// the row of a task as it shows now, without opening anything (null: not shown)
	function findRow(key) {
		if (root.folded) return null;
		for (let i = 0; i < openModel.count; i += 1) {
			if (openModel.get(i).key === key) return openList.itemAtIndex(i);
		}
		if (!root.showClosed) return null;
		for (let i = 0; i < closedModel.count; i += 1) {
			if (closedModel.get(i).key === key) return closedList.itemAtIndex(i);
		}
		return null;
	}

	readonly property Item headerItem: header

	function syncModels() {
		openModel.sync(Todos.openOf(root.group));
		closedModel.sync(root.showClosed ? Todos.closedOf(root.group) : []);
	}

	onGroupChanged: root.syncModels()
	onShowClosedChanged: root.syncModels()
	Component.onCompleted: root.syncModels()

	onAddingChanged: {
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing += root.adding ? 1 : -1;
	}
	onRenamingChanged: {
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing += root.renaming ? 1 : -1;
	}
	onSortingChanged: {
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing += root.sorting ? 1 : -1;
		if (root.sorting) Todos.lookForModels();
	}
	Component.onDestruction: {
		const window = QsWindow.window;
		if (window && window.typing !== undefined) window.typing -= (root.adding ? 1 : 0) + (root.renaming ? 1 : 0) + (root.sorting ? 1 : 0);
	}

	implicitHeight: column.implicitHeight

	SyncedModel {
		id: openModel
	}

	SyncedModel {
		id: closedModel
	}

	ColumnLayout {
		id: column

		width: root.width
		spacing: 0

		// ── header ────────────────────────────────────────────────────────────
		Clickable {
			id: header

			Layout.fillWidth: true
			visible: !root.headless
			implicitHeight: root.px(root.compact ? 32 : 38)
			radius: Theme.radius.medium
			pressedScale: 0.99
			interactive: !root.renaming
			color: drop.containsDrag ? Theme.primaryContainer : "transparent"
			onClicked: Todos.toggleFold(Todos.tasksPath, `group:${root.name}`)

			Behavior on color {
				ColorAnim {}
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: root.px(4)
				anchors.rightMargin: root.px(2)
				spacing: root.px(6)

				Glyph {
					icon: "chevron_down"
					size: root.px(16)
					color: Theme.textSubtle
					rotation: root.folded ? -90 : 0

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				Glyph {
					icon: root.name === Todos.inbox ? "inbox_outline" : "folder_outline"
					size: root.px(16)
					color: root.openCount > 0 ? Theme.primary : Theme.textSubtle
				}

				StyledText {
					Layout.fillWidth: true
					visible: !root.renaming
					text: root.name
					elide: Text.ElideRight
					font.pixelSize: root.px(root.compact ? Theme.size.body : Theme.size.title)
					font.weight: Font.Bold
					tone: root.openCount > 0 ? Theme.text : Theme.textMuted
				}

				Field {
					id: renameField

					Layout.fillWidth: true
					visible: root.renaming
					clearable: false
					fontSize: root.px(Theme.size.body)
					onAccepted: {
						Todos.renameGroup(root.name, renameField.text);
						root.renaming = false;
					}
					onEscapePressed: root.renaming = false
					onFocusedChanged: if (!renameField.focused) root.renaming = false
				}

				Badge {
					visible: !root.renaming && scale > 0.01
					count: root.openCount
				}

				Item {
					visible: !root.renaming
					Layout.preferredWidth: header.hovered ? actions.implicitWidth : 0
					Layout.preferredHeight: actions.implicitHeight
					clip: true

					Behavior on Layout.preferredWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Row {
						id: actions

						anchors.right: parent.right
						spacing: 0
						opacity: header.hovered ? 1 : 0

						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}

						IconButton {
							width: root.px(26)
							height: root.px(26)
							icon: "plus"
							iconSize: root.px(15)
							onClicked: root.startAdding()
						}

						IconButton {
							width: root.px(26)
							height: root.px(26)
							icon: "tag_multiple_outline"
							iconSize: root.px(14)
							checked: root.sorting
							onClicked: {
								root.sorting = !root.sorting;
								if (root.sorting) categoryField.focusInput();
							}
						}

						IconButton {
							width: root.px(26)
							height: root.px(26)
							icon: "pin"
							iconSize: root.px(14)
							checked: Todos.isPinned(Todos.groupKey(root.name))
							onClicked: Todos.togglePin(Todos.groupKey(root.name))
						}

						IconButton {
							visible: root.name !== Todos.inbox
							width: root.px(26)
							height: root.px(26)
							icon: "pencil"
							iconSize: root.px(14)
							onClicked: {
								renameField.text = root.name;
								root.renaming = true;
								renameField.focusInput();
							}
						}

						IconButton {
							visible: root.name !== Todos.inbox
							width: root.px(26)
							height: root.px(26)
							icon: root.confirmDelete ? "delete" : "delete_outline"
							iconSize: root.px(14)
							variant: root.confirmDelete ? "danger" : "ghost"
							onClicked: {
								if (root.confirmDelete) Todos.deleteGroup(root.name);
								else {
									root.confirmDelete = true;
									unconfirm.restart();
								}
							}

							Timer {
								id: unconfirm

								interval: 2600
								onTriggered: root.confirmDelete = false
							}
						}
					}
				}
			}
		}

		// ── categories ────────────────────────────────────────────────────────
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: root.sorting ? sortColumn.implicitHeight + root.px(10) : 0
			clip: true
			visible: Layout.preferredHeight > 0.5
			opacity: root.sorting ? 1 : 0

			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Behavior on opacity {
				Anim {}
			}

			ColumnLayout {
				id: sortColumn

				x: root.px(6)
				y: root.px(4)
				width: parent.width - root.px(12)
				spacing: root.px(6)

				Flow {
					Layout.fillWidth: true
					spacing: root.px(4)
					visible: (root.group?.categories.length ?? 0) > 0

					Repeater {
						model: root.group?.categories ?? []

						delegate: Rectangle {
							id: categoryPill

							required property string modelData
							readonly property bool renaming: root.renamingCategory === categoryPill.modelData

							height: root.px(28)
							width: categoryRow.implicitWidth + root.px(10)
							radius: height / 2
							color: Theme.layer2

							RowLayout {
								id: categoryRow

								anchors.verticalCenter: parent.verticalCenter
								x: root.px(10)
								spacing: root.px(2)

								StyledText {
									visible: !categoryPill.renaming
									text: categoryPill.modelData
									font.pixelSize: root.px(Theme.size.label)
									font.weight: Font.Medium

									MouseArea {
										anchors.fill: parent
										cursorShape: Qt.IBeamCursor
										onDoubleClicked: {
											root.renamingCategory = categoryPill.modelData;
											categoryRename.text = categoryPill.modelData;
											categoryRename.forceActiveFocus();
											categoryRename.selectAll();
										}
									}
								}

								TextInput {
									id: categoryRename

									visible: categoryPill.renaming
									Layout.preferredWidth: Math.max(root.px(60), contentWidth + 4)
									color: Theme.text
									font.family: Theme.fontFamily
									font.pixelSize: root.px(Theme.size.label)
									selectByMouse: true
									onAccepted: {
										Todos.renameCategory(root.name, categoryPill.modelData, categoryRename.text);
										root.renamingCategory = "";
									}
									onActiveFocusChanged: if (!activeFocus && categoryPill.renaming) root.renamingCategory = ""
									Keys.onEscapePressed: root.renamingCategory = ""
								}

								IconButton {
									Layout.preferredWidth: root.px(22)
									Layout.preferredHeight: root.px(22)
									icon: "close"
									iconSize: root.px(12)
									onClicked: Todos.removeCategory(root.name, categoryPill.modelData)
								}
							}
						}
					}
				}

				Field {
					id: categoryField

					Layout.fillWidth: true
					icon: "tag_outline"
					placeholder: "New category"
					fontSize: root.px(root.compact ? Theme.size.label + 1 : Theme.size.body)
					onAccepted: {
						Todos.addCategory(root.name, categoryField.text);
						categoryField.text = "";
					}
					onEscapePressed: root.sorting = false
				}

				// which model sorts
				RowLayout {
					Layout.fillWidth: true
					visible: Todos.aiEnabled
					spacing: root.px(6)

					Glyph {
						Layout.alignment: Qt.AlignTop
						Layout.topMargin: root.px(5)
						icon: "robot_outline"
						size: root.px(16)
						color: Todos.aiError !== "" ? Theme.danger : Theme.textMuted
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: root.px(4)

						Flow {
							Layout.fillWidth: true
							spacing: root.px(4)

							Repeater {
								model: Todos.aiModels

								delegate: Chip {
									required property var modelData

									height: root.px(26)
									text: modelData.name.replace(/:latest$/, "")
									selected: modelData.name === Todos.aiModel
									onClicked: Todos.pickModel(modelData.name)
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							visible: Todos.aiError !== ""
							text: Todos.aiError
							tone: Theme.danger
							wrapMode: Text.Wrap
							font.pixelSize: root.px(Theme.size.small)
						}
					}
				}
			}
		}

		// ── tasks ─────────────────────────────────────────────────────────────
		Item {
			id: body

			Layout.fillWidth: true
			Layout.preferredHeight: root.folded ? 0 : content.implicitHeight
			clip: true
			visible: Layout.preferredHeight > 0.5
			opacity: root.folded ? 0 : 1

			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.long
				}
			}

			Behavior on opacity {
				Anim {}
			}

			ColumnLayout {
				id: content

				width: body.width
				spacing: 0

				ListView {
					id: openList

					Layout.fillWidth: true
					Layout.preferredHeight: contentHeight
					interactive: false
					model: openModel
					spacing: root.px(1)

					add: Transition {
						ParallelAnimation {
							Anim {
								property: "opacity"
								from: 0
								to: 1
							}
							SpatialAnim {
								property: "scale"
								from: 0.92
								to: 1
							}
						}
					}
					remove: Transition {
						ParallelAnimation {
							Anim {
								property: "opacity"
								to: 0
								duration: Motion.medium
							}
							Anim {
								property: "x"
								to: root.px(24)
								duration: Motion.medium
							}
						}
					}
					displaced: Transition {
						SpatialAnim {
							properties: "x,y"
							duration: Motion.medium
						}
					}

					delegate: TodoBoardRow {
						board: root.board
						compact: root.compact
						zoom: root.zoom
						width: openList.width
					}
				}

				// a new task here
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: root.adding ? addField.implicitHeight + root.px(8) : 0
					clip: true
					visible: Layout.preferredHeight > 0.5

					Behavior on Layout.preferredHeight {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Field {
						id: addField

						x: root.px(4)
						y: root.px(4)
						width: parent.width - root.px(8)
						icon: "plus"
						placeholder: "New task"
						fontSize: root.px(root.compact ? Theme.size.label + 1 : Theme.size.body)
						onAccepted: {
							if (addField.text.trim() === "") {
								root.adding = false;
								return;
							}
							Todos.addTask(root.name, addField.text);
							addField.text = "";
						}
						onEscapePressed: root.adding = false
						onFocusedChanged: if (!addField.focused && addField.text.trim() === "") root.adding = false
					}
				}

				// the done ones
				Clickable {
					Layout.fillWidth: true
					Layout.leftMargin: root.px(4)
					visible: root.closedCount > 0
					implicitHeight: root.px(root.compact ? 24 : 28)
					radius: Theme.radius.small
					pressedScale: 0.98
					onClicked: root.showClosed = !root.showClosed

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: root.px(4)
						spacing: root.px(6)

						Glyph {
							icon: "chevron_down"
							size: root.px(14)
							color: Theme.textSubtle
							rotation: root.showClosed ? 0 : -90

							Behavior on rotation {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: `${root.closedCount} done`
							tone: Theme.textSubtle
							font.pixelSize: root.px(Theme.size.small)
							font.weight: Font.Medium
						}
					}
				}

				ListView {
					id: closedList

					Layout.fillWidth: true
					Layout.preferredHeight: contentHeight
					visible: root.showClosed
					interactive: false
					model: closedModel
					spacing: root.px(1)

					add: Transition {
						Anim {
							property: "opacity"
							from: 0
							to: 1
						}
					}
					displaced: Transition {
						SpatialAnim {
							properties: "y"
							duration: Motion.medium
						}
					}

					delegate: TodoBoardRow {
						board: root.board
						compact: root.compact
						zoom: root.zoom
						width: closedList.width
					}
				}

				Item {
					Layout.preferredHeight: root.px(root.compact ? 4 : 8)
				}
			}
		}
	}

	DropArea {
		id: drop

		anchors.fill: parent
		keys: ["todo-task"]
		onDropped: drag => {
			const key = drag.source?.taskKey ?? "";
			if (key !== "") Todos.moveTask(key, root.name);
		}
	}
}
