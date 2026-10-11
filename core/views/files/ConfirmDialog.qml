import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// "Delete for good?" and the like: a question with two answers.
DialogFrame {
	id: root

	property var question: ({})

	function ask(question) {
		root.question = question;
		root.show();
		keys.forceActiveFocus();
	}

	function answer(yes) {
		const run = root.question.run;
		root.hide();
		if (yes && typeof run === "function") run();
	}

	cardWidth: 420
	onDismissed: root.answer(false)

	Item {
		id: keys

		focus: root.shown
		Keys.onReturnPressed: root.answer(true)
		Keys.onEnterPressed: root.answer(true)
		Keys.onEscapePressed: root.answer(false)
	}

	ColumnLayout {
		width: parent.width
		spacing: 14

		RowLayout {
			spacing: 14

			Rectangle {
				Layout.alignment: Qt.AlignTop
				width: 44
				height: 44
				radius: 14
				color: Qt.tint(Theme.layer2, Qt.alpha(root.question.danger ? Theme.danger : Theme.primary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: root.question.danger ? "delete_alert_outline" : "help_circle_outline"
					size: 22
					color: root.question.danger ? Theme.danger : Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					Layout.fillWidth: true
					text: String(root.question.title || "")
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					wrapMode: Text.WordWrap
				}

				StyledText {
					Layout.fillWidth: true
					visible: text !== ""
					text: String(root.question.detail || "")
					tone: Theme.textMuted
					wrapMode: Text.WordWrap
				}
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight
			spacing: 8

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.answer(false)
			}

			TextButton {
				text: String(root.question.confirm || "OK")
				variant: root.question.danger ? "danger" : "filled"
				icon: root.question.danger ? "delete_outline" : "check"
				onClicked: root.answer(true)
			}
		}
	}
}
