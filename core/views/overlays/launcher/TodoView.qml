pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >todo: the lists in ~/todo on the left, the selected one rendered
// on the right. Enter adds the typed text as a task, Ctrl+N (or +) names a
// new list, ↑↓ switch lists, the pin puts a list on the desktop.
RowLayout {
	id: root

	property string argument: ""
	property bool active: false
	// Enter creates a list named after the argument instead of adding a task
	property bool naming: false
	property string selectedPath: ""
	readonly property int selectedIndex: Todos.lists.findIndex(list => list.path === root.selectedPath)
	readonly property var selected: root.selectedIndex >= 0 ? Todos.lists[root.selectedIndex] : null
	readonly property string task: String(root.argument || "").trim()

	signal closeRequested
	signal argumentRequested(string text)

	spacing: 14

	onActiveChanged: {
		root.naming = false;
		if (root.active) Todos.refresh();
	}

	Connections {
		target: Todos

		function onListsChanged() {
			if (root.selectedIndex < 0 && Todos.lists.length > 0) root.selectedPath = Todos.lists[0].path;
		}
		function onListCreated(path) {
			if (path === root.selectedPath) doc.reload();
		}
	}

	function move(delta) {
		if (Todos.lists.length === 0) return;
		const index = Math.max(0, Math.min(Todos.lists.length - 1, (root.selectedIndex < 0 ? 0 : root.selectedIndex + delta)));
		root.selectedPath = Todos.lists[index].path;
		listView.positionViewAtIndex(index, ListView.Contain);
	}

	function handleKey(event) {
		if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
			root.naming = !root.naming;
			return true;
		}
		return false;
	}

	function cancel() {
		if (!root.naming) return false;
		root.naming = false;
		return true;
	}

	function activate(modifiers) {
		if (root.naming) {
			if (root.task === "") return;
			root.selectedPath = Todos.createList(root.task, "");
			root.naming = false;
			root.argumentRequested("");
			return;
		}
		if (root.task === "") return;
		if (!root.selected) {
			root.selectedPath = Todos.createList("Todo", `- [ ] ${root.task}\n`);
		} else {
			doc.addTask(root.task);
		}
		root.argumentRequested("");
	}

	function openInEditor() {
		if (!root.selected) return;
		Quickshell.execDetached(["kitty", "-e", "nano", "-0", root.selected.path]);
		root.closeRequested();
	}

	// ── lists ─────────────────────────────────────────────────────────────
	ColumnLayout {
		Layout.preferredWidth: 210
		Layout.maximumWidth: 210
		Layout.fillWidth: false
		Layout.fillHeight: true
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 6
				text: "Lists"
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
			id: listView

			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			spacing: 2
			model: Todos.lists
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: Clickable {
				id: listRow

				required property var modelData
				required property int index
				readonly property bool picked: listRow.modelData.path === root.selectedPath
				readonly property bool finished: listRow.modelData.total > 0 && listRow.modelData.done === listRow.modelData.total

				width: listView.width
				implicitHeight: 42
				radius: Theme.radius.medium
				pressedScale: 0.98
				showHover: false
				color: listRow.picked ? Theme.primaryContainer : (listRow.hovered ? Theme.layer1 : "transparent")
				onClicked: root.selectedPath = listRow.modelData.path

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 10
					spacing: 10

					Glyph {
						icon: Todos.isPinned(listRow.modelData.path) ? "pin" : (listRow.finished ? "checkbox_marked" : "format_list_checks")
						size: 16
						color: listRow.picked || listRow.finished ? Theme.primary : Theme.textMuted
					}

					StyledText {
						Layout.fillWidth: true
						text: listRow.modelData.name
						font.weight: listRow.picked ? Font.DemiBold : Font.Medium
					}

					StyledText {
						visible: listRow.modelData.total > 0
						text: `${listRow.modelData.done}/${listRow.modelData.total}`
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

	// ── selected list ─────────────────────────────────────────────────────
	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		ColumnLayout {
			anchors.fill: parent
			visible: root.selected !== null
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: root.selected?.name ?? ""
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}

					StyledText {
						visible: doc.progress.total > 0
						text: `${doc.progress.done} of ${doc.progress.total} done`
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					icon: "pencil"
					iconSize: 16
					variant: "tonal"
					onClicked: root.openInEditor()
				}

				IconButton {
					icon: "pin"
					iconSize: 16
					variant: "tonal"
					checked: root.selected !== null && Todos.isPinned(root.selected.path)
					onClicked: Todos.togglePin(root.selected.path)
				}
			}

			Flickable {
				id: docFlick

				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: doc.implicitHeight
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				TodoDocument {
					id: doc

					width: docFlick.width - 8
					path: root.selectedPath
				}

				EmptyState {
					width: docFlick.width
					y: 60
					visible: doc.loaded && doc.empty
					icon: "checkbox_blank_outline"
					title: "No tasks"
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: root.selected === null && !Todos.loading
			icon: "format_list_checks"
			title: "No lists"
		}
	}
}
