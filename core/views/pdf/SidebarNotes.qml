pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Every mark and note of the file, in the order of its pages: what kind,
// its words or the text marked, by whom. A click goes there and chooses it.
Item {
	id: root

	readonly property var kinds: ({
		highlight: ["marker", "Marked"], underline: ["format_underline", "Underlined"], strike: ["format_strikethrough_variant", "Struck out"],
		squiggly: ["format_underline", "Underlined"], ink: ["draw", "Drawn"], rect: ["square_outline", "Box"], ellipse: ["circle_outline", "Circle"],
		line: ["vector_line", "Line"], arrow: ["arrow_top_right", "Arrow"], note: ["note_outline", "Note"], textbox: ["format_text", "Text box"],
		stamp: ["stamper", "Stamp"], link: ["link_variant", "Link"], field: ["form_textbox", "Field"], text: ["format_text_variant_outline", "Text changed"],
		whiteout: ["eraser", "Covered"], image: ["image_outline", "Picture"], signature: ["draw_pen", "Signature"], redact: ["marker_cancel", "Blacked out"]
	})

	readonly property var rows: {
		const order = {};
		Pdf.pages.forEach((p, i) => order[p.id] = i);
		return Pdf.items.filter(item => order[item.page] !== undefined).slice().sort((a, b) => order[a.page] - order[b.page] || ((a.rect?.[1] ?? a.at?.[1] ?? a.quads?.[0]?.[1] ?? 0) - (b.rect?.[1] ?? b.at?.[1] ?? b.quads?.[0]?.[1] ?? 0))).map(item => ({ item: item, index: order[item.page] }));
	}

	ListView {
		id: list

		anchors.fill: parent
		model: root.rows
		spacing: 4
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		section.property: "index"
		section.delegate: StyledText {
			required property string section

			leftPadding: 12
			topPadding: 8
			bottomPadding: 2
			text: `Page ${Number(section) + 1}`
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		delegate: Clickable {
			id: row

			required property var modelData
			readonly property var item: row.modelData.item
			readonly property var kind: root.kinds[row.item.kind] ?? ["shape_outline", row.item.kind]
			readonly property string words: row.item.note && row.item.note.trim() ? row.item.note : (row.item.text || "")
			readonly property bool chosen: Pdf.selected.includes(row.item.id)

			x: 6
			width: list.width - 12
			height: Math.max(40, column.implicitHeight + 14)
			radius: Theme.radius.small
			color: row.chosen ? Theme.primarySoft : (row.hovered ? Theme.layer1 : "transparent")
			onClicked: {
				const y = row.item.rect?.[1] ?? row.item.at?.[1] ?? row.item.quads?.[0]?.[1] ?? row.item.points?.[0]?.[1] ?? -1;
				Pdf.goTo(row.modelData.index, y);
				Pdf.selected = [row.item.id];
			}

			Rectangle {
				id: swatch

				x: 8
				anchors.verticalCenter: parent.verticalCenter
				width: 26
				height: 26
				radius: 13
				color: Qt.alpha(row.item.color || (row.item.kind === "redact" ? "#000000" : Theme.primary), 0.22)

				Glyph {
					anchors.centerIn: parent
					icon: row.kind[0]
					size: 15
					color: row.item.kind === "redact" ? Theme.text : Theme.legible(row.item.color || Theme.primary, 3)
				}
			}

			Column {
				id: column

				anchors.left: swatch.right
				anchors.leftMargin: 8
				anchors.right: parent.right
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				spacing: 2

				StyledText {
					width: parent.width
					text: row.kind[1] + (row.item.author ? `  ·  ${row.item.author}` : "")
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
				StyledText {
					width: parent.width
					visible: row.words !== ""
					text: row.words
					wrapMode: Text.WordWrap
					maximumLineCount: 3
					elide: Text.ElideRight
				}
			}
		}
	}

	Column {
		anchors.centerIn: parent
		spacing: 8
		visible: root.rows.length === 0

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: "comment_text_multiple_outline"
			size: 32
			color: Theme.textFaint
		}
		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 200
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.WordWrap
			text: "No marks yet – select text and choose a colour"
			tone: Theme.textSubtle
		}
	}
}
