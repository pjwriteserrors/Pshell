pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// Plain subscribing: a link in the field, a row of faces, and the newest videos
// of all of them or the one picked. Who is live on Twitch or YouTube comes first.
Flickable {
	id: root

	// a source id; "" for all
	property string channel: ""
	property int limit: 48
	property bool more: false
	property var videos: []
	property var videoById: ({})
	property string adding: ""
	property string addError: ""
	readonly property var picked: Streams.sourceById[root.channel] ?? null
	// merged channels are one face and one list here
	readonly property var pickedGroup: root.channel ? Streams.groupOf(root.channel) : []
	readonly property bool pickedMerged: root.pickedGroup.length > 1
	readonly property var streams: Streams.liveStreams.filter(item => root.channel === "" || root.pickedGroup.some(other => other.id === item.source))

	function load() {
		const asked = root.channel;
		Streams.call("feed", { source: asked, limit: root.limit }, data => {
			if (!data || asked !== root.channel) return;
			const byId = {};
			for (const video of data.videos) byId[video.id] = video;
			root.videoById = byId;
			root.videos = data.videos;
			root.more = data.more;
			cards.sync(root.videos.map(video => ({ key: video.id })));
		});
	}

	function pick(id) {
		if (root.channel === id) return;
		root.channel = id;
		root.limit = 48;
		root.contentY = 0;
		cards.clear();
		root.load();
	}

	function add() {
		const value = field.text.trim();
		if (!value || root.adding) return;
		root.adding = value;
		root.addError = "";
		Streams.call("add", { input: value }, (data, error) => {
			root.adding = "";
			root.addError = error;
			if (error) return;
			field.text = "";
			if (data) root.pick(data.id);
		});
	}

	onVisibleChanged: if (visible) root.load()
	Component.onCompleted: root.load()
	// reaching the end asks for more
	onContentYChanged: {
		if (root.more && root.contentY + root.height > root.contentHeight - 600 && !loadMore.running) {
			root.limit += 48;
			loadMore.start();
		}
	}

	Timer {
		id: loadMore

		interval: 200
		onTriggered: root.load()
	}

	Connections {
		target: Streams

		function onFeedStampChanged() {
			if (root.visible) stamped.restart();
		}
	}

	Timer {
		id: stamped

		interval: 300
		onTriggered: root.load()
	}

	SyncedModel {
		id: cards
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 16

		Item {
			Layout.preferredHeight: 64
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			Text {
				text: "Subscriptions"
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 40
				font.weight: Font.Black
			}
			Item {
				Layout.fillWidth: true
			}
			Field {
				id: field

				Layout.preferredWidth: 420
				Layout.preferredHeight: 44
				icon: "plus"
				placeholder: "YouTube link, @channel or Twitch name"
				onAccepted: root.add()
			}
			BigButton {
				implicitHeight: 44
				text: root.adding !== "" ? "Looking…" : "Subscribe"
				onClicked: root.add()
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.addError !== ""
			text: root.addError
			color: Theme.danger
			font.pixelSize: Theme.size.body
			wrapMode: Text.Wrap
		}

		// ── the faces ───────────────────────────────────────────────────
		ListView {
			id: faces

			Layout.fillWidth: true
			Layout.preferredHeight: 104
			orientation: ListView.Horizontal
			spacing: 6
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			model: [{ id: "", name: "All", avatar: "", colors: null, live: false }].concat(Streams.ownSources.filter(item => !item.group || Streams.groupOf(item.id).find(other => other.kind !== "twitch")?.id === item.id || !Streams.groupOf(item.id).some(other => other.kind !== "twitch") && Streams.groupOf(item.id)[0].id === item.id).map(item => {
				const group = Streams.groupOf(item.id);
				return group.length > 1 ? Object.assign({}, item, { name: group.map(other => other.name).join(" & "), live: group.some(other => other.live) }) : item;
			}).sort((a, b) => (b.live - a.live) || a.name.localeCompare(b.name)))

			delegate: Item {
				id: face

				required property var modelData
				readonly property bool current: root.channel === face.modelData.id

				width: 88
				height: faces.height

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.large
					color: face.current ? Theme.primaryContainer : (faceArea.containsMouse ? Theme.layer1 : "transparent")

					Behavior on color {
						ColorAnim {}
					}
				}

				Column {
					anchors.centerIn: parent
					spacing: 7

					Item {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 56
						height: 56
						scale: faceArea.pressed ? 0.92 : (faceArea.containsMouse || face.current ? 1.08 : 1)

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Avatar {
							anchors.fill: parent
							visible: face.modelData.id !== ""
							source: face.modelData.avatar
							name: face.modelData.name
							colors: face.modelData.colors
							live: face.modelData.live
						}
						Rectangle {
							anchors.fill: parent
							visible: face.modelData.id === ""
							radius: width / 2
							color: Theme.layer3

							Glyph {
								anchors.centerIn: parent
								icon: "play_circle"
								size: 28
								color: Theme.text
							}
						}
					}
					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 80
						horizontalAlignment: Text.AlignHCenter
						text: face.modelData.name
						font.pixelSize: Theme.size.small
						font.weight: face.current ? Font.Bold : Font.Medium
						elide: Text.ElideRight
					}
				}

				MouseArea {
					id: faceArea

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.pick(face.modelData.id)
				}
			}
		}

		// ── one channel: how it may speak up ─────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: !!root.picked
			spacing: 14

			StyledText {
				text: root.pickedGroup.map(other => other.name).join(" & ")
				font.pixelSize: Theme.size.heading + 4
				font.weight: Font.Black
			}
			StyledText {
				Layout.fillWidth: true
				text: root.picked?.error || root.picked?.pattern || ""
				font.pixelSize: Theme.size.body
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
			Segmented {
				visible: !root.pickedMerged
				Layout.preferredWidth: 240
				Layout.preferredHeight: 32
				options: [{ value: "all", label: "All" }, { value: "live", label: "Live only" }, { value: "silent", label: "Silent" }]
				current: root.picked?.notify ?? "live"
				onSelected: value => Streams.updateSource(root.channel, { notify: value })
			}
			TextButton {
				visible: !root.pickedMerged
				text: "Unsubscribe"
				variant: "ghost"
				confirm: true
				confirmText: "Sure?"
				onActivated: {
					Streams.call("removeSource", { id: root.channel });
					root.pick("");
				}
			}
		}

		// ── live first ──────────────────────────────────────────────────
		SectionHeading {
			visible: root.streams.length > 0
			text: "Live now"
		}
		Flow {
			Layout.fillWidth: true
			spacing: 16
			visible: root.streams.length > 0

			Repeater {
				model: root.streams

				LiveCard {
					required property var modelData

					width: grid.cellWidth - 16
					height: Math.round(width * 9 / 16) + 66
					stream: modelData
				}
			}
		}

		SectionHeading {
			visible: root.streams.length > 0 && cards.count > 0
			text: "Newest videos"
		}

		GridView {
			id: grid

			readonly property int columns: Math.max(2, Math.floor((width + 16) / 320))

			Layout.fillWidth: true
			Layout.preferredHeight: Math.ceil(cards.count / grid.columns) * grid.cellHeight
			interactive: false
			cellWidth: Math.floor(width / grid.columns)
			cellHeight: Math.round((grid.cellWidth - 16) * 9 / 16) + 86
			model: cards

			add: Transition {
				ParallelAnimation {
					SpatialAnim {
						property: "scale"
						from: 0.88
						to: 1
						duration: Motion.long
					}
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}
				}
			}
			displaced: Transition {
				SpatialAnim {
					properties: "x,y"
					duration: Motion.long
				}
			}

			delegate: Item {
				id: cell

				required property string key

				width: grid.cellWidth
				height: grid.cellHeight
				z: card.lifted ? 10 : 0

				VideoCard {
					id: card

					anchors.fill: parent
					anchors.rightMargin: 16
					anchors.bottomMargin: 18
					video: root.videoById[cell.key] ?? null
				}
			}
		}

		// nothing here
		ColumnLayout {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 60
			visible: cards.count === 0 && root.streams.length === 0
			spacing: 10

			Text {
				Layout.alignment: Qt.AlignHCenter
				text: root.picked?.kind === "twitch" ? `${root.picked.name} is not live` : (Streams.ownSources.length === 0 ? "Subscribe to something" : "No videos yet")
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 30
				font.weight: Font.Black
			}
			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: root.picked?.kind === "twitch" ? "It shows up here when it goes live, and you get told." : "Paste a YouTube link or a Twitch name above."
				font.pixelSize: Theme.size.title
				tone: Theme.textMuted
			}
		}
	}
}
