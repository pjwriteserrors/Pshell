pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// Series found on the channels the user added, those with the newest videos
// first: from playlists, titles, descriptions, hashtags and tags, read slowly in
// the background. One click follows one; the picture opens it to change it first.
// The page is the grid itself, so only the cards in sight are made.
GridView {
	id: root

	// a channel's source id; "" for all
	property string channel: ""
	property string query: ""
	readonly property var words: root.query.toLowerCase().split(/\s+/).filter(word => word !== "")
	readonly property var found: root.words.length === 0 ? Streams.shownDiscoveries : Streams.shownDiscoveries.filter(item => {
		const text = [item.name, item.sourceName, ...(item.parts ?? []).map(part => part.name)].join(" ").toLowerCase();
		return root.words.every(word => text.includes(word));
	})
	readonly property var channels: {
		const count = {};
		for (const item of root.found) count[item.source] = (count[item.source] ?? 0) + 1;
		const name = id => Streams.makerName(Streams.groupOf(id)).toLowerCase();
		return Object.keys(count).map(id => ({ id: id, count: count[id] })).sort((a, b) => name(a.id).localeCompare(name(b.id)));
	}
	readonly property var shown: root.found.filter(item => root.channel === "" || item.source === root.channel)
	readonly property real progress: (Streams.scan.total ?? 0) > 0 ? Streams.scan.done / Streams.scan.total : 0
	readonly property bool reading: (Streams.scan.now ?? "") !== "" || (root.progress > 0 && root.progress < 1)
	readonly property int columns: Math.max(1, Math.min(Math.floor((root.width - 88 + 16) / 320), Math.max(3, cards.count)))

	leftMargin: 44
	rightMargin: 44
	bottomMargin: 40
	cellWidth: Math.floor((root.width - 88) / root.columns)
	cellHeight: Math.round((root.cellWidth - 16) * 9 / 16) + 76
	cacheBuffer: root.cellHeight * 2
	currentIndex: -1
	highlightFollowsCurrentItem: false
	keyNavigationEnabled: false
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}
	model: cards

	// a header that grows keeps the first card where it was and so slides
	// itself away; at the top the page stays at the top
	property bool atTop: true
	onContentYChanged: root.atTop = root.contentY <= root.originY + 1
	onOriginYChanged: if (root.atTop) Qt.callLater(root.positionViewAtBeginning)
	onShownChanged: cards.sync(root.shown.map(item => ({ key: item.key })))
	onChannelsChanged: if (root.channel !== "" && !root.channels.some(entry => entry.id === root.channel)) root.channel = ""
	Component.onCompleted: cards.sync(root.shown.map(item => ({ key: item.key })))

	SyncedModel {
		id: cards
	}

	header: ColumnLayout {
		width: root.width - 88
		spacing: 16

		Item {
			Layout.preferredHeight: 64
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			ColumnLayout {
				spacing: 0

				Text {
					text: "Explore"
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 40
					font.weight: Font.Black
				}
				StyledText {
					text: "Series found on your channels, newest videos first"
					font.pixelSize: Theme.size.title
					tone: Theme.textMuted
				}
			}

			Item {
				Layout.fillWidth: true
			}

			// how far reading the channels got
			ColumnLayout {
				visible: root.reading
				Layout.preferredWidth: 300
				spacing: 5

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignRight
					text: Streams.scan.paused ? `Reading paused${Streams.scan.why ? `: ${Streams.scan.why}` : ""}` : (Streams.scan.now || "Reading the channels")
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					wrapMode: Text.Wrap
					maximumLineCount: 3
					elide: Text.ElideRight
				}
				TextButton {
					Layout.alignment: Qt.AlignRight
					visible: !!Streams.scan.paused && Streams.scan.why !== "A game is running"
					text: "Read on"
					variant: "ghost"
					onActivated: Streams.call("scanGo", {})
				}
				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 4
					radius: 2
					color: Qt.alpha(Theme.text, 0.12)

					Rectangle {
						height: parent.height
						radius: 2
						color: Theme.primary
						width: parent.width * root.progress

						Behavior on width {
							Anim {
								duration: Motion.extraLong
							}
						}
					}
				}
				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignRight
					text: `${Streams.scan.done ?? 0} of ${Streams.scan.total ?? 0} videos read, more is found as it goes`
					font.pixelSize: Theme.size.tiny
					tone: Theme.textSubtle
					tabular: true
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 16

			Segmented {
				Layout.preferredWidth: 330
				Layout.preferredHeight: 34
				options: [
					{ value: "all", label: `All ${Streams.discoveries.length}` },
					{ value: "detected", label: `Without playlists ${Streams.discoveries.filter(item => Streams.isDetected(item)).length}` }
				]
				current: Streams.settings.exploreKinds ?? "all"
				onSelected: value => {
					root.channel = "";
					Streams.setSetting("exploreKinds", value);
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Field {
				Layout.preferredWidth: 360
				Layout.preferredHeight: 38
				icon: "magnify"
				placeholder: "Search"
				onTextChanged: root.query = text
				onEscapePressed: text = ""
			}
		}

		ExploreChannels {
			Layout.fillWidth: true
			Layout.bottomMargin: 16
			visible: root.channels.length > 1
			channels: root.channels
			total: root.found.length
			current: root.channel
			onPicked: id => root.channel = id
		}
	}

	footer: ColumnLayout {
		width: root.width - 88
		spacing: 16

		ColumnLayout {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 80
			visible: cards.count === 0
			spacing: 10

			Text {
				Layout.alignment: Qt.AlignHCenter
				text: root.words.length > 0 ? "Nothing found" : (Streams.ownSources.length === 0 ? "No channels yet" : (root.reading ? "Reading your channels" : "Nothing new to suggest"))
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 30
				font.weight: Font.Black
			}
			StyledText {
				Layout.alignment: Qt.AlignHCenter
				visible: root.words.length === 0
				text: Streams.ownSources.length === 0 ? "Series appear here once you follow a channel." : (root.reading ? "Series appear here as they are found." : (Streams.discoveries.length > 0 ? "The rest are only playlists." : "Everything found is followed or waved away."))
				tone: Theme.textMuted
				font.pixelSize: Theme.size.title
			}
		}

		ExploreExtras {
			Layout.fillWidth: true
		}
	}

	add: Transition {
		ParallelAnimation {
			SpatialAnim {
				property: "scale"
				from: 0.82
				to: 1
				duration: Motion.extraLong
			}
			Anim {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.long
			}
		}
	}
	// followed or waved away: it flies up and is gone
	remove: Transition {
		ParallelAnimation {
			Anim {
				property: "opacity"
				to: 0
				duration: Motion.long
			}
			SpatialAnim {
				property: "scale"
				to: 0.8
				duration: Motion.long
			}
		}
	}
	displaced: Transition {
		SpatialAnim {
			properties: "x,y"
			duration: Motion.long
		}
	}
	move: Transition {
		SpatialAnim {
			properties: "x,y"
			duration: Motion.long
		}
	}

	delegate: Item {
		id: cell

		required property string key

		width: root.cellWidth
		height: root.cellHeight
		z: card.lifted ? 10 : 0

		ExploreCard {
			id: card

			anchors.fill: parent
			anchors.rightMargin: 16
			anchors.bottomMargin: 20
			itemKey: cell.key
		}
	}
}
