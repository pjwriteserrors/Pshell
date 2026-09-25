import QtQuick
import QtQuick.Controls
import qs.style.theme

// Multi-line input with the same focus language as Field.
Rectangle {
	id: root

	property alias text: area.text
	property alias area: area
	property string placeholder: ""
	property bool monospace: false
	readonly property bool focused: area.activeFocus

	signal edited(string text)

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
			selectByMouse: true
			background: null
			padding: 10
			onTextChanged: root.edited(text)
		}
	}
}
