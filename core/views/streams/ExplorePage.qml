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
Flickable {
	id: root

	// a channel's source id; "" for all
	property string channel: ""
	readonly property var channels: {
		const seen = {};
		for (const item of Streams.shownDiscoveries) seen[item.source] = item.sourceName;
		return Object.keys(seen).map(id => ({ id: id, name: seen[id] })).sort((a, b) => a.name.localeCompare(b.name));
	}
	readonly property var shown: Streams.shownDiscoveries.filter(item => root.channel === "" || item.source === root.channel)
	readonly property real progress: (Streams.scan.total ?? 0) > 0 ? Streams.scan.done / Streams.scan.total : 0
	readonly property bool reading: (Streams.scan.now ?? "") !== "" || (root.progress > 0 && root.progress < 1)

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	onShownChanged: model.sync(root.shown.map(item => ({ key: item.key })))
	Component.onCompleted: model.sync(root.shown.map(item => ({ key: item.key })))

	SyncedModel {
		id: model
	}

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

		Flow {
			Layout.fillWidth: true
			spacing: 6
			visible: root.channels.length > 1

			Chip {
				text: "All channels"
				selected: root.channel === ""
				onClicked: root.channel = ""
			}
			Repeater {
				model: root.channels

				Chip {
					required property var modelData

					text: modelData.name
					selected: root.channel === modelData.id
					onClicked: root.channel = modelData.id
				}
			}
		}

		GridView {
			id: grid

			readonly property int columns: Math.max(1, Math.min(Math.floor((width + 16) / 320), Math.max(3, model.count)))

			Layout.fillWidth: true
			Layout.preferredHeight: Math.ceil(model.count / grid.columns) * grid.cellHeight
			interactive: false
			cellWidth: Math.floor(width / grid.columns)
			cellHeight: Math.round((grid.cellWidth - 16) * 9 / 16) + 76
			model: model

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

				width: grid.cellWidth
				height: grid.cellHeight
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

		ColumnLayout {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 80
			visible: model.count === 0
			spacing: 10

			Text {
				Layout.alignment: Qt.AlignHCenter
				text: Streams.ownSources.length === 0 ? "No channels yet" : (root.reading ? "Reading your channels" : "Nothing new to suggest")
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 30
				font.weight: Font.Black
			}
			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: Streams.ownSources.length === 0 ? "Series appear here once you follow a channel." : (root.reading ? "Series appear here as they are found." : (Streams.discoveries.length > 0 ? "The rest are only playlists." : "Everything found is followed or waved away."))
				tone: Theme.textMuted
				font.pixelSize: Theme.size.title
			}
		}

		ExploreExtras {
			Layout.fillWidth: true
		}
	}
}
