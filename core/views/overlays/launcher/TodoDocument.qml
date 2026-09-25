pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A rendered markdown todo file: headings, clickable `- [ ]` checkboxes,
// bullets and text with inline bold/italic/code. Watches the file, writes
// toggles and new tasks straight back. Shared by the launcher (>todo) and
// the desktop widgets.
ColumnLayout {
	id: root

	property string path: ""
	property bool compact: false
	property string content: ""
	property bool loaded: false
	readonly property var entries: Todos.parse(root.content)
	readonly property var progress: Todos.counts(root.content)
	readonly property bool empty: root.entries.every(entry => entry.kind === "blank")

	spacing: root.compact ? 1 : 2

	function write(next) {
		if (root.path === "") return;
		Todos.noteEdit(root.content, next);
		root.content = next;
		file.setText(next);
	}

	function toggle(line) {
		root.write(Todos.toggled(root.content, line));
	}

	function reload() {
		file.reload();
	}

	function addTask(task) {
		if (String(task || "").trim() === "") return;
		root.write(Todos.withTask(root.content, task));
	}

	onPathChanged: {
		root.content = "";
		root.loaded = false;
	}

	FileView {
		id: file

		path: root.path
		watchChanges: true
		atomicWrites: false
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			root.content = text();
			root.loaded = true;
		}
		onLoadFailed: {
			root.content = "";
			root.loaded = true;
		}
		onSaved: Todos.refresh()
	}

	Repeater {
		model: root.entries

		delegate: Clickable {
			id: row

			required property var modelData
			required property int index
			readonly property var entry: row.modelData
			readonly property bool task: row.entry.kind === "task"
			readonly property bool heading: row.entry.kind === "heading"
			readonly property real topGap: row.heading && row.index > 0 ? (root.compact ? 6 : 10) : 0

			Layout.fillWidth: true
			implicitHeight: row.entry.kind === "blank"
				? (root.compact ? 4 : 6)
				: Math.max(line.implicitHeight + (root.compact ? 6 : 10), row.task ? (root.compact ? 26 : 32) : 0) + row.topGap
			radius: Theme.radius.small
			interactive: row.task
			showHover: row.task
			pressedScale: 0.985
			onClicked: root.toggle(row.entry.line)

			RowLayout {
				x: 6 + row.entry.indent * (root.compact ? 16 : 20)
				y: row.topGap
				width: row.width - x - 6
				height: row.height - row.topGap
				spacing: root.compact ? 8 : 10
				visible: row.entry.kind !== "blank"

				Glyph {
					visible: row.task
					Layout.alignment: Qt.AlignTop
					Layout.topMargin: root.compact ? 4 : 6
					icon: row.entry.done ? "checkbox_marked" : "checkbox_blank_outline"
					size: root.compact ? 17 : 19
					color: row.entry.done ? Theme.primary : Theme.textMuted
				}

				StyledText {
					visible: row.entry.kind === "bullet"
					Layout.alignment: Qt.AlignTop
					Layout.topMargin: root.compact ? 3 : 5
					Layout.preferredWidth: root.compact ? 10 : 12
					text: row.entry.marker || "•"
					tone: Theme.primary
					horizontalAlignment: Text.AlignHCenter
					font.pixelSize: root.compact ? Theme.size.label : Theme.size.body
					font.weight: Font.Bold
				}

				StyledText {
					id: line

					Layout.fillWidth: true
					Layout.alignment: Qt.AlignVCenter
					text: row.entry.kind === "code"
						? Todos.escapeHtml(row.entry.text)
						: Todos.inline(row.entry.text, Theme.primary, Theme.monoFamily)
					textFormat: Text.StyledText
					wrapMode: Text.Wrap
					elide: Text.ElideNone
					linkColor: Theme.primary
					tone: row.entry.done ? Theme.textSubtle : (row.entry.kind === "code" ? Theme.textMuted : Theme.text)
					font.strikeout: row.entry.done
					font.family: row.entry.kind === "code" ? Theme.monoFamily : Theme.fontFamily
					font.pixelSize: {
						if (row.heading) {
							if (row.entry.level === 1) return root.compact ? Theme.size.title : Theme.size.heading;
							if (row.entry.level === 2) return root.compact ? Theme.size.body + 1 : Theme.size.title;
							return root.compact ? Theme.size.body : Theme.size.body + 1;
						}
						return root.compact ? Theme.size.label + 1 : Theme.size.body + 1;
					}
					font.weight: row.heading ? Font.Bold : Font.Normal
					onLinkActivated: link => Qt.openUrlExternally(link)
				}
			}
		}
	}
}
