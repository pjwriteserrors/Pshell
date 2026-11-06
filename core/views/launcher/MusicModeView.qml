pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >music (>songs): what plays, what comes after it in the queue and
// what played lately; the words typed after it look through those and the
// songs of the playing one's folder by title, artist, album and file name.
// Enter plays (a song of the queue is jumped to), Shift+Enter plays it next,
// Ctrl+Enter puts it at the end of the queue.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0

	// the songs beside the one that plays, asked for once per folder
	property var folderSongs: []
	property string folderOf: ""
	// the recent ones whose tags were asked for already
	property var tagsAsked: ({})

	readonly property string words: root.argument.trim().toLowerCase()

	// [{ path, section }]
	readonly property var rows: {
		const out = [];
		const seen = {};
		const push = (path, section) => {
			if (!path || seen[path]) return;
			seen[path] = true;
			out.push({ path: path, section: section });
		};
		const after = Music.index >= 0 ? Music.queue.slice(Music.index + 1) : Music.queue;
		if (root.words === "") {
			if (Music.current) push(Music.path, "Now playing");
			for (const path of after.slice(0, 30)) push(path, "Up next");
			for (const path of Music.recent) {
				if (!Music.queue.includes(path)) push(path, "Recently played");
			}
			return out;
		}
		const terms = root.words.split(/\s+/).filter(w => w);
		const fits = path => {
			const hay = [Music.titleOf(path), Music.artistOf(path), Music.tags[path]?.album ?? "", String(path).slice(String(path).lastIndexOf("/") + 1)].join(" ").toLowerCase();
			return terms.every(w => hay.includes(w));
		};
		for (const path of Music.queue) if (fits(path)) push(path, "In the queue");
		for (const path of Music.recent) if (fits(path)) push(path, "Recently played");
		for (const path of root.folderSongs) if (fits(path)) push(path, "In this folder");
		return out;
	}

	signal closeRequested

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
		root.askTags();
		root.askFolder();
	}
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))

	// tags of songs that played before this start of the helper
	function askTags() {
		const missing = Music.recent.concat(root.folderSongs).filter(p => !Music.tags[p] && !root.tagsAsked[p]).slice(0, 80);
		if (missing.length === 0) return;
		for (const p of missing) root.tagsAsked[p] = true;
		Music.request("tags", { paths: missing }, data => {
			if (data?.items) Music.tags = Object.assign({}, Music.tags, data.items);
		});
	}

	function askFolder() {
		if (!Music.current || root.folderOf === Music.path) return;
		const path = Music.path;
		root.folderOf = path;
		Music.request("folder", { path: path }, data => {
			if (root.folderOf !== path) return;
			root.folderSongs = data?.paths ?? [];
			root.askTags();
		});
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
		if (modifiers & Qt.ShiftModifier) root.run("next", row.path);
		else if (modifiers & Qt.ControlModifier) root.run("add", row.path);
		else root.run("play", row.path);
	}

	function run(how, path) {
		root.closeRequested();
		// once the launcher has left, the window takes the keyboard
		later.how = how;
		later.path = path;
		later.restart();
	}

	Timer {
		id: later

		property string how: ""
		property string path: ""
		interval: Motion.medium
		onTriggered: {
			if (later.how === "next") return Music.add([later.path], true);
			if (later.how === "add") return Music.add([later.path], false);
			const at = Music.queue.indexOf(later.path);
			if (at >= 0) {
				if (at !== Music.index) Music.jump(at);
				else if (!Music.playing) Music.play();
				Music.showWindow();
			} else Music.open(later.path);
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.rows.length === 0
		icon: "music_note"
		title: root.words ? "No song by that name" : "Nothing played yet"
		subtitle: root.words ? "" : "Open a song in Files, or drop some on the player"
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
			id: songCell

			required property var modelData
			required property int index
			// a heading above the first of each part
			readonly property bool head: songCell.index === 0 || root.rows[songCell.index - 1]?.section !== songCell.modelData.section

			width: list.width

			Item {
				visible: songCell.head
				width: parent.width
				height: songCell.index === 0 ? 24 : 32

				StyledText {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 6
					text: songCell.modelData.section
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			ListItem {
				id: songRow

				readonly property var modelData: songCell.modelData
				readonly property int index: songCell.index
				readonly property string path: songRow.modelData.path
				readonly property string art: Music.covers[songRow.path]?.art ?? ""
				readonly property bool playing: songRow.path === Music.path && Music.current

				width: list.width
				title: Music.titleOf(songRow.path)
				subtitle: [Music.artistOf(songRow.path), Music.tags[songRow.path]?.album ?? ""].filter(x => x).join(" · ")
				selected: root.currentIndex === songRow.index
				icon: "music_note"
				leading: songRow.art !== "" ? coverTile : null
				onPointed: root.currentIndex = songRow.index
				onClicked: root.run("play", songRow.path)
				Component.onCompleted: Music.wantCover(songRow.path)

				Component {
					id: coverTile

					ClippingRectangle {
						radius: songRow.selected ? Theme.radius.medium : 18
						color: Theme.layer2

						Behavior on radius {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Image {
							anchors.fill: parent
							source: "file://" + songRow.art
							sourceSize: Qt.size(72, 72)
							fillMode: Image.PreserveAspectCrop
							asynchronous: true
						}
					}
				}

				Glyph {
					visible: songRow.playing
					icon: Music.playing ? "volume_high" : "pause"
					size: 16
					color: Theme.primary
				}

				StyledText {
					visible: (Music.tags[songRow.path]?.duration ?? 0) > 0
					text: Music.formatTime(Music.tags[songRow.path]?.duration ?? 0)
					tone: Theme.textSubtle
					tabular: true
					font.pixelSize: Theme.size.small
				}
			}
		}
	}
}
