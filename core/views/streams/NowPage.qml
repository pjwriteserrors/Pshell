pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Home: one thing large, then rows of what is live, what goes on, what is new.
Flickable {
	id: root

	signal openSeries(string id, var from)
	signal openTonight
	signal newSeries(var preset)

	readonly property real cardWidth: Math.max(270, Math.min(420, (root.width - 88 - 3 * 14) / 3.6))
	readonly property real cardHeight: Math.round(root.cardWidth * 9 / 16) + 62
	readonly property var billboardItems: {
		const out = [];
		for (const stream of Streams.liveStreams.slice(0, 3)) {
			out.push({
				key: `live:${stream.source}`, kind: "live", title: stream.name, subtitle: stream.title, kicker: stream.category || (stream.platform === "twitch" ? "Twitch" : "YouTube"),
				meta: stream.viewers > 0 ? `${Number(stream.viewers).toLocaleString(Qt.locale(), "f", 0)} watching` : "", picture: stream.pictureUrl, large: "", colors: stream.colors, accent: Streams.accent(stream.colors), source: stream.source, total: 0, cells: [], done: 0
			});
		}
		for (const item of Streams.openSeries.slice(0, 5)) {
			out.push({
				key: `series:${item.id}`, kind: "series", title: item.name, subtitle: item.next ? item.next.title : "", kicker: item.sourceNames.join(", "), meta: `${item.watched} of ${item.total} watched · ${Streams.span(item.remaining)} left`,
				picture: item.picture, large: item.spoiler ? "" : Streams.large(item.pictureId), colors: item.colors, accent: Streams.accent(item.colors), seriesId: item.id, cells: item.cells, total: item.total, done: item.partial, spoiler: item.spoiler, resume: (item.next?.position ?? 0) > 0
			});
		}
		return out;
	}
	readonly property var fresh: {
		const out = [];
		for (const item of Streams.series) {
			if (item.status !== "active") continue;
			for (const episode of item.newest) {
				if (!episode.watched) out.push({ key: episode.id, series: item.id, episode: episode });
			}
		}
		return out.sort((a, b) => b.episode.published - a.episode.published).slice(0, 12);
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	ColumnLayout {
		id: column

		width: root.width
		spacing: 18

		// ── getting going ───────────────────────────────────────────────
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: root.height
			visible: Streams.ownSources.length === 0

			ColumnLayout {
				anchors.centerIn: parent
				spacing: 14

				Text {
					Layout.alignment: Qt.AlignHCenter
					text: "What do you want to follow?"
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: 44
					font.weight: Font.Black
				}
				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: "A YouTube channel, a playlist, a Twitch name or any feed."
					font.pixelSize: Theme.size.title
					tone: Theme.textMuted
				}
				BigButton {
					Layout.alignment: Qt.AlignHCenter
					Layout.topMargin: 8
					text: "Add a channel"
					icon: "plus"
					onClicked: Streams.open({ page: "sources" })
				}
			}
		}

		Billboard {
			id: billboard

			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(440, Math.min(root.height * 0.74, 720))
			Layout.bottomMargin: -72
			visible: root.billboardItems.length > 0
			items: root.billboardItems
			scrolled: root.contentY
			currentKey: root.billboardItems[0]?.key ?? ""
			onOpenSeries: (id, from) => root.openSeries(id, from)
		}

		Rail {
			Layout.fillWidth: true
			title: "Live now"
			keys: Streams.liveStreams.map(item => ({ key: item.source }))
			cardWidth: root.cardWidth
			cardHeight: root.cardHeight
			card: LiveCard {
				property string cardKey: ""

				stream: Streams.liveStreams.find(item => item.source === cardKey) ?? null
			}
		}

		Rail {
			Layout.fillWidth: true
			title: "Continue watching"
			note: {
				const total = Streams.openSeries.reduce((sum, item) => sum + item.remaining, 0);
				return total > 0 ? `${Streams.span(total)} waiting` : "";
			}
			keys: Streams.openSeries.map(item => ({ key: item.id }))
			cardWidth: root.cardWidth
			cardHeight: root.cardHeight
			card: SeriesCard {
				property string cardKey: ""

				seriesId: cardKey
				onOpened: from => root.openSeries(cardKey, from)
			}
		}

		Rail {
			Layout.fillWidth: true
			title: "New episodes"
			keys: root.fresh.map(item => ({ key: item.key }))
			cardWidth: root.cardWidth
			cardHeight: root.cardHeight
			card: EpisodeCard {
				property string cardKey: ""
				readonly property var entry: root.fresh.find(item => item.key === cardKey) ?? null

				episode: entry?.episode ?? null
				seriesItem: Streams.seriesById[entry?.series] ?? null
			}
		}

		Inbox {
			Layout.fillWidth: true
			visible: Streams.inbox.length > 0
			cardWidth: root.cardWidth
		}

		Rail {
			Layout.fillWidth: true
			title: "Found on your channels"
			note: Streams.shownDiscoveries.length > 8 ? `${Streams.shownDiscoveries.length} in Explore` : ""
			keys: Streams.shownDiscoveries.slice(0, 8).map(item => ({ key: item.key }))
			cardWidth: root.cardWidth
			cardHeight: Math.round(root.cardWidth * 9 / 16) + 66
			card: ExploreCard {
				property string cardKey: ""

				itemKey: cardKey
			}
		}

		Item {
			Layout.preferredHeight: 10
		}
	}
}
