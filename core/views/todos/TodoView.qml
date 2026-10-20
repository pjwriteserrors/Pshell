pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views

// Launcher >todo, two tabs (Ctrl+Tab):
//
// Tasks – the groups on the left (a task dragged onto one moves there), the
// board on the right. Enter adds the typed text as a task of the selected
// group ("#group" and "!"/"!!"/"!!!" in the text pick group and priority),
// Ctrl+N names a new group.
//
// Notes – the notes on the left, filtered by the typed text, the selected
// one rendered on the right with the tasks it belongs to. Enter opens it in
// the editor (or makes a note of that name when none fits), Ctrl+N names a
// new one.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	// Enter creates a group or note named after the argument
	property bool naming: false
	readonly property string tab: Todos.launcherTab
	readonly property bool notesTab: root.tab === "notes"
	// "" for every group
	property string selectedGroup: ""
	property string selectedNote: ""
	readonly property string query: String(root.argument || "").trim()
	readonly property var shownNotes: {
		const wanted = root.query.toLowerCase();
		return Todos.notes.filter(note => wanted === "" || root.naming || note.name.toLowerCase().indexOf(wanted) >= 0)
			.slice().sort((left, right) => right.modified - left.modified);
	}
	readonly property var note: Todos.notes.find(note => note.path === root.selectedNote) ?? null

	// what the launcher shows for this view
	readonly property string placeholder: root.notesTab ? (root.naming ? "Note name" : "Search notes") : (root.naming ? "Group name" : `New task in ${root.selectedGroup || Todos.inbox}`)
	readonly property string enterHint: root.naming ? "create" : (root.notesTab ? (root.shownNotes.length === 0 && root.query !== "" ? "new note" : "edit") : "add")
	readonly property string newLabel: root.notesTab ? "new note" : "new group"

	signal closeRequested
	signal argumentRequested(string text)

	spacing: 12

	onActiveChanged: {
		root.naming = false;
		if (!root.active) return;
		Todos.refreshNotes();
		Qt.callLater(root.applyTarget);
	}
	onTabChanged: root.naming = false
	onShownNotesChanged: {
		if (root.notesTab && root.shownNotes.length > 0 && !root.shownNotes.some(note => note.path === root.selectedNote))
			root.selectedNote = root.shownNotes[0].path;
	}

	Connections {
		target: Todos

		function onTargetChanged() {
			if (root.active) Qt.callLater(root.applyTarget);
		}
		function onNoteCreated(path) {
			if (path === root.selectedNote) noteDoc.reload();
		}
	}

	// go where Todos.showTask / showNote asked for
	function applyTarget() {
		const target = Todos.target;
		if (!target) return;
		Todos.target = null;
		if (target.kind === "note") {
			Todos.launcherTab = "notes";
			if (root.query !== "") root.argumentRequested("");
			root.selectedNote = target.path;
			return;
		}
		const task = Todos.findTask(target.key);
		if (!task) return;
		Todos.launcherTab = "tasks";
		root.selectedGroup = "";
		board.reveal(target.key);
	}

	function move(delta) {
		if (root.notesTab) {
			const paths = root.shownNotes.map(note => note.path);
			if (paths.length === 0) return;
			const index = Math.max(0, Math.min(paths.length - 1, paths.indexOf(root.selectedNote) + delta));
			root.selectedNote = paths[index];
			noteList.positionViewAtIndex(index, ListView.Contain);
			return;
		}
		const names = [""].concat(Todos.groups.map(group => group.name));
		const index = Math.max(0, Math.min(names.length - 1, names.indexOf(root.selectedGroup) + delta));
		root.selectedGroup = names[index];
		groupList.positionViewAtIndex(index, ListView.Contain);
	}

	function handleKey(event) {
		if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
			root.naming = !root.naming;
			return true;
		}
		if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) && (event.modifiers & Qt.ControlModifier)) {
			Todos.launcherTab = root.notesTab ? "tasks" : "notes";
			return true;
		}
		return false;
	}

	function cancel() {
		if (root.naming) {
			root.naming = false;
			return true;
		}
		if (!root.notesTab && board.selectedKey !== "") {
			board.selectedKey = "";
			return true;
		}
		return false;
	}

	function activate(modifiers) {
		if (root.notesTab) {
			if (root.naming || (root.shownNotes.length === 0 && root.query !== "")) {
				if (root.query === "") return;
				const path = Todos.createNote(root.query);
				root.naming = false;
				root.argumentRequested("");
				if (path === "") return;
				root.selectedNote = path;
				Todos.openEditor(path, -1);
				root.closeRequested();
				return;
			}
			if (root.note) {
				Todos.openEditor(root.note.path, -1);
				root.closeRequested();
			}
			return;
		}
		if (root.query === "") return;
		if (root.naming) {
			root.selectedGroup = Todos.addGroup(root.query);
			root.naming = false;
			root.argumentRequested("");
			return;
		}
		const group = Todos.addTask(root.selectedGroup || Todos.inbox, root.query);
		root.argumentRequested("");
		if (group === "") return;
		// the new one is the last of its group
		const added = Todos.tasks.filter(task => task.group === group).sort((left, right) => right.line - left.line)[0];
		if (added) board.reveal(added.key);
	}

	// ── tabs ──────────────────────────────────────────────────────────────
	Segmented {
		Layout.preferredWidth: 260
		options: [
			{ value: "tasks", label: "Tasks", icon: "checkbox_marked_circle_outline" },
			{ value: "notes", label: "Notes", icon: "note_text_outline" }
		]
		current: root.tab
		onSelected: value => Todos.launcherTab = value
	}

	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		// ── tasks ─────────────────────────────────────────────────────────
		RowLayout {
			id: tasksPage

			width: parent.width
			height: parent.height
			spacing: 14
			x: root.notesTab ? -40 : 0
			opacity: root.notesTab ? 0 : 1
			visible: opacity > 0.01
			enabled: !root.notesTab

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}

			Behavior on opacity {
				Anim {}
			}

			ColumnLayout {
				Layout.preferredWidth: 210
				Layout.maximumWidth: 210
				Layout.fillHeight: true
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					StyledText {
						Layout.fillWidth: true
						Layout.leftMargin: 6
						text: "Groups"
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					IconButton {
						icon: "playlist_plus"
						iconSize: 18
						variant: "tonal"
						checked: root.naming
						onClicked: root.naming = !root.naming
					}
				}

				ListView {
					id: groupList

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					spacing: 2
					model: groupModel
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					SyncedModel {
						id: groupModel
					}

					readonly property var rows: [{ key: "\u0001all", name: "", open: Todos.openTasks.length }].concat(Todos.groups.map(group => ({ key: group.name, name: group.name, open: group.open })))

					onRowsChanged: groupModel.sync(groupList.rows)
					Component.onCompleted: groupModel.sync(groupList.rows)

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

					delegate: Clickable {
						id: groupRow

						required property string json
						readonly property var info: JSON.parse(groupRow.json)
						readonly property bool all: groupRow.info.name === ""
						readonly property bool picked: groupRow.info.name === root.selectedGroup

						width: groupList.width
						implicitHeight: 38
						radius: Theme.radius.medium
						pressedScale: 0.98
						showHover: false
						scale: groupDrop.containsDrag ? 1.04 : 1
						color: groupDrop.containsDrag ? Theme.primaryContainer : (groupRow.picked ? Theme.primaryContainer : (groupRow.hovered ? Theme.layer1 : "transparent"))
						onClicked: root.selectedGroup = groupRow.info.name

						Behavior on color {
							ColorAnim {}
						}

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						DropArea {
							id: groupDrop

							anchors.fill: parent
							keys: ["todo-task"]
							enabled: !groupRow.all
							onDropped: drag => {
								const key = drag.source?.taskKey ?? "";
								if (key !== "") Todos.moveTask(key, groupRow.info.name);
							}
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 10

							Glyph {
								icon: groupRow.all ? "checkbox_marked_circle_outline" : (Todos.isPinned(Todos.groupKey(groupRow.info.name)) ? "pin" : (groupRow.info.name === Todos.inbox ? "inbox_outline" : "folder_outline"))
								size: 16
								color: groupRow.picked || groupDrop.containsDrag ? Theme.primary : (groupRow.info.open > 0 || groupRow.all ? Theme.textMuted : Theme.textFaint)
							}

							StyledText {
								Layout.fillWidth: true
								text: groupRow.all ? "All tasks" : groupRow.info.name
								elide: Text.ElideRight
								tone: groupRow.info.open > 0 || groupRow.all || groupRow.picked ? Theme.text : Theme.textSubtle
								font.weight: groupRow.picked ? Font.DemiBold : Font.Medium
							}

							StyledText {
								visible: groupRow.info.open > 0
								text: groupRow.info.open
								tone: Theme.textSubtle
								tabular: true
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Rectangle {
				Layout.preferredWidth: 1
				Layout.fillHeight: true
				color: Theme.outline
			}

			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: root.selectedGroup === "" ? "All tasks" : root.selectedGroup
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}

						StyledText {
							readonly property int open: root.selectedGroup === "" ? Todos.openTasks.length : (Todos.findGroup(root.selectedGroup)?.open ?? 0)

							text: `${open} open`
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					IconButton {
						icon: "pin"
						iconSize: 16
						variant: "tonal"
						readonly property string key: root.selectedGroup === "" ? Todos.overviewKey : Todos.groupKey(root.selectedGroup)
						checked: Todos.isPinned(key)
						onClicked: Todos.togglePin(key)
					}
				}

				TodoBoard {
					id: board

					Layout.fillWidth: true
					Layout.fillHeight: true
					filter: root.selectedGroup
					headless: root.selectedGroup !== ""
				}
			}
		}

		// ── notes ─────────────────────────────────────────────────────────
		RowLayout {
			id: notesPage

			width: parent.width
			height: parent.height
			spacing: 14
			x: root.notesTab ? 0 : 40
			opacity: root.notesTab ? 1 : 0
			visible: opacity > 0.01
			enabled: root.notesTab

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}

			Behavior on opacity {
				Anim {}
			}

			Timer {
				interval: 3000
				repeat: true
				running: root.active && root.notesTab
				onTriggered: Todos.refreshNotes()
			}

			ColumnLayout {
				Layout.preferredWidth: 210
				Layout.maximumWidth: 210
				Layout.fillHeight: true
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					StyledText {
						Layout.fillWidth: true
						Layout.leftMargin: 6
						text: "Notes"
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					IconButton {
						icon: "note_plus"
						iconSize: 18
						variant: "tonal"
						checked: root.naming
						onClicked: root.naming = !root.naming
					}
				}

				ListView {
					id: noteList

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					spacing: 2
					model: noteModel
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					SyncedModel {
						id: noteModel
					}

					readonly property var rows: root.shownNotes.map(note => ({ key: note.path, name: note.name, links: Todos.tasksOf(note.name).length }))

					onRowsChanged: noteModel.sync(noteList.rows)
					Component.onCompleted: noteModel.sync(noteList.rows)

					add: Transition {
						ParallelAnimation {
							Anim {
								property: "opacity"
								from: 0
								to: 1
							}
							SpatialAnim {
								property: "x"
								from: -16
								to: 0
							}
						}
					}
					remove: Transition {
						Anim {
							property: "opacity"
							to: 0
							duration: Motion.short
						}
					}
					displaced: Transition {
						SpatialAnim {
							properties: "y"
							duration: Motion.medium
						}
					}

					delegate: Clickable {
						id: noteRow

						required property string key
						required property string json
						readonly property var info: JSON.parse(noteRow.json)
						readonly property bool picked: noteRow.key === root.selectedNote

						width: noteList.width
						implicitHeight: 38
						radius: Theme.radius.medium
						pressedScale: 0.98
						showHover: false
						color: noteRow.picked ? Theme.primaryContainer : (noteRow.hovered ? Theme.layer1 : "transparent")
						onClicked: root.selectedNote = noteRow.key

						Behavior on color {
							ColorAnim {}
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 10

							Glyph {
								icon: Todos.isPinned(noteRow.key) ? "pin" : "note_text_outline"
								size: 16
								color: noteRow.picked ? Theme.primary : Theme.textMuted
							}

							StyledText {
								Layout.fillWidth: true
								text: noteRow.info.name
								elide: Text.ElideRight
								font.weight: noteRow.picked ? Font.DemiBold : Font.Medium
							}

							Glyph {
								visible: noteRow.info.links > 0
								icon: "link_variant"
								size: 13
								color: Theme.textSubtle
							}
						}
					}
				}
			}

			Rectangle {
				Layout.preferredWidth: 1
				Layout.fillHeight: true
				color: Theme.outline
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				ColumnLayout {
					anchors.fill: parent
					visible: root.note !== null
					spacing: 10

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: root.note?.name ?? ""
								elide: Text.ElideRight
								font.pixelSize: Theme.size.heading
								font.weight: Font.Bold
							}

							StyledText {
								text: root.note ? new Date(root.note.modified * 1000).toLocaleString(Qt.locale(), "d. MMMM yyyy, HH:mm") : ""
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}

						IconButton {
							icon: "pencil"
							iconSize: 16
							variant: "tonal"
							onClicked: {
								Todos.openEditor(root.note.path, -1);
								root.closeRequested();
							}
						}

						IconButton {
							icon: "pin"
							iconSize: 16
							variant: "tonal"
							checked: root.note !== null && Todos.isPinned(root.note.path)
							onClicked: Todos.togglePin(root.note.path)
						}

						IconButton {
							id: deleteNote

							property bool confirm: false

							icon: deleteNote.confirm ? "delete" : "delete_outline"
							iconSize: 16
							variant: deleteNote.confirm ? "danger" : "tonal"
							onClicked: {
								if (!deleteNote.confirm) {
									deleteNote.confirm = true;
									unconfirm.restart();
									return;
								}
								deleteNote.confirm = false;
								Todos.deleteNote(root.note.path);
							}

							Timer {
								id: unconfirm

								interval: 2600
								onTriggered: deleteNote.confirm = false
							}
						}
					}

					TodoNoteLinks {
						Layout.fillWidth: true
						name: root.note?.name ?? ""
					}

					Flickable {
						id: noteFlick

						Layout.fillWidth: true
						Layout.fillHeight: true
						contentHeight: noteDoc.implicitHeight
						clip: true
						boundsBehavior: Flickable.StopAtBounds
						ScrollBar.vertical: ThinScrollBar {}

						TodoDocument {
							id: noteDoc

							width: noteFlick.width - 8
							path: root.selectedNote
							opacity: noteDoc.loaded ? 1 : 0

							Behavior on opacity {
								Anim {}
							}
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.note === null && Todos.notesLoaded
					icon: "note_text_outline"
					title: "No notes"
				}
			}
		}
	}
}
