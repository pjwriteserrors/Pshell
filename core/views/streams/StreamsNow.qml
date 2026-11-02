import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// In the media panel: which episode of which series this is, and the series'
// steps. A click opens the series.
Clickable {
	id: root

	readonly property var item: Streams.playing
	readonly property var series: Streams.seriesById[root.item?.series] ?? null

	implicitHeight: 56
	radius: Theme.radius.medium
	color: Theme.layer2
	onClicked: Streams.open({ page: "series", series: root.item.series })

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 10
		spacing: 6

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: root.series?.name ?? ""
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}
			StyledText {
				text: `Episode ${root.item?.number ?? ""} of ${root.item?.total ?? ""}`
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				tabular: true
			}
		}
		EpisodeSteps {
			Layout.fillWidth: true
			cells: root.series?.cells ?? []
			total: root.series?.total ?? 0
			done: root.series?.partial ?? 0
			accent: Streams.accent(root.series?.colors)
		}
	}
}
