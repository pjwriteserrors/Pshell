pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Out: smaller (with how much smaller it would get, measured on a few pages
// first), grayscale, everything made fixed, PDF/A for keeping; or as other
// files – pictures of the pages, the text, Word or Writer, its tables, the
// pictures in it. What is set to happen "when saved" happens to the file
// itself on saving; the rest makes new files beside it. And the same done
// to other PDFs at once.
PaneFrame {
	id: root

	property Item dock: null
	property string quality: Pdf.recipe.finish?.compress || "recommended"
	property var estimate: null
	property bool estimating: false
	property string imageFormat: "png"
	property string dpi: "150"
	property string office: "docx"
	readonly property var finish: Pdf.recipe.finish ?? ({})
	readonly property var missing: Files.pdfMissing ?? ({})

	title: "Export"
	subtitle: Pdf.meta ? `${Pdf.formatBytes(Pdf.meta.bytes)} · PDF ${Pdf.meta.version ?? ""}` : ""
	onClose: Pdf.tool = ""

	Component.onCompleted: {
		Files.knowPdfTools?.();
		root.measure();
	}

	onQualityChanged: root.measure()

	function measure() {
		if (!Pdf.current) return;
		root.estimating = true;
		Pdf.request("estimate", { path: Pdf.sourcePath("a"), quality: root.quality, password: Pdf.password }, data => {
			root.estimating = false;
			root.estimate = data;
		});
	}

	function lacks(tool) {
		return root.missing[tool] ? `Needs ${root.missing[tool]}` : "";
	}

	// ── smaller ────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Smaller"
	}

	Segmented {
		width: parent.width
		options: [{ value: "light", label: "A little" }, { value: "recommended", label: "Good" }, { value: "strong", label: "Strong" }]
		current: root.quality
		onSelected: value => {
			root.quality = value;
			if (root.finish.compress) Pdf.setFinish("compress", value, "Smaller when saved");
		}
	}

	// before and after, as two bars that grow to their size
	Column {
		width: parent.width
		spacing: 6

		Repeater {
			model: [{ label: "Now", bytes: root.estimate?.before ?? Pdf.meta?.bytes ?? 0 }, { label: "Then", bytes: root.estimate?.after ?? 0 }]

			delegate: Row {
				id: bar

				required property var modelData
				required property int index
				readonly property real most: Math.max(1, root.estimate?.before ?? Pdf.meta?.bytes ?? 1)

				spacing: 8

				StyledText {
					width: 40
					text: bar.modelData.label
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Rectangle {
					width: Math.max(4, (root.bodyWidth - 140) * Math.min(1, bar.modelData.bytes / bar.most))
					height: 14
					radius: 7
					anchors.verticalCenter: parent.verticalCenter
					color: bar.index === 0 ? Theme.textFaint : Theme.primary
					opacity: bar.index === 1 && root.estimating ? 0.4 : 1

					Behavior on width {
						SpatialAnim {
							duration: Motion.long
						}
					}
				}

				StyledText {
					text: bar.index === 1 && root.estimating ? "measuring…" : (bar.modelData.bytes > 0 ? Pdf.formatBytes(bar.modelData.bytes) : "–")
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	StyledText {
		visible: !!root.estimate && root.estimate.after >= root.estimate.before
		width: parent.width
		wrapMode: Text.WordWrap
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		text: "It is about as small as it gets already."
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "A smaller copy"
			icon: "arrow_collapse_all"
			enabled: !root.lacks("compress")
			onActivated: Pdf.runTool("compress", { level: root.quality }, "Made smaller")
		}
	}

	// ── when saved ─────────────────────────────────────────────────────────
	SectionLabel {
		text: "When saved"
	}

	PaneLine {
		label: "Smaller"
		detail: root.lacks("compress") || "The pictures in it made lighter"

		Toggle {
			checked: !!root.finish.compress
			onToggled: on => Pdf.setFinish("compress", on ? root.quality : "", on ? "Smaller when saved" : "Not smaller")
		}
	}

	PaneLine {
		label: "Grayscale"
		detail: root.lacks("grayscale") || "No colours, for printing in black"

		Toggle {
			checked: !!root.finish.grayscale
			onToggled: on => Pdf.setFinish("grayscale", on, on ? "Grayscale when saved" : "In colour")
		}
	}

	PaneLine {
		label: "Everything fixed"
		detail: "Marks and form fields become part of the page"

		Toggle {
			checked: !!root.finish.flatten
			onToggled: on => Pdf.setFinish("flatten", on, on ? "Fixed when saved" : "Left editable")
		}
	}

	PaneLine {
		label: "PDF/A"
		detail: root.lacks("pdfa") || "For archives: fonts inside, nothing outside"

		Toggle {
			checked: !!root.finish.pdfa
			onToggled: on => Pdf.setFinish("pdfa", on, on ? "PDF/A when saved" : "No PDF/A")
		}
	}

	// ── as other files ─────────────────────────────────────────────────────
	SectionLabel {
		text: "As other files, beside it"
	}

	Row {
		width: parent.width
		spacing: 6

		Segmented {
			width: (parent.width - 6) / 2
			options: [{ value: "png", label: "PNG" }, { value: "jpg", label: "JPG" }]
			current: root.imageFormat
			onSelected: value => root.imageFormat = value
		}

		Segmented {
			width: (parent.width - 6) / 2
			options: [{ value: "72", label: "72" }, { value: "150", label: "150" }, { value: "300", label: "300 dpi" }]
			current: root.dpi
			onSelected: value => root.dpi = value
		}
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Pages as pictures"
			icon: "image_multiple_outline"
			enabled: !root.lacks("toimages")
			onActivated: Pdf.runTool("toimages", { format: root.imageFormat, dpi: Number(root.dpi) }, "Pages made pictures")
		}

		TextButton {
			text: "The pictures in it"
			icon: "image_search_outline"
			onActivated: Pdf.runTool("imagesout", {}, "Pictures taken out")
		}

		TextButton {
			text: "The text"
			icon: "text_long"
			onActivated: Pdf.runTool("totext", {}, "Text taken out")
		}

		TextButton {
			text: "Tables (this page)"
			icon: "table_arrow_right"
			onActivated: Pdf.tableOut?.(Pdf.page)
		}

		TextButton {
			text: "All tables as CSV"
			icon: "table_large"
			onActivated: Pdf.runTool("tocsv", {}, "Tables taken out")
		}
	}

	Row {
		width: parent.width
		spacing: 6

		Segmented {
			id: officeKind

			width: parent.width - officeButton.width - 6
			options: [{ value: "docx", label: "Word" }, { value: "odt", label: "Writer" }, { value: "rtf", label: "RTF" }]
			current: root.office
			onSelected: value => root.office = value
		}

		TextButton {
			id: officeButton

			text: "Make it"
			icon: "file_word_outline"
			enabled: !root.lacks("tooffice")
			onActivated: Pdf.runTool("tooffice", { format: root.office }, "Converted")
		}
	}

	StyledText {
		visible: !!root.lacks("tooffice")
		text: `Word and Writer: ${root.lacks("tooffice")}`
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	// ── saving ─────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Saving"
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Save"
			icon: "content_save_outline"
			variant: "filled"
			enabled: Pdf.dirty
			onActivated: Pdf.save()
		}

		TextButton {
			text: "Save a copy"
			icon: "content_save_all_outline"
			onActivated: Pdf.saveCopy()
		}

		TextButton {
			text: "Save as…"
			icon: "content_save_edit_outline"
			onActivated: Pdf.chooseSaveAs()
		}

		TextButton {
			text: "Repair"
			icon: "wrench_outline"
			onActivated: Pdf.runTool("repair", {}, "Repaired")
		}
	}

	PaneLine {
		label: "Saving changes the file itself"
		detail: "Its earlier state is kept (Info › Earlier saves); off: a copy beside it"

		Toggle {
			checked: Pdf.setting("saveMode", "replace") === "replace"
			onToggled: on => Pdf.setSetting("saveMode", on ? "replace" : "copy")
		}
	}

	// ── the same to others ─────────────────────────────────────────────────
	SectionLabel {
		text: "The same to other PDFs"
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "What is set here for the whole file – layout (watermark, numbers, header, footer), what happens when saved, the details – done to other PDFs, each saved beside itself."
	}

	Row {
		spacing: 6

		Chip {
			id: blankRule

			text: "Also take empty pages out"
			onClicked: blankRule.selected = !blankRule.selected
		}

		Chip {
			id: turnRule

			text: "Turn all"
			onClicked: turnRule.selected = !turnRule.selected
		}
	}

	TextButton {
		text: "Choose PDFs…"
		icon: "file_multiple_outline"
		onActivated: Files.pick({ title: "Do the same to these", multiple: true, filters: ["*.pdf"], folder: Pdf.folderOf(Pdf.path) }, paths => {
			if (!paths || paths.length === 0) return;
			const template = { doc: Pdf.recipe.doc, finish: Object.assign({}, Pdf.recipe.finish, { sign: null }), meta: null, label: "edited", rules: { removeBlank: blankRule.selected, rotate: turnRule.selected ? 90 : 0 } };
			Pdf.startJob("batch", { recipe: template, paths: paths }, `Doing it to ${paths.length} files`, result => {
				const made = result?.created ?? [];
				if (made.length > 0) Pdf.say(`${made.length} ${made.length === 1 ? "file" : "files"} made beside them`, "file_multiple_outline");
			});
		})
	}
}
