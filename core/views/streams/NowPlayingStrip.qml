import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What plays: which episode of which series, and how far along it is.
Clickable {
	id: root

	readonly property var item: Streams.playing
	readonly property color accent: Streams.accent(Streams.seriesById[root.item?.series]?.colors)

	implicitHeight: root.item ? 62 : 0
	radius: Theme.radius.medium
	color: Theme.layer3
	clip: true
	opacity: root.item ? 1 : 0
	onClicked: if (root.item?.series) Streams.open({ page: "series", series: root.item.series })

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.long
		}
	}
	Behavior on opacity {
		Anim {}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 9
		spacing: 3

		StyledText {
			Layout.fillWidth: true
			text: root.item?.series ? `${root.item.seriesName} · ${root.item.number} of ${root.item.total}` : "Playing"
			font.pixelSize: Theme.size.tiny
			tone: Theme.textMuted
			elide: Text.ElideRight
		}
		StyledText {
			Layout.fillWidth: true
			text: root.item?.title ?? ""
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 3
			radius: 2
			color: Qt.alpha(Theme.text, 0.13)

			Rectangle {
				height: parent.height
				radius: 2
				color: root.accent
				width: parent.width * ((root.item?.duration ?? 0) > 0 ? Math.min(1, root.item.position / root.item.duration) : 0)

				Behavior on width {
					Anim {
						duration: Motion.extraLong
					}
				}
			}
		}
	}
}
