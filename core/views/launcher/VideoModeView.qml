pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >video (>film): what plays, what was left half seen, the episodes
// of the series that plays and what was opened lately; the words typed after
// it look through those by title, episode and file name. Enter plays on where
// it was left, Shift+Enter from the start, Ctrl+Enter opens it in the editor.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0

	// a picture of each row's video, asked for once its row shows: path → file
	property var frames: ({})
	property var framesAsked: ({})

	readonly property string words: root.argument.trim().toLowerCase()

	// left in the middle, newest first (as Video resumes them: past 15 s, not at the end)
	readonly property var halfSeen: Object.entries(Video.progress_)
		.filter(([path, kept]) => !kept.watched && kept.pos > 15 && kept.dur > 0 && kept.pos < kept.dur - 20)
		.sort((a, b) => (b[1].at || 0) - (a[1].at || 0))
		.map(([path]) => path)

	// [{ path, section }]
	readonly property var rows: {
		const out = [];
		const seen = {};
		const push = (path, section) => {
			if (!path || seen[path]) return;
			seen[path] = true;
			out.push({ path: path, section: section });
		};
		const series = Video.list.length > 1 && Video.list.some(path => Video.episodeOf(path)) ? "Episodes" : "In this folder";
		if (root.words === "") {
			if (Video.current) push(Video.path, "Now playing");
			for (const path of root.halfSeen.slice(0, 12)) push(path, "Continue watching");
			if (Video.list.length > 1) {
				const after = Video.index >= 0 ? Video.list.slice(Video.index + 1).concat(Video.list.slice(0, Video.index)) : Video.list;
				for (const path of after.slice(0, 40)) push(path, series);
			}
			for (const path of Video.recent) push(path, "Recently opened");
			return out;
		}
		const terms = root.words.split(/\s+/).filter(w => w);
		const fits = path => {
			const hay = [Video.titleOf(path), Video.episodeOf(path)?.label ?? "", String(path).slice(String(path).lastIndexOf("/") + 1)].join(" ").toLowerCase();
			return terms.every(w => hay.includes(w));
		};
		if (Video.current && fits(Video.path)) push(Video.path, "Now playing");
		for (const path of root.halfSeen) if (fits(path)) push(path, "Continue watching");
		for (const path of Video.list) if (fits(path)) push(path, series);
		for (const path of Video.recent) if (fits(path)) push(path, "Recently opened");
		return out;
	}

	signal closeRequested

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
	}
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))

	// where its picture is taken: where it was left, else a little in
	function frameTime(path) {
		const kept = Video.progressOf(path);
		if (kept && !kept.watched && kept.pos > 0) return kept.pos;
		return kept?.dur > 0 ? kept.dur * 0.1 : 20;
	}

	function wantFrame(path) {
		if (root.frames[path] || root.framesAsked[path]) return;
		root.framesAsked[path] = true;
		Video.frameOf(path, root.frameTime(path), file => {
			if (file) root.frames = Object.assign({}, root.frames, { [path]: file });
		}, 160);
	}

	// "12 min left", "Seen", or how long it is
	function noteOf(path) {
		const kept = Video.progressOf(path);
		if (!kept) return "";
		if (kept.watched) return "Seen";
		if (kept.dur > 0 && kept.pos > 15) {
			const left = Math.max(1, Math.round((kept.dur - kept.pos) / 60));
			return left >= 60 ? `${Math.floor(left / 60)} h ${left % 60} min left` : `${left} min left`;
		}
		return kept.dur > 0 ? Video.formatTime(kept.dur) : "";
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
		if (modifiers & Qt.ShiftModifier) root.run("start", row.path);
		else if (modifiers & Qt.ControlModifier) root.run("edit", row.path);
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
			const path = later.path;
			if (later.how === "edit") return Video.edit(path);
			// one of the series that plays keeps the series around it
			const list = Video.list.includes(path) ? Video.list : undefined;
			if (later.how === "start") return Video.open(path, { start: 0, list: list });
			if (path === Video.path && Video.current) {
				Video.showWindow();
				if (!Video.playing) Video.play();
			} else Video.open(path, { list: list });
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.rows.length === 0
		icon: "movie_open_outline"
		title: root.words ? "No video by that name" : "Nothing watched yet"
		subtitle: root.words ? "" : "Open a video in Files, or drop one on the player"
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
			id: filmCell

			required property var modelData
			required property int index
			// a heading above the first of each part
			readonly property bool head: filmCell.index === 0 || root.rows[filmCell.index - 1]?.section !== filmCell.modelData.section

			width: list.width

			Item {
				visible: filmCell.head
				width: parent.width
				height: filmCell.index === 0 ? 24 : 32

				StyledText {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 6
					text: filmCell.modelData.section
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			ListItem {
				id: filmRow

				readonly property var modelData: filmCell.modelData
				readonly property int index: filmCell.index
				readonly property string path: filmRow.modelData.path
				readonly property string frame: root.frames[filmRow.path] ?? ""
				readonly property var kept: Video.progressOf(filmRow.path)
				readonly property bool half: !!filmRow.kept && !filmRow.kept.watched && filmRow.kept.pos > 15 && filmRow.kept.dur > 0
				readonly property bool playing: filmRow.path === Video.path && Video.current

				width: list.width
				title: Video.titleOf(filmRow.path)
				subtitle: [Video.episodeOf(filmRow.path)?.label ?? "", root.noteOf(filmRow.path)].filter(x => x).join(" · ")
				selected: root.currentIndex === filmRow.index
				icon: "movie_outline"
				leading: filmRow.frame !== "" ? frameTile : null
				onPointed: root.currentIndex = filmRow.index
				onClicked: root.run("play", filmRow.path)
				// asked for only once the row is made, that is when it shows
				Component.onCompleted: root.wantFrame(filmRow.path)

				Component {
					id: frameTile

					ClippingRectangle {
						radius: filmRow.selected ? Theme.radius.medium : 18
						color: Theme.layer2

						Behavior on radius {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Image {
							anchors.fill: parent
							source: Video.fileUrl(filmRow.frame)
							sourceSize: Qt.size(96, 54)
							fillMode: Image.PreserveAspectCrop
							asynchronous: true
						}
					}
				}

				Glyph {
					visible: filmRow.playing
					icon: Video.playing ? "volume_high" : "pause"
					size: 16
					color: Theme.primary
				}

				Glyph {
					visible: !!filmRow.kept?.watched && !filmRow.playing
					icon: "check"
					size: 16
					color: Theme.success
				}

				// how far it was seen
				Rectangle {
					visible: filmRow.half
					implicitWidth: 64
					implicitHeight: 4
					radius: 2
					color: Theme.layer3

					Rectangle {
						width: parent.width * Math.min(1, (filmRow.kept?.pos ?? 0) / Math.max(1, filmRow.kept?.dur ?? 1))
						height: parent.height
						radius: parent.radius
						color: Theme.primary
					}
				}
			}
		}
	}
}
