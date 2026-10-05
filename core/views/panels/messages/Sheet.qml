pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// A mail, or a piece of one, as its sender laid it out: the picture a
// browser drew of it (scripts/messages/render.py), with its links where they
// are. The picture wears the shell's colours, is see-through where the mail
// was white, and is made for the screen's own pixels: shown at its size it
// is as sharp as text, so it is only shrunk where there is no room for it.
//
// Its text can be marked like text: the browser also wrote down where every
// word stands. Dragging marks from word to word, a double click one word,
// Ctrl+A all of it; Ctrl+C copies, and what is marked is in the primary
// selection at once.
// `page`: { image, width, height, links: [{ x, y, w, h, href }], text }
Item {
	id: root

	property var page: null
	readonly property real factor: root.page ? Math.min(1, width / root.page.width) : 1

	// [[x, y, w, h, word, block]] in reading order, read once the pointer comes
	property var words: []
	property bool wanted: false
	// the words the marking runs between, -1 for none
	property int anchor: -1
	property int caret: -1
	readonly property int first: root.anchor < 0 ? -1 : Math.min(root.anchor, root.caret)
	readonly property int last: root.anchor < 0 ? -1 : Math.max(root.anchor, root.caret)
	// the marked words as one bar per line
	readonly property var bars: {
		const bars = [];
		if (root.first < 0) return bars;
		for (let i = root.first; i <= root.last && i < root.words.length; i += 1) {
			const word = root.words[i];
			const bar = bars[bars.length - 1];
			if (bar && Math.abs(bar.y - word[1]) < Math.max(3, bar.h * 0.5) && word[0] >= bar.x) {
				bar.w = Math.max(bar.w, word[0] + word[2] - bar.x);
				bar.h = Math.max(bar.h, word[3]);
			} else {
				bars.push({ x: word[0], y: word[1], w: word[2], h: word[3] });
			}
		}
		return bars;
	}

	function wordAt(x, y) {
		const px = x / root.factor;
		const py = y / root.factor;
		let best = -1;
		let least = Infinity;
		for (let i = 0; i < root.words.length; i += 1) {
			const word = root.words[i];
			const dy = py < word[1] ? word[1] - py : (py > word[1] + word[3] ? py - word[1] - word[3] : 0);
			const dx = px < word[0] ? word[0] - px : (px > word[0] + word[2] ? px - word[0] - word[2] : 0);
			// the line counts for more than the place in it
			const distance = dy * 6 + dx;
			if (distance < least) {
				least = distance;
				best = i;
			}
		}
		return best;
	}

	function marked() {
		if (root.first < 0) return "";
		let text = "";
		for (let i = root.first; i <= root.last && i < root.words.length; i += 1) {
			const word = root.words[i];
			if (i > root.first) {
				const before = root.words[i - 1];
				if (word[5] !== before[5]) text += word[1] - before[1] > before[3] * 1.9 ? "\n\n" : "\n";
				else text += " ";
			}
			text += word[4];
		}
		return text;
	}

	function clear() {
		root.anchor = -1;
		root.caret = -1;
	}

	function copy(primary) {
		const text = root.marked();
		if (text === "") return;
		Quickshell.execDetached(primary ? ["wl-copy", "--primary", "--", text] : ["wl-copy", "--", text]);
	}

	implicitWidth: root.page?.width ?? 0
	implicitHeight: root.page ? Math.ceil(root.page.height * root.factor) : 0

	onPageChanged: {
		root.clear();
		root.words = [];
	}
	onActiveFocusChanged: if (!root.activeFocus) root.clear()

	Keys.onPressed: event => {
		if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_C && root.first >= 0) {
			root.copy(false);
			event.accepted = true;
		} else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_A && root.words.length > 0) {
			root.anchor = 0;
			root.caret = root.words.length - 1;
			root.copy(true);
			event.accepted = true;
		} else if (event.key === Qt.Key_Escape && root.first >= 0) {
			root.clear();
			event.accepted = true;
		}
	}

	HoverHandler {
		onHoveredChanged: if (hovered) root.wanted = true
	}

	FileView {
		path: root.wanted && root.page?.text ? root.page.text : ""
		printErrors: false
		onLoaded: {
			try {
				root.words = JSON.parse(text());
			} catch (error) {
				root.words = [];
			}
		}
	}

	Image {
		width: root.page ? root.page.width * root.factor : 0
		height: root.page ? root.page.height * root.factor : 0
		source: root.page ? `file://${root.page.image}` : ""
		asynchronous: true
		cache: false
		smooth: root.factor < 1
		mipmap: root.factor < 1
	}

	Repeater {
		model: root.bars

		delegate: Rectangle {
			required property var modelData

			x: modelData.x * root.factor - 1
			y: modelData.y * root.factor
			width: modelData.w * root.factor + 2
			height: modelData.h * root.factor
			radius: 2
			color: Qt.alpha(Theme.primary, 0.38)
		}
	}

	MouseArea {
		property bool dragged: false

		anchors.fill: parent
		cursorShape: Qt.IBeamCursor
		preventStealing: true
		onPressed: event => {
			root.wanted = true;
			root.forceActiveFocus();
			dragged = false;
			root.anchor = root.wordAt(event.x, event.y);
			root.caret = root.anchor;
		}
		onPositionChanged: event => {
			if (!pressed || root.anchor < 0) return;
			const at = root.wordAt(event.x, event.y);
			if (at !== root.caret) dragged = true;
			root.caret = at;
		}
		onReleased: {
			// a plain click marks nothing
			if (!dragged) root.clear();
			else root.copy(true);
		}
		onDoubleClicked: event => {
			root.anchor = root.wordAt(event.x, event.y);
			root.caret = root.anchor;
			dragged = true;
			root.copy(true);
		}
	}

	Repeater {
		model: root.page?.links ?? []

		delegate: MouseArea {
			required property var modelData

			x: modelData.x * root.factor
			y: modelData.y * root.factor
			width: modelData.w * root.factor
			height: modelData.h * root.factor
			cursorShape: Qt.PointingHandCursor
			onClicked: Qt.openUrlExternally(modelData.href)
		}
	}
}
