pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The chooser's own part, under the files: who asks and what, the filter
// and the app's options, the name to save as, and the way out. It answers
// every question an app can ask through the portal:
//   OpenFile    one file, many files, one folder or many folders
//   SaveFile    a name in a folder (an existing one is replaced only when agreed)
//   SaveFiles   a folder for files the app names (those already there are agreed to)
Rectangle {
	id: root

	property var entry: null
	property var pane: null
	property var view: null

	// the filter shown: an index into entry.filters, -1 for every file
	property int filterIndex: -1
	// the app's own options: { id: value }; a check box is "true" or "false"
	property var choiceValues: ({})

	readonly property string method: root.entry?.method ?? "OpenFile"
	readonly property bool saving: root.method === "SaveFile"
	readonly property bool savingMany: root.method === "SaveFiles"
	readonly property bool folders: !!root.entry?.directory && root.method === "OpenFile"
	readonly property bool many: !!root.entry?.multiple
	readonly property string folder: root.pane && root.pane.isFolder ? String(root.pane.location.path) : ""
	readonly property var filters: root.entry?.filters ?? []
	readonly property var choices: root.entry?.choices ?? []
	readonly property int waiting: Math.max(0, Files.chooseQueue.length - 1)

	readonly property string heading: {
		const title = root.entry?.title ?? "";
		if (title !== "") return title;
		if (root.saving) return "Save";
		if (root.savingMany) return "Choose where the files go";
		if (root.folders) return root.many ? "Choose folders" : "Choose a folder";
		return root.many ? "Open files" : "Open a file";
	}

	readonly property string acceptText: {
		const label = root.entry?.acceptLabel ?? "";
		if (label !== "") return label;
		if (root.saving || root.savingMany) return "Save";
		return root.folders ? "Choose" : "Open";
	}

	// what an open would answer now
	readonly property var chosen: {
		root.pane?.selectionTick;
		if (!root.entry || !root.pane || root.saving || root.savingMany) return [];
		const rows = root.pane.selectedRows();
		if (root.folders) {
			const dirs = rows.filter(row => row.dir).map(row => row.path);
			if (dirs.length > 0) return root.many ? dirs : dirs.slice(0, 1);
			return root.folder !== "" ? [root.folder] : [];
		}
		const filter = root.filterIndex >= 0 ? root.filters[root.filterIndex] : null;
		const files = rows.filter(row => !row.dir && Files.filterTakes(filter, row)).map(row => row.path);
		return root.many ? files : files.slice(0, 1);
	}

	readonly property real chosenSize: {
		root.pane?.selectionTick;
		if (!root.pane || root.folders) return 0;
		return root.pane.selectedRows().filter(row => root.chosen.includes(row.path)).reduce((sum, row) => sum + (row.size || 0), 0);
	}

	readonly property bool canAccept: {
		if (!root.entry) return false;
		if (root.saving) return root.folder !== "" && nameField.text.trim() !== "";
		if (root.savingMany) return root.savingFolder() !== "";
		return root.chosen.length > 0;
	}

	implicitHeight: column.implicitHeight + 24
	height: root.implicitHeight
	radius: Theme.radius.large
	color: Theme.layer1
	border.width: 1
	border.color: Theme.outline

	// ── a new question ────────────────────────────────────────────────────
	function reset(entry) {
		root.filterIndex = entry.filter ?? -1;
		const values = {};
		for (const choice of entry.choices ?? []) values[choice.id] = choice.default !== "" ? choice.default : (choice.options.length > 0 ? String(choice.options[0][0]) : "false");
		root.choiceValues = values;
		const file = entry.method === "SaveFile" ? entry.currentFile : "";
		nameField.text = file !== "" ? Files.nameOf(file) : (entry.currentName || "");
	}

	function takeFocus() {
		if (root.saving) {
			nameField.focusInput();
			// the name without its ending is what one usually changes
			const name = nameField.text;
			const dot = name.lastIndexOf(".");
			nameField.input.select(0, dot > 0 ? dot : name.length);
		} else if (root.view) {
			root.view.focusFiles();
		}
	}

	// ── the answers ───────────────────────────────────────────────────────
	function cancel() {
		if (root.entry) Files.finishChoose(root.entry, { response: 1 });
	}

	function finish(paths) {
		if (!root.entry || paths.length === 0) return;
		Sounds.play("confirm");
		Files.finishChoose(root.entry, {
			response: 0,
			paths: paths,
			choices: Object.keys(root.choiceValues).map(id => [id, String(root.choiceValues[id])]),
			filter: root.filterIndex
		});
	}

	function savingFolder() {
		if (!root.pane) return "";
		const rows = root.pane.selectedRows();
		if (rows.length === 1 && rows[0].dir) return rows[0].path;
		return root.folder;
	}

	// what the name field means: a name here, a path of its own, a folder to step into
	function targetOf(text) {
		const name = text.trim();
		if (name.startsWith("~/")) return Files.home + name.slice(1);
		if (name.startsWith("/")) return name;
		return `${root.folder === "/" ? "" : root.folder}/${name}`;
	}

	function accept() {
		if (!root.entry || !root.pane) return;
		if (root.saving) {
			const name = nameField.text.trim();
			if (name === "" || root.folder === "") return;
			if (name === "..") {
				nameField.text = "";
				root.pane.goUp();
				return;
			}
			// a folder's name steps into it, as in every chooser
			const into = root.pane.rows.find(row => row.dir && row.name === name);
			if (into) {
				nameField.text = "";
				root.pane.openFolder(into.path);
				return;
			}
			const path = root.targetOf(name);
			if (name.endsWith("/")) {
				root.pane.openFolder(path.replace(/\/+$/, ""));
				nameField.text = "";
				return;
			}
			root.saveTo([path]);
			return;
		}
		if (root.savingMany) {
			const target = root.savingFolder();
			if (target === "") return;
			root.saveTo((root.entry.files ?? []).map(name => `${target === "/" ? "" : target}/${name}`));
			return;
		}
		// a file asked for while a folder is picked: the folder opens
		if (!root.folders && root.chosen.length === 0) {
			const current = root.pane.currentRow;
			if (current?.dir) root.pane.openFolder(current.path);
			return;
		}
		root.finish(root.chosen);
	}

	// saving over what is there is agreed to first
	function saveTo(paths) {
		Files.request("describe", { paths: paths }, data => {
			const there = (data?.entries ?? []).map(entry => String(entry.path));
			const dirs = (data?.entries ?? []).filter(entry => entry.dir).map(entry => String(entry.path));
			if (dirs.length > 0) {
				Files.say(`${Files.nameOf(dirs[0])} is a folder`, "folder_alert_outline");
				return;
			}
			if (there.length === 0) {
				root.finish(paths);
				return;
			}
			root.view?.askConfirm({
				title: there.length === 1 ? `Replace ${Files.nameOf(there[0])}?` : `Replace ${there.length} files?`,
				detail: there.length === 1 ? `It is already in ${Files.nameOf(Files.parentOf(there[0])) || "/"}; saving writes over it.` : there.map(path => Files.nameOf(path)).join(", "),
				confirm: "Replace",
				danger: true,
				run: () => root.finish(paths)
			});
		});
	}

	// a file opened (double click, Enter) in the files
	function openedFiles(rows) {
		if (root.saving) {
			if (rows.length > 0) {
				nameField.text = rows[0].name;
				root.accept();
			}
			return;
		}
		if (root.folders || root.savingMany) return;
		const filter = root.filterIndex >= 0 ? root.filters[root.filterIndex] : null;
		const paths = rows.filter(row => Files.filterTakes(filter, row)).map(row => row.path);
		if (paths.length > 0) root.finish(root.many ? paths : paths.slice(0, 1));
	}

	// another filter: a name to save takes its ending
	function pickFilter(index) {
		root.filterIndex = index;
		if (!root.saving || index < 0) return;
		const glob = (root.filters[index]?.rules ?? []).map(rule => String(rule[1])).find(pattern => /^\*\.[A-Za-z0-9]+$/.test(pattern));
		const name = nameField.text;
		if (!glob || name === "") return;
		const dot = name.lastIndexOf(".");
		nameField.text = `${dot > 0 ? name.slice(0, dot) : name}${glob.slice(1)}`;
	}

	// a file clicked while saving: its name is the one to save as
	Connections {
		target: root.pane
		ignoreUnknownSignals: true

		function onSelectionTickChanged() {
			if (!root.saving || !root.pane) return;
			const rows = root.pane.selectedRows();
			if (rows.length === 1 && !rows[0].dir) nameField.text = rows[0].name;
		}
	}

	// ── the bar ───────────────────────────────────────────────────────────
	ColumnLayout {
		id: column

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		spacing: 10

		// who asks, what for, and the app's options
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Item {
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28

				Image {
					id: appIcon

					anchors.fill: parent
					source: root.entry?.appIcon ? Quickshell.iconPath(root.entry.appIcon, true) : ""
					sourceSize: Qt.size(56, 56)
					visible: status === Image.Ready
					asynchronous: true
				}

				Glyph {
					anchors.centerIn: parent
					visible: !appIcon.visible
					icon: root.saving || root.savingMany ? "content_save_outline" : (root.folders ? "folder_outline" : "file_outline")
					color: Theme.primary
					size: 22
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					Layout.fillWidth: true
					text: root.heading
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					visible: text !== ""
					text: {
						const app = root.entry?.appName ?? "";
						const what = root.savingMany ? `${(root.entry?.files ?? []).length} files: ${(root.entry?.files ?? []).join(", ")}` : "";
						return [app !== "" ? `${app} asks` : "", what, root.waiting > 0 ? `${root.waiting} more waiting` : ""].filter(part => part !== "").join(" · ");
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			// the app's own options: a check box, or one of a few
			Repeater {
				model: root.choices

				delegate: Item {
					id: choice

					required property var modelData
					readonly property bool check: (choice.modelData.options ?? []).length === 0
					readonly property string value: String(root.choiceValues[choice.modelData.id] ?? "")

					Layout.preferredWidth: choice.check ? checkRow.implicitWidth : choiceButton.implicitWidth
					Layout.preferredHeight: 36

					RowLayout {
						id: checkRow

						visible: choice.check
						anchors.verticalCenter: parent.verticalCenter
						spacing: 8

						StyledText {
							text: choice.modelData.label
							font.pixelSize: Theme.size.small
						}

						Toggle {
							checked: choice.value === "true"
							onToggled: on => root.choiceValues = Object.assign({}, root.choiceValues, { [choice.modelData.id]: on ? "true" : "false" })
						}
					}

					TextButton {
						id: choiceButton

						visible: !choice.check
						anchors.verticalCenter: parent.verticalCenter
						variant: "tonal"
						icon: "chevron_down"
						text: {
							const option = (choice.modelData.options ?? []).find(each => String(each[0]) === choice.value);
							return `${choice.modelData.label}: ${option ? option[1] : choice.value}`;
						}
						onActivated: choiceList.open()

						PickList {
							id: choiceList

							y: -height - 6
							current: choice.value
							entries: (choice.modelData.options ?? []).map(each => ({ value: String(each[0]), label: String(each[1]) }))
							onPicked: value => root.choiceValues = Object.assign({}, root.choiceValues, { [choice.modelData.id]: String(value) })
						}
					}
				}
			}

			TextButton {
				id: filterButton

				visible: root.filters.length > 0 && !root.savingMany && !root.folders
				variant: "tonal"
				icon: "filter_variant"
				text: root.filterIndex >= 0 ? (root.filters[root.filterIndex]?.name ?? "") : "All files"
				onActivated: filterList.open()

				PickList {
					id: filterList

					y: -height - 6
					x: filterButton.width - width
					current: String(root.filterIndex)
					entries: root.filters.map((filter, index) => ({
						value: String(index),
						label: filter.name,
						detail: (filter.rules ?? []).map(rule => String(rule[1])).join(" "),
						icon: "filter_variant"
					})).concat([{ value: "-1", label: "All files", detail: "Everything, whatever the app asked for", icon: "file_multiple_outline" }])
					onPicked: value => root.pickFilter(Number(value))
				}
			}
		}

		// the name, or what is chosen; and the buttons
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Field {
				id: nameField

				visible: root.saving
				Layout.fillWidth: true
				icon: "form_textbox"
				placeholder: "Name"
				clearable: true
				onAccepted: root.accept()
				onEscapePressed: root.cancel()
				onDownPressed: root.view?.focusFiles()
			}

			StyledText {
				visible: !root.saving
				Layout.fillWidth: true
				text: {
					if (root.savingMany) {
						const target = root.savingFolder();
						return target === "" ? "Open a folder to save in" : `Into ${Files.nameOf(target) || "/"}`;
					}
					if (root.chosen.length === 0) return root.folders ? "Open the folder to choose" : (root.many ? "Pick one file or more" : "Pick a file");
					if (root.chosen.length === 1) return Files.nameOf(root.chosen[0]) || root.chosen[0];
					return `${root.chosen.length} ${root.folders ? "folders" : "files"}${root.chosenSize > 0 ? ` · ${Format.bytes(root.chosenSize)}` : ""}`;
				}
				tone: root.chosen.length > 0 || root.savingMany ? Theme.text : Theme.textMuted
				elide: Text.ElideMiddle
			}

			StyledText {
				visible: root.saving
				Layout.maximumWidth: 260
				text: root.folder !== "" ? `in ${Files.nameOf(root.folder) || "/"}` : "Open a folder to save in"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideMiddle
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onActivated: root.cancel()
			}

			TextButton {
				text: root.acceptText
				variant: "filled"
				enabled: root.canAccept
				onActivated: root.accept()
			}
		}
	}
}
