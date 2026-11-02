import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One episode in a row: fresh from its series.
CardFrame {
	id: root

	property var episode: null
	property var seriesItem: null

	source: root.episode?.thumb ?? ""
	colors: root.seriesItem?.colors ?? null
	spoiler: root.seriesItem?.spoiler ?? false
	accent: Streams.accent(root.seriesItem?.colors)
	onClicked: Streams.play(root.episode.id)

	overlay: [
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 4
			visible: (root.episode?.progress ?? 0) > 0
			color: Qt.rgba(1, 1, 1, 0.25)

			Rectangle {
				height: parent.height
				width: parent.width * (root.episode?.progress ?? 0)
				color: root.accent
			}
		},
		PlayMark {
			shown: root.hovered
			onClicked: Streams.play(root.episode.id)
		}
	]

	ColumnLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 1

		StyledText {
			Layout.fillWidth: true
			text: root.seriesItem?.spoiler && !root.hovered ? `Episode ${root.episode?.n}` : (root.episode?.title ?? "")
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}
		StyledText {
			Layout.fillWidth: true
			text: [root.seriesItem?.name, Streams.ago(root.episode?.published)].filter(part => !!part).join(" · ")
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			elide: Text.ElideRight
		}
	}
}
