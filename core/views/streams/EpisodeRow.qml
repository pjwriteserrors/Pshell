import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One episode: its number, its picture with how far it got, what happens in it.
// The check springs; on hover it can go elsewhere too.
Item {
	id: root

	required property var episode
	property var seriesItem: null
	readonly property color accent: Streams.accent(root.seriesItem?.colors)
	readonly property bool isNext: root.seriesItem?.next?.id === root.episode?.id
	readonly property bool hovered: hover.hovered
	readonly property bool veiled: !!root.seriesItem?.spoiler && !root.episode?.watched && !hover.hovered

	signal checkClicked(var episode)
	signal recapWanted(var episode)

	implicitHeight: 112

	HoverHandler {
		id: hover

		onHoveredChanged: if (hovered) Streams.prefetch([root.episode?.id])
	}

	// the next one is lit from the left in the series' colour
	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		visible: root.isNext || hover.hovered
		color: Qt.alpha(Theme.text, hover.hovered ? 0.07 : 0)
		gradient: root.isNext && !hover.hovered ? nextLight : null

		Gradient {
			id: nextLight

			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Qt.alpha(root.accent, 0.3)
			}
			GradientStop {
				position: 0.7
				color: Qt.alpha(root.accent, 0)
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		onClicked: Streams.play(root.episode.id)
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 10
		anchors.rightMargin: 14
		anchors.topMargin: 8
		anchors.bottomMargin: 8
		spacing: 16

		Text {
			Layout.preferredWidth: 48
			horizontalAlignment: Text.AlignRight
			text: root.episode?.number ?? root.episode?.n ?? ""
			color: root.isNext ? root.accent : (root.episode?.watched ? Theme.textFaint : Theme.textSubtle)
			font.family: Theme.fontFamily
			font.pixelSize: 28
			font.weight: Font.Black
			font.features: { "tnum": 1 }
		}

		Thumb {
			id: picture

			Layout.preferredWidth: 170
			Layout.fillHeight: true
			radius: Theme.radius.medium
			source: root.episode?.thumb ?? ""
			colors: root.seriesItem?.colors ?? null
			spoiler: root.veiled
			dimmed: root.episode?.watched ?? false
			zoom: hover.hovered ? 1.06 : 1

			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: 4
				bottomLeftRadius: Theme.radius.medium
				bottomRightRadius: Theme.radius.medium
				color: Qt.rgba(1, 1, 1, 0.25)
				visible: (root.episode?.progress ?? 0) > 0 && !root.episode?.watched

				Rectangle {
					height: parent.height
					width: parent.width * (root.episode?.progress ?? 0)
					color: root.accent

					Behavior on width {
						Anim {}
					}
				}
			}

			Rectangle {
				anchors.centerIn: parent
				width: 40
				height: 40
				radius: 20
				color: Qt.rgba(0, 0, 0, 0.6)
				border.width: 1.5
				border.color: "white"
				opacity: hover.hovered ? 1 : 0
				scale: hover.hovered ? 1 : 0.6

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
					icon: "play"
					size: 22
					color: "white"
					surface: "black"
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 3

			StyledText {
				Layout.fillWidth: true
				text: root.veiled ? `Episode ${root.episode?.n}` : (root.episode?.title ?? "")
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
				tone: root.episode?.watched ? Theme.textMuted : Theme.text
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				text: {
					const parts = [];
					if (!root.episode?.guessed) parts.push(Streams.ago(root.episode?.published));
					const length = root.episode?.duration || root.episode?.guess;
					if (length) parts.push(`${root.episode?.duration ? "" : "about "}${Streams.span(length)}`);
					const progress = root.episode?.progress ?? 0;
					if (progress > 0 && !root.episode?.watched && root.episode?.duration) parts.push(`Stopped at ${Streams.clock(root.episode.position)}`);
					if (root.episode?.chapters?.length) parts.push(`${root.episode.chapters.length} chapters`);
					return parts.filter(part => !!part).join(" · ");
				}
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				visible: !root.veiled && text !== ""
				text: root.episode?.description ?? ""
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
			}
		}

		Glyph {
			visible: root.episode?.offline ?? false
			icon: "download"
			size: 16
			color: Theme.success
		}
		Spinner {
			visible: root.episode?.offlineBusy ?? false
			Layout.preferredWidth: 16
			Layout.preferredHeight: 16
		}

		Row {
			spacing: 2
			opacity: hover.hovered ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			IconButton {
				width: 32
				height: 32
				icon: "television"
				visible: Streams.hasMpv
				onClicked: Streams.play(root.episode.id, "mpv")
			}
			IconButton {
				width: 32
				height: 32
				icon: "cellphone_play"
				visible: Plugins.on("phone")
				onClicked: Streams.toPhone(root.episode.url, root.episode.position, root.episode.title)
			}
			IconButton {
				width: 32
				height: 32
				icon: "robot_outline"
				onClicked: root.recapWanted(root.episode)
			}
			IconButton {
				width: 32
				height: 32
				icon: "playlist_remove"
				onClicked: Streams.teach(root.seriesItem.id, root.episode.id, "no")
			}
		}

		Rectangle {
			id: check

			Layout.preferredWidth: 30
			Layout.preferredHeight: 30
			radius: 15
			color: root.episode?.watched ? root.accent : "transparent"
			border.width: root.episode?.watched ? 0 : 2
			border.color: checkArea.containsMouse ? root.accent : Theme.textFaint
			scale: checkArea.pressed ? 0.8 : (checkArea.containsMouse ? 1.14 : 1)

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {
					duration: Motion.medium
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "check_bold"
				size: 16
				color: Theme.contrast(root.accent, "#000000") > 4.5 ? "black" : "white"
				opacity: root.episode?.watched ? 1 : 0
				scale: root.episode?.watched ? 1 : 0.3

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}

			MouseArea {
				id: checkArea

				anchors.fill: parent
				anchors.margins: -5
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.checkClicked(root.episode)
			}
		}
	}
}
