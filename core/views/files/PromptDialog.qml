import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One line to type: the name of a new tag or collection, a password.
DialogFrame {
	id: root

	property string title: ""
	property var done: null

	function open(title, placeholder, text, done, password) {
		root.title = title;
		root.done = done;
		field.placeholder = placeholder;
		field.password = password;
		field.text = text;
		root.show();
		Qt.callLater(() => {
			field.focusInput();
			field.input.selectAll();
		});
	}

	function finish(keep) {
		const done = root.done;
		const text = field.text;
		root.hide();
		if (keep && done && text.trim() !== "") done(text);
	}

	cardWidth: 400
	onDismissed: root.finish(false)

	ColumnLayout {
		width: parent.width
		spacing: 14

		StyledText {
			text: root.title
			font.pixelSize: Theme.size.title
			font.weight: Font.DemiBold
		}

		Field {
			id: field

			Layout.fillWidth: true
			onAccepted: root.finish(true)
			onEscapePressed: root.finish(false)
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight
			spacing: 8

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.finish(false)
			}

			TextButton {
				text: "OK"
				variant: "filled"
				onClicked: root.finish(true)
			}
		}
	}
}
