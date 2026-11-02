pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Which channel's suggestions Explore shows: a row of faces, each with how many
// it found. Merged channels are one face stack under their maker's name.
Flow {
	id: root

	// [{id, count}] of the channels with suggestions; id is a source id
	property var channels: []
	property int total: 0
	// "" for all
	property string current: ""

	signal picked(string id)

	spacing: 4

	component Tile: Item {
		id: tile

		property string source: ""
		property string name: ""
		property int count: 0
		readonly property bool selected: root.current === tile.source
		// another one is picked: this one steps back
		readonly property bool faded: root.current !== "" && !tile.selected
		default property alias picture: holder.data

		width: Math.max(104, holder.width + 30)
		height: 112
		opacity: tile.faded && !tileHover.hovered ? 0.55 : 1

		Behavior on opacity {
			Anim {}
		}

		HoverHandler {
			id: tileHover

			cursorShape: Qt.PointingHandCursor
		}
		TapHandler {
			onTapped: root.picked(tile.source)
		}

		Rectangle {
			anchors.fill: parent
			radius: Theme.radius.large
			color: tile.selected ? Theme.layer2 : (tileHover.hovered ? Theme.layer1 : "transparent")

			Behavior on color {
				ColorAnim {}
			}
		}

		// the ring of the one picked
		Rectangle {
			anchors.horizontalCenter: holder.horizontalCenter
			anchors.verticalCenter: holder.verticalCenter
			width: holder.width + 10
			height: holder.height + 10
			radius: height / 2
			color: "transparent"
			border.width: 2.5
			border.color: Theme.primary
			opacity: tile.selected ? 1 : 0
			scale: tile.selected ? 1 : 0.85

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Item {
			id: holder

			anchors.horizontalCenter: parent.horizontalCenter
			y: 12
			width: Math.max(56, holder.childrenRect.width)
			height: 56
			scale: tileHover.hovered ? 1.06 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		// how many it found
		Rectangle {
			x: holder.x + holder.width - width + 8
			y: holder.y - 4
			width: Math.max(22, countText.implicitWidth + 10)
			height: 22
			radius: 11
			color: tile.selected ? Theme.primary : Theme.layer3
			border.width: 2
			border.color: Theme.bg
			visible: tile.count > 0

			StyledText {
				id: countText

				anchors.centerIn: parent
				text: tile.count
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
				color: tile.selected ? Theme.onPrimary : Theme.text
				tabular: true
			}
		}

		StyledText {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.leftMargin: 4
			anchors.rightMargin: 4
			y: holder.y + holder.height + 10
			horizontalAlignment: Text.AlignHCenter
			text: tile.name
			font.pixelSize: Theme.size.small
			font.weight: tile.selected ? Font.Bold : Font.DemiBold
			color: tile.selected ? Theme.primary : Theme.text
			elide: Text.ElideRight
		}
	}

	Tile {
		source: ""
		name: "All"
		count: root.total

		Rectangle {
			width: 56
			height: 56
			radius: 28
			color: Theme.layer2

			Glyph {
				anchors.centerIn: parent
				icon: "view_grid_outline"
				size: 24
				color: Theme.text
			}
		}
	}

	Repeater {
		model: root.channels

		delegate: Tile {
			id: one

			required property var modelData
			// merged channels: their faces fanned, the one with the most videos in front
			readonly property var members: Streams.groupOf(one.modelData.id).slice().sort((a, b) => (a.kind === "twitch") - (b.kind === "twitch") || (b.videos ?? 0) - (a.videos ?? 0)).slice(0, 3)

			source: one.modelData.id
			name: Streams.makerName(Streams.groupOf(one.modelData.id))
			count: one.modelData.count

			Repeater {
				model: one.members.length

				delegate: Item {
					id: face

					required property int index
					readonly property var item: one.members[one.members.length - 1 - face.index]

					x: face.index * 18
					z: face.index
					width: 56
					height: 56

					Rectangle {
						anchors.centerIn: parent
						width: 60
						height: 60
						radius: 30
						color: Theme.bg
						visible: one.members.length > 1
					}
					Avatar {
						anchors.fill: parent
						source: face.item?.avatar ?? ""
						name: face.item?.name ?? ""
						colors: face.item?.colors ?? null
						live: face.item?.live ?? false
					}
				}
			}
		}
	}
}
