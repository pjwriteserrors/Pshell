pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Rhymes for the last three words in front of the cursor, cut every way
// they can be ("Trucks no more", "Trucks · no more", "Trucks no · more" …):
// for each piece what rhymes over all its syllables, what rhymes at the
// end, what comes close and what the user wrote before.
Item {
	id: pane

	signal picked(string text)
	signal look(string word)

	property int split: 0
	readonly property var found: Rhymes.around
	readonly property var splits: pane.found?.splits ?? []
	readonly property var pieces: pane.splits[Math.min(pane.split, pane.splits.length - 1)] ?? []
	readonly property var kinds: ({ multi: "Multi", perfect: "Perfect", near: "Near", yours: "Yours" })

	onFoundChanged: if (pane.split >= pane.splits.length) pane.split = 0

	function spanOf(piece) {
		return (pane.found?.spans ?? []).find(s => s.from === piece.from && s.to === piece.to) ?? null;
	}

	Column {
		id: head

		x: 16
		y: 4
		width: parent.width - 32
		spacing: 10

		// the ways of cutting the words
		Flow {
			width: parent.width
			spacing: 6
			visible: pane.splits.length > 1

			Repeater {
				model: pane.splits

				Chip {
					required property var modelData
					required property int index

					text: modelData.map(p => p.text).join("  ·  ")
					selected: pane.split === index
					onClicked: pane.split = index
				}
			}
		}
	}

	Flickable {
		id: flick

		anchors.top: head.bottom
		anchors.topMargin: 10
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		contentHeight: pieceColumn.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: pieceColumn

			x: 16
			width: flick.width - 32
			spacing: 22

			Repeater {
				model: pane.pieces

				Column {
					id: piece

					required property var modelData
					readonly property var span: pane.spanOf(piece.modelData)

					width: pieceColumn.width
					spacing: 12

					Row {
						spacing: 10
						visible: pane.pieces.length > 1 || (pane.found?.words?.length ?? 0) > 0

						StyledText {
							text: piece.modelData.text
							font.pixelSize: Theme.size.heading
							font.weight: Font.DemiBold
						}

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: syl.implicitWidth + 12
							height: 20
							radius: 10
							color: Theme.layer2
							visible: (piece.span?.syllables ?? 0) > 0

							StyledText {
								id: syl

								anchors.centerIn: parent
								text: `${piece.span?.syllables ?? 0}`
								font.pixelSize: Theme.size.small
								tone: Theme.textMuted
							}
						}
					}

					Repeater {
						model: piece.span?.groups ?? []

						Column {
							id: group

							required property var modelData
							required property int index

							width: piece.width
							spacing: 8

							StyledText {
								text: pane.kinds[group.modelData.kind] ?? group.modelData.kind
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
									model: group.modelData.items.slice(0, group.modelData.kind === "multi" ? 36 : 30)

									WordChip {
										required property var modelData
										required property int index

										text: modelData.text
										syllables: modelData.syllables || 0
										order: index + group.index * 4
										strong: group.modelData.kind === "multi" || group.modelData.kind === "yours"
										accent: group.modelData.kind === "yours" ? Theme.tertiary : Theme.primary
										onClicked: mouse => {
											if (mouse.button === Qt.RightButton) pane.look(modelData.text);
											else pane.picked(modelData.text);
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	Glyph {
		anchors.centerIn: parent
		visible: !Rhymes.missing && (pane.found === null || pane.splits.length === 0)
		icon: "format_quote_open"
		size: 48
		color: Theme.textFaint
	}

	Column {
		anchors.centerIn: parent
		spacing: 12
		visible: Rhymes.missing

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: "cloud_off_outline"
			size: 40
			color: Theme.textFaint
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: "No dictionary"
			tone: Theme.textMuted
		}

		TextButton {
			anchors.horizontalCenter: parent.horizontalCenter
			text: "Try again"
			onClicked: Rhymes.retry()
		}
	}
}
