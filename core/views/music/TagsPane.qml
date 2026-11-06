pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the song says about itself, to be changed: its words and its cover,
// written into the file (a copy that takes its place). "Look it up" asks
// MusicBrainz by the name (AcoustID by the sound, with a key in music.json)
// and a hit fills the fields and brings its cover along.
Item {
	id: root

	property color accent: Theme.primary

	// the song the fields are of: the one that plays, until it is saved or left
	property string path: ""
	property var draft: ({})
	property string coverFile: ""
	property bool busy: false
	property bool looking: false
	property var hits: []
	property string lookError: ""
	// the fields take the draft again (a field typed in keeps its own text otherwise)
	signal reloaded

	readonly property var fields: [
		{ key: "title", label: "Title" },
		{ key: "artist", label: "Artist" },
		{ key: "album", label: "Album" },
		{ key: "albumartist", label: "Album artist" },
		{ key: "track", label: "Track", narrow: true },
		{ key: "year", label: "Year", narrow: true },
		{ key: "genre", label: "Genre" }
	]
	readonly property var song: Music.tags[root.path] ?? null
	readonly property bool changed: root.coverFile !== "" || root.fields.some(f => (root.draft[f.key] ?? "") !== String(root.song?.[f.key] ?? ""))

	function load() {
		root.path = Music.path;
		root.coverFile = "";
		root.hits = [];
		root.lookError = "";
		const t = Music.tags[root.path] ?? {};
		const next = {};
		for (const f of root.fields) next[f.key] = String(t[f.key] ?? "");
		root.draft = next;
		root.reloaded();
	}

	function set(key, value) {
		root.draft = Object.assign({}, root.draft, { [key]: value });
	}

	function save() {
		if (!root.path || root.busy) return;
		root.busy = true;
		Music.writeTags(root.path, root.draft, root.coverFile, (data, error) => {
			root.busy = false;
			if (!error) root.coverFile = "";
		});
	}

	function lookUp() {
		if (!root.path || root.looking) return;
		root.looking = true;
		root.hits = [];
		root.lookError = "";
		const path = root.path;
		Music.lookup(path, (results, error) => {
			if (root.path !== path) return;
			root.looking = false;
			root.hits = results;
			root.lookError = error ? "MusicBrainz did not answer" : (results.length === 0 ? "Nothing found by that name" : "");
		});
	}

	function take(hit) {
		const next = Object.assign({}, root.draft);
		for (const f of root.fields)
			if (hit[f.key]) next[f.key] = String(hit[f.key]);
		root.draft = next;
		root.reloaded();
		root.hits = [];
		if (hit.cover) Music.fetchCover(hit.cover, file => {
			if (file) root.coverFile = file;
		});
	}

	Component.onCompleted: root.load()

	Connections {
		target: Music

		// another song: its own words, unless these were being changed
		function onPathChanged() {
			if (!root.changed) root.load();
		}

		function onTagsChanged() {
			if (!root.changed && Music.tags[root.path]) root.load();
		}
	}

	StyledText {
		id: heading

		x: 4
		text: "Tags"
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	StyledText {
		anchors.left: heading.right
		anchors.leftMargin: 10
		anchors.right: parent.right
		anchors.rightMargin: 44
		anchors.baseline: heading.baseline
		tone: Theme.textMuted
		elide: Text.ElideMiddle
		font.pixelSize: Theme.size.small
		text: root.path ? root.path.slice(root.path.lastIndexOf("/") + 1) : ""
	}

	EmptyState {
		anchors.centerIn: parent
		visible: !root.path
		icon: "tag_outline"
		title: "Nothing plays"
		subtitle: "The tags of the song that plays can be changed here"
	}

	Flickable {
		id: flick

		anchors.fill: parent
		anchors.topMargin: heading.height + 14
		visible: root.path !== ""
		contentHeight: body.implicitHeight + 12
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: body

			x: 4
			width: flick.width - 12
			spacing: 12

			// the cover and what can be done with it
			Row {
				spacing: 14

				Rectangle {
					width: 104
					height: 104
					radius: Theme.radius.large
					color: Theme.layer2
					clip: true

					Image {
						anchors.fill: parent
						source: root.coverFile ? "file://" + root.coverFile : (Music.covers[root.path]?.art ? "file://" + Music.covers[root.path].art : "")
						sourceSize: Qt.size(208, 208)
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						visible: status === Image.Ready
					}

					Glyph {
						anchors.centerIn: parent
						visible: !root.coverFile && !Music.covers[root.path]?.art
						icon: "music_note"
						size: 36
						color: Theme.textMuted
					}

					Rectangle {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 6
						visible: root.coverFile !== ""
						width: newWord.implicitWidth + 12
						height: 20
						radius: 10
						color: root.accent

						StyledText {
							id: newWord

							anchors.centerIn: parent
							text: "new"
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
							tone: Theme.contrast(root.accent, Qt.color("#000000")) > 4 ? "#111111" : "#ffffff"
						}
					}
				}

				Column {
					anchors.verticalCenter: parent.verticalCenter
					spacing: 8

					TextButton {
						text: "Choose a picture…"
						icon: "image_edit_outline"
						onActivated: picker.running = true
					}

					TextButton {
						text: root.looking ? "Looking…" : "Look it up"
						icon: "magnify"
						busy: root.looking
						onActivated: root.lookUp()
					}
				}
			}

			// what was found
			Column {
				width: parent.width
				spacing: 4
				visible: root.hits.length > 0 || root.lookError !== ""

				StyledText {
					visible: root.lookError !== ""
					text: root.lookError
					tone: Theme.textMuted
				}

				Repeater {
					model: root.hits

					delegate: Clickable {
						id: hit

						required property var modelData

						width: body.width
						height: 48
						radius: Theme.radius.medium
						color: hit.hovered ? Theme.layer2 : Qt.alpha(Theme.layer2, 0.5)
						onClicked: root.take(hit.modelData)

						Column {
							anchors.left: parent.left
							anchors.leftMargin: 12
							anchors.right: score.left
							anchors.rightMargin: 8
							anchors.verticalCenter: parent.verticalCenter
							spacing: 1

							StyledText {
								width: parent.width
								elide: Text.ElideRight
								font.weight: Font.DemiBold
								text: `${hit.modelData.title} – ${hit.modelData.artist}`
							}

							StyledText {
								width: parent.width
								elide: Text.ElideRight
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
								text: [hit.modelData.album, hit.modelData.year, hit.modelData.track ? `track ${hit.modelData.track}` : ""].filter(x => x).join(" · ") || "no album"
							}
						}

						StyledText {
							id: score

							anchors.right: parent.right
							anchors.rightMargin: 12
							anchors.verticalCenter: parent.verticalCenter
							tone: Theme.textSubtle
							tabular: true
							font.pixelSize: Theme.size.small
							text: `${hit.modelData.how === "sound" ? "by sound" : "by name"} · ${Math.round((hit.modelData.score || 0) * 100)}%`
						}
					}
				}
			}

			// the fields, two short ones side by side
			Flow {
				width: parent.width
				spacing: 10

				Repeater {
					model: root.fields

					delegate: Column {
						id: field

						required property var modelData

						width: field.modelData.narrow ? (body.width - 10) / 2 : body.width
						spacing: 4

						StyledText {
							x: 2
							text: field.modelData.label
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}

						Field {
							id: input

							width: parent.width
							clearable: false
							Component.onCompleted: input.text = root.draft[field.modelData.key] ?? ""
							onEdited: text => root.set(field.modelData.key, text)
							onAccepted: root.save()

							Connections {
								target: root

								function onReloaded() {
									input.text = root.draft[field.modelData.key] ?? "";
								}
							}
						}
					}
				}
			}

			Row {
				spacing: 8

				TextButton {
					variant: "filled"
					text: root.busy ? "Saving…" : "Save into the file"
					icon: "content_save_outline"
					busy: root.busy
					enabled: root.changed && !root.busy
					onActivated: root.save()
				}

				TextButton {
					variant: "ghost"
					text: "Undo"
					icon: "undo"
					enabled: root.changed && !root.busy
					onActivated: root.load()
				}
			}
		}
	}

	Process {
		id: picker

		command: ["python3", `${Paths.scripts}/pick_files.py`, "--single", "--start", root.path.slice(0, root.path.lastIndexOf("/")), "--filter", "Pictures|*.png *.jpg *.jpeg *.webp *.bmp", "Cover for the song"]
		stdout: StdioCollector {
			onStreamFinished: {
				const file = String(this.text).trim().split("\n")[0];
				if (file) root.coverFile = file;
			}
		}
	}
}
