pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The episodes of the folder (or what was opened together), in order: a
// picture of each, how much of it was seen, the one that plays lit. A click
// plays it (where it was left), a right click marks it seen or not.
PaneFrame {
	id: root

	title: Video.episode && Video.episode.season > 0 ? `Season ${Video.episode.season}` : "Up next"
	subtitle: {
		const seen = Video.list.filter(p => Video.progressOf(p)?.watched).length;
		return `${Video.list.length} videos${seen > 0 ? ` · ${seen} seen` : ""}`;
	}

	Repeater {
		model: Video.list

		Clickable {
			id: row

			required property string modelData
			required property int index
			readonly property bool playing: row.modelData === Video.path
			readonly property var kept: Video.progressOf(row.modelData)
			readonly property real length: Video.metas[row.modelData]?.duration ?? row.kept?.dur ?? 0
			property string frame: ""

			width: root.bodyWidth
			height: 72
			radius: Theme.radius.medium
			color: row.playing ? Qt.alpha(root.accent, 0.16) : (row.hovered ? Theme.layer2 : "transparent")
			tint: Theme.text
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			onClicked: Video.jump(row.index)
			onRightClicked: Video.setWatched(row.modelData, !row.kept?.watched)

			Component.onCompleted: {
				Video.frameOf(row.modelData, Math.max(5, Math.min(90, (row.length || 600) * 0.12)), file => row.frame = file, 240);
				if (!Video.metas[row.modelData]) Video.probe(row.modelData);
			}

			Item {
				id: thumb

				x: 6
				anchors.verticalCenter: parent.verticalCenter
				width: 100
				height: 58

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.small
					color: Theme.layer2
				}

				Image {
					id: picture

					anchors.fill: parent
					source: row.frame ? "file://" + row.frame : ""
					fillMode: Image.PreserveAspectCrop
					asynchronous: true
					opacity: status === Image.Ready ? (row.kept?.watched && !row.playing ? 0.55 : 1) : 0
					layer.enabled: true

					Behavior on opacity {
						Anim {}
					}
				}

				// how far it was seen
				Rectangle {
					anchors.left: parent.left
					anchors.bottom: parent.bottom
					height: 3
					radius: 1.5
					visible: (row.kept?.dur ?? 0) > 0 && (row.kept?.pos ?? 0) > 5
					width: parent.width * Math.min(1, (row.playing ? Video.position : row.kept?.pos ?? 0) / Math.max(1, row.playing ? Video.duration : (row.kept?.dur ?? 1)))
					color: root.accent
				}

				// the one that plays: bars that move while it does
				Row {
					anchors.centerIn: parent
					spacing: 3
					visible: row.playing

					Repeater {
						model: 3

						Rectangle {
							id: bar

							required property int index

							width: 4
							height: 6
							radius: 2
							color: "white"
							anchors.verticalCenter: parent.verticalCenter

							SequentialAnimation on height {
								running: row.playing && Video.playing
								loops: Animation.Infinite
								NumberAnimation {
									to: 18 - bar.index * 3
									duration: 300 + bar.index * 90
									easing.type: Easing.InOutSine
								}
								NumberAnimation {
									to: 5
									duration: 300 + bar.index * 90
									easing.type: Easing.InOutSine
								}
							}
						}
					}
				}

				Glyph {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 3
					visible: !!row.kept?.watched && !row.playing
					icon: "check_circle"
					size: 16
					color: "white"
					surface: "transparent"
				}
			}

			Column {
				anchors.left: thumb.right
				anchors.leftMargin: 12
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 2

				StyledText {
					width: parent.width
					text: Video.episodeOf(row.modelData)?.label ?? `${row.index + 1}`
					tone: row.playing ? root.accent : Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				StyledText {
					width: parent.width
					text: Video.titleOf(row.modelData)
					wrapMode: Text.WordWrap
					maximumLineCount: 2
					font.weight: row.playing ? Font.DemiBold : Font.Normal
				}

				StyledText {
					width: parent.width
					visible: row.length > 0
					text: {
						const left = row.length - (row.kept?.pos ?? 0);
						if (row.kept?.watched) return `${Video.formatTime(row.length)} · seen`;
						if ((row.kept?.pos ?? 0) > 15) return `${Math.max(1, Math.round(left / 60))} min left`;
						return Video.formatTime(row.length);
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}
		}
	}
}
