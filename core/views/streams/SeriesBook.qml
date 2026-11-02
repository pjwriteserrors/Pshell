pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A series' book: who is in it, what was noted by episode, and a search through what
// was said. A click on anything goes to that moment.
Rectangle {
	id: root

	property string seriesId: ""
	property bool shown: false
	// characters | notes | search
	property string tab: "characters"
	// all | character | event | note
	property string kind: "all"
	property var notes: []
	property var hits: []
	property var index: null
	property string query: ""
	property var book: null
	property int picked: 0
	property string error: ""
	property int editing: -1
	readonly property var series: Streams.seriesById[root.seriesId] ?? null
	readonly property color accent: Streams.accent(root.series?.colors)
	readonly property var job: Streams.sheetsJob?.series === root.seriesId ? Streams.sheetsJob : null
	readonly property var person: (root.book?.sheets ?? []).find(item => item.id === root.picked) ?? (root.book?.sheets ?? [])[0] ?? null
	readonly property var shownNotes: root.notes.filter(note => root.kind === "all" || note.kind === root.kind)

	signal closeRequested

	function load() {
		Streams.call("notes", { series: root.seriesId }, data => root.notes = data ?? []);
		root.loadBook();
	}

	function loadBook() {
		Streams.call("sheets", { series: root.seriesId }, data => {
			if (data) root.book = data;
		});
	}

	function search() {
		if (root.query.trim() === "") return;
		Streams.call("searchSeries", { series: root.seriesId, query: root.query }, data => {
			if (!data) return;
			root.hits = data.hits;
			root.index = data.index;
		});
	}

	function jump(video, at) {
		Streams.call("play", { video: video, player: "app", at: at });
		root.closeRequested();
	}

	function build() {
		root.error = "";
		Streams.call("sheet", { what: "build", series: root.seriesId });
	}

	onShownChanged: if (shown) {
		root.load();
		if (root.tab === "search") Streams.call("indexSeries", { id: root.seriesId }, data => root.index = data);
	}
	onTabChanged: if (root.tab === "search") Streams.call("indexSeries", { id: root.seriesId }, data => root.index = data)

	color: Theme.base

	MouseArea {
		anchors.fill: parent
	}

	Connections {
		target: Streams

		function onSheetChanged(series) {
			if (series === root.seriesId) reloadSoon.restart();
		}
		function onSheetError(series, error) {
			if (series === root.seriesId) root.error = error;
		}
		function onBookTabWantedChanged() {
			if (Streams.bookTabWanted) root.tab = Streams.bookTabWanted;
		}
	}

	Timer {
		id: reloadSoon

		interval: 300
		onTriggered: root.loadBook()
	}
	Timer {
		interval: 4000
		repeat: true
		running: root.shown && root.tab === "search"
		onTriggered: root.query.trim() !== "" ? root.search() : Streams.call("searchSeries", { series: root.seriesId, query: "" }, data => root.index = data?.index ?? null)
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 28
		spacing: 16

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			Text {
				text: root.series?.name ?? ""
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 30
				font.weight: Font.Black
			}
			Segmented {
				Layout.preferredWidth: 640
				Layout.preferredHeight: 36
				options: [{ value: "characters", label: "Characters" }, { value: "story", label: "Story" }, { value: "notes", label: `Notes ${root.notes.length || ""}` }, { value: "clips", label: "Clips" }, { value: "search", label: "What was said" }]
				current: root.tab
				onSelected: value => root.tab = value
			}
			Item {
				Layout.fillWidth: true
			}
			IconButton {
				width: 38
				height: 38
				icon: "close"
				onClicked: root.closeRequested()
			}
		}

		SeriesStory {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.tab === "story"
			seriesId: root.seriesId
			shown: root.shown && root.tab === "story"
		}
		SeriesClips {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.tab === "clips"
			seriesId: root.seriesId
			shown: root.shown && root.tab === "clips"
		}

		// ── characters ──────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.tab === "characters"
			spacing: 22

			ColumnLayout {
				Layout.preferredWidth: 240
				Layout.maximumWidth: 240
				Layout.fillHeight: true
				spacing: 10

				ListView {
					id: people

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					spacing: 4
					model: root.book?.sheets ?? []

					delegate: Clickable {
						id: face

						required property var modelData
						readonly property bool current: root.person?.id === face.modelData.id

						width: people.width
						implicitHeight: 56
						radius: Theme.radius.large
						color: face.current ? Qt.alpha(root.accent, 0.26) : (face.hovered ? Theme.layer1 : "transparent")
						pressedScale: 0.97
						onClicked: root.picked = face.modelData.id

						Behavior on color {
							ColorAnim {}
						}

						RowLayout {
							anchors.fill: parent
							anchors.margins: 8
							spacing: 10

							Rectangle {
								Layout.preferredWidth: 38
								Layout.preferredHeight: 38
								radius: 19
								color: Qt.darker(root.accent, 1.6)

								Text {
									anchors.centerIn: parent
									text: face.modelData.name.slice(0, 1).toUpperCase()
									color: "white"
									font.family: Theme.fontFamily
									font.pixelSize: 18
									font.weight: Font.Black
								}
							}
							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: face.modelData.name
									font.pixelSize: Theme.size.body
									font.weight: Font.Bold
									elide: Text.ElideRight
								}
								StyledText {
									Layout.fillWidth: true
									text: `${face.modelData.facts.length} ${face.modelData.facts.length === 1 ? "fact" : "facts"}`
									font.pixelSize: Theme.size.small
									tone: Theme.textMuted
								}
							}
						}
					}
				}
				Field {
					Layout.fillWidth: true
					icon: "plus"
					placeholder: "Add a character"
					onAccepted: {
						if (text.trim() !== "") Streams.call("sheet", { what: "add", series: root.seriesId, name: text }, data => {
							if (data) root.book = data;
						});
						text = "";
					}
				}

				StyledText {
					Layout.topMargin: 4
					text: "Kind of sheet"
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4

					Repeater {
						model: root.book?.templates ?? []

						Chip {
							required property var modelData

							text: modelData.label
							selected: root.book?.template === modelData.id
							onClicked: Streams.call("sheet", { what: "template", series: root.seriesId, template: modelData.id }, data => {
								if (data) root.book = data;
							})
						}
					}
				}

				// the work, and how far it is
				ColumnLayout {
					Layout.fillWidth: true
					visible: !!root.job
					spacing: 4

					StyledText {
						Layout.fillWidth: true
						text: root.job ? [root.job.name, root.job.field].filter(word => !!word).join(": ") : ""
						font.pixelSize: Theme.size.small
						wrapMode: Text.Wrap
					}
					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 6
						radius: 3
						color: Qt.alpha(Theme.text, 0.14)

						Rectangle {
							height: parent.height
							radius: 3
							color: root.accent
							width: parent.width * (root.job?.total ? root.job.done / root.job.total : 0)

							Behavior on width {
								Anim {
									duration: Motion.long
								}
							}
						}
					}
				}
				StyledText {
					Layout.fillWidth: true
					visible: root.error !== ""
					text: root.error
					color: Theme.danger
					font.pixelSize: Theme.size.small
					wrapMode: Text.Wrap
				}
				BigButton {
					Layout.fillWidth: true
					text: root.job ? "Stop" : ((root.book?.sheets ?? []).length > 0 ? "Update from what I watched" : "Make the sheets")
					icon: root.job ? "close" : "creation"
					main: !root.job
					onClicked: root.job ? Streams.call("sheet", { what: "stop" }) : root.build()
				}
				StyledText {
					Layout.fillWidth: true
					text: "Only from episodes you have seen, so nothing gets spoiled."
					font.pixelSize: Theme.size.tiny
					tone: Theme.textSubtle
					wrapMode: Text.Wrap
				}
			}

			SheetView {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: !!root.person
				sheet: root.person
				sections: root.book?.sections ?? []
				accent: root.accent
				seriesId: root.seriesId
				onChanged: data => root.book = data
			}

			ColumnLayout {
				Layout.fillWidth: true
				Layout.alignment: Qt.AlignVCenter
				visible: !root.person
				spacing: 8

				Text {
					Layout.alignment: Qt.AlignHCenter
					text: "No sheets yet"
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 30
					font.weight: Font.Black
				}
				StyledText {
					Layout.alignment: Qt.AlignHCenter
					Layout.maximumWidth: 520
					horizontalAlignment: Text.AlignHCenter
					text: "“Make the sheets” finds the characters and asks the AI about each of them, a little at a time. Every answer must quote the subtitles, or it is not kept."
					tone: Theme.textMuted
					font.pixelSize: Theme.size.title
					wrapMode: Text.Wrap
				}
			}
		}

		// ── notes, by episode ───────────────────────────────────────────
		Segmented {
			Layout.preferredWidth: 420
			Layout.preferredHeight: 32
			visible: root.tab === "notes"
			options: [{ value: "all", label: "All" }, { value: "character", label: "Characters" }, { value: "event", label: "Events" }, { value: "note", label: "Notes" }]
			current: root.kind
			onSelected: value => root.kind = value
		}
		ListView {
			id: noteList

			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.tab === "notes"
			clip: true
			spacing: 8
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: root.shownNotes
			section.property: "title"
			section.delegate: Text {
				required property string section

				width: noteList.width
				topPadding: 16
				bottomPadding: 6
				text: section
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.heading
				font.weight: Font.Black
				elide: Text.ElideRight
			}

			delegate: Rectangle {
				id: note

				required property var modelData
				readonly property color tint: ({ character: root.accent, event: Theme.warning })[note.modelData.kind] ?? Theme.textFaint

				width: noteList.width
				height: noteBody.implicitHeight + 24
				radius: Theme.radius.large
				color: noteHover.hovered ? Theme.layer2 : Theme.layer1

				Behavior on color {
					ColorAnim {}
				}

				HoverHandler {
					id: noteHover
				}

				RowLayout {
					id: noteBody

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 12
					spacing: 12

					// when: a click goes there
					Clickable {
						Layout.alignment: Qt.AlignTop
						implicitWidth: timeWord.implicitWidth + 18
						implicitHeight: 26
						radius: 8
						color: Qt.alpha(note.tint, 0.22)
						onClicked: root.jump(note.modelData.video, note.modelData.at)

						Text {
							id: timeWord

							anchors.centerIn: parent
							text: Streams.clock(note.modelData.at)
							color: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.small
							font.weight: Font.Bold
							font.features: { "tnum": 1 }
						}
					}
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 3

						Text {
							visible: note.modelData.kind !== "note"
							text: ({ character: "CHARACTER", event: "EVENT" })[note.modelData.kind] ?? ""
							color: note.tint
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Black
							font.letterSpacing: 1
						}
						// **bold**, lists and the like are simply written
						StyledText {
							Layout.fillWidth: true
							visible: root.editing !== note.modelData.id
							text: note.modelData.text
							textFormat: Text.MarkdownText
							font.pixelSize: Theme.size.title
							wrapMode: Text.Wrap
						}
						Loader {
							Layout.fillWidth: true
							active: root.editing === note.modelData.id
							visible: active
							sourceComponent: Field {
								text: note.modelData.text
								Component.onCompleted: focusInput()
								onAccepted: Streams.call("editNote", { id: note.modelData.id, text: text, kind: note.modelData.kind }, () => {
									root.editing = -1;
									root.load();
								})
								onEscapePressed: root.editing = -1
							}
						}
					}
					Row {
						Layout.alignment: Qt.AlignTop
						spacing: 2
						opacity: noteHover.hovered ? 1 : 0

						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}

						IconButton {
							width: 28
							height: 28
							icon: "tune"
							onClicked: root.editing = note.modelData.id
						}
						IconButton {
							width: 28
							height: 28
							icon: "delete_outline"
							onClicked: Streams.call("removeNote", { id: note.modelData.id }, () => root.load())
						}
					}
				}
			}
		}
		StyledText {
			Layout.fillWidth: true
			visible: root.tab === "notes" && noteList.count === 0
			horizontalAlignment: Text.AlignHCenter
			text: "Press B while watching to write something down. **Bold** and lists work."
			tone: Theme.textMuted
			font.pixelSize: Theme.size.title
		}

		// ── what was said ───────────────────────────────────────────────
		Field {
			Layout.fillWidth: true
			visible: root.tab === "search"
			icon: "magnify"
			placeholder: "A dragon, a name, anything somebody said"
			onEdited: text => {
				root.query = text;
				debounce.restart();
			}
			Timer {
				id: debounce

				interval: 220
				onTriggered: root.search()
			}
		}
		StyledText {
			Layout.fillWidth: true
			visible: root.tab === "search" && !!root.index && root.index.total > 0 && root.index.done < root.index.total
			text: `Reading the subtitles: ${root.index?.done ?? 0} of ${root.index?.total ?? 0} episodes. What is read can be searched already.`
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}
		ListView {
			id: hitList

			Layout.fillWidth: true
			Layout.fillHeight: true
			visible: root.tab === "search"
			clip: true
			spacing: 6
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: root.hits

			delegate: Clickable {
				id: hit

				required property var modelData

				width: hitList.width
				implicitHeight: hitColumn.implicitHeight + 20
				radius: Theme.radius.medium
				color: hit.hovered ? Theme.layer2 : Theme.layer1
				pressedScale: 0.985
				onClicked: root.jump(hit.modelData.video, hit.modelData.at)

				ColumnLayout {
					id: hitColumn

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 10
					spacing: 3

					StyledText {
						Layout.fillWidth: true
						text: hit.modelData.text
						textFormat: Text.StyledText
						font.pixelSize: Theme.size.body
						wrapMode: Text.Wrap
					}
					StyledText {
						Layout.fillWidth: true
						text: `${Streams.clock(hit.modelData.at)} · ${hit.modelData.title ?? ""}`
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
						elide: Text.ElideRight
					}
				}
			}
		}
	}
}
