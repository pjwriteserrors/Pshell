pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The sheet the song is written on: the title on top, the lines below,
// centred like the editor's page. One cursor glides over all lines; ↑ ↓ ← →
// cross from line to line, Enter cuts one, Backspace joins two, Shift with
// ↑ ↓ at a line's edge takes whole lines (copied, cut, moved, deleted).
FocusScope {
	id: sheet

	property int activeRow: 0
	// lines taken whole: from, to (-1 none)
	property int selFrom: -1
	property int selTo: -1
	property string selectionWord: ""
	readonly property real fontSize: 17
	readonly property real textWidth: Math.max(160, Math.min(660, list.width - 2 * 96 - 40))
	readonly property real margin: Math.round((list.width - sheet.textWidth - 86) / 2) + 20
	readonly property alias view: list

	// the colours of the rhymes: around the circle from the accent, far enough apart to tell
	function colourOf(group) {
		const base = Theme.primary.hslHue >= 0 ? Theme.primary.hslHue : 0.6;
		const hue = (base + group * 0.381966) % 1;
		const shade = Qt.hsla(hue, Theme.dark ? 0.62 : 0.58, Theme.dark ? 0.68 : 0.42, 1);
		return Theme.legible(shade, 3.0);
	}

	// the made lines by their key: the list's own lookup lags behind an insert
	property var made: ({})
	// where the cursor goes in a line that is still being made
	property var pending: null

	function rowItem(index) {
		const line = index >= 0 && index < Rhymes.lines.count ? Rhymes.lines.get(index) : null;
		return line ? (sheet.made[line.key] ?? null) : null;
	}

	function focusRow(index) {
		if (sheet.activeRow !== index) sheet.activeRow = index;
		caretMoved();
	}

	function caretMoved() {
		caret.follow();
		blink.restart();
	}

	function goTo(index, column) {
		if (Rhymes.lines.count === 0) return;
		const i = Math.max(0, Math.min(Rhymes.lines.count - 1, index));
		sheet.activeRow = i;
		const place = () => {
			const item = sheet.rowItem(i);
			if (!item) return;
			item.place(column < 0 ? item.edit.length : column);
			sheet.reveal(i);
		};
		if (sheet.rowItem(i)) place();
		else {
			// the line is not made yet: it takes the cursor itself when it is
			sheet.pending = { key: Rhymes.lines.get(i).key, column: column };
			list.positionViewAtIndex(i, ListView.Contain);
		}
	}

	function takeFocus() {
		sheet.goTo(Math.min(sheet.activeRow, Rhymes.lines.count - 1), -1);
	}

	// the line in view, scrolled to softly
	function reveal(index) {
		const item = sheet.rowItem(index);
		if (!item) return;
		const top = item.y - list.originY;
		const bottom = top + item.height;
		const room = list.height;
		let target = list.contentY - list.originY;
		if (top < target + 60) target = top - 60;
		else if (bottom > target + room - 120) target = bottom - room + 120;
		else return;
		scroller.to = Math.max(0, Math.min(target, list.contentHeight - room)) + list.originY;
		scroller.restart();
	}

	function clearSelection() {
		sheet.selFrom = -1;
		sheet.selTo = -1;
	}

	function selectLines(from, to) {
		sheet.selFrom = from;
		sheet.selTo = to;
	}

	readonly property bool hasLines: sheet.selFrom >= 0

	// the keys of a line: those that go beyond it are the sheet's
	function key(row, event) {
		const edit = row.edit;
		const ctrl = event.modifiers & Qt.ControlModifier;
		const shift = event.modifiers & Qt.ShiftModifier;
		const alt = event.modifiers & Qt.AltModifier;
		const i = row.index;
		const atStart = edit.cursorPosition === 0 && edit.selectedText === "";
		const atEnd = edit.cursorPosition === edit.length && edit.selectedText === "";
		const firstLine = edit.cursorRectangle.y < 4;
		const lastLine = edit.cursorRectangle.y + edit.cursorRectangle.height > edit.contentHeight - 4;
		const k = event.key;

		// whole lines taken
		if (sheet.hasLines) {
			const a = Math.min(sheet.selFrom, sheet.selTo);
			const b = Math.max(sheet.selFrom, sheet.selTo);
			if (shift && (k === Qt.Key_Up || k === Qt.Key_Down)) {
				sheet.selTo = Math.max(0, Math.min(Rhymes.lines.count - 1, sheet.selTo + (k === Qt.Key_Up ? -1 : 1)));
				sheet.goTo(sheet.selTo, k === Qt.Key_Up ? 0 : -1);
				event.accepted = true;
				return;
			}
			if (ctrl && (k === Qt.Key_C || k === Qt.Key_X)) {
				Quickshell.clipboardText = Rhymes.linesText(a, b);
				if (k === Qt.Key_X) Rhymes.removeLines(a, b);
				sheet.clearSelection();
				event.accepted = true;
				return;
			}
			if (k === Qt.Key_Backspace || k === Qt.Key_Delete) {
				Rhymes.removeLines(a, b);
				sheet.clearSelection();
				event.accepted = true;
				return;
			}
			if (alt && (k === Qt.Key_Up || k === Qt.Key_Down)) {
				const by = k === Qt.Key_Up ? -1 : 1;
				if ((by < 0 && a > 0) || (by > 0 && b < Rhymes.lines.count - 1)) {
					Rhymes.remember();
					Rhymes.lines.move(by < 0 ? a - 1 : b + 1, by < 0 ? b : a, 1);
					Rhymes.changed();
					sheet.selFrom += by;
					sheet.selTo += by;
					sheet.goTo(i + by, edit.cursorPosition);
				}
				event.accepted = true;
				return;
			}
			if (k === Qt.Key_Escape || !(k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt)) {
				sheet.clearSelection();
				if (k === Qt.Key_Escape) {
					event.accepted = true;
					return;
				}
			}
		}

		if (ctrl && k === Qt.Key_Z) {
			if (shift) Rhymes.redo();
			else Rhymes.undo();
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_Y) {
			Rhymes.redo();
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_A) {
			if (edit.selectedText.length === edit.length && edit.length > 0 || edit.length === 0)
				sheet.selectLines(0, Rhymes.lines.count - 1);
			else edit.selectAll();
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_V) {
			const text = String(Quickshell.clipboardText || "");
			if (text.includes("\n")) {
				const at = edit.selectionStart;
				if (edit.selectedText !== "") edit.remove(edit.selectionStart, edit.selectionEnd);
				Rhymes.insertText(i, at, text);
				event.accepted = true;
			}
		} else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && ctrl) {
			// the line starts now; on to the next (a held key stamps once)
			event.accepted = true;
			if (event.isAutoRepeat) return;
			Rhymes.stamp(i, Rhymes.beatPlaying ? undefined : Rhymes.cue);
			if (i + 1 < Rhymes.lines.count) sheet.goTo(i + 1, 0);
		} else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && !shift && !alt) {
			if (edit.selectedText !== "") edit.remove(edit.selectionStart, edit.selectionEnd);
			Rhymes.split(i, edit.cursorPosition);
			event.accepted = true;
		} else if (k === Qt.Key_Backspace && atStart && i > 0 && !ctrl) {
			Rhymes.joinUp(i);
			event.accepted = true;
		} else if (k === Qt.Key_Delete && atEnd && i + 1 < Rhymes.lines.count) {
			Rhymes.joinUp(i + 1);
			event.accepted = true;
		} else if (alt && (k === Qt.Key_Up || k === Qt.Key_Down)) {
			Rhymes.moveLine(i, k === Qt.Key_Up ? -1 : 1);
			event.accepted = true;
		} else if (ctrl && shift && k === Qt.Key_K) {
			Rhymes.removeLines(i, i);
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_D) {
			Rhymes.duplicateLine(i);
			event.accepted = true;
		} else if (k === Qt.Key_Up && shift && firstLine && (edit.cursorPosition === 0 || edit.selectedText.length === edit.length)) {
			sheet.selectLines(i, Math.max(0, i - 1));
			sheet.goTo(Math.max(0, i - 1), 0);
			event.accepted = true;
		} else if (k === Qt.Key_Down && shift && lastLine && (edit.cursorPosition === edit.length || edit.selectedText.length === edit.length)) {
			sheet.selectLines(i, Math.min(Rhymes.lines.count - 1, i + 1));
			sheet.goTo(Math.min(Rhymes.lines.count - 1, i + 1), -1);
			event.accepted = true;
		} else if (k === Qt.Key_Up && !shift && firstLine && i > 0) {
			const x = edit.cursorRectangle.x;
			sheet.activeRow = i - 1;
			sheet.rowItem(i - 1)?.placeAt(x, false);
			sheet.reveal(i - 1);
			event.accepted = true;
		} else if (k === Qt.Key_Down && !shift && lastLine && i + 1 < Rhymes.lines.count) {
			const x = edit.cursorRectangle.x;
			sheet.activeRow = i + 1;
			sheet.rowItem(i + 1)?.placeAt(x, true);
			sheet.reveal(i + 1);
			event.accepted = true;
		} else if (k === Qt.Key_Left && atStart && !shift && i > 0) {
			sheet.goTo(i - 1, -1);
			event.accepted = true;
		} else if (k === Qt.Key_Right && atEnd && !shift && i + 1 < Rhymes.lines.count) {
			sheet.goTo(i + 1, 0);
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_Home) {
			sheet.goTo(0, 0);
			event.accepted = true;
		} else if (ctrl && k === Qt.Key_End) {
			sheet.goTo(Rhymes.lines.count - 1, -1);
			event.accepted = true;
		} else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
			event.accepted = true;
		}
	}

	Connections {
		target: Rhymes

		function onJump(rowIndex, column) {
			sheet.clearSelection();
			sheet.goTo(rowIndex, column);
		}
	}

	ListView {
		id: list

		anchors.fill: parent
		model: Rhymes.lines
		// every line stays made: the cursor and the selection live in them
		cacheBuffer: 100000
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		focus: true
		reuseItems: false
		ScrollBar.vertical: ThinScrollBar {}

		NumberAnimation {
			id: scroller

			target: list
			property: "contentY"
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}

		header: Item {
			width: list.width
			height: titleColumn.implicitHeight + 34

			Column {
				id: titleColumn

				x: sheet.margin
				y: 26
				width: sheet.textWidth
				spacing: 4

				TextInput {
					id: titleInput

					width: parent.width
					text: Rhymes.song?.title ?? ""
					color: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.display
					font.weight: Font.Bold
					selectByMouse: true
					selectionColor: Qt.alpha(Theme.primary, 0.35)
					cursorDelegate: Rectangle {
						width: 2
						radius: 1
						color: Theme.primary
						visible: titleInput.activeFocus
					}
					onTextEdited: Rhymes.rename(titleInput.text)
					Keys.onReturnPressed: sheet.goTo(0, 0)
					Keys.onDownPressed: sheet.goTo(0, 0)

					StyledText {
						text: "Untitled"
						visible: titleInput.text === ""
						font: titleInput.font
						tone: Theme.textFaint
					}
				}

				Row {
					spacing: 12

					TextInput {
						id: artistInput

						text: Rhymes.song?.artist ?? ""
						color: Theme.textMuted
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
						selectByMouse: true
						width: Math.max(60, contentWidth + 4)
						cursorDelegate: Rectangle {
							width: 2
							radius: 1
							color: Theme.primary
							visible: artistInput.activeFocus
						}
						onTextEdited: Rhymes.setArtist(artistInput.text)
						Keys.onReturnPressed: sheet.goTo(0, 0)

						StyledText {
							text: Rhymes.setting("artist", "") || "Artist"
							visible: artistInput.text === "" && !artistInput.activeFocus
							font: artistInput.font
							tone: Theme.textFaint
						}
					}

					Repeater {
						model: {
							const out = [];
							const lines = (Rhymes.analysis.lines || []).filter(l => l.syl > 0);
							if (lines.length > 0) {
								out.push(`${lines.length} ${lines.length === 1 ? "line" : "lines"}`);
								out.push(`${Math.round(lines.reduce((a, l) => a + l.syl, 0) / lines.length)} syllables a line`);
							}
							if (Rhymes.song?.bpm > 0) out.push(`${Math.round(Rhymes.song.bpm)} BPM`);
							return out;
						}

						StyledText {
							required property string modelData

							text: modelData
							font.pixelSize: Theme.size.body
							tone: Theme.textSubtle
						}
					}
				}
			}
		}

		footer: Item {
			width: list.width
			height: list.height * 0.45

			// a click under the last line goes to its end
			MouseArea {
				anchors.fill: parent
				onClicked: sheet.goTo(Rhymes.lines.count - 1, -1)
			}
		}

		delegate: LineRow {
			sheet: sheet
		}

		add: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}

				SpatialAnim {
					property: "scale"
					from: 0.96
					to: 1
				}
			}
		}

		remove: Transition {
			Anim {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
		}

		displaced: Transition {
			SpatialAnim {
				property: "y"
			}

			Anim {
				property: "opacity"
				to: 1
			}

			Anim {
				property: "scale"
				to: 1
			}
		}

		move: Transition {
			SpatialAnim {
				property: "y"
			}
		}

		moveDisplaced: Transition {
			SpatialAnim {
				property: "y"
			}
		}

		// the line whose time has come while the beat plays
		Rectangle {
			id: playingBar

			readonly property Item target: Rhymes.playingRow >= 0 ? sheet.rowItem(Rhymes.playingRow) : null

			parent: list.contentItem
			x: sheet.margin - 92
			y: target ? target.y + (target.header ? 20 : 0) + 6 : 0
			width: 3
			height: target ? Math.max(18, target.edit.contentHeight) : 0
			radius: 2
			color: Theme.primary
			opacity: target && Rhymes.hasBeat ? 1 : 0
			z: 3

			Behavior on y {
				SpatialAnim {}
			}

			Behavior on height {
				SpatialAnim {}
			}

			Behavior on opacity {
				Anim {}
			}
		}

		// the one cursor: it glides from place to place, also from line to line
		Rectangle {
			id: caret

			parent: list.contentItem
			width: 2
			radius: 1
			color: Theme.primary
			z: 4
			visible: sheet.activeFocus || (sheet.rowItem(sheet.activeRow)?.edit.activeFocus ?? false)

			function follow() {
				const item = sheet.rowItem(sheet.activeRow);
				if (!item) return;
				const r = item.edit.cursorRectangle;
				const p = item.edit.mapToItem(list.contentItem, r.x, r.y);
				caret.x = p.x;
				caret.y = p.y + 2;
				caret.height = Math.max(14, r.height - 4);
			}

			Behavior on x {
				NumberAnimation {
					duration: 70
					easing.type: Easing.OutCubic
				}
			}

			Behavior on y {
				NumberAnimation {
					duration: 110
					easing.type: Easing.OutCubic
				}
			}

			SequentialAnimation on opacity {
				id: blink

				loops: Animation.Infinite
				running: caret.visible

				PropertyAction {
					value: 1
				}

				PauseAnimation {
					duration: 600
				}

				NumberAnimation {
					to: 0.15
					duration: 260
				}

				PauseAnimation {
					duration: 260
				}

				NumberAnimation {
					to: 1
					duration: 200
				}
			}
		}

		onContentYChanged: caret.follow()
		onWidthChanged: Qt.callLater(caret.follow)
		onCountChanged: Qt.callLater(caret.follow)
	}

	// the colours change places as the words change: the cursor stays with its line
	Connections {
		target: Rhymes

		function onAnalysisChanged() {
			Qt.callLater(caret.follow);
		}
	}
}
