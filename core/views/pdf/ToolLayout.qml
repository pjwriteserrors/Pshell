pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"
import "../viewer"

// What goes on every page: a watermark (words or a picture), page numbers,
// a header and a footer, Bates numbers for files handed over. Shown on the
// pages at once as they will be written; sliders move them live.
PaneFrame {
	id: root

	property Item dock: null
	property string before: ""

	readonly property var doc: Pdf.recipe.doc ?? ({})
	readonly property var positions: [{ value: "top-left", label: "↖" }, { value: "top", label: "↑" }, { value: "top-right", label: "↗" }, { value: "bottom-left", label: "↙" }, { value: "bottom", label: "↓" }, { value: "bottom-right", label: "↘" }]

	title: "Layout"
	subtitle: "On every page: written when saved, shown now"
	onClose: Pdf.tool = ""

	// one part changed; `live` while a slider moves, kept as one step when let go
	function set(key, changes, live, label) {
		const now = root.doc[key];
		const value = changes === null ? null : Object.assign({}, now ?? root.fresh(key), changes);
		if (live) {
			if (root.before === "") root.before = JSON.stringify(Pdf.recipe);
			const next = Pdf.clone(Pdf.recipe);
			next.doc[key] = value;
			Pdf.preview(next);
			return;
		}
		if (root.before !== "") {
			const next = Pdf.clone(Pdf.recipe);
			next.doc[key] = value;
			Pdf.preview(next);
			Pdf.commitFrom(root.before, label);
			root.before = "";
			return;
		}
		Pdf.setDoc(key, value, label);
	}

	function fresh(key) {
		return ({
			watermark: { text: "CONFIDENTIAL", image: "", size: 60, opacity: 0.15, angle: 45, color: "#888888", pages: "" },
			numbers: { position: "bottom", format: "{n} / {total}", start: 1, from: 1, size: 10 },
			header: { left: "{title}", center: "", right: "{date}", size: 9 },
			footer: { left: "{file}", center: "", right: "Page {n} of {total}", size: 9 },
			bates: { prefix: "", start: 1, digits: 6, position: "bottom-right" }
		})[key];
	}

	component Part: Rectangle {
		id: part

		property string key: ""
		property string label: ""
		property string icon: ""
		default property alias body: inner.data
		readonly property bool on: !!root.doc[part.key]

		width: parent.width
		height: head.height + (part.on ? inner.implicitHeight + 14 : 0) + 12
		radius: Theme.radius.large
		color: part.on ? Theme.layer2 : "transparent"
		border.color: Theme.outline
		clip: true

		Behavior on height {
			SpatialAnim {}
		}

		Item {
			id: head

			width: parent.width
			height: 46

			Glyph {
				id: partIcon

				x: 12
				anchors.verticalCenter: parent.verticalCenter
				icon: part.icon
				size: 18
				color: part.on ? Theme.primary : Theme.text
			}

			StyledText {
				anchors.left: partIcon.right
				anchors.leftMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				text: part.label
				font.weight: Font.DemiBold
			}

			Toggle {
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				checked: part.on
				onToggled: on => root.set(part.key, on ? {} : null, false, on ? `${part.label} on` : `${part.label} off`)
			}
		}

		Column {
			id: inner

			x: 12
			y: head.height
			width: parent.width - 24
			spacing: 8
			opacity: part.on ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "In the words: {n} the page, {total} how many, {date} today, {title} the title, {file} the file's name."
	}

	// ── watermark ──────────────────────────────────────────────────────────
	Part {
		key: "watermark"
		label: "Watermark"
		icon: "watermark"

		Field {
			width: parent.width
			height: 36
			placeholder: "Words"
			text: root.doc.watermark?.text ?? ""
			onAccepted: root.set("watermark", { text: text, image: "" }, false, "Watermark words")
			onFocusedChanged: if (!focused && text !== (root.doc.watermark?.text ?? "")) root.set("watermark", { text: text, image: "" }, false, "Watermark words")
		}

		Row {
			spacing: 6

			TextButton {
				text: root.doc.watermark?.image ? "Another picture…" : "A picture instead…"
				icon: "image_outline"
				onActivated: Files.pick({ title: "A picture as the watermark", filters: ["*.png", "*.jpg", "*.jpeg", "*.webp"] }, paths => {
					if (paths?.length) root.set("watermark", { image: paths[0] }, false, "Watermark picture");
				})
			}

			TextButton {
				visible: !!root.doc.watermark?.image
				text: "Words again"
				variant: "ghost"
				onActivated: root.set("watermark", { image: "" }, false, "Watermark words")
			}
		}

		TuneSlider {
			width: parent.width
			label: "Size"
			from: 0
			to: 200
			step: 1
			value: root.doc.watermark?.size ?? 60
			valueText: `${Math.round(root.doc.watermark?.size ?? 60)}`
			onMoved: value => root.set("watermark", { size: Math.max(6, value) }, true)
			onCommitted: value => root.set("watermark", { size: Math.max(6, value) }, false, "Watermark size")
		}

		TuneSlider {
			width: parent.width
			label: "Seen"
			from: 0
			to: 1
			step: 0.01
			value: root.doc.watermark?.opacity ?? 0.15
			onMoved: value => root.set("watermark", { opacity: Math.max(0.02, value) }, true)
			onCommitted: value => root.set("watermark", { opacity: Math.max(0.02, value) }, false, "Watermark opacity")
		}

		TuneSlider {
			width: parent.width
			label: "Angle"
			from: -90
			to: 90
			step: 1
			value: root.doc.watermark?.angle ?? 45
			valueText: `${Math.round(root.doc.watermark?.angle ?? 45)}°`
			onMoved: value => root.set("watermark", { angle: Math.round(value) }, true)
			onCommitted: value => root.set("watermark", { angle: Math.round(value) }, false, "Watermark angle")
		}

		EditSwatches {
			current: root.doc.watermark?.color ?? "#888888"
			colors: ["#888888", "#000000", "#c62828", "#1565c0", "#2e7d32", "#ff8f00"]
			onPicked: color => root.set("watermark", { color: color }, false, "Watermark colour")
		}

		Field {
			width: parent.width
			height: 36
			placeholder: "Only on pages (e.g. 1-3, 7) – empty: all"
			text: root.doc.watermark?.pages ?? ""
			onAccepted: root.set("watermark", { pages: text }, false, "Watermark pages")
		}
	}

	// ── page numbers ───────────────────────────────────────────────────────
	Part {
		key: "numbers"
		label: "Page numbers"
		icon: "numeric"

		Segmented {
			width: parent.width
			options: root.positions
			current: root.doc.numbers?.position ?? "bottom"
			onSelected: value => root.set("numbers", { position: value }, false, "Numbers moved")
		}

		Flow {
			width: parent.width
			spacing: 6

			Repeater {
				model: ["{n}", "{n} / {total}", "Page {n}", "Page {n} of {total}", "Seite {n} von {total}", "- {n} -"]

				delegate: Chip {
					required property string modelData

					text: modelData.replace("{n}", "3").replace("{total}", "12")
					selected: (root.doc.numbers?.format ?? "") === modelData
					onClicked: root.set("numbers", { format: modelData }, false, "Numbers changed")
				}
			}
		}

		PaneLine {
			label: "Starting at"
			detail: `from page ${root.doc.numbers?.from ?? 1}, counting from ${root.doc.numbers?.start ?? 1}`

			Row {
				spacing: 2

				IconButton {
					icon: "minus"
					onClicked: root.set("numbers", { from: Math.max(1, (root.doc.numbers?.from ?? 1) - 1) }, false, "Numbers start")
				}

				IconButton {
					icon: "plus"
					onClicked: root.set("numbers", { from: Math.min(Pdf.pageCount, (root.doc.numbers?.from ?? 1) + 1) }, false, "Numbers start")
				}

				IconButton {
					icon: "numeric_1_box_outline"
					onClicked: root.set("numbers", { start: (root.doc.numbers?.start ?? 1) + 1 }, false, "Numbers count")
				}
			}
		}

		TuneSlider {
			width: parent.width
			label: "Size"
			from: 0
			to: 24
			step: 0.5
			value: root.doc.numbers?.size ?? 10
			onMoved: value => root.set("numbers", { size: Math.max(5, value) }, true)
			onCommitted: value => root.set("numbers", { size: Math.max(5, value) }, false, "Numbers size")
		}
	}

	// ── header and footer ──────────────────────────────────────────────────
	Repeater {
		model: [{ key: "header", label: "Header", icon: "page_layout_header" }, { key: "footer", label: "Footer", icon: "page_layout_footer" }]

		delegate: Part {
			id: hf

			required property var modelData

			key: hf.modelData.key
			label: hf.modelData.label
			icon: hf.modelData.icon

			Repeater {
				model: [{ part: "left", label: "Left" }, { part: "center", label: "Middle" }, { part: "right", label: "Right" }]

				delegate: Field {
					required property var modelData

					width: hf.width - 24
					height: 34
					placeholder: modelData.label
					text: root.doc[hf.key]?.[modelData.part] ?? ""
					onAccepted: root.set(hf.key, { [modelData.part]: text }, false, `${hf.label} changed`)
					onFocusedChanged: if (!focused && text !== (root.doc[hf.key]?.[modelData.part] ?? "")) root.set(hf.key, { [modelData.part]: text }, false, `${hf.label} changed`)
				}
			}

			TuneSlider {
				width: hf.width - 24
				label: "Size"
				from: 0
				to: 20
				step: 0.5
				value: root.doc[hf.key]?.size ?? 9
				onMoved: value => root.set(hf.key, { size: Math.max(5, value) }, true)
				onCommitted: value => root.set(hf.key, { size: Math.max(5, value) }, false, `${hf.label} size`)
			}
		}
	}

	// ── Bates ──────────────────────────────────────────────────────────────
	Part {
		key: "bates"
		label: "Bates numbers"
		icon: "barcode"

		Field {
			width: parent.width
			height: 34
			placeholder: "Before the number (e.g. ACME-)"
			text: root.doc.bates?.prefix ?? ""
			onAccepted: root.set("bates", { prefix: text }, false, "Bates prefix")
			onFocusedChanged: if (!focused && text !== (root.doc.bates?.prefix ?? "")) root.set("bates", { prefix: text }, false, "Bates prefix")
		}

		Field {
			width: parent.width
			height: 34
			placeholder: "The first number"
			text: String(root.doc.bates?.start ?? 1)
			onAccepted: root.set("bates", { start: Math.max(0, Number(text) || 1) }, false, "Bates start")
		}

		Segmented {
			width: parent.width
			options: [{ value: "4", label: "0001" }, { value: "6", label: "000001" }, { value: "8", label: "00000001" }]
			current: String(root.doc.bates?.digits ?? 6)
			onSelected: value => root.set("bates", { digits: Number(value) }, false, "Bates digits")
		}

		Segmented {
			width: parent.width
			options: root.positions
			current: root.doc.bates?.position ?? "bottom-right"
			onSelected: value => root.set("bates", { position: value }, false, "Bates moved")
		}

		StyledText {
			text: `e.g. ${root.doc.bates?.prefix ?? ""}${String(root.doc.bates?.start ?? 1).padStart(root.doc.bates?.digits ?? 6, "0")}`
			tone: Theme.textMuted
			font.family: Theme.monoFamily
		}
	}
}
