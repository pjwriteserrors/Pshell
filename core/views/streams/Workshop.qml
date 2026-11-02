pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// Where a series is made: which channel, how its videos are told apart, and
// beside it the channel's real videos, sorting themselves as the words change.
// A click on a video settles it for good.
Rectangle {
	id: root

	// null: a new series; else the series whose rule is changed
	property var editing: null
	property string name: ""
	property var sources: []
	property string playlist: ""
	property var words: []
	property var descWords: []
	property var notWords: []
	property var tagWords: []
	// what the form has no field for stays as it was
	property var otherRule: ({})
	property int minMinutes: 0
	property bool noShorts: true
	property bool ignoreFooter: true
	property bool trust: false
	// "any" word is enough, or "all" of them have to be there
	property string match: "any"
	property var taught: ({})
	property string startAfter: ""
	// the channel's playlists; loaded once a channel is picked
	property var playlists: []
	property bool loadingPlaylists: false
	property string playlistSource: ""
	property var videos: []
	property var videoById: ({})
	property var footerLines: []
	property int unknown: 0
	property int sure: 0
	property int maybe: 0
	property bool nameTouched: false
	readonly property bool usesDescriptions: root.descWords.length + root.tagWords.length > 0
	readonly property var rule: Object.assign({}, root.otherRule, { title: root.words, desc: root.descWords, tags: root.tagWords, not: root.notWords, match: root.match, minMinutes: root.minMinutes, noShorts: root.noShorts, trust: root.trust, ignoreFooter: root.ignoreFooter })
	readonly property bool canSave: root.sources.length + (root.playlist ? 1 : 0) > 0 && root.name.trim() !== "" && (root.playlist !== "" || root.words.length + root.descWords.length + root.tagWords.length > 0)
	readonly property string loadingNote: root.sources.concat(root.playlist ? [root.playlist] : []).map(id => Streams.sourceById[id]?.loading ?? "").filter(text => !!text)[0] ?? ""

	signal close
	signal created(string id)

	color: Streams.pageColor

	function reset(preset) {
		const item = preset ?? {};
		root.editing = item.id ? item : null;
		root.name = item.name ?? "";
		root.nameTouched = !!item.name;
		root.sources = item.sources ?? (Streams.ownSources.length === 1 ? [Streams.ownSources[0].id] : []);
		root.playlist = item.playlist ?? "";
		const rule = item.rule ?? {};
		root.words = rule.title ?? [];
		root.descWords = rule.desc ?? [];
		root.notWords = rule.not ?? [];
		root.tagWords = rule.tags ?? [];
		root.otherRule = rule;
		root.minMinutes = rule.minMinutes ?? 0;
		root.noShorts = rule.noShorts ?? true;
		root.trust = rule.trust ?? false;
		root.match = rule.match ?? "any";
		root.ignoreFooter = rule.ignoreFooter ?? true;
		root.taught = {};
		root.startAfter = "";
		root.playlists = [];
		root.playlistSource = "";
		root.askPlaylists();
		root.preview();
	}

	// a merged channel brings the others along, unless one of them is here already:
	// then it is being put back on its own
	function pickSource(id) {
		if (root.sources.includes(id)) {
			root.sources = root.sources.filter(one => one !== id);
			return;
		}
		const group = Streams.groupOf(id).filter(item => item.kind !== "twitch").map(item => item.id);
		const alone = group.some(one => root.sources.includes(one));
		root.sources = alone ? root.sources.concat([id]) : root.sources.concat(group.length > 0 ? group : [id]);
	}

	function askPlaylists() {
		const source = root.sources.find(id => Streams.sourceById[id]?.kind === "youtube") ?? "";
		if (source === root.playlistSource) return;
		root.playlistSource = source;
		root.playlists = [];
		if (!source) return;
		root.loadingPlaylists = true;
		Streams.call("playlists", { id: source }, data => {
			root.loadingPlaylists = false;
			if (root.playlistSource === source) root.playlists = data ?? [];
		});
	}

	function preview() {
		debounce.restart();
	}

	function askPreview() {
		const all = root.sources.slice();
		Streams.call("preview", { sources: all, playlist: root.playlist, rule: root.rule, taught: root.taught }, data => {
			if (!data) return;
			const byId = {};
			for (const video of data.videos) byId[video.id] = video;
			root.videoById = byId;
			root.videos = data.videos;
			root.footerLines = data.footerLines;
			root.unknown = data.unknownDescriptions;
			root.sure = data.sure;
			root.maybe = data.maybe;
			rows.sync(root.videos.slice(0, 400).map(video => ({ key: video.id })));
			if (root.usesDescriptions && root.unknown > 0 && !root.loadingNote) Streams.call("needDescriptions", { sources: all });
		});
	}

	function setAnswer(id, answer) {
		const next = Object.assign({}, root.taught);
		if (next[id] === answer) delete next[id];
		else next[id] = answer;
		root.taught = next;
		root.preview();
	}

	function pickPlaylist(entry) {
		// a playlist is a source of its own, kept out of the user's list
		if (root.playlist && root.playlist.endsWith(entry.id)) {
			root.playlist = "";
			root.preview();
			return;
		}
		Streams.call("add", { input: `https://www.youtube.com/playlist?list=${entry.id}`, hidden: true }, (data, error) => {
			if (error) return Streams.report()(null, error);
			root.playlist = data.id;
			if (!root.nameTouched) root.name = entry.title;
			root.preview();
		});
	}

	function save() {
		if (!root.canSave) return;
		if (root.editing) {
			Streams.updateSeries(root.editing.id, { name: root.name, sources: root.sources, playlist: root.playlist, rule: root.rule });
			for (const id of Object.keys(root.taught)) Streams.teach(root.editing.id, id, root.taught[id]);
			root.close();
			return;
		}
		Streams.call("createSeries", { name: root.name.trim(), sources: root.sources, playlist: root.playlist, rule: root.rule, taught: root.taught, startAfter: root.startAfter }, Streams.report(data => {
			if (data) root.created(data.id);
		}));
	}

	onRuleChanged: root.preview()
	onSourcesChanged: {
		root.askPlaylists();
		root.preview();
	}

	Timer {
		id: debounce

		interval: 90
		onTriggered: root.askPreview()
	}

	// more of the channel arrived
	Timer {
		interval: 1500
		repeat: true
		running: root.visible && root.loadingNote !== ""
		onTriggered: root.askPreview()
	}

	onLoadingNoteChanged: if (root.loadingNote === "") root.preview()

	SyncedModel {
		id: rows
	}

	RowLayout {
		anchors.fill: parent
		spacing: 0

		// ── the rule ────────────────────────────────────────────────────
		ColumnLayout {
			Layout.preferredWidth: Math.min(400, root.width * 0.38)
			Layout.maximumWidth: Math.min(400, root.width * 0.38)
			Layout.fillHeight: true
			spacing: 0

		Flickable {
			Layout.fillWidth: true
			Layout.fillHeight: true
			contentHeight: form.implicitHeight + 40
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: form

				x: 24
				y: 18
				width: parent.width - 48
				spacing: 14

				RowLayout {
					spacing: 6
					IconButton {
						width: 34
						height: 34
						icon: "arrow_left"
						onClicked: root.close()
					}
					StyledText {
						text: root.editing ? "Change the rule" : "New series"
						font.pixelSize: 28
						font.weight: Font.Black
					}
				}

				Field {
					Layout.fillWidth: true
					placeholder: "Its name"
					text: root.name
					icon: "playlist_plus"
					onEdited: text => {
						root.name = text;
						root.nameTouched = true;
					}
				}

				FormLabel {
					text: "From which channel"
				}

				Flow {
					Layout.fillWidth: true
					spacing: 5

					Repeater {
						model: Streams.ownSources.filter(source => source.kind !== "twitch")

						Chip {
							required property var modelData

							text: modelData.name
							selected: root.sources.includes(modelData.id)
							onClicked: root.pickSource(modelData.id)
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: text !== ""
					text: {
						const merged = [];
						for (const id of root.sources) merged.push(...Streams.groupOf(id).filter(item => item.group && item.kind !== "twitch"));
						const left = merged.filter(item => !root.sources.includes(item.id)).map(item => item.name);
						if (merged.length === 0) return "";
						return left.length > 0 ? `Left out of this series: ${[...new Set(left)].join(", ")}` : "Merged channels count together. Click one to leave it out of this series.";
					}
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					wrapMode: Text.Wrap
				}

				StyledText {
					Layout.fillWidth: true
					visible: Streams.ownSources.filter(source => source.kind !== "twitch").length === 0
					text: "Add the channel under Channels first."
					tone: Theme.warning
					font.pixelSize: Theme.size.small
				}

				// the surest way, when the channel has one
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.playlists.length > 0 || root.loadingPlaylists
					spacing: 6

					RowLayout {
						FormLabel {
							text: "A playlist of the channel (the surest way)"
						}
						Spinner {
							visible: root.loadingPlaylists
							Layout.preferredWidth: 12
							Layout.preferredHeight: 12
						}
					}

					Flow {
						Layout.fillWidth: true
						spacing: 5

						Repeater {
							model: root.playlists.slice(0, 16)

							Chip {
								required property var modelData

								text: modelData.count > 0 ? `${modelData.title} · ${modelData.count}` : modelData.title
								icon: "playlist_check"
								selected: root.playlist.endsWith(modelData.id) && root.playlist !== ""
								onClicked: root.pickPlaylist(modelData)
							}
						}
					}
				}

				FormLabel {
					visible: root.playlist === ""
					text: root.match === "all" ? "The title has all of" : "The title has one of"
				}
				WordsField {
					Layout.fillWidth: true
					visible: root.playlist === ""
					words: root.words
					placeholder: "riptide"
					onChangedWords: words => root.words = words
				}

				FormLabel {
					visible: root.playlist === ""
					text: root.match === "all" ? "The description has all of" : "The description has one of"
				}
				WordsField {
					Layout.fillWidth: true
					visible: root.playlist === ""
					words: root.descWords
					placeholder: "Horror Minecraft"
					onChangedWords: words => root.descWords = words
				}

				FormLabel {
					visible: root.playlist === ""
					text: root.match === "all" ? "It is tagged with all of" : "It is tagged with one of"
				}
				WordsField {
					Layout.fillWidth: true
					visible: root.playlist === ""
					words: root.tagWords
					placeholder: "steam deck"
					onChangedWords: words => root.tagWords = words
				}

				FormLabel {
					visible: root.playlist === ""
					text: "Words needed"
				}
				Segmented {
					Layout.fillWidth: true
					Layout.preferredHeight: 34
					visible: root.playlist === ""
					options: [{ value: "any", label: "Any of them" }, { value: "all", label: "All of them" }]
					current: root.match
					onSelected: value => root.match = value
				}

				FormLabel {
					text: "But not"
				}
				WordsField {
					Layout.fillWidth: true
					words: root.notWords
					placeholder: "trailer, challenge"
					onChangedWords: words => root.notWords = words
				}

				RowLayout {
					Layout.fillWidth: true
					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0
						StyledText {
							text: "Ignore the channel's footer"
						}
						StyledText {
							Layout.fillWidth: true
							text: root.footerLines.length > 0 ? `Under nearly every video: "${root.footerLines[0]}"` : "Lines under nearly every video do not count."
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideRight
						}
					}
					Toggle {
						checked: root.ignoreFooter
						onToggled: checked => root.ignoreFooter = checked
					}
				}

				RowLayout {
					Layout.fillWidth: true
					StyledText {
						Layout.fillWidth: true
						text: "Leave out shorts"
					}
					Toggle {
						checked: root.noShorts
						onToggled: checked => root.noShorts = checked
					}
				}

				RowLayout {
					Layout.fillWidth: true
					StyledText {
						Layout.fillWidth: true
						text: root.minMinutes > 0 ? `At least ${root.minMinutes} minutes long` : "Any length"
					}
					Segmented {
						Layout.preferredWidth: 160
						Layout.preferredHeight: 28
						options: [{ value: "0", label: "Any" }, { value: "5", label: "5" }, { value: "15", label: "15" }, { value: "30", label: "30" }]
						current: String(root.minMinutes)
						onSelected: value => root.minMinutes = Number(value)
					}
				}

			}
		}

		BigButton {
			Layout.fillWidth: true
			Layout.margins: 24
			Layout.topMargin: 10
			text: root.editing ? "Save" : (root.sure > 0 ? `Follow ${root.sure} ${root.sure === 1 ? "episode" : "episodes"}` : "Follow")
			icon: "check"
			enabled: root.canSave
			opacity: root.canSave ? 1 : 0.4
			onClicked: root.save()
		}
		}

		Rectangle {
			Layout.preferredWidth: 1
			Layout.fillHeight: true
			color: Theme.outline
		}

		// ── what it finds ───────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 0

			RowLayout {
				Layout.fillWidth: true
				Layout.leftMargin: 28
				Layout.rightMargin: 28
				Layout.topMargin: 24
				Layout.bottomMargin: 12
				spacing: 28

				Tally {
					value: root.sure
					label: "episodes in the series"
					tone: Theme.text
				}
				Tally {
					visible: root.maybe > 0
					value: root.maybe
					label: "maybe, you decide"
					tone: Theme.warning
				}
				Item {
					Layout.fillWidth: true
				}
				RowLayout {
					visible: root.loadingNote !== ""
					spacing: 8
					Spinner {
						Layout.preferredWidth: 16
						Layout.preferredHeight: 16
					}
					StyledText {
						text: root.loadingNote
						font.pixelSize: Theme.size.body
						tone: Theme.textMuted
					}
				}
				TextButton {
					visible: root.maybe > 0
					text: "They all belong"
					variant: "tonal"
					onActivated: root.trust = true
				}
			}

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 28
				Layout.rightMargin: 28
				Layout.bottomMargin: 8
				visible: root.usesDescriptions && root.unknown > 0
				text: `${root.unknown} videos have no description yet. They are read one by one, or all at once with a YouTube key (Channels → key).`
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				wrapMode: Text.Wrap
			}

			GridView {
				id: wall

				readonly property int columns: Math.max(2, Math.floor(width / 210))

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.leftMargin: 24
				Layout.rightMargin: 12
				clip: true
				cellWidth: Math.floor(width / wall.columns)
				cellHeight: Math.round((wall.cellWidth - 12) * 9 / 16) + 58
				model: rows
				boundsBehavior: Flickable.StopAtBounds
				cacheBuffer: 600
				ScrollBar.vertical: ThinScrollBar {}

				add: Transition {
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}
				}
				move: Transition {
					SpatialAnim {
						properties: "x,y"
						duration: Motion.extraLong
					}
				}
				moveDisplaced: Transition {
					SpatialAnim {
						properties: "x,y"
						duration: Motion.extraLong
					}
				}
				displaced: Transition {
					SpatialAnim {
						properties: "x,y"
						duration: Motion.extraLong
					}
				}
				remove: Transition {
					Anim {
						property: "opacity"
						to: 0
						duration: Motion.short
					}
				}

				delegate: Item {
					id: hit

					required property string key
					readonly property var video: root.videoById[hit.key] ?? null
					readonly property string verdict: hit.video?.state ?? "none"

					width: wall.cellWidth
					height: wall.cellHeight
					z: hitHover.hovered ? 5 : 0

					HoverHandler {
						id: hitHover
					}

					Item {
						id: poster

						width: parent.width - 12
						height: Math.round(width * 9 / 16)
						scale: hitHover.hovered ? 1.05 : (hit.verdict === "none" ? 0.94 : 1)

						Behavior on scale {
							SpatialAnim {
								duration: Motion.long
							}
						}

						Thumb {
							anchors.fill: parent
							source: hit.video?.thumb ?? ""
							dimmed: hit.verdict === "none" && !hitHover.hovered
							zoom: hitHover.hovered ? 1.04 : 1
						}

						Rectangle {
							anchors.fill: parent
							radius: Theme.radius.medium
							color: "transparent"
							border.width: hit.verdict === "maybe" ? 2 : (hit.verdict === "sure" ? 1.5 : 0)
							border.color: hit.verdict === "maybe" ? Theme.warning : Qt.alpha(Theme.success, 0.8)

							Behavior on border.color {
								ColorAnim {}
							}
						}

						// its fate
						Rectangle {
							x: 7
							y: 7
							width: 24
							height: 24
							radius: 12
							color: hit.verdict === "sure" ? Theme.success : Theme.warning
							visible: hit.verdict !== "none"
							scale: hit.verdict !== "none" ? 1 : 0

							Behavior on scale {
								SpatialAnim {
									duration: Motion.long
								}
							}

							Glyph {
								anchors.centerIn: parent
								icon: hit.verdict === "sure" ? "check_bold" : "help"
								size: 15
								color: "black"
								surface: "white"
							}
						}

						// a word from the user
						Row {
							anchors.bottom: parent.bottom
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottomMargin: 7
							spacing: 4
							opacity: hitHover.hovered ? 1 : 0
							visible: opacity > 0.01

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}

							BigButton {
								implicitHeight: 30
								text: "Belongs"
								main: hit.video?.taught === "yes"
								onClicked: root.setAnswer(hit.key, "yes")
							}
							BigButton {
								implicitHeight: 30
								text: "No"
								main: hit.video?.taught === "no"
								onClicked: root.setAnswer(hit.key, "no")
							}
						}
					}

					ColumnLayout {
						anchors.left: poster.left
						anchors.right: poster.right
						anchors.top: poster.bottom
						anchors.topMargin: 6
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: hit.video?.title ?? ""
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
							tone: hit.verdict === "none" ? Theme.textSubtle : Theme.text
							elide: Text.ElideRight
						}
						StyledText {
							Layout.fillWidth: true
							text: hit.video?.why ?? ""
							font.pixelSize: Theme.size.tiny
							tone: hit.verdict === "maybe" ? Theme.warning : Theme.textSubtle
							elide: Text.ElideRight
						}
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: rows.count === 0

				ColumnLayout {
					anchors.centerIn: parent
					spacing: 8

					Text {
						Layout.alignment: Qt.AlignHCenter
						text: root.sources.length === 0 ? "Pick a channel" : "On the way"
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: 30
						font.weight: Font.Black
					}
					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: root.sources.length === 0 ? "Its videos appear here and sort themselves as you type." : (root.loadingNote || "The channel's videos are being fetched.")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.title
					}
				}
			}
		}
	}
}
