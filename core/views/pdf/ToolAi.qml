pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Asking about the document (the shell's local model): a summary, a question
// about all of it in the launcher's chat, the selected words translated or
// explained, its tables taken out, a name for the file, read aloud; and for
// an invoice its amount, due date and IBAN at hand.
PaneFrame {
	id: root

	property Item dock: null
	property string answerTitle: ""
	property string answer: ""

	title: "Ask"
	subtitle: Pdf.asking ? "Thinking…" : "With the local model – nothing leaves the computer"
	onClose: Pdf.tool = ""

	Connections {
		target: Pdf

		function onAiAnswer(title, text) {
			root.answerTitle = title;
			root.answer = text;
		}
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Sum it up"
			icon: "text_box_search_outline"
			variant: "filled"
			enabled: typeof Pdf.summarize === "function"
			onActivated: Pdf.summarize()
		}

		TextButton {
			text: Pdf.speaking ? "Stop reading" : "Read it aloud"
			icon: Pdf.speaking ? "stop" : "account_voice"
			enabled: typeof Pdf.readAloud === "function"
			onActivated: Pdf.speaking ? Pdf.stopSpeaking() : Pdf.readAloud()
		}

		TextButton {
			text: "The table on this page"
			icon: "table_arrow_right"
			enabled: typeof Pdf.tableOut === "function"
			onActivated: Pdf.tableOut(Pdf.page)
		}
	}

	Row {
		width: parent.width
		spacing: 6

		Field {
			id: question

			width: parent.width - askButton.width - 6
			height: 38
			icon: "chat_question_outline"
			placeholder: "Ask about the document"
			onAccepted: askButton.activated()
		}

		TextButton {
			id: askButton

			text: "Ask"
			icon: "send"
			enabled: typeof Pdf.askAi === "function"
			onActivated: {
				Pdf.askAi(question.text.trim());
				question.text = "";
			}
		}
	}

	// the selected words
	Column {
		width: parent.width
		spacing: 6
		visible: Pdf.selectionText !== "" && typeof Pdf.selectionAction === "function"

		SectionLabel {
			text: "The selected words"
		}

		StyledText {
			width: parent.width
			text: `“${Pdf.selectionText}”`
			wrapMode: Text.WordWrap
			maximumLineCount: 3
			elide: Text.ElideRight
			font.italic: true
			tone: Theme.textMuted
		}

		Flow {
			width: parent.width
			spacing: 6

			Repeater {
				model: [{ id: "translate", label: "Translate", icon: "translate" }, { id: "explain", label: "Explain", icon: "lightbulb_outline" }, { id: "ask", label: "Ask about it", icon: "chat_outline" },
					{ id: "speak", label: "Read aloud", icon: "account_voice" }, { id: "note", label: "Keep as a note", icon: "note_outline" }, { id: "todo", label: "Make a task", icon: "checkbox_marked_circle_plus_outline" }]

				delegate: TextButton {
					required property var modelData

					text: modelData.label
					icon: modelData.icon
					onActivated: Pdf.selectionAction(modelData.id)
				}
			}
		}
	}

	// the answer, appearing
	Rectangle {
		width: parent.width
		visible: root.answer !== "" || Pdf.asking
		height: answerColumn.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.layer2
		opacity: visible ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Behavior on height {
			SpatialAnim {}
		}

		Column {
			id: answerColumn

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 8

			Row {
				spacing: 8

				Spinner {
					width: 16
					height: 16
					visible: Pdf.asking
				}

				StyledText {
					text: Pdf.asking ? "Thinking…" : root.answerTitle
					font.weight: Font.DemiBold
				}
			}

			TextEdit {
				width: parent.width
				visible: root.answer !== ""
				text: root.answer
				readOnly: true
				selectByMouse: true
				wrapMode: TextEdit.Wrap
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.body
			}

			Row {
				spacing: 6
				visible: root.answer !== ""

				TextButton {
					text: "Copy"
					icon: "content_copy"
					variant: "ghost"
					onActivated: {
						Quickshell.execDetached(["wl-copy", "--", root.answer]);
						Sounds.play("copied");
					}
				}

				TextButton {
					text: "As a note on the page"
					icon: "note_plus_outline"
					variant: "ghost"
					onActivated: {
						const p = Pdf.pages[Pdf.page];
						if (!p) return;
						Pdf.addItem({ kind: "note", page: p.id, at: [20, 20], text: root.answer, color: "#ffd54f" }, "Note");
					}
				}
			}
		}
	}

	// ── an invoice ─────────────────────────────────────────────────────────
	Rectangle {
		width: parent.width
		visible: !!Pdf.invoice
		height: invoiceColumn.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.primarySoft

		Column {
			id: invoiceColumn

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 8

			Row {
				spacing: 8

				Glyph {
					icon: "receipt_outline"
					size: 18
					color: Theme.primary
				}

				StyledText {
					text: "An invoice"
					font.weight: Font.DemiBold
				}
			}

			StyledText {
				width: parent.width
				wrapMode: Text.WordWrap
				text: [Pdf.invoiceText?.() ?? "", Pdf.invoice?.due ? `due ${Pdf.invoice.due}` : "", Pdf.invoice?.number ? `No. ${Pdf.invoice.number}` : ""].filter(t => t).join(" · ")
			}

			Flow {
				width: parent.width
				spacing: 6

				TextButton {
					visible: !!Pdf.invoice?.iban
					text: "Copy the IBAN"
					icon: "bank_outline"
					onActivated: Pdf.copyInvoice("iban")
				}

				TextButton {
					visible: !!Pdf.invoice?.amount
					text: "Copy the amount"
					icon: "currency_eur"
					onActivated: Pdf.copyInvoice("amount")
				}

				TextButton {
					text: "Remind me to pay"
					icon: "bell_outline"
					onActivated: Pdf.remindInvoice()
				}

				TextButton {
					text: Pdf.invoiceCustomer ? `File under ${Pdf.invoiceCustomer.name}` : "File it"
					icon: "folder_move_outline"
					onActivated: Pdf.fileInvoice()
				}
			}
		}
	}
}
