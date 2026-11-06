pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Edit.js" as Edit

// Chapters of the film made here: a mark at a moment with a name, written
// into the export (players show them along their seek bar). The file's own
// can be taken over – where they land after the cuts.
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var chapters: (Video.recipe.chapters ?? []).slice().sort((a, b) => a.t - b.t)
	// the one the playhead is in
	readonly property int current: {
		const t = root.editor?.playhead ?? 0;
		let found = -1;
		root.chapters.forEach((c, i) => {
			if (c.t <= t + 0.05) found = i;
		});
		return found;
	}

	title: "Chapters"
	subtitle: root.chapters.length === 0 ? "Marks along the film, with names" : `${root.chapters.length} ${root.chapters.length === 1 ? "chapter" : "chapters"}`
	closable: false

	function addHere() {
		const t = Math.round((root.editor?.playhead ?? 0) * 10) / 10;
		if (root.chapters.some(c => Math.abs(c.t - t) < 0.2)) return root.editor.say("There is a chapter here already", "bookmark_outline");
		root.editor.change(r => {
			r.chapters = (r.chapters || []).concat([{ t: t, title: `Chapter ${root.chapters.filter(c => c.t < t).length + 1}` }]).sort((a, b) => a.t - b.t);
		});
	}

	function rename(t, title, live) {
		const fn = r => {
			const c = (r.chapters || []).find(v => Math.abs(v.t - t) < 1e-3);
			if (c) c.title = title;
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function remove(t) {
		root.editor.change(r => {
			r.chapters = (r.chapters || []).filter(v => Math.abs(v.t - t) > 1e-3);
		});
	}

	function moveHere(t) {
		const to = Math.round(root.editor.playhead * 10) / 10;
		root.editor.change(r => {
			const c = (r.chapters || []).find(v => Math.abs(v.t - t) < 1e-3);
			if (c) c.t = to;
			r.chapters.sort((a, b) => a.t - b.t);
		});
	}

	// the file's chapters through the cuts: each where its start is in the
	// film; one that a clip starts inside of begins with that clip
	function takeFiles() {
		const clips = Video.clipsOf(Video.recipe);
		const out = [];
		clips.forEach((clip, i) => {
			if ((clip.src || Video.path) !== Video.path) return;
			for (const ch of Video.chapters) {
				const end = ch.end ?? Infinity;
				if (ch.t >= clip.a && ch.t < clip.b) out.push({ t: Video.sourceToOut(i, ch.t), title: ch.title || "" });
				else if (ch.t < clip.a && end > clip.a) out.push({ t: Video.sourceToOut(i, clip.a), title: ch.title || "" });
			}
		});
		const kept = [];
		for (const c of out.sort((a, b) => a.t - b.t))
			if (!kept.some(k => Math.abs(k.t - c.t) < 0.5)) kept.push({ t: Math.round(c.t * 10) / 10, title: c.title });
		if (kept.length === 0) return root.editor.say("None of the file's chapters is left in the film", "bookmark_off_outline");
		root.editor.change(r => r.chapters = kept);
		root.editor.say(`${kept.length} of the file's chapters taken`, "bookmark_multiple_outline");
	}

	Flow {
		width: parent.width
		spacing: 8

		TextButton {
			text: "A chapter here"
			icon: "bookmark_plus_outline"
			variant: "filled"
			onActivated: root.addHere()
		}

		TextButton {
			visible: Video.chapters.length > 0
			text: `The file's ${Video.chapters.length}`
			icon: "bookmark_multiple_outline"
			onActivated: root.takeFiles()
		}
	}

	StyledText {
		width: parent.width
		visible: root.chapters.length === 0
		wrapMode: Text.WordWrap
		text: Video.chapters.length > 0 ? "The file has chapters of its own – take them, and they move along with the cuts." : "Put the playhead where a part begins and add one; the first should be at the start."
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	// by count: a name being typed is not built anew with each letter
	Repeater {
		model: root.chapters.length

		delegate: Rectangle {
			id: row

			required property int index
			readonly property var chapter: root.chapters[row.index] ?? ({ t: 0, title: "" })
			readonly property bool here: root.current === row.index

			// moved to another place in the list: the name follows (not while typed in)
			onChapterChanged: if (!name.focused && name.text !== row.chapter.title) name.text = row.chapter.title

			width: parent?.width ?? 300
			height: 46
			radius: Theme.radius.small
			color: row.here ? Qt.alpha(root.accent, 0.14) : Theme.layer1

			Behavior on y {
				SpatialAnim {}
			}

			Clickable {
				id: jump

				x: 4
				anchors.verticalCenter: parent.verticalCenter
				width: 74
				height: 34
				radius: 17
				onClicked: root.editor.seekOut(row.chapter.t)

				StyledText {
					anchors.centerIn: parent
					text: Edit.time(row.chapter.t)
					tabular: true
					font.pixelSize: Theme.size.small
					tone: row.here ? root.accent : Theme.text
				}
			}

			Field {
				id: name

				anchors.left: jump.right
				anchors.leftMargin: 6
				anchors.right: buttons.left
				anchors.rightMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				height: 34
				clearable: false
				placeholder: "Its name"
				Component.onCompleted: name.text = row.chapter.title
				onEdited: text => {
					root.rename(row.chapter.t, text, true);
					typingDone.restart();
				}

				Timer {
					id: typingDone

					interval: 700
					onTriggered: root.editor.endDrag()
				}
			}

			Row {
				id: buttons

				anchors.right: parent.right
				anchors.rightMargin: 4
				anchors.verticalCenter: parent.verticalCenter

				// to the playhead
				IconButton {
					width: 30
					height: 30
					icon: "map_marker_outline"
					onClicked: root.moveHere(row.chapter.t)
				}

				IconButton {
					width: 30
					height: 30
					icon: "close"
					onClicked: root.remove(row.chapter.t)
				}
			}
		}
	}
}
