import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.core.services

// Multi-line input with the same focus language as Field.
Rectangle {
	id: root

	property alias text: area.text
	property alias area: area
	property string placeholder: ""
	property bool monospace: false
	// bold, italics and pictures in the text; `text` is then markup
	property bool rich: false
	// what is typed here is corrected (Autocorrect)
	property bool autocorrect: false
	readonly property bool focused: area.activeFocus
	// the keyboard is here: a field keeps its focus in a panel that is closed
	readonly property bool typing: root.autocorrect && root.focused && Window.active

	onTypingChanged: {
		if (root.typing) Autocorrect.enter(root);
		else Autocorrect.leave(root);
	}
	Component.onDestruction: Autocorrect.leave(root)

	// Ctrl+V asks first: `pasting` is emitted instead of the text going in, paste() puts it in
	property bool asksPaste: false

	signal edited(string text)
	signal pasting

	function paste() {
		area.paste();
	}

	function focusInput() {
		area.forceActiveFocus();
	}

	implicitHeight: 96
	implicitWidth: 240
	radius: Theme.radius.large
	color: root.focused ? Theme.layer2 : Theme.layer1
	border.width: root.focused ? 1.5 : 0
	border.color: Qt.alpha(Theme.primary, 0.85)

	Behavior on color {
		ColorAnim {}
	}

	ScrollView {
		id: scroll

		anchors.fill: parent
		anchors.margins: 4
		clip: true
		ScrollBar.vertical: ThinScrollBar {}

		TextArea {
			id: area

			color: Theme.text
			selectionColor: Qt.alpha(Theme.primary, 0.4)
			selectedTextColor: Theme.text
			placeholderText: root.placeholder
			placeholderTextColor: Theme.textSubtle
			font.family: root.monospace ? Theme.monoFamily : Theme.fontFamily
			font.pixelSize: Theme.size.body
			wrapMode: TextEdit.Wrap
			textFormat: root.rich ? TextEdit.RichText : TextEdit.PlainText
			selectByMouse: true
			background: null
			padding: 10
			onTextChanged: root.edited(text)
			Keys.onPressed: event => {
				if (root.asksPaste && event.matches(StandardKey.Paste)) {
					event.accepted = true;
					root.pasting();
				}
			}
		}
	}
}
