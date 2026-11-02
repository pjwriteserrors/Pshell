import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Someone who is live: what the stream looks like now, who and what.
CardFrame {
	id: root

	property var stream: null

	source: root.stream?.pictureUrl ?? ""
	colors: root.stream?.colors ?? null
	accent: "#e5484d"
	onClicked: Streams.playLive(root.stream.source)

	overlay: [
		Rectangle {
			x: 10
			y: 10
			height: 24
			width: sign.width + 16
			radius: 6
			color: "#e5484d"

			Row {
				id: sign

				anchors.centerIn: parent
				spacing: 6

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: 7
					height: 7
					radius: 4
					color: "white"
					SequentialAnimation on opacity {
						loops: Animation.Infinite
						NumberAnimation {
							to: 0.3
							duration: 800
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 1
							duration: 800
							easing.type: Easing.InOutSine
						}
					}
				}
				Text {
					anchors.verticalCenter: parent.verticalCenter
					text: (root.stream?.viewers ?? 0) > 0 ? Number(root.stream.viewers).toLocaleString(Qt.locale(), "f", 0) : "LIVE"
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					font.weight: Font.Bold
					font.features: { "tnum": 1 }
				}
			}
		},
		Row {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 8
			spacing: 4
			opacity: root.hovered ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {}
			}

			BigButton {
				visible: Streams.hasMpv
				implicitHeight: 34
				implicitWidth: 34
				icon: "picture_in_picture_top_right"
				main: false
				onClicked: Streams.playLive(root.stream.source, { pip: true })
			}
			BigButton {
				visible: root.stream?.platform === "twitch"
				implicitHeight: 34
				implicitWidth: 34
				icon: "chat"
				main: false
				onClicked: Streams.playLive(root.stream.source, { chat: true })
			}
		},
		PlayMark {
			shown: root.hovered
			onClicked: Streams.playLive(root.stream.source)
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
			source: root.stream?.avatar ?? ""
			name: root.stream?.name ?? ""
			colors: root.stream?.colors ?? null
		}
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.stream?.title ?? ""
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				text: {
					const parts = [root.stream?.name, root.stream?.category];
					if (root.stream?.behind) parts.push(`${root.stream.behind.left} behind`);
					return parts.filter(part => !!part).join(" · ");
				}
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
		}
	}
}
