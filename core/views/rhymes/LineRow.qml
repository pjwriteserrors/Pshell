pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One line of the song: its start in the beat on the left, the words with
// their rhymes coloured behind them, the scheme letter, the syllables and
// the stresses on the right. A [Section] line is a heading; a heading that
// comes back with nothing under it (the hook again) shows what it repeats.
Item {
	id: row

	required property int index
	required property string text
	required property real t
	// a heading that repeats the hook: when each of its lines comes again
	required property string refs
	required property int key
	required property var sheet

	Component.onCompleted: {
		row.sheet.made[row.key] = row;
		const wanted = row.sheet.pending;
		if (wanted && wanted.key === row.key) {
			row.sheet.pending = null;
			// once the list has put the line in the window; what was typed into it meanwhile stays where it went
			const before = edit.text;
			Qt.callLater(() => {
				if (edit.text === before) row.place(wanted.column < 0 ? edit.length : wanted.column);
				else edit.forceActiveFocus();
				row.sheet.reveal(row.index);
			});
		}
	}
	Component.onDestruction: {
		if (row.sheet.made[row.key] === row) delete row.sheet.made[row.key];
		Autocorrect.leave(edit);
	}

	// what is typed here is corrected, like everywhere else (not in a heading)
	readonly property bool typing: edit.activeFocus && !row.header && Window.active && Window.visibility !== Window.Hidden
	onTypingChanged: {
		if (row.typing) Autocorrect.enter(edit);
		else Autocorrect.leave(edit);
	}

	readonly property bool active: row.sheet.activeRow === row.index
	readonly property bool header: /^\s*\[[^\]]+\]\s*$/.test(row.text)
	// what the helper found, as long as it is about this text
	readonly property var info: {
		const line = (Rhymes.analysis.lines || [])[row.index];
		return line && line.t === row.text ? line : null;
	}
	property var shownInfo: null
	onInfoChanged: if (row.info) row.shownInfo = row.info
	onTextChanged: if (!row.info && row.shownInfo && row.shownInfo.t !== row.text) row.shownInfo = null
	readonly property var section: (Rhymes.analysis.sections || []).find(s => s.line === row.index) ?? null
	readonly property bool repeats: row.section !== null && row.section.ref !== null && row.section.ref !== undefined
	readonly property bool selected: row.sheet.selFrom >= 0 && row.index >= Math.min(row.sheet.selFrom, row.sheet.selTo) && row.index <= Math.max(row.sheet.selFrom, row.sheet.selTo)
	readonly property bool playing: Rhymes.playingRow === row.index && Rhymes.hasBeat
	readonly property bool hovered: hover.hovered
	property alias edit: edit

	width: ListView.view ? ListView.view.width : 0
	height: column.y + column.height + (row.header ? 0 : 2)

	HoverHandler {
		id: hover
	}

	function caretRect() {
		const r = edit.cursorRectangle;
		return edit.mapToItem(row, r.x, r.y, r.width, r.height);
	}

	function place(position) {
		edit.cursorPosition = Math.max(0, Math.min(edit.length, position));
		edit.forceActiveFocus();
	}

	// where the cursor stands in the line, for ↑ ↓ from the line above or below
	function placeAt(x, fromAbove) {
		const y = fromAbove ? 2 : edit.contentHeight - 2;
		row.place(edit.positionAt(x, y));
	}

	// a selection across lines: the sheet's
	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: row.sheet.margin - 10
		anchors.rightMargin: row.sheet.margin - 10
		radius: Theme.radius.small
		color: Theme.primarySoft
		opacity: row.selected ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	// ── the line's time ────────────────────────────────────────────────────
	Item {
		id: timeSlot

		x: row.sheet.margin - width - 14
		y: column.y + edit.y + Math.max(0, (Math.min(edit.contentHeight, 30) - height) / 2)
		width: 58
		height: 22
		visible: Rhymes.hasBeat && !row.header
		opacity: row.t >= 0 || row.hovered || row.active ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Clickable {
			id: timeChip

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			height: 22
			width: timeLabel.implicitWidth + 14
			radius: height / 2
			color: row.playing ? Theme.primary : (row.t >= 0 ? Theme.layer2 : "transparent")
			tint: row.playing ? Theme.onPrimary : Theme.text
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			sound: ""
			onClicked: mouse => {
				if (row.t >= 0) Rhymes.playFromRow(row.index);
				else Rhymes.stamp(row.index, Rhymes.beatPlaying ? undefined : Rhymes.cue);
			}
			onRightClicked: Rhymes.unstamp(row.index)

			Behavior on color {
				ColorAnim {}
			}

			StyledText {
				id: timeLabel

				anchors.centerIn: parent
				text: row.t >= 0 ? Format.clock(row.t, 1) : "+"
				tabular: true
				font.pixelSize: Theme.size.small
				font.weight: row.playing ? Font.DemiBold : Font.Normal
				tone: row.playing ? Theme.onPrimary : (row.t >= 0 ? Theme.textMuted : Theme.textSubtle)
			}
		}
	}

	Column {
		id: column

		x: row.sheet.margin
		y: row.header ? (row.index === 0 ? 4 : 20) : 0
		width: row.sheet.textWidth
		spacing: 6

		Item {
			width: parent.width
			height: Math.max(edit.contentHeight, 20) + (row.header ? 6 : 12)

			// the colours of the rhymes, behind the words
			Item {
				id: marks

				x: edit.x
				y: edit.y
				width: edit.width
				height: edit.height
				visible: !row.header && Rhymes.setting("colours", true)

				// a mark per word; the words of one multi are bridged to the next on the same line
				readonly property var pieces: {
					const info = row.shownInfo;
					if (!info || !info.words) return [];
					const words = info.words;
					const out = [];
					for (let i = 0; i < words.length; i += 1) {
						const w = words[i];
						if (w.g === undefined) continue;
						const next = words[i + 1];
						const bridge = next && w.m !== undefined && next.m === w.m && next.g === w.g;
						out.push({ s: w.s, e: bridge ? next.s : w.e, g: w.g, multi: w.m !== undefined, end: w.e });
					}
					return out;
				}

				Repeater {
					model: marks.pieces

					Rectangle {
						id: mark

						required property var modelData
						readonly property rect a: edit.positionToRectangle(mark.modelData.s)
						readonly property rect b: edit.positionToRectangle(mark.modelData.e)
						// a bridge that would cross a wrap stops at the word
						readonly property rect wordEnd: edit.positionToRectangle(mark.modelData.end)
						readonly property bool oneLine: Math.abs(mark.a.y - mark.b.y) < 2
						readonly property color tone: row.sheet.colourOf(mark.modelData.g)

						x: mark.a.x - 3
						y: mark.a.y + 1
						width: mark.oneLine ? mark.b.x - mark.a.x + (mark.modelData.end === mark.modelData.e ? 6 : 0) : mark.wordEnd.x - mark.a.x + 6
						height: mark.a.height - 1
						radius: 6
						color: Qt.alpha(mark.tone, mark.modelData.multi ? 0.2 : 0.16)
						opacity: 0
						scale: 0.85
						Component.onCompleted: {
							mark.opacity = 1;
							mark.scale = 1;
						}

						Behavior on opacity {
							Anim {
								duration: Motion.medium
							}
						}

						Behavior on scale {
							SpatialAnim {}
						}

						Behavior on x {
							enabled: mark.opacity === 1
							SpatialAnim {
								duration: Motion.short
							}
						}

						Behavior on width {
							enabled: mark.opacity === 1
							SpatialAnim {
								duration: Motion.short
							}
						}

						Behavior on color {
							ColorAnim {}
						}

						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.leftMargin: 3
							anchors.rightMargin: 3
							height: 2
							radius: 1
							color: Qt.alpha(mark.tone, 0.85)
						}
					}
				}

				// a word that comes back again and again
				Repeater {
					model: (row.shownInfo?.words || []).filter(w => w.r >= 3)

					Row {
						id: repeated

						required property var modelData
						readonly property rect a: edit.positionToRectangle(repeated.modelData.s)
						readonly property rect b: edit.positionToRectangle(repeated.modelData.e)

						x: repeated.a.x
						y: repeated.a.y + repeated.a.height + 1
						spacing: 3

						Repeater {
							model: Math.max(1, Math.floor((repeated.b.x - repeated.a.x) / 5))

							Rectangle {
								width: 2
								height: 2
								radius: 1
								color: Theme.warning
								opacity: 0.8
							}
						}
					}
				}
			}

			TextEdit {
				id: edit

				y: row.header ? 2 : 6
				width: parent.width
				text: row.text
				wrapMode: TextEdit.Wrap
				textFormat: TextEdit.PlainText
				selectByMouse: true
				persistentSelection: false
				color: row.header ? Theme.primary : Theme.text
				selectionColor: Qt.alpha(Theme.primary, 0.35)
				selectedTextColor: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: row.header ? Theme.size.small : row.sheet.fontSize
				font.weight: row.header ? Font.Bold : Font.Normal
				font.letterSpacing: row.header ? 1.6 : 0
				font.capitalization: row.header ? Font.AllUppercase : Font.MixedCase
				cursorDelegate: Item {}
				focus: row.active

				onTextChanged: if (edit.text !== row.text) Rhymes.typed(row.index, edit.text)
				onCursorPositionChanged: if (edit.activeFocus) {
					Rhymes.cursorAt(row.index, edit.cursorPosition);
					row.sheet.caretMoved();
				}
				onActiveFocusChanged: if (edit.activeFocus) {
					row.sheet.focusRow(row.index);
					Rhymes.cursorAt(row.index, edit.cursorPosition);
				}
				onSelectedTextChanged: if (edit.selectedText !== "") row.sheet.selectionWord = edit.selectedText

				Keys.onPressed: event => row.sheet.key(row, event)
			}

			// what the hook says, when it only comes back
			Item {
				anchors.left: edit.left
				anchors.right: parent.right
				anchors.verticalCenter: edit.verticalCenter
				visible: row.header

				Rectangle {
					x: edit.contentWidth + 14
					anchors.verticalCenter: parent.verticalCenter
					width: Math.max(0, parent.width - x)
					height: 1
					color: Theme.outline
				}
			}
		}

		Loader {
			active: row.repeats
			visible: active
			width: parent.width

			sourceComponent: Clickable {
				id: ghost

				readonly property int from: row.section?.ref ?? -1
				readonly property var texts: {
					const out = [];
					void Rhymes.analysis;
					for (let i = ghost.from + 1; i >= 1 && i < Rhymes.lines.count; i += 1) {
						const text = Rhymes.lines.get(i).text;
						if (/^\s*\[[^\]]+\]\s*$/.test(text)) break;
						if (text.trim() !== "") out.push(text);
					}
					return out;
				}

				width: parent.width
				height: ghostColumn.implicitHeight + 16
				radius: Theme.radius.medium
				color: Theme.layer1
				onClicked: Rhymes.jump(ghost.from + 1, 0)

				Column {
					id: ghostColumn

					x: 14
					y: 8
					width: parent.width - 28
					spacing: 2

					Repeater {
						model: ghost.texts

						Item {
							id: ghostLine

							required property string modelData
							required property int index
							readonly property real t: {
								void row.refs;
								return Rhymes.refTimes(row.index)[ghostLine.index] ?? -1;
							}
							readonly property bool playing: Rhymes.playingMark?.row === row.index && Rhymes.playingMark?.ref === ghostLine.index

							width: parent.width
							height: Math.max(ghostText.implicitHeight, 26)

							StyledText {
								id: ghostText

								anchors.verticalCenter: parent.verticalCenter
								width: parent.width
								text: ghostLine.modelData
								elide: Text.ElideRight
								font.pixelSize: row.sheet.fontSize - 2
								font.italic: true
								tone: ghostLine.playing ? Theme.primary : Theme.textSubtle
							}

							// its time, where the times of the lines are
							Clickable {
								x: -ghostColumn.x - ghost.x - 14 - width
								anchors.verticalCenter: ghostText.verticalCenter
								height: 22
								width: refLabel.implicitWidth + 14
								radius: height / 2
								visible: Rhymes.hasBeat
								opacity: ghostLine.t >= 0 || row.hovered || row.active ? 1 : 0
								color: ghostLine.playing ? Theme.primary : (ghostLine.t >= 0 ? Theme.layer2 : "transparent")
								tint: ghostLine.playing ? Theme.onPrimary : Theme.text
								acceptedButtons: Qt.LeftButton | Qt.RightButton
								sound: ""
								onClicked: {
									if (ghostLine.t >= 0) Rhymes.play(Math.max(0, ghostLine.t - 0.15));
									else Rhymes.stampRef(row.index, ghostLine.index, Rhymes.beatPlaying ? undefined : Rhymes.cue);
								}
								onRightClicked: Rhymes.unstampRef(row.index, ghostLine.index)

								Behavior on color {
									ColorAnim {}
								}

								Behavior on opacity {
									Anim {}
								}

								StyledText {
									id: refLabel

									anchors.centerIn: parent
									text: ghostLine.t >= 0 ? Format.clock(ghostLine.t, 1) : "+"
									tabular: true
									font.pixelSize: Theme.size.small
									font.weight: ghostLine.playing ? Font.DemiBold : Font.Normal
									tone: ghostLine.playing ? Theme.onPrimary : (ghostLine.t >= 0 ? Theme.textMuted : Theme.textSubtle)
								}
							}
						}
					}
				}

				Glyph {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 8
					icon: "repeat"
					size: 14
					color: Theme.textFaint
				}
			}
		}
	}

	// ── the scheme, the syllables, the stresses ────────────────────────────
	Item {
		id: side

		x: row.sheet.margin + row.sheet.textWidth + 14
		y: column.y + 6
		width: 86
		height: 24
		visible: !row.header && row.text.trim() !== ""

		readonly property var info: row.shownInfo
		readonly property int ending: {
			const words = side.info?.words || [];
			const last = words[words.length - 1];
			return last && last.g !== undefined ? last.g : -1;
		}
		readonly property color tone: side.ending >= 0 ? row.sheet.colourOf(side.ending) : Theme.textFaint

		Rectangle {
			id: letter

			width: 22
			height: 22
			radius: 11
			color: side.ending >= 0 ? Qt.alpha(side.tone, 0.22) : "transparent"
			border.width: side.info?.self ? 1.5 : (side.ending >= 0 ? 0 : 1)
			border.color: side.info?.self ? Theme.warning : Theme.outline
			opacity: side.info?.scheme ? 1 : 0

			Behavior on color {
				ColorAnim {}
			}

			Behavior on opacity {
				Anim {}
			}

			RollText {
				anchors.centerIn: parent
				text: side.info?.scheme ?? ""
				tone: side.ending >= 0 ? side.tone : Theme.textSubtle
				pixelSize: Theme.size.small
			}
		}

		Column {
			anchors.left: letter.right
			anchors.leftMargin: 10
			anchors.verticalCenter: letter.verticalCenter
			spacing: 3

			Row {
				spacing: 5

				RollText {
					text: String(side.info?.syl ?? "")
					tone: Theme.textMuted
					pixelSize: Theme.size.body
					weight: Font.Medium
					minimumWidth: 14
				}

				// against the line before it in the section
				StyledText {
					readonly property int delta: {
						if (!side.info) return 0;
						const lines = Rhymes.analysis.lines || [];
						for (let i = row.index - 1; i >= 0; i -= 1) {
							const other = lines[i];
							if (!other || /^\s*\[[^\]]+\]\s*$/.test(other.t)) return 0;
							if (other.syl > 0) return side.info.syl - other.syl;
						}
						return 0;
					}

					anchors.verticalCenter: parent.verticalCenter
					visible: Math.abs(delta) >= 2
					text: delta > 0 ? `+${delta}` : `−${-delta}`
					font.pixelSize: Theme.size.tiny
					tone: Theme.warning
				}
			}

			Row {
				spacing: 2
				visible: Rhymes.setting("stress", true)

				Repeater {
					model: String(side.info?.stress ?? "").slice(0, 18).split("").filter(c => c !== "")

					Rectangle {
						required property string modelData

						width: 4
						height: 4
						radius: 2
						color: modelData === "1" ? Theme.textMuted : Theme.textFaint
						scale: modelData === "1" ? 1 : 0.7
					}
				}
			}
		}
	}

	// one moment of light when the line is found (search, a version)
	Rectangle {
		id: flashLight

		anchors.fill: parent
		anchors.leftMargin: row.sheet.margin - 10
		anchors.rightMargin: row.sheet.margin - 10
		radius: Theme.radius.small
		color: Theme.primary
		opacity: 0

		SequentialAnimation {
			id: flashing

			Anim {
				target: flashLight
				property: "opacity"
				to: 0.22
				duration: Motion.short
			}

			Anim {
				target: flashLight
				property: "opacity"
				to: 0
				duration: Motion.extraLong * 2
			}
		}
	}

	Connections {
		target: Rhymes

		function onFlash(at) {
			if (at === row.index) flashing.restart();
		}
	}
}
