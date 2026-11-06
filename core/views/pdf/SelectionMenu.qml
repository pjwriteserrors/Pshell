pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Above text that was selected: what is done with it, springing up from
// the words. Copy, mark it in a colour, underline, strike out, a note, black
// it out for good; and what the shell does with words – translate, ask the
// AI, read aloud, keep as a note (Pdf.selectionAction, the shell's part).
Item {
	id: root

	// where it may go (the reader's area in the view's coordinates)
	property rect bounds: Qt.rect(0, 0, 0, 0)
	property bool live: false
	property rect box: Qt.rect(0, 0, 0, 0)

	function showAt(rect) {
		root.box = rect;
		root.live = true;
	}

	function hide() {
		root.live = false;
	}

	readonly property bool below: root.box.y - card.height - 10 < root.bounds.y
	x: Math.max(root.bounds.x + 8, Math.min(root.bounds.x + root.bounds.width - card.width - 8, root.box.x + root.box.width / 2 - card.width / 2))
	// above the words, else below them, else (a whole page chosen) at the top of what is seen
	y: Math.max(root.bounds.y + 8, Math.min(root.bounds.y + root.bounds.height - card.height - 8, root.below ? root.box.y + root.box.height + 10 : root.box.y - card.height - 10))
	width: card.width
	height: card.height
	visible: card.opacity > 0.01

	readonly property var colours: ["#ffd54f", "#81c784", "#64b5f6", "#f48fb1"]
	readonly property bool shellActions: typeof Pdf.selectionAction === "function"

	function run(name) {
		if (root.shellActions) Pdf.selectionAction(name);
		root.hide();
	}

	Rectangle {
		id: card

		width: row.implicitWidth + 12
		height: 44
		radius: 22
		color: Qt.alpha(Theme.bg, 0.97)
		border.color: Theme.outline
		opacity: root.live && !!Pdf.selection ? 1 : 0
		scale: root.live && !!Pdf.selection ? 1 : 0.86
		transformOrigin: root.below ? Item.Top : Item.Bottom

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.OutBack
				easing.overshoot: 1.6
			}
		}

		Row {
			id: row

			anchors.centerIn: parent
			spacing: 2

			MenuKey {
				icon: "content_copy"
				tip: "Copy"
				onClicked: {
					if (root.shellActions) Pdf.selectionAction("copy");
					else Quickshell.execDetached(["wl-copy", "--", Pdf.selectionText]);
					root.hide();
				}
			}

			Separator {}

			// marked in a colour: the dots
			Repeater {
				model: root.colours

				Clickable {
					id: dot

					required property string modelData

					anchors.verticalCenter: parent.verticalCenter
					width: 26
					height: 26
					radius: 13
					color: "transparent"
					onClicked: {
						Pdf.style = Object.assign({}, Pdf.style, { color: dot.modelData });
						Pdf.markSelection("highlight", { color: dot.modelData });
						root.hide();
					}

					Rectangle {
						anchors.centerIn: parent
						width: dot.hovered ? 20 : 16
						height: width
						radius: width / 2
						color: dot.modelData
						border.color: Qt.darker(dot.modelData, 1.25)

						Behavior on width {
							SpatialAnim {
								duration: Motion.short
							}
						}
					}
				}
			}

			MenuKey {
				icon: "format_underline"
				tip: "Underline"
				onClicked: {
					Pdf.markSelection("underline");
					root.hide();
				}
			}
			MenuKey {
				icon: "format_strikethrough_variant"
				tip: "Strike out"
				onClicked: {
					Pdf.markSelection("strike");
					root.hide();
				}
			}
			MenuKey {
				icon: "note_plus_outline"
				tip: "A note on it"
				onClicked: {
					Pdf.markSelection("highlight", { note: " " });
					root.hide();
				}
			}
			MenuKey {
				icon: "marker_cancel"
				tip: "Black out for good"
				onClicked: {
					Pdf.markSelection("redact");
					root.hide();
				}
			}

			Separator {
				visible: root.shellActions
			}

			MenuKey {
				visible: root.shellActions
				icon: "translate"
				tip: "Translate"
				onClicked: root.run("translate")
			}
			MenuKey {
				visible: root.shellActions
				icon: "lightbulb_on_outline"
				tip: "Explain"
				onClicked: root.run("explain")
			}
			MenuKey {
				visible: root.shellActions
				icon: "creation"
				tip: "Ask the AI"
				onClicked: root.run("ask")
			}
			MenuKey {
				visible: root.shellActions
				icon: "account_voice"
				tip: "Read aloud"
				onClicked: root.run("speak")
			}
			MenuKey {
				visible: root.shellActions
				icon: "note_text_outline"
				tip: "Keep as a note"
				onClicked: root.run("note")
			}
			MenuKey {
				visible: root.shellActions
				icon: "checkbox_marked_circle_plus_outline"
				tip: "A task"
				onClicked: root.run("todo")
			}
			MenuKey {
				visible: root.shellActions
				icon: "web"
				tip: "Search the web"
				onClicked: root.run("search")
			}
		}
	}

	component Separator: Rectangle {
		anchors.verticalCenter: parent?.verticalCenter
		width: 1
		height: 22
		color: Theme.outline
	}

	component MenuKey: IconButton {
		id: key

		property string tip: ""

		anchors.verticalCenter: parent?.verticalCenter
		width: 34
		height: 34
		iconSize: 18

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: -height - 10
			width: tipLabel.implicitWidth + 16
			height: 24
			radius: 12
			color: Qt.rgba(0.06, 0.06, 0.07, 0.92)
			opacity: key.hovered ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				SequentialAnimation {
					PauseAnimation {
						duration: key.hovered ? 400 : 0
					}
					Anim {
						duration: Motion.short
					}
				}
			}

			StyledText {
				id: tipLabel

				anchors.centerIn: parent
				text: key.tip
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.small
			}
		}
	}
}
