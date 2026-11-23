pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The songs and the ideas. The search looks in the titles and in every
// line written; a found line opens its song there.
Item {
	id: library

	property string tab: "songs"
	readonly property bool searching: Rhymes.query.trim() !== ""
	property alias searchField: search

	signal insert(string text)

	function terms() {
		return Rhymes.found?.terms ?? [];
	}

	// the words searched for, marked
	function marked(text) {
		let out = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;");
		for (const term of library.terms()) {
			const safe = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/&/g, "&amp;").replace(/</g, "&lt;");
			out = out.replace(new RegExp(`(${safe})`, "gi"), `<span style="color:${Theme.primary}">$1</span>`);
		}
		return out;
	}

	Column {
		id: top

		x: 12
		y: 10
		width: parent.width - 24
		spacing: 10

		Field {
			id: search

			width: parent.width
			icon: "magnify"
			placeholder: "Search"
			onEdited: text => Rhymes.search(text)
			onEscapePressed: {
				search.text = "";
				Rhymes.search("");
			}
		}

		Segmented {
			width: parent.width
			visible: !library.searching
			options: [{ value: "songs", label: "Songs", icon: "music_note" }, { value: "ideas", label: "Ideas", icon: "lightbulb_outline" }]
			current: library.tab
			onSelected: value => library.tab = value
		}
	}

	// ── songs ──────────────────────────────────────────────────────────────
	ListView {
		id: songs

		anchors.top: top.bottom
		anchors.topMargin: 10
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		clip: true
		spacing: 2
		visible: !library.searching && library.tab === "songs"
		model: Rhymes.songs
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		currentIndex: Rhymes.songs.findIndex(s => s.id === Rhymes.song?.id)
		highlightFollowsCurrentItem: true
		highlightMoveDuration: Motion.long
		highlightResizeDuration: Motion.long

		highlight: Item {
			Rectangle {
				anchors.fill: parent
				anchors.leftMargin: 8
				anchors.rightMargin: 8
				radius: Theme.radius.medium
				color: Theme.layer2
			}

			Rectangle {
				x: 8
				anchors.verticalCenter: parent.verticalCenter
				width: 3
				height: parent.height * 0.5
				radius: 2
				color: Theme.primary
			}
		}

		header: Item {
			width: songs.width
			height: 46

			Clickable {
				x: 8
				y: 2
				width: parent.width - 16
				height: 40
				radius: Theme.radius.medium
				color: "transparent"
				onClicked: Rhymes.create("")

				Row {
					x: 12
					anchors.verticalCenter: parent.verticalCenter
					spacing: 10

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: "plus"
						size: 18
						color: Theme.primary
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: "New song"
						tone: Theme.primary
						font.weight: Font.Medium
					}
				}
			}
		}

		add: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}

				SpatialAnim {
					property: "x"
					from: -20
					to: 0
				}
			}
		}

		displaced: Transition {
			SpatialAnim {
				property: "y"
			}
		}

		delegate: Clickable {
			id: entry

			required property var modelData
			required property int index
			readonly property bool current: Rhymes.song?.id === entry.modelData.id

			x: 8
			width: songs.width - 16
			height: 58
			radius: Theme.radius.medium
			color: "transparent"
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			onClicked: Rhymes.load(entry.modelData.id)
			onRightClicked: mouse => {
				const song = entry.modelData;
				menu.entries = [
					{ text: "Duplicate", icon: "content_copy", action: () => Rhymes.duplicate(song.id) },
					{ text: "Play in Music", icon: "playlist_music", enabled: song.beat, action: () => Rhymes.playInMusic(song.id) },
					{ text: "Move to the trash", icon: "delete_outline", danger: true, action: () => Rhymes.remove(song.id) }
				];
				menu.show(entry, mouse.x, mouse.y);
			}

			Column {
				x: 16
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width - 28
				spacing: 2

				Row {
					width: parent.width
					spacing: 6

					StyledText {
						width: Math.min(implicitWidth, parent.width - (beatGlyph.visible ? 22 : 0))
						text: entry.modelData.title || "Untitled"
						elide: Text.ElideRight
						font.weight: entry.current ? Font.DemiBold : Font.Medium
					}

					Glyph {
						id: beatGlyph

						anchors.verticalCenter: parent.verticalCenter
						visible: entry.modelData.beat
						icon: "music_note"
						size: 13
						color: Theme.textSubtle
					}
				}

				StyledText {
					width: parent.width
					text: entry.modelData.first || `${Format.ago(entry.modelData.modified * 1000)}`
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}
			}
		}

	}

	// ── ideas ──────────────────────────────────────────────────────────────
	Item {
		anchors.top: top.bottom
		anchors.topMargin: 10
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		visible: !library.searching && library.tab === "ideas"

		Field {
			id: idea

			x: 12
			width: parent.width - 24
			icon: "plus"
			placeholder: "A line, a punchline…"
			autocorrect: true
			onAccepted: {
				Rhymes.addIdea(idea.text);
				idea.text = "";
			}
		}

		ListView {
			id: ideas

			anchors.top: idea.bottom
			anchors.topMargin: 10
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			clip: true
			spacing: 6
			model: Rhymes.ideas
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			add: Transition {
				ParallelAnimation {
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}

					SpatialAnim {
						property: "scale"
						from: 0.9
						to: 1
					}
				}
			}

			remove: Transition {
				Anim {
					property: "opacity"
					to: 0
				}
			}

			displaced: Transition {
				SpatialAnim {
					property: "y"
				}
			}

			delegate: Clickable {
				id: card

				required property var modelData

				x: 12
				width: ideas.width - 24
				height: ideaText.implicitHeight + 34
				radius: Theme.radius.large
				color: Theme.layer1
				onClicked: library.insert(card.modelData.text)

				StyledText {
					id: ideaText

					x: 14
					y: 10
					width: parent.width - 28 - (card.hovered ? 26 : 0)
					text: card.modelData.text
					wrapMode: Text.Wrap
				}

				StyledText {
					x: 14
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 6
					text: `${Format.ago(card.modelData.created * 1000)}${card.modelData.source && card.modelData.source !== "pc" ? " · " + card.modelData.source : ""}`
					font.pixelSize: Theme.size.tiny
					tone: Theme.textFaint
				}

				IconButton {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 6
					width: 24
					height: 24
					icon: "close"
					opacity: card.hovered ? 1 : 0
					onClicked: Rhymes.dropIdea(card.modelData.id)

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}
			}
		}
	}

	// ── found ──────────────────────────────────────────────────────────────
	ListView {
		id: results

		anchors.top: top.bottom
		anchors.topMargin: 6
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		clip: true
		spacing: 4
		visible: library.searching
		model: (Rhymes.found?.songs ?? []).concat((Rhymes.found?.ideas ?? []).map(i => ({ idea: true, text: i.text, id: i.id })))
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: hit

			required property var modelData
			required property int index

			width: results.width
			height: hitColumn.implicitHeight + 16
			opacity: 0
			Component.onCompleted: opacity = 1

			Behavior on opacity {
				SequentialAnimation {
					PauseAnimation {
						duration: Math.min(hit.index, 12) * 20
					}

					Anim {}
				}
			}

			Column {
				id: hitColumn

				x: 8
				y: 8
				width: parent.width - 16
				spacing: 2

				Clickable {
					width: parent.width
					height: 30
					radius: Theme.radius.small
					color: "transparent"
					onClicked: hit.modelData.idea ? library.insert(hit.modelData.text) : Rhymes.load(hit.modelData.id, hit.modelData.hits?.[0]?.line ?? -1)

					Row {
						x: 8
						anchors.verticalCenter: parent.verticalCenter
						spacing: 8

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: hit.modelData.idea ? "lightbulb_outline" : "music_note"
							size: 14
							color: Theme.textSubtle
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							width: hitColumn.width - 40
							text: library.marked(hit.modelData.idea ? hit.modelData.text : hit.modelData.title)
							textFormat: Text.StyledText
							elide: Text.ElideRight
							font.weight: Font.Medium
						}
					}
				}

				Repeater {
					model: hit.modelData.idea ? [] : (hit.modelData.hits ?? [])

					Clickable {
						required property var modelData

						width: hitColumn.width
						height: 26
						radius: Theme.radius.small
						color: "transparent"
						onClicked: Rhymes.load(hit.modelData.id, modelData.line)

						StyledText {
							x: 30
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 38
							text: library.marked(modelData.text)
							textFormat: Text.StyledText
							elide: Text.ElideRight
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
						}
					}
				}
			}
		}
	}

	SmallMenu {
		id: menu

		parent: library
	}
}
