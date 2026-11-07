pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"
import "../viewer"
import "Edit.js" as Edit

// Text: a click on words of the page makes them a correction – the old
// words are covered (and taken out of the file under the cover) and written
// anew in a font that looks like theirs, at their size and colour. What a
// PDF really is allows no more: a paragraph does not flow on by itself.
// Also: covering with a colour, and new words anywhere.
PaneFrame {
	id: root

	property Item dock: null

	readonly property var pens: [
		{ id: "text", label: "Correct words", icon: "format_text" },
		{ id: "textbox", label: "New words", icon: "form_textbox" },
		{ id: "whiteout", label: "Cover", icon: "eraser" }
	]
	readonly property var chosen: Pdf.selected.map(id => Pdf.itemById(id)).filter(item => item && (item.kind === "text" || item.kind === "whiteout" || item.kind === "textbox"))
	readonly property var first: root.chosen[0] ?? null
	readonly property var corrections: Pdf.items.filter(item => item.kind === "text" || item.kind === "whiteout")

	// a corrected line grows to hold its new words (the helper wraps at the box)
	FontMetrics {
		id: measure

		font.family: Edit.family(root.first?.font)
		font.bold: !!root.first?.bold
		font.italic: !!root.first?.italic
		font.pixelSize: 100
	}

	function fitted(item, text) {
		const width = measure.advanceWidth(text) / 100 * (item.size ?? 12) + 2 * (item.pad ?? (item.kind === "textbox" ? 2 : 0)) + 1;
		if (item.kind !== "text" || !item.rect || width <= item.rect[2]) return { text: text };
		return { text: text, rect: [item.rect[0], item.rect[1], Math.round(width * 100) / 100, item.rect[3]] };
	}

	title: "Text"
	subtitle: "Click words on the page to change them"
	onClose: Pdf.tool = ""

	Component.onCompleted: if (!["text", "textbox", "whiteout", "select"].includes(Pdf.draw)) Pdf.draw = "text"

	Connections {
		target: Pdf

		function onToolChanged() {
			if (Pdf.tool === "text" && !["text", "textbox", "whiteout", "select"].includes(Pdf.draw)) Pdf.draw = "text";
		}
	}

	Row {
		width: parent.width
		spacing: 6

		Repeater {
			model: root.pens.concat([{ id: "select", label: "Choose", icon: "cursor_default_outline" }])

			delegate: Clickable {
				id: key

				required property var modelData
				readonly property bool current: Pdf.draw === key.modelData.id

				width: (parent.width - 18) / 4
				height: 58
				radius: Theme.radius.medium
				color: key.current ? Theme.primarySoft : (key.hovered ? Theme.layer3 : Theme.layer2)
				onClicked: Pdf.draw = key.modelData.id

				Column {
					anchors.centerIn: parent
					spacing: 3

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: key.modelData.icon
						size: 20
						color: key.current ? Theme.primary : Theme.text
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: key.modelData.label
						font.pixelSize: 9
						tone: key.current ? Theme.primary : Theme.textMuted
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
			text: "Click a word: its line opens to be written anew, in a font like its own. Enter finishes, Escape too. Scanned pages have no words to find – make them readable first (Scans).",
			textbox: "Click or drag where new words go, then type.",
			whiteout: "Drag over what should vanish – it is covered, and the words under it are taken out of the file.",
			select: "Click a correction to change its look below, drag it to move it."
		})[Pdf.draw] ?? ""
	}

	EditSwatches {
		visible: Pdf.draw === "whiteout"
		current: Pdf.style.coverColor ?? "#ffffff"
		colors: ["#ffffff", "#f5f5f5", "#fffde7", "#000000", "#eeeeee", "#e3f2fd"]
		onPicked: color => Pdf.setPenStyle({ coverColor: color || "#ffffff" })
	}

	// ── the chosen one ─────────────────────────────────────────────────────
	Rectangle {
		width: parent.width
		visible: !!root.first
		height: look.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.layer2

		Column {
			id: look

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 10

			StyledText {
				text: root.first?.kind === "whiteout" ? "Covered" : (root.first?.was ? `Was: “${root.first.was}”` : "Words")
				width: parent.width
				elide: Text.ElideRight
				font.weight: Font.DemiBold
			}

			Field {
				width: parent.width
				visible: root.first?.kind !== "whiteout"
				text: root.first?.text ?? ""
				placeholder: "The words"
				onAccepted: if (root.first) Pdf.updateItem(root.first.id, root.fitted(root.first, text), "Text changed")
			}

			Segmented {
				width: parent.width
				visible: root.first?.kind !== "whiteout"
				options: [{ value: "Helvetica", label: "Sans" }, { value: "Times-Roman", label: "Serif" }, { value: "Courier", label: "Mono" }]
				current: /times/i.test(root.first?.font ?? "") ? "Times-Roman" : (/courier/i.test(root.first?.font ?? "") ? "Courier" : "Helvetica")
				onSelected: value => Pdf.setOnSelected({ font: value }, false, "Font changed")
			}

			Row {
				spacing: 6
				visible: root.first?.kind !== "whiteout"

				Chip {
					text: "Bold"
					icon: "format_bold"
					selected: !!root.first?.bold
					onClicked: Pdf.setOnSelected({ bold: !root.first.bold }, false, "Bold")
				}

				Chip {
					text: "Italic"
					icon: "format_italic"
					selected: !!root.first?.italic
					onClicked: Pdf.setOnSelected({ italic: !root.first.italic }, false, "Italic")
				}

				Chip {
					text: "Keep what is under"
					visible: root.first?.kind === "text"
					selected: !!root.first?.keepUnder
					onClicked: Pdf.setOnSelected({ keepUnder: !root.first.keepUnder }, false, "Changed")
				}
			}

			TuneSlider {
				width: parent.width
				visible: root.first?.kind !== "whiteout"
				label: "Size"
				from: 0
				to: 48
				step: 0.5
				value: root.first?.size ?? 12
				valueText: `${(root.first?.size ?? 12).toFixed(1)} pt`
				onMoved: value => Pdf.setOnSelected({ size: Math.max(4, value) }, true)
				onCommitted: value => Pdf.setOnSelected({ size: Math.max(4, value) }, false, "Size changed")
			}

			SectionLabel {
				text: root.first?.kind === "whiteout" ? "Colour" : "Colour of the words"
			}

			EditSwatches {
				current: root.first?.kind === "whiteout" ? (root.first?.color ?? "#ffffff") : (root.first?.color ?? "#000000")
				colors: ["#000000", "#333333", "#1a237e", "#b71c1c", "#1b5e20", "#ffffff"]
				onPicked: color => Pdf.setOnSelected({ color: color }, false, "Colour changed")
			}

			SectionLabel {
				visible: root.first?.kind === "text"
				text: "Paper behind it"
			}

			EditSwatches {
				visible: root.first?.kind === "text"
				current: root.first?.coverColor ?? "#ffffff"
				colors: ["#ffffff", "#f5f5f5", "#fffde7", "#000000"]
				onPicked: color => Pdf.setOnSelected({ coverColor: color }, false, "Paper colour")
			}

			TextButton {
				text: "Remove – the old words come back"
				icon: "delete_outline"
				variant: "danger"
				onActivated: Pdf.deleteSelected()
			}
		}
	}

	SectionLabel {
		visible: root.corrections.length > 0
		text: `Changed · ${root.corrections.length}`
	}

	Repeater {
		model: root.corrections

		delegate: Clickable {
			id: row

			required property var modelData

			width: parent.width
			height: 40
			radius: Theme.radius.small
			color: Pdf.selected.includes(row.modelData.id) ? Theme.primarySoft : (row.hovered ? Theme.layer2 : "transparent")
			onClicked: {
				Pdf.goTo(Pdf.indexOf(row.modelData.page), Math.max(0, row.modelData.rect[1] - 60));
				Pdf.draw = "select";
				Pdf.selected = [row.modelData.id];
			}

			Glyph {
				id: glyph

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				icon: Edit.iconOf(row.modelData)
				size: 16
			}

			StyledText {
				anchors.left: glyph.right
				anchors.leftMargin: 10
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				text: row.modelData.kind === "whiteout" ? `Covered · page ${Pdf.indexOf(row.modelData.page) + 1}` : `${row.modelData.was ? row.modelData.was + " → " : ""}${row.modelData.text || "…"}`
				elide: Text.ElideRight
			}
		}
	}
}
