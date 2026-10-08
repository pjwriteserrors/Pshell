pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Every command at a glance: a group to a band, its name on the left, its
// commands as tiles in rows of four. Tiles keep their place while a filter
// is typed; what does not match steps back.
Item {
	id: root

	// [{ label, cells: [{ index, command, glyph, match, pinned }] }]
	property var sections: []
	property int current: -1

	readonly property int columns: 4
	readonly property real labelWidth: 86
	readonly property real tileHeight: 46
	readonly property real gap: 6
	readonly property real bandGap: 14
	readonly property real contentHeight: root.sections.reduce((sum, section) => {
		const rows = Math.ceil(section.cells.length / root.columns);
		return sum + rows * root.tileHeight + (rows - 1) * root.gap;
	}, 0) + Math.max(0, root.sections.length - 1) * root.bandGap

	signal pointed(int index)
	signal activated(int index)
	signal pinRequested(int index)

	Flickable {
		anchors.fill: parent
		clip: true
		contentHeight: bands.height
		boundsBehavior: Flickable.StopAtBounds

		Column {
			id: bands

			width: parent.width
			spacing: root.bandGap

			Repeater {
				model: root.sections.length

				delegate: Item {
					id: band

					required property int index

					readonly property var section: root.sections[band.index] || ({ label: "", cells: [] })

					width: bands.width
					height: grid.height

					SectionLabel {
						y: (root.tileHeight - height) / 2
						width: root.labelWidth - 10
						text: band.section.label
					}

					Grid {
						id: grid

						x: root.labelWidth
						width: parent.width - root.labelWidth
						columns: root.columns
						spacing: root.gap

						Repeater {
							model: band.section.cells.length

							delegate: CommandTile {
								id: tile

								required property int index

								readonly property var cell: band.section.cells[tile.index] || null

								width: (grid.width - (root.columns - 1) * root.gap) / root.columns
								height: root.tileHeight
								command: tile.cell?.command ?? null
								glyph: tile.cell?.glyph ?? "console"
								selected: tile.cell !== null && tile.cell.index === root.current
								dimmed: tile.cell !== null && !tile.cell.match
								pinned: tile.cell?.pinned ?? false
								onPointed: if (tile.cell) root.pointed(tile.cell.index)
								onClicked: if (tile.cell) root.activated(tile.cell.index)
								onRightClicked: if (tile.cell) root.pinRequested(tile.cell.index)
							}
						}
					}
				}
			}
		}
	}
}
