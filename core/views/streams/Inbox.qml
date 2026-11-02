pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Videos that might belong to a series: a word from the user settles each,
// and the card makes way.
Rail {
	id: root

	title: "Does this belong?"
	note: Streams.inbox.length > 1 ? `${Streams.inbox.length} to look at` : ""
	keys: Streams.inbox.map(item => ({ key: `${item.series}:${item.video}` }))
	cardHeight: Math.round(root.cardWidth * 9 / 16) + 92
	card: CardFrame {
		property string cardKey: ""
		readonly property var item: Streams.inbox.find(entry => `${entry.series}:${entry.video}` === cardKey) ?? null

		id: frame

		source: frame.item?.thumb ?? ""
		onClicked: {}

		ColumnLayout {
			anchors.left: parent.left
			anchors.right: parent.right
			spacing: 2

			StyledText {
				Layout.fillWidth: true
				text: frame.item?.title ?? ""
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				text: `For ${frame.item?.seriesName ?? ""}`
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
			RowLayout {
				Layout.topMargin: 3
				spacing: 4

				TextButton {
					text: "Belongs"
					icon: "check"
					variant: "tonal"
					onActivated: Streams.teach(frame.item.series, frame.item.video, "yes")
				}
				TextButton {
					text: "No"
					variant: "ghost"
					onActivated: Streams.teach(frame.item.series, frame.item.video, "no")
				}
			}
		}
	}
}
