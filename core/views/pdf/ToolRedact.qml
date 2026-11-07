pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Blacking out for good: boxes drawn, words marked, or everything a search
// finds – IBANs, mail addresses, phone numbers, dates, amounts, names, own
// words, a pattern. Each hit is shown first and can be left out with a
// click. When saved, the pages they are on become pictures with the black
// boxes in them (200 dpi), so nothing is left under the black.
PaneFrame {
	id: root

	property Item dock: null
	property var presets: []
	property bool finding: false
	readonly property var redactions: Pdf.items.filter(item => item.kind === "redact")
	readonly property int hitsOn: Pdf.redactHits.filter(h => h.on !== false).length

	title: "Black out"
	subtitle: root.redactions.length > 0 ? `${root.redactions.length} ${root.redactions.length === 1 ? "place" : "places"} – black for good when saved` : "Gone for good when saved – not only covered"
	onClose: {
		Pdf.redactHits = [];
		Pdf.tool = "";
	}

	Component.onCompleted: if (!["redact", "redact-box", "select"].includes(Pdf.draw)) Pdf.draw = "redact"

	function find() {
		const preset = root.presets.join(",");
		if (!preset && words.text.trim() === "" && pattern.text.trim() === "") return Pdf.say("Choose what to look for", "magnify");
		root.finding = true;
		Pdf.request("find", { path: Pdf.sourcePath("a"), password: Pdf.password, preset: preset, words: words.text, regex: pattern.text.trim() }, data => {
			root.finding = false;
			if (!data) return;
			const idsOf = {};
			Pdf.pages.forEach(p => {
				if (p.src === "a") (idsOf[p.n] = idsOf[p.n] || []).push(p.id);
			});
			const hits = [];
			for (const hit of data.hits ?? [])
				for (const id of idsOf[hit.page] ?? []) hits.push({ page: id, rects: hit.rects, text: hit.text, on: true });
			Pdf.redactHits = hits;
			if (hits.length === 0) Pdf.say("Nothing found (scanned pages need their text read first: Scans)", "magnify_close");
			else Pdf.goTo(Pdf.indexOf(hits[0].page), Math.max(0, hits[0].rects[0][1] - 80));
		});
	}

	Row {
		width: parent.width
		spacing: 6

		Repeater {
			model: [{ id: "redact", label: "Over words", icon: "format_color_text" }, { id: "redact-box", label: "A box", icon: "rectangle" }, { id: "select", label: "Choose", icon: "cursor_default_outline" }]

			delegate: Clickable {
				id: pen

				required property var modelData
				readonly property bool current: Pdf.draw === pen.modelData.id

				width: (parent.width - 12) / 3
				height: 54
				radius: Theme.radius.medium
				color: pen.current ? Theme.primarySoft : (pen.hovered ? Theme.layer3 : Theme.layer2)
				onClicked: Pdf.draw = pen.modelData.id

				Column {
					anchors.centerIn: parent
					spacing: 3

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: pen.modelData.icon
						size: 20
						color: pen.current ? Theme.primary : Theme.text
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: pen.modelData.label
						font.pixelSize: 9
					}
				}
			}
		}
	}

	TextButton {
		visible: Pdf.selectionText !== ""
		text: "Black out the selected text"
		icon: "eye_off_outline"
		onActivated: Pdf.markSelection("redact")
	}

	// ── found ──────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Find and black out"
	}

	Flow {
		width: parent.width
		spacing: 6

		Repeater {
			model: [{ id: "iban", label: "IBANs" }, { id: "email", label: "Mail addresses" }, { id: "phone", label: "Phone numbers" }, { id: "date", label: "Dates" }, { id: "amount", label: "Amounts" }, { id: "names", label: "Names" }]

			delegate: Chip {
				required property var modelData

				text: modelData.label
				selected: root.presets.includes(modelData.id)
				onClicked: root.presets = selected ? root.presets.filter(p => p !== modelData.id) : root.presets.concat([modelData.id])
			}
		}
	}

	Field {
		id: words

		width: parent.width
		height: 36
		icon: "text_search"
		placeholder: "Own words, with commas"
		onAccepted: root.find()
	}

	Field {
		id: pattern

		width: parent.width
		height: 36
		icon: "regex"
		placeholder: "Or a pattern (regular expression)"
		onAccepted: root.find()
	}

	Row {
		spacing: 6

		TextButton {
			text: root.finding ? "Looking…" : "Find"
			icon: "magnify"
			busy: root.finding
			variant: "filled"
			onActivated: root.find()
		}

		TextButton {
			visible: Pdf.redactHits.length > 0
			text: `Black out ${root.hitsOn}`
			icon: "eye_off_outline"
			variant: "danger"
			onActivated: Pdf.applyRedactHits()
		}

		TextButton {
			visible: Pdf.redactHits.length > 0
			text: "Let go"
			variant: "ghost"
			onActivated: Pdf.redactHits = []
		}
	}

	StyledText {
		width: parent.width
		visible: Pdf.redactHits.length > 0
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: `${Pdf.redactHits.length} found – on the page, a click on a hit leaves it out (red) or takes it in again (black).`
	}

	Repeater {
		model: Pdf.redactHits.slice(0, 200)

		delegate: Clickable {
			id: hit

			required property var modelData
			required property int index

			width: parent.width
			height: 34
			radius: Theme.radius.small
			color: hit.hovered ? Theme.layer2 : "transparent"
			onClicked: Pdf.goTo(Pdf.indexOf(hit.modelData.page), Math.max(0, hit.modelData.rects[0][1] - 80))

			Glyph {
				id: mark

				x: 8
				anchors.verticalCenter: parent.verticalCenter
				icon: hit.modelData.on !== false ? "checkbox_marked" : "checkbox_blank_outline"
				size: 18
				color: hit.modelData.on !== false ? Theme.text : Theme.textSubtle

				MouseArea {
					anchors.fill: parent
					anchors.margins: -6
					onClicked: {
						const next = Pdf.redactHits.slice();
						next[hit.index] = Object.assign({}, next[hit.index], { on: next[hit.index].on === false });
						Pdf.redactHits = next;
					}
				}
			}

			StyledText {
				anchors.left: mark.right
				anchors.leftMargin: 8
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				text: `${hit.modelData.text} · p. ${Pdf.indexOf(hit.modelData.page) + 1}`
				elide: Text.ElideRight
				font.strikeout: hit.modelData.on === false
			}
		}
	}

	// ── already marked ─────────────────────────────────────────────────────
	TextButton {
		visible: root.redactions.length > 0
		text: `Take all ${root.redactions.length} back`
		icon: "eye_outline"
		confirm: true
		onActivated: Pdf.removeItems(root.redactions.map(r => r.id))
	}
}
