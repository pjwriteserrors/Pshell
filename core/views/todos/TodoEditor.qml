pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.launcher

// The editor of one note (Todos.openEditor / newNote, Mod+T): the markdown
// as it is in the file, saved a moment after typing stops, with the tasks
// the note belongs to above it. Enter continues a list, Shift+Enter starts a
// description below a checkbox, Tab and Shift+Tab indent, Ctrl+Space steps a
// checkbox's state. Without a path the name comes first; renaming moves the
// file and its links.
FloatingWindow {
	id: root

	// the file being edited; follows Todos.editorPath once a rename or a new note exists
	property string currentPath: ""
	// a rename or a new note in flight: switch over once the file is there
	property string pendingPath: ""
	// the text as the file has it; anything else in the area is unsaved
	property string savedText: ""
	readonly property bool dirty: area.text !== root.savedText
	// a rename or new list is being started: its editorPath change is ours
	property bool applying: false
	readonly property var progress: Todos.counts(area.text)

	title: root.currentPath === "" ? "New note" : Todos.displayName(root.currentPath)
	visible: true
	implicitWidth: 680
	implicitHeight: 760
	minimumSize: Qt.size(420, 340)
	color: Theme.base

	function save() {
		if (!root.dirty || root.currentPath === "") return;
		Todos.noteEdit(root.savedText, area.text);
		root.savedText = area.text;
		file.setText(area.text);
	}

	function close() {
		saveTimer.stop();
		root.save();
		Todos.closeEditor();
	}

	function follow() {
		const path = Todos.editorPath;
		if (path === root.currentPath) {
			root.goTo(Todos.editorLine);
			return;
		}
		saveTimer.stop();
		root.save();
		root.currentPath = path;
		if (path === "") {
			area.text = "";
			root.savedText = "";
			nameField.text = "";
			nameField.focusInput();
		}
	}

	// cursor to the end of a line (-1: end of the text)
	function goTo(line) {
		const lines = area.text.split("\n");
		let position = area.text.length;
		if (line >= 0 && line < lines.length) {
			position = 0;
			for (let i = 0; i < line; i += 1) position += lines[i].length + 1;
			position += lines[line].length;
		}
		area.cursorPosition = position;
		area.forceActiveFocus();
	}

	function applyName() {
		const name = nameField.text.trim();
		if (name === "") return;
		root.applying = true;
		if (root.currentPath === "") {
			// a note of that name is there already: open it as it is
			const known = Todos.findNote(name);
			const path = known ? known.path : Todos.createNote(name, area.text);
			if (path !== "") {
				root.savedText = area.text;
				if (known) root.currentPath = path;
				else root.pendingPath = path;
				Todos.editorPath = path;
				area.forceActiveFocus();
			}
			root.applying = false;
			return;
		}
		if (name !== Todos.displayName(root.currentPath)) {
			saveTimer.stop();
			root.save();
			const target = Todos.renameNote(root.currentPath, name);
			if (target !== root.currentPath) root.pendingPath = target;
		}
		root.applying = false;
		if (root.pendingPath === "") nameField.text = Todos.displayName(root.currentPath);
	}

	// ── line edits on the text area (kept in its undo history) ───────────
	function lineBounds(position) {
		const text = area.text;
		const start = text.lastIndexOf("\n", position - 1) + 1;
		let end = text.indexOf("\n", position);
		if (end < 0) end = text.length;
		return { start, end, text: text.slice(start, end) };
	}

	function replaceRange(start, end, text) {
		area.remove(start, end);
		area.insert(start, text);
	}

	function setMark(mark) {
		const cursor = area.cursorPosition;
		const line = root.lineBounds(cursor);
		const task = /^(\s*[-*+]\s+\[)(.)\]/.exec(line.text);
		if (task) {
			const at = line.start + task[1].length;
			root.replaceRange(at, at + 1, mark);
			area.cursorPosition = cursor;
			return;
		}
		const bullet = /^(\s*[-*+]\s+)/.exec(line.text);
		const lead = bullet ? bullet[1] : /^\s*/.exec(line.text)[0];
		const insert = bullet ? `[${mark}] ` : `- [${mark}] `;
		area.insert(line.start + lead.length, insert);
		area.cursorPosition = cursor + insert.length;
	}

	function cycleMark() {
		const line = root.lineBounds(area.cursorPosition);
		const task = Todos.taskPattern.exec(line.text);
		if (!task) {
			root.setMark(" ");
			return;
		}
		root.setMark(task[2] === "/" ? "x" : (Todos.isDone(task[2]) ? " " : "/"));
	}

	// no heading → # → ## → ### → none
	function cycleHeading() {
		const cursor = area.cursorPosition;
		const line = root.lineBounds(cursor);
		const heading = /^(#{1,6})\s+/.exec(line.text);
		const level = heading ? heading[1].length : 0;
		const next = level >= 3 ? "" : "#".repeat(level + 1) + " ";
		const old = heading ? heading[0].length : 0;
		root.replaceRange(line.start, line.start + old, next);
		area.cursorPosition = Math.max(line.start, cursor + next.length - old);
	}

	function toggleBullet() {
		const cursor = area.cursorPosition;
		const line = root.lineBounds(cursor);
		const bullet = /^(\s*)[-*+]\s+(?:\[.\]\s+)?/.exec(line.text);
		if (bullet) {
			root.replaceRange(line.start + bullet[1].length, line.start + bullet[0].length, "");
			area.cursorPosition = Math.max(line.start, cursor - (bullet[0].length - bullet[1].length));
			return;
		}
		const lead = /^\s*/.exec(line.text)[0];
		area.insert(line.start + lead.length, "- ");
		area.cursorPosition = cursor + 2;
	}

	// a new description line below the task (after the lines it already has)
	function addDescription() {
		const line = root.lineBounds(area.cursorPosition);
		const task = Todos.taskPattern.exec(line.text);
		const lead = task ? task[1] : /^\s*/.exec(line.text)[0];
		let end = line.end;
		if (task) {
			while (end < area.text.length) {
				const next = root.lineBounds(end + 1);
				const nextLead = /^\s*/.exec(next.text)[0];
				if (next.text.trim() === "" || /^\s*([-*+]|\d+[.)])\s/.test(next.text) || Todos.columns(nextLead) <= Todos.columns(lead)) break;
				end = next.end;
			}
		}
		const insert = `\n${lead}\t`;
		area.insert(end, insert);
		area.cursorPosition = end + insert.length;
	}

	function newLine() {
		const cursor = area.cursorPosition;
		const line = root.lineBounds(cursor);
		const item = /^(\s*)([-*+]\s+(?:\[.\]\s+)?|\d+[.)]\s+)(.*)$/.exec(line.text);
		if (item && item[3].trim() === "" && cursor === line.end) {
			// Enter on an empty item ends the list
			root.replaceRange(line.start, line.end, item[1]);
			return;
		}
		let marker = "";
		if (item) marker = /\[.\]/.test(item[2]) ? "- [ ] " : (/^\d/.test(item[2]) ? `${Number(item[2].replace(/\D/g, "")) + 1}${item[2].replace(/[\d\s]/g, "")} ` : `${item[2].trim()} `);
		const lead = item ? item[1] : /^\s*/.exec(line.text)[0];
		area.insert(cursor, `\n${lead}${marker}`);
	}

	function indent(outdent) {
		const text = area.text;
		const from = root.lineBounds(Math.min(area.selectionStart, area.selectionEnd)).start;
		const to = root.lineBounds(Math.max(area.selectionStart, area.selectionEnd)).end;
		const cursor = area.cursorPosition;
		const lines = text.slice(from, to).split("\n");
		const next = lines.map(line => outdent ? line.replace(/^(\t| {1,4})/, "") : `\t${line}`).join("\n");
		if (next === text.slice(from, to)) return;
		const single = lines.length === 1;
		root.replaceRange(from, to, next);
		if (single) area.cursorPosition = Math.max(from, cursor + next.length - (to - from));
		else area.select(from, from + next.length);
	}

	onVisibleChanged: if (!root.visible) root.close()

	Component.onCompleted: {
		root.follow();
		if (root.currentPath === "") nameField.focusInput();
	}

	Connections {
		target: Todos

		function onEditorPathChanged() {
			if (!root.applying) root.follow();
		}
		function onEditorRequested() {
			root.follow();
		}
		function onNoteCreated(path) {
			if (path !== root.pendingPath) return;
			root.pendingPath = "";
			root.currentPath = path;
			nameField.text = Todos.displayName(path);
		}
	}

	FileView {
		id: file

		path: root.currentPath
		watchChanges: true
		atomicWrites: false
		blockWrites: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			const text = file.text();
			nameField.text = Todos.displayName(root.currentPath);
			// typing that is not saved yet is newer than the file
			if (root.dirty) {
				root.save();
				return;
			}
			if (text === area.text) {
				root.savedText = text;
				return;
			}
			const first = area.text === "" && !area.activeFocus;
			const cursor = area.cursorPosition;
			root.savedText = text;
			area.text = text;
			if (first) root.goTo(Todos.editorLine);
			else area.cursorPosition = Math.min(cursor, text.length);
		}
		onSaved: Todos.refreshNotes()
	}

	Timer {
		id: saveTimer

		interval: 450
		onTriggered: root.save()
	}

	Shortcut {
		sequence: "Escape"
		onActivated: root.close()
	}

	Shortcut {
		sequence: "Ctrl+S"
		onActivated: {
			saveTimer.stop();
			root.save();
		}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: Theme.panelPadding
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: nameField

				Layout.fillWidth: true
				icon: "format_list_checks"
				placeholder: "Name"
				clearable: false
				fontSize: Theme.size.title
				onAccepted: root.applyName()
				onEscapePressed: root.close()
			}

			Connections {
				target: nameField.input

				function onActiveFocusChanged() {
					if (!nameField.input.activeFocus && root.currentPath !== "" && root.pendingPath === "") root.applyName();
				}
			}

			StyledText {
				visible: root.progress.total > 0
				text: `${root.progress.done}/${root.progress.total}`
				tone: root.progress.done === root.progress.total ? Theme.primary : Theme.textSubtle
				tabular: true
				font.weight: Font.DemiBold
			}

			IconButton {
				visible: root.currentPath !== ""
				icon: "pin"
				iconSize: 16
				variant: "tonal"
				checked: Todos.isPinned(root.currentPath)
				onClicked: Todos.togglePin(root.currentPath)
			}
		}

		TodoNoteLinks {
			Layout.fillWidth: true
			name: root.currentPath === "" ? "" : Todos.displayName(root.currentPath)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 2

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "format_header_pound"
				iconSize: 18
				onClicked: {
					root.cycleHeading();
					area.forceActiveFocus();
				}
			}

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "format_list_bulleted"
				iconSize: 18
				onClicked: {
					root.toggleBullet();
					area.forceActiveFocus();
				}
			}

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "format_list_checkbox"
				iconSize: 18
				onClicked: {
					root.setMark(" ");
					area.forceActiveFocus();
				}
			}

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "text_long"
				iconSize: 18
				onClicked: {
					root.addDescription();
					area.forceActiveFocus();
				}
			}

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "format_indent_decrease"
				iconSize: 18
				onClicked: {
					root.indent(true);
					area.forceActiveFocus();
				}
			}

			IconButton {
				Layout.preferredWidth: 32
				Layout.preferredHeight: 32
				icon: "format_indent_increase"
				iconSize: 18
				onClicked: {
					root.indent(false);
					area.forceActiveFocus();
				}
			}

			Item {
				Layout.fillWidth: true
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.fillHeight: true
			radius: Theme.radius.large
			color: area.activeFocus ? Theme.layer2 : Theme.layer1

			ScrollView {
				anchors.fill: parent
				anchors.margins: 4
				clip: true
				ScrollBar.vertical: ThinScrollBar {}

				TextArea {
					id: area

					color: Theme.text
					selectionColor: Qt.alpha(Theme.primary, 0.4)
					selectedTextColor: Theme.text
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.body
					tabStopDistance: area.font.pixelSize * 2.4
					wrapMode: TextEdit.Wrap
					textFormat: TextEdit.PlainText
					selectByMouse: true
					persistentSelection: true
					background: null
					padding: 12
					onTextChanged: if (root.dirty) saveTimer.restart()
					Keys.onPressed: event => {
						const control = event.modifiers & Qt.ControlModifier;
						const shift = event.modifiers & Qt.ShiftModifier;
						if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !control) {
							event.accepted = true;
							if (shift) root.addDescription();
							else root.newLine();
						} else if (event.key === Qt.Key_Tab && !control) {
							event.accepted = true;
							root.indent(false);
						} else if (event.key === Qt.Key_Backtab) {
							event.accepted = true;
							root.indent(true);
						} else if (event.key === Qt.Key_Space && control) {
							event.accepted = true;
							root.cycleMark();
						}
					}
				}
			}
		}
	}
}
