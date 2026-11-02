import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One video of a channel: where it stopped along the picture's foot, how long
// it is in the corner; dim when watched. The check on hover marks it.
CardFrame {
	id: root

	property var video: null
	readonly property var channel: Streams.sourceById[root.video?.source] ?? null
	readonly property bool watched: !!root.video?.watched

	source: root.video?.thumb ?? ""
	colors: root.channel?.colors ?? null
	accent: Streams.accent(root.channel?.colors)
	dimmed: root.watched
	onClicked: Streams.play(root.video.id)
	onHoveredChanged: if (root.hovered) Streams.prefetch([root.video?.id])

	overlay: [
		Rectangle {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 8
			visible: (root.video?.duration ?? 0) > 0
			implicitWidth: lengthWord.implicitWidth + 12
			implicitHeight: 22
			radius: 5
			color: Qt.rgba(0, 0, 0, 0.78)

			Text {
				id: lengthWord

				anchors.centerIn: parent
				text: Streams.clock(root.video?.duration)
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				font.features: { "tnum": 1 }
			}
		},
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 5
			visible: (root.video?.progress ?? 0) > 0 && !root.watched
			bottomLeftRadius: Theme.radius.large
			bottomRightRadius: Theme.radius.large
			color: Qt.rgba(1, 1, 1, 0.3)

			Rectangle {
				height: parent.height
				width: parent.width * (root.video?.progress ?? 0)
				color: root.accent
			}
		},
		Rectangle {
			x: 8
			y: 8
			width: 30
			height: 30
			radius: 15
			color: root.watched ? root.accent : Qt.rgba(0, 0, 0, 0.62)
			opacity: root.hovered || root.watched ? 1 : 0
			visible: opacity > 0.01
			scale: markArea.pressed ? 0.82 : (markArea.containsMouse ? 1.14 : 1)

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "check_bold"
				size: 16
				color: "white"
				surface: "black"
			}
			MouseArea {
				id: markArea

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: Streams.mark(root.video.id, !root.watched)
			}
		},
		PlayMark {
			shown: root.hovered
			onClicked: Streams.play(root.video.id)
		}
	]

	RowLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 10

		Avatar {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			Layout.alignment: Qt.AlignTop
			source: root.channel?.avatar ?? ""
			name: root.channel?.name ?? ""
			colors: root.channel?.colors ?? null
		}
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.video?.title ?? ""
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
				tone: root.watched ? Theme.textMuted : Theme.text
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				text: {
					const parts = [root.channel?.name, Streams.ago(root.video?.published)];
					if ((root.video?.position ?? 0) > 0 && !root.watched) parts.push(`stopped at ${Streams.clock(root.video.position)}`);
					return parts.filter(word => !!word).join(" · ");
				}
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
		}
	}
}
