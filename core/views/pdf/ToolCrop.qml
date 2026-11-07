pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"
import "../viewer"

// Cropping: a box drawn on the page (its corners and edges pull it, Shift
// keeps it square), or margins taken off all round; then given to this page,
// the chosen ones, all, the odd or the even ones. The cut is a crop box –
// nothing is thrown away, taking it off brings it all back.
PaneFrame {
	id: root

	property Item dock: null
	property real margin: 0

	readonly property var current: Pdf.pages[Pdf.page] ?? null
	readonly property var draft: root.current ? (Pdf.cropDraft[root.current.id] ?? null) : null
	readonly property bool cropped: Pdf.scopeIds().some(id => !!Pdf.pageById(id)?.crop)

	title: "Crop"
	subtitle: root.draft ? `${Math.round(root.draft[2] / 72 * 25.4)} × ${Math.round(root.draft[3] / 72 * 25.4)} mm` : "Draw the box on the page"
	onClose: {
		Pdf.cropDraft = {};
		Pdf.tool = "";
	}

	// the shown page less a margin all round (mm)
	function inset(mm) {
		if (!root.current) return;
		const size = Pdf.baseSize(root.current);
		const shown = root.current.crop ?? [0, 0, size.width, size.height];
		const m = mm / 25.4 * 72;
		Pdf.cropDraft = Object.assign({}, Pdf.cropDraft, { [root.current.id]: [shown[0] + m, shown[1] + m, Math.max(10, shown[2] - 2 * m), Math.max(10, shown[3] - 2 * m)].map(v => Math.round(v * 100) / 100) });
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "Drag a box over what stays. A click without dragging takes the whole page to start from."
	}

	TuneSlider {
		width: parent.width
		label: "Margin off"
		from: 0
		to: 40
		step: 1
		value: root.margin
		valueText: `${Math.round(root.margin)} mm`
		onMoved: value => {
			root.margin = value;
			root.inset(value);
		}
		onCommitted: value => {
			root.margin = value;
			root.inset(value);
		}
	}

	SectionLabel {
		text: "Give it to"
	}

	EditScope {}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Crop"
			icon: "crop"
			variant: "filled"
			enabled: Object.keys(Pdf.cropDraft).length > 0
			onActivated: {
				Pdf.applyCrop(Pdf.pageScope);
				root.margin = 0;
			}
		}

		TextButton {
			text: "Take the crop off"
			icon: "crop_free"
			visible: root.cropped
			onActivated: Pdf.cropPages(Pdf.scopeIds(), null)
		}

		TextButton {
			text: "Let go"
			variant: "ghost"
			visible: Object.keys(Pdf.cropDraft).length > 0
			onActivated: {
				Pdf.cropDraft = {};
				root.margin = 0;
			}
		}
	}

	SectionLabel {
		text: "By itself"
	}

	TextButton {
		text: "Cut the empty margins away, page by page"
		icon: "crop_free"
		onActivated: Pdf.runTool("crop", { margin: 12 }, "Margins cut away")
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "Each page to what is drawn on it, plus a little room – made as a new file beside this one."
	}
}
