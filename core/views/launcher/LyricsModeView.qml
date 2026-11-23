pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >rhyme (kind "rhyme"): rhymes for the words typed, the last three
// of them cut every way; Enter copies one. Launcher >verses (kind "lyrics"):
// the songs of the rhymes window, found by title or by any line in them;
// Enter opens the song at that line.
Item {
	id: root

	property string kind: "rhyme"
	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	property var answer: null
	property var songs: []

	readonly property string words: root.argument.trim()

	signal closeRequested

	// [{ section, text, detail, id, line, syllables }]
	readonly property var rows: {
		const out = [];
		if (root.kind === "rhyme") {
			const names = { multi: "Multi", perfect: "Perfect", near: "Near", yours: "Yours" };
			for (const span of root.answer?.spans ?? []) {
				const piece = (root.answer.words || []).slice(span.from, span.to).join(" ");
				for (const group of span.groups || [])
					for (const item of group.items.slice(0, group.kind === "multi" ? 12 : 16))
						out.push({ section: `${names[group.kind] ?? group.kind} · ${piece}`, text: item.text, detail: item.song || "", syllables: item.syllables || 0 });
			}
			return out;
		}
		if (root.words === "") {
			for (const song of root.songs.slice(0, 40))
				out.push({ section: "Songs", text: song.title || "Untitled", detail: song.first || "", id: song.id, line: -1 });
			return out;
		}
		for (const song of root.answer?.songs ?? []) {
			if (song.inTitle || (song.hits || []).length === 0) out.push({ section: "Songs", text: song.title || "Untitled", detail: song.first || "", id: song.id, line: song.hits?.[0]?.line ?? -1 });
			for (const hit of song.hits || []) out.push({ section: song.title || "Untitled", text: hit.text, detail: "", id: song.id, line: hit.line });
		}
		for (const idea of root.answer?.ideas ?? []) out.push({ section: "Ideas", text: idea.text, detail: "", idea: true });
		return out;
	}

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
		Rhymes.wake();
		if (root.kind === "lyrics") Rhymes.request("songs", {}, data => root.songs = data.songs || []);
		ask.restart();
	}
	onArgumentChanged: ask.restart()
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))

	Timer {
		id: ask

		interval: 70
		onTriggered: {
			if (!root.active) return;
			if (root.kind === "rhyme") {
				const words = root.words.match(/[A-Za-z0-9']+/g) || [];
				if (words.length === 0) return root.answer = null;
				Rhymes.rhymesFor(words.slice(-3), data => root.answer = data);
			} else if (root.words !== "") {
				Rhymes.latest("search", { query: root.words }, data => root.answer = data);
			} else root.answer = null;
		}
	}

	function move(delta) {
		root.select(root.currentIndex + delta);
	}

	function select(index) {
		if (root.rows.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.rows.length - 1, index));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const row = root.rows[root.currentIndex];
		if (!row) return;
		if (root.kind === "rhyme" || row.idea) {
			Quickshell.clipboardText = row.text;
			root.closeRequested();
			return;
		}
		root.closeRequested();
		later.id = row.id;
		later.line = row.line;
		later.restart();
	}

	// once the launcher has left, the window takes the keyboard
	Timer {
		id: later

		property string id: ""
		property int line: -1
		interval: Motion.medium
		onTriggered: {
			Rhymes.open();
			Rhymes.load(later.id, later.line);
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.rows.length === 0
		icon: root.kind === "rhyme" ? "format_quote_open" : "music_note"
		title: root.kind === "rhyme" ? (root.words ? "" : "A word") : (root.words ? "Nothing found" : "No songs yet")
	}

	ListView {
		id: list

		anchors.fill: parent
		visible: root.rows.length > 0
		clip: true
		spacing: 2
		model: root.rows
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Column {
			id: cell

			required property var modelData
			required property int index
			readonly property bool head: cell.index === 0 || root.rows[cell.index - 1]?.section !== cell.modelData.section

			width: list.width

			Item {
				visible: cell.head
				width: parent.width
				height: cell.index === 0 ? 24 : 32

				StyledText {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 6
					text: cell.modelData.section
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			ListItem {
				width: list.width
				title: cell.modelData.text
				subtitle: cell.modelData.detail
				selected: root.currentIndex === cell.index
				icon: root.kind === "rhyme" ? "format_quote_open" : (cell.modelData.idea ? "lightbulb_outline" : (cell.modelData.line >= 0 ? "text_box_outline" : "music_note"))
				onPointed: root.currentIndex = cell.index
				onClicked: {
					root.currentIndex = cell.index;
					root.activate(0);
				}

				StyledText {
					visible: cell.modelData.syllables > 0
					text: String(cell.modelData.syllables)
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}
	}
}
