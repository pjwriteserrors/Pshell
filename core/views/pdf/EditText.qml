pragma ComponentBehavior: Bound

import QtQuick
import "Edit.js" as Edit

// Words in a box laid out as the helper writes them: wrapped at spaces within
// the box less its padding, the first baseline at pad + the font's ascent,
// then a fixed pitch – in the URW twins of the standard fonts, whose widths
// are the same – so what is seen here is where it lands in the file.
Item {
	id: root

	property string text: ""
	// points; `s` pixels per point
	property real size: 12
	property real s: 1
	property string font: "Helvetica"
	property bool bold: false
	property bool italic: false
	property color color: "black"
	property real pad: 0
	property string align: "left"
	// one line, never wrapped (a corrected line)
	property bool single: false

	readonly property string kind: /times|roman|serif/i.test(root.font) ? "times" : (/courier|mono/i.test(root.font) ? "courier" : "helvetica")
	readonly property real ascent: ({ helvetica: 0.718, times: 0.683, courier: 0.629 })[root.kind]
	readonly property real pitch: ({ helvetica: 1.0626, times: 1.035, courier: 0.904 })[root.kind]
	readonly property var lines: root.layout()
	readonly property real contentHeight: (root.pad * 2 + root.lines.length * root.pitch * root.size) * root.s

	FontMetrics {
		id: measure

		font.family: Edit.family(root.font)
		font.pixelSize: 100
		font.bold: root.bold
		font.italic: root.italic
	}

	FontMetrics {
		id: shownMetrics

		font.family: Edit.family(root.font)
		font.pixelSize: Math.max(1, root.size * root.s)
		font.bold: root.bold
		font.italic: root.italic
	}

	function widthOf(text) {
		return measure.advanceWidth(text) / 100 * root.size;
	}

	function layout() {
		const out = [];
		const room = root.width / Math.max(0.001, root.s) - root.pad * 2;
		for (const para of String(root.text).split("\n")) {
			if (root.single || room <= 0) {
				out.push(para);
				continue;
			}
			const words = para.split(" ");
			let line = "";
			for (const word of words) {
				const tryLine = line === "" ? word : `${line} ${word}`;
				if (line !== "" && root.widthOf(tryLine) > room + 0.01) {
					out.push(line);
					line = word;
				} else line = tryLine;
			}
			out.push(line);
		}
		return out;
	}

	Repeater {
		model: root.lines

		delegate: Text {
			required property string modelData
			required property int index

			readonly property real base: (root.pad + root.ascent * root.size + index * root.pitch * root.size) * root.s

			x: root.align === "center" ? (root.width - implicitWidth) / 2 : (root.align === "right" ? root.width - root.pad * root.s - implicitWidth : root.pad * root.s)
			y: base - shownMetrics.ascent
			text: modelData
			color: root.color
			textFormat: Text.PlainText
			font: shownMetrics.font
		}
	}
}
