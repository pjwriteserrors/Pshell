pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Scans: their text read (OCR) so it can be found, selected and copied;
// pages turned straight, the paper made white and the writing crisp. Done
// to the drawn copy at once, so the result is seen before it is saved.
// New pages photographed with the phone are cleaned the same way.
PaneFrame {
	id: root

	property Item dock: null
	property string lang: Pdf.setting("ocrLang", "deu+eng")
	property bool colour: true
	property var angle: null
	readonly property var baked: Pdf.recipe.sources?.a?.baked ?? []
	readonly property bool busy: Pdf.runningJobs.some(j => j.kind === "bake")

	title: "Scans"
	subtitle: Pdf.meta?.scanned ? "This looks scanned: its text can't be found yet" : "Readable, straight and clean"
	onClose: Pdf.tool = ""

	Component.onCompleted: {
		const p = Pdf.pages[Pdf.page];
		if (p && p.src === "a") Pdf.request("skew", { path: Pdf.sourcePath("a"), pages: [p.n], password: Pdf.password }, data => root.angle = data?.angles?.[0] ?? null);
	}

	// ── the text ───────────────────────────────────────────────────────────
	SectionLabel {
		text: "Make the text readable"
	}

	Segmented {
		width: parent.width
		options: [{ value: "deu+eng", label: "German + English" }, { value: "deu", label: "German" }, { value: "eng", label: "English" }]
		current: root.lang
		onSelected: value => {
			root.lang = value;
			Pdf.setSetting("ocrLang", value);
		}
	}

	TextButton {
		width: parent.width
		text: root.baked.includes("ocr") ? "Read again" : "Read the text (OCR)"
		icon: "text_recognition"
		variant: Pdf.meta?.scanned ? "filled" : "tonal"
		busy: root.busy
		enabled: !root.busy
		onActivated: Pdf.bake("ocr", { languages: root.lang, force: root.baked.includes("ocr") }, "Text read")
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "The pages stay as they look; the words lie invisibly over them. A page by minute or so on long files – the bar at the top shows how far."
	}

	// ── the look ───────────────────────────────────────────────────────────
	SectionLabel {
		text: "Clean"
	}

	StyledText {
		visible: root.angle !== null && Math.abs(root.angle) > 0.2
		text: `This page leans ${Math.abs(root.angle).toFixed(1)}° ${root.angle > 0 ? "right" : "left"}`
		tone: Theme.warning
	}

	PaneLine {
		label: "Keep colours"
		detail: "Off: black on white, smallest"

		Toggle {
			checked: root.colour
			onToggled: on => root.colour = on
		}
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Straight and clean"
			icon: "auto_fix"
			enabled: !root.busy
			onActivated: Pdf.bake("clean", { deskew: true, colour: root.colour }, "Scans cleaned")
		}

		TextButton {
			text: "Only straight"
			icon: "format_rotate_90"
			enabled: !root.busy
			onActivated: Pdf.bake("deskew", {}, "Pages straightened")
		}

		TextButton {
			text: "Repair the file"
			icon: "wrench_outline"
			enabled: !root.busy
			onActivated: Pdf.bake("repair", {}, "Repaired")
		}
	}

	StyledText {
		visible: root.baked.length > 0
		width: parent.width
		wrapMode: Text.WordWrap
		tone: Theme.primary
		text: `Done here: ${root.baked.map(b => ({ ocr: "text read", clean: "cleaned", deskew: "straightened", repair: "repaired", unlock: "unlocked" })[b] ?? b).join(", ")} – save to keep it, Ctrl+Z to undo.`
	}

	// ── new pages ──────────────────────────────────────────────────────────
	SectionLabel {
		text: "New pages"
	}

	TextButton {
		text: "Photograph pages with the phone"
		icon: "cellphone_screenshot"
		onActivated: {
			Pdf.bridgeStart("scan");
			root.dock?.sheet("BridgeSheet.qml", { kind: "scan" });
		}
	}
}
