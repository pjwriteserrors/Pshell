import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A series: its picture with the name on it, the steps along the picture's
// foot, what is next under it. The steps move as episodes come or get watched.
CardFrame {
	id: root

	property string seriesId: ""
	readonly property var item: Streams.seriesById[root.seriesId] ?? null

	signal opened(var from)

	source: root.item?.picture ?? ""
	colors: root.item?.colors ?? null
	spoiler: root.item?.spoiler ?? false
	accent: Streams.accent(root.item?.colors)
	dimmed: root.item?.status === "paused"
	onClicked: root.opened(root.picture)
	onHoveredChanged: if (root.hovered) Streams.prefetch([root.item?.next?.id])

	overlay: [
		// the foot of the picture is dark, for the name
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: parent.height * 0.6
			bottomLeftRadius: Theme.radius.large
			bottomRightRadius: Theme.radius.large
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0)
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0.86)
				}
			}
		},
		Text {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: steps.top
			anchors.margins: 12
			anchors.bottomMargin: 8
			text: root.item?.name ?? ""
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.heading
			font.weight: Font.Black
			elide: Text.ElideRight
		},
		EpisodeSteps {
			id: steps

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 12
			barHeight: 5
			cells: root.item?.cells ?? []
			total: root.item?.total ?? 0
			done: root.item?.partial ?? 0
			accent: "white"
		},
		// new episodes
		Rectangle {
			x: 10
			y: 10
			visible: (root.item?.fresh ?? 0) > 0
			implicitWidth: freshWord.implicitWidth + 14
			implicitHeight: 22
			radius: 6
			color: root.accent

			Text {
				id: freshWord

				anchors.centerIn: parent
				text: root.item?.fresh === 1 ? "NEW" : `${root.item?.fresh ?? 0} NEW`
				color: Theme.contrast(root.accent, "#000000") > 4.5 ? "black" : "white"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Black
				font.letterSpacing: 0.6
			}
		},
		Glyph {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 10
			visible: root.item?.status === "paused"
			icon: "sleep"
			size: 18
			color: "white"
			surface: "black"
		},
		PlayMark {
			shown: root.hovered && !!root.item?.next
			onClicked: Streams.playNext(root.seriesId)
		}
	]

	ColumnLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 1

		StyledText {
			Layout.fillWidth: true
			text: {
				const item = root.item;
				if (!item) return "";
				if (item.status === "paused") return item.waiting > 0 ? `Resting · ${item.waiting} waiting` : "Resting";
				if (!item.next) return item.total > 0 ? "All watched" : (item.sourceNames.join(", ") || "Nothing yet");
				if (item.spoiler && !root.hovered) return `Episode ${item.next.n}`;
				return item.next.title;
			}
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}
		StyledText {
			Layout.fillWidth: true
			text: (root.item?.left ?? 0) > 0 ? `${root.item.watched} of ${root.item.total} · ${Streams.span(root.item.remaining)} left` : `${root.item?.total ?? 0} episodes`
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			tabular: true
			elide: Text.ElideRight
		}
	}
}
