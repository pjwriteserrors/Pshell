pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A rendered markdown note: headings (a click folds them, remembered in
// Todos.folds), checkboxes (TodoTaskRow), bullets, --- as lines and text with
// inline bold/italic/code. Watches the file, writes changes straight back.
// Shared by the launcher (>todo, notes) and the desktop widgets, which zoom it.
ColumnLayout {
	id: root

	property string path: ""
	property bool compact: false
	property real zoom: 1
	property string content: ""
	property bool loaded: false
	readonly property var entries: Todos.parse(root.content)
	readonly property var progress: Todos.counts(root.content)
	readonly property bool empty: root.entries.every(entry => entry.kind === "blank")
	// the entries that show: none below a folded heading; headings carry
	// foldable (something is below them) and folded
	readonly property var shown: {
		const folds = Todos.folds[root.path] ?? [];
		const out = [];
		let hiddenBelow = 0;
		for (let i = 0; i < root.entries.length; i += 1) {
			const entry = root.entries[i];
			if (entry.kind === "heading" && hiddenBelow > 0 && entry.level <= hiddenBelow) hiddenBelow = 0;
			if (hiddenBelow > 0) continue;
			if (entry.kind !== "heading") {
				out.push(entry);
				continue;
			}
			const next = root.entries.slice(i + 1).find(other => other.kind !== "blank");
			const foldable = next !== undefined && !(next.kind === "heading" && next.level <= entry.level);
			const folded = foldable && folds.indexOf(Todos.foldKey(entry)) >= 0;
			out.push(Object.assign({}, entry, { foldable, folded }));
			if (folded) hiddenBelow = entry.level;
		}
		return out;
	}
	// the task whose picker is open (its line), -1 for none
	property int picking: -1

	function px(value) {
		return Math.max(1, Math.round(value * root.zoom));
	}

	spacing: root.px(root.compact ? 1 : 2)

	function write(next) {
		if (root.path === "") return;
		Todos.noteEdit(root.content, next);
		root.content = next;
		file.setText(next);
	}

	function toggle(line) {
		root.write(Todos.toggled(root.content, line));
	}

	function cycle(line) {
		root.write(Todos.cycled(root.content, line));
	}

	function setMark(line, mark) {
		root.picking = -1;
		root.write(Todos.withMark(root.content, line, mark));
	}

	function setPriority(line, level) {
		root.picking = -1;
		root.write(Todos.withPriority(root.content, line, level));
	}

	function reload() {
		file.reload();
	}

	onPathChanged: {
		root.content = "";
		root.loaded = false;
		root.picking = -1;
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
		onSaved: Todos.refreshNotes()
	}

	Repeater {
		model: root.shown

		delegate: Loader {
			id: slot

			required property var modelData
			required property int index

			Layout.fillWidth: true
			sourceComponent: slot.modelData.kind === "task" ? taskRow : (slot.modelData.kind === "rule" ? ruleRow : otherRow)

			Component {
				id: taskRow

				TodoTaskRow {
					entry: slot.modelData
					compact: root.compact
					zoom: root.zoom
					expanded: root.picking === slot.modelData.line
					onToggleRequested: root.toggle(slot.modelData.line)
					onExpandRequested: root.picking = root.picking === slot.modelData.line ? -1 : slot.modelData.line
					onMarkPicked: mark => root.setMark(slot.modelData.line, mark)
					onPriorityPicked: level => root.setPriority(slot.modelData.line, level)
					onEditRequested: {
						root.picking = -1;
						Todos.openEditor(root.path, slot.modelData.line);
					}
				}
			}

			Component {
				id: ruleRow

				Item {
					implicitHeight: root.px(root.compact ? 12 : 16)

					Rectangle {
						x: root.px(6)
						width: parent.width - root.px(12)
						height: 1
						anchors.verticalCenter: parent.verticalCenter
						color: Theme.outline
					}
				}
			}

			Component {
				id: otherRow

				Clickable {
					id: row

					readonly property var entry: slot.modelData
					readonly property bool heading: row.entry.kind === "heading"
					readonly property real topGap: row.heading && slot.index > 0 ? root.px(root.compact ? 6 : 10) : 0

					implicitHeight: row.entry.kind === "blank"
						? root.px(root.compact ? 4 : 6)
						: line.implicitHeight + root.px(root.compact ? 6 : 10) + row.topGap
					radius: Theme.radius.small
					interactive: row.heading && row.entry.foldable === true
					showHover: row.interactive
					pressedScale: 0.99
					onClicked: Todos.toggleFold(root.path, Todos.foldKey(row.entry))

					RowLayout {
						x: root.px(6) + row.entry.indent * root.px(root.compact ? 16 : 20)
						y: row.topGap
						width: row.width - x - root.px(6)
						height: row.height - row.topGap
						spacing: root.px(root.compact ? 6 : 8)
						visible: row.entry.kind !== "blank"

						StyledText {
							visible: row.entry.kind === "bullet"
							Layout.alignment: Qt.AlignTop
							Layout.topMargin: root.px(root.compact ? 3 : 5)
							Layout.preferredWidth: root.px(root.compact ? 10 : 12)
							text: row.entry.marker || "•"
							tone: Theme.primary
							horizontalAlignment: Text.AlignHCenter
							font.pixelSize: root.px(root.compact ? Theme.size.label : Theme.size.body)
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
							tone: row.entry.kind === "code" ? Theme.textMuted : Theme.text
							font.family: row.entry.kind === "code" ? Theme.monoFamily : Theme.fontFamily
							font.pixelSize: {
								if (row.heading) {
									if (row.entry.level === 1) return root.px(root.compact ? Theme.size.title : Theme.size.heading);
									if (row.entry.level === 2) return root.px(root.compact ? Theme.size.body + 1 : Theme.size.title);
									return root.px(root.compact ? Theme.size.body : Theme.size.body + 1);
								}
								return root.px(root.compact ? Theme.size.label + 1 : Theme.size.body + 1);
							}
							font.weight: row.heading ? Font.Bold : Font.Normal
							onLinkActivated: link => Qt.openUrlExternally(link)
						}

						Glyph {
							visible: row.interactive
							icon: row.entry.folded ? "chevron_right" : "chevron_down"
							size: root.px(root.compact ? 15 : 17)
							color: row.entry.folded ? Theme.primary : Theme.textSubtle
							opacity: row.entry.folded || row.hovered ? 1 : 0.6
						}
					}
				}
			}
		}
	}
}
