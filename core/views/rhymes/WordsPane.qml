pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Words for the word at the cursor: of the same meaning (those that rhyme
// with the end of the line above first), and the words the song uses again
// and again.
Item {
	id: pane

	signal picked(string text)

	property string word: ""
	property string rhymeWith: ""
	readonly property var found: Rhymes.synonyms

	function ask(word, rhymeWith) {
		pane.word = word;
		pane.rhymeWith = rhymeWith || "";
		Rhymes.askSynonyms(word, pane.rhymeWith);
	}

	// how often each word comes back, with the lines it is in
	readonly property var repeated: {
		const counts = {};
		const lines = Rhymes.analysis.lines || [];
		for (let i = 0; i < lines.length; i += 1) {
			for (const w of lines[i].words || []) {
				if (!(w.r >= 3)) continue;
				const text = String(lines[i].t).slice(w.s, w.e).toLowerCase();
				if (!counts[text]) counts[text] = { word: text, count: w.r, rows: [] };
				counts[text].rows.push(i);
			}
		}
		return Object.values(counts).sort((a, b) => b.count - a.count);
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: column.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: column

			x: 16
			y: 4
			width: flick.width - 32
			spacing: 18

			Field {
				id: field

				width: parent.width
				icon: "magnify"
				placeholder: "A word"
				text: pane.word
				onAccepted: pane.ask(field.text.trim(), pane.rhymeWith)
			}

			Column {
				width: parent.width
				spacing: 8
				visible: (pane.found?.rhyming?.length ?? 0) > 0

				StyledText {
					text: `Rhymes with ${pane.rhymeWith}`
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					font.letterSpacing: 1
					font.capitalization: Font.AllUppercase
					tone: Theme.primary
				}

				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: pane.found?.rhyming ?? []

						WordChip {
							required property string modelData
							required property int index

							text: modelData
							order: index
							strong: true
							onClicked: mouse => {
								if (mouse.button === Qt.RightButton) pane.ask(modelData, pane.rhymeWith);
								else pane.picked(modelData);
							}
						}
					}
				}
			}

			Repeater {
				model: pane.found?.senses ?? []

				Column {
					id: sense

					required property var modelData
					required property int index

					width: column.width
					spacing: 8

					StyledText {
						text: sense.modelData.kind
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						font.letterSpacing: 1
						font.capitalization: Font.AllUppercase
						tone: Theme.textSubtle
					}

					Flow {
						width: parent.width
						spacing: 6

						Repeater {
							model: sense.modelData.words.concat(sense.modelData.broader.map(w => "↑ " + w))

							WordChip {
								required property string modelData
								required property int index

								text: modelData
								order: index + sense.index * 3
								opacity: modelData.startsWith("↑") ? 0.7 : 1
								onClicked: mouse => {
									const word = modelData.replace(/^↑ /, "");
									if (mouse.button === Qt.RightButton) pane.ask(word, pane.rhymeWith);
									else pane.picked(word);
								}
							}
						}
					}
				}
			}

			Column {
				width: parent.width
				spacing: 8
				visible: pane.repeated.length > 0

				StyledText {
					text: "Again and again"
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					font.letterSpacing: 1
					font.capitalization: Font.AllUppercase
					tone: Theme.warning
				}

				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: pane.repeated

						WordChip {
							id: again

							required property var modelData
							required property int index
							property int next: 0

							text: `${modelData.word}  ×${modelData.count}`
							order: index
							accent: Theme.warning
							onClicked: {
								// from one place of it to the next
								const rows = modelData.rows;
								Rhymes.jump(rows[again.next % rows.length], 0);
								Rhymes.flash(rows[again.next % rows.length]);
								again.next += 1;
							}
						}
					}
				}
			}
		}
	}
}
