pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"
import "../viewer"
import "Edit.js" as Edit

// Marks: pens for text (highlight, underline, strike, wavy), drawing by
// hand, shapes, notes, text boxes and links – all real annotations, so any
// viewer shows them and they stay editable here. Each pen keeps its own
// colour and width. What is chosen on the page is changed here too, and
// every mark of the file is listed below, a click goes to it.
PaneFrame {
	id: root

	property Item dock: null

	readonly property var pens: [
		{ id: "select", label: "Choose", icon: "cursor_default_outline", key: "V" },
		{ id: "highlight", label: "Highlight", icon: "marker", key: "H" },
		{ id: "underline", label: "Underline", icon: "format_underline", key: "U" },
		{ id: "strike", label: "Strike", icon: "format_strikethrough_variant", key: "" },
		{ id: "squiggly", label: "Wavy", icon: "wave", key: "" },
		{ id: "pen", label: "Pen", icon: "draw", key: "P" },
		{ id: "marker", label: "Marker", icon: "format_color_highlight", key: "M" },
		{ id: "eraser", label: "Eraser", icon: "eraser", key: "E" },
		{ id: "rect", label: "Box", icon: "rectangle_outline", key: "R" },
		{ id: "ellipse", label: "Circle", icon: "circle_outline", key: "O" },
		{ id: "line", label: "Line", icon: "vector_line", key: "L" },
		{ id: "arrow", label: "Arrow", icon: "arrow_top_right", key: "A" },
		{ id: "note", label: "Note", icon: "note_text_outline", key: "N" },
		{ id: "textbox", label: "Text box", icon: "form_textbox", key: "T" },
		{ id: "link", label: "Link", icon: "link_variant", key: "" }
	]
	readonly property string pen: Pdf.draw
	readonly property bool lined: ["pen", "marker", "rect", "ellipse", "line", "arrow"].includes(root.pen)
	readonly property bool filled: ["rect", "ellipse", "textbox"].includes(root.pen)
	readonly property var chosen: Pdf.selected.map(id => Pdf.itemById(id)).filter(item => !!item)
	readonly property var first: root.chosen[0] ?? null

	title: "Mark"
	subtitle: "Annotations any viewer shows – and that stay editable"
	onClose: Pdf.tool = ""

	Component.onCompleted: {
		if (!root.pens.some(p => p.id === Pdf.draw)) Pdf.draw = "highlight";
	}

	// ── pens ───────────────────────────────────────────────────────────────
	Grid {
		width: parent.width
		columns: 5
		spacing: 4

		Repeater {
			model: root.pens

			delegate: Clickable {
				id: penKey

				required property var modelData
				readonly property bool current: Pdf.draw === penKey.modelData.id

				width: (parent.width - 16) / 5
				height: 52
				radius: Theme.radius.medium
				color: penKey.current ? Theme.primarySoft : (penKey.hovered ? Theme.layer3 : Theme.layer2)
				onClicked: Pdf.draw = penKey.modelData.id

				Behavior on color {
					ColorAnim {}
				}

				Column {
					anchors.centerIn: parent
					spacing: 2

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: penKey.modelData.icon
						size: 20
						color: penKey.current ? Theme.primary : Theme.text
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: penKey.modelData.label + (penKey.modelData.key ? ` ${penKey.modelData.key}` : "")
						font.pixelSize: 9
						tone: penKey.current ? Theme.primary : Theme.textMuted
					}
				}
			}
		}
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: ({
			select: "Click a mark to choose it, Shift for more; drag to move, the corners to resize. Delete removes, Ctrl+D doubles, the arrows nudge.",
			highlight: "Select words on the page – they are marked when you let go.",
			underline: "Select words to underline them.",
			strike: "Select words to strike them out.",
			squiggly: "Select words for a wavy line under them.",
			pen: "Draw freely; the line is smoothed when you let go.",
			marker: "A wide translucent stroke by hand.",
			eraser: "Drag over drawings, lines and marks to take them away.",
			rect: "Drag a box; Shift makes it square.",
			ellipse: "Drag a circle; Shift keeps it round.",
			line: "Drag a line; Shift holds it to 45°.",
			arrow: "Drag from the start to where it points; Shift holds it to 45°.",
			note: "Click where the note goes, then write it.",
			textbox: "Drag a box or just click, then type. Ctrl+Enter finishes.",
			link: "Drag a box over what should lead somewhere, then give an address or a page number."
		})[root.pen] ?? ""
	}

	// ── how the pen draws ──────────────────────────────────────────────────
	Column {
		width: parent.width
		spacing: 10
		visible: root.pen !== "select" && root.pen !== "eraser" && root.pen !== "link"

		SectionLabel {
			text: "Colour"
		}

		EditSwatches {
			current: Pdf.style.color ?? ""
			onPicked: color => Pdf.setPenStyle({ color: color })
		}

		TuneSlider {
			width: parent.width
			visible: root.lined
			label: "Width"
			from: 0
			to: 12
			step: 0.5
			value: Pdf.style.width ?? 2
			valueText: `${(Pdf.style.width ?? 2).toFixed(1)} pt`
			onCommitted: value => Pdf.setPenStyle({ width: Math.max(0.5, value) })
		}

		TuneSlider {
			width: parent.width
			visible: root.pen !== "note" && root.pen !== "textbox"
			label: "Opacity"
			from: 0
			to: 1
			step: 0.05
			value: Pdf.style.opacity ?? 1
			valueText: `${Math.round((Pdf.style.opacity ?? 1) * 100)} %`
			onCommitted: value => Pdf.setPenStyle({ opacity: Math.max(0.05, value) })
		}

		TuneSlider {
			width: parent.width
			visible: root.pen === "textbox"
			label: "Size"
			from: 0
			to: 48
			step: 1
			value: Pdf.style.size ?? 12
			valueText: `${Pdf.style.size ?? 12} pt`
			onCommitted: value => Pdf.setPenStyle({ size: Math.max(5, value) })
		}

		Segmented {
			width: parent.width
			visible: root.pen === "textbox"
			options: [{ value: "Helvetica", label: "Sans" }, { value: "Times-Roman", label: "Serif" }, { value: "Courier", label: "Mono" }]
			current: Pdf.style.font ?? "Helvetica"
			onSelected: value => Pdf.setPenStyle({ font: value })
		}

		SectionLabel {
			visible: root.filled
			text: "Filled with"
		}

		EditSwatches {
			visible: root.filled
			allowNone: true
			current: Pdf.style.fill ?? ""
			onPicked: color => Pdf.setPenStyle({ fill: color })
		}
	}

	// ── what is chosen ─────────────────────────────────────────────────────
	Rectangle {
		width: parent.width
		visible: root.chosen.length > 0
		height: chosenColumn.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.layer2

		Column {
			id: chosenColumn

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 10

			Row {
				spacing: 8

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: Edit.iconOf(root.first)
					size: 18
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: root.chosen.length === 1 ? Edit.nameOf(root.first) : `${root.chosen.length} chosen`
					font.weight: Font.DemiBold
				}
			}

			StyledText {
				width: parent.width
				visible: !!root.first?.text && root.chosen.length === 1 && ["highlight", "underline", "strike", "squiggly"].includes(root.first?.kind)
				text: `“${root.first?.text ?? ""}”`
				wrapMode: Text.WordWrap
				maximumLineCount: 3
				elide: Text.ElideRight
				tone: Theme.textMuted
				font.italic: true
			}

			EditSwatches {
				visible: root.chosen.some(item => !["image", "signature", "redact", "link", "field", "whiteout"].includes(item.kind))
				current: root.first?.color ?? ""
				onPicked: color => Pdf.setOnSelected({ color: color }, false, "Colour changed")
			}

			TuneSlider {
				width: parent.width
				visible: root.chosen.some(item => ["ink", "rect", "ellipse", "line", "arrow"].includes(item.kind))
				label: "Width"
				from: 0
				to: 12
				step: 0.5
				value: root.first?.width ?? 2
				onMoved: value => Pdf.setOnSelected({ width: Math.max(0.5, value) }, true)
				onCommitted: value => Pdf.setOnSelected({ width: Math.max(0.5, value) }, false, "Width changed")
			}

			TuneSlider {
				width: parent.width
				visible: root.chosen.some(item => ["ink", "rect", "ellipse", "line", "arrow", "highlight", "image"].includes(item.kind))
				label: "Opacity"
				from: 0
				to: 1
				step: 0.05
				value: root.first?.opacity ?? 1
				onMoved: value => Pdf.setOnSelected({ opacity: Math.max(0.05, value) }, true)
				onCommitted: value => Pdf.setOnSelected({ opacity: Math.max(0.05, value) }, false, "Opacity changed")
			}

			TuneSlider {
				width: parent.width
				visible: root.chosen.some(item => ["textbox", "text"].includes(item.kind))
				label: "Size"
				from: 0
				to: 48
				step: 0.5
				value: root.first?.size ?? 12
				onMoved: value => Pdf.setOnSelected({ size: Math.max(4, value) }, true)
				onCommitted: value => Pdf.setOnSelected({ size: Math.max(4, value) }, false, "Size changed")
			}

			// a comment that goes with the mark (shown by other viewers as its note)
			AreaField {
				id: comment

				width: parent.width
				height: 64
				visible: root.chosen.length === 1 && root.first?.kind !== "textbox" && root.first?.kind !== "text"
				placeholder: root.first?.kind === "note" ? "What the note says" : "A comment on it"
				text: root.first?.kind === "note" ? (root.first?.text ?? "") : (root.first?.note ?? "")
				onEdited: text => noteSave.restart()

				Timer {
					id: noteSave

					interval: 700
					onTriggered: {
						if (!root.first) return;
						const now = root.first.kind === "note" ? (root.first.text ?? "") : (root.first.note ?? "");
						if (comment.text !== now) Pdf.updateItem(root.first.id, root.first.kind === "note" ? { text: comment.text } : { note: comment.text }, "Comment written");
					}
				}
			}

			Flow {
				width: parent.width
				spacing: 6

				TextButton {
					text: "Double"
					icon: "content_duplicate"
					onActivated: Pdf.duplicateSelected()
				}

				TextButton {
					text: "Edit words"
					icon: "pencil_outline"
					visible: root.chosen.length === 1 && ["textbox", "text", "note", "link", "field"].includes(root.first?.kind)
					onActivated: Pdf.editingText = root.first.id
				}

				TextButton {
					text: "Remove"
					icon: "delete_outline"
					variant: "danger"
					onActivated: Pdf.deleteSelected()
				}
			}
		}
	}

	// ── every mark of the file ─────────────────────────────────────────────
	SectionLabel {
		visible: Pdf.items.length > 0
		text: `All marks · ${Pdf.items.length}`
	}

	Repeater {
		model: {
			// in page order, then down the page
			const order = {};
			Pdf.pages.forEach((p, i) => order[p.id] = i);
			return Pdf.items.filter(item => order[item.page] !== undefined).slice().sort((a, b) => (order[a.page] - order[b.page]) || (Pdf.boundsOf(a)[1] - Pdf.boundsOf(b)[1])).slice(0, 400);
		}

		delegate: Clickable {
			id: row

			required property var modelData
			readonly property bool chosen: Pdf.selected.includes(row.modelData.id)
			readonly property string words: row.modelData.text || row.modelData.note || row.modelData.label || row.modelData.url || ""

			width: parent.width
			height: 44
			radius: Theme.radius.small
			color: row.chosen ? Theme.primarySoft : (row.hovered ? Theme.layer2 : "transparent")
			onClicked: {
				const i = Pdf.indexOf(row.modelData.page);
				Pdf.goTo(i, Math.max(0, Pdf.boundsOf(row.modelData)[1] - 40));
				Pdf.draw = "select";
				Pdf.selected = [row.modelData.id];
			}

			Rectangle {
				id: dot

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				width: 26
				height: 26
				radius: 8
				color: Qt.alpha(row.modelData.color || "#888888", 0.25)

				Glyph {
					anchors.centerIn: parent
					icon: Edit.iconOf(row.modelData)
					size: 15
					color: row.modelData.color && row.modelData.color !== "#ffffff" ? row.modelData.color : Theme.text
				}
			}

			Column {
				anchors.left: dot.right
				anchors.leftMargin: 10
				anchors.right: parent.right
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter

				StyledText {
					width: parent.width
					text: row.words !== "" ? row.words : Edit.nameOf(row.modelData)
					elide: Text.ElideRight
				}

				StyledText {
					text: `${Edit.nameOf(row.modelData)} · page ${Pdf.indexOf(row.modelData.page) + 1}${row.modelData.author ? " · " + row.modelData.author : ""}`
					font.pixelSize: Theme.size.tiny
					tone: Theme.textSubtle
				}
			}
		}
	}

	// the marked words and the notes, as text
	TextButton {
		visible: Pdf.items.some(item => item.text || item.note)
		text: "Copy the marked words and notes"
		icon: "content_copy"
		onActivated: {
			const lines = [];
			const order = {};
			Pdf.pages.forEach((p, i) => order[p.id] = i);
			for (const item of Pdf.items.slice().sort((a, b) => (order[a.page] - order[b.page]) || (Pdf.boundsOf(a)[1] - Pdf.boundsOf(b)[1]))) {
				const words = [item.text, item.note].filter(t => t).join(" — ");
				if (words) lines.push(`p. ${order[item.page] + 1}: ${words}`);
			}
			Quickshell.execDetached(["wl-copy", "--", lines.join("\n")]);
			Sounds.play("copied");
			Pdf.say(`${lines.length} copied`, "content_copy");
		}
	}
}
