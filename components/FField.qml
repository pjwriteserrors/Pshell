import QtQuick

// Text on a wire. The words sit on the filament, the caret is a spark, and
// the wire lights up under what has been typed. No box.
FocusScope {
	id: field

	property alias text: input.text
	property alias input: input
	property string placeholder: ""
	property string icon: ""
	property bool mono: false
	property int fontSize: Filament.textMd
	property bool showWire: true
	readonly property bool focused: input.activeFocus

	signal accepted()
	signal escaped()

	implicitHeight: fontSize + 18
	implicitWidth: 200

	function take() { input.forceActiveFocus(); }
	function selectAll() { input.selectAll(); }

	FIcon {
		id: iconItem
		visible: field.icon !== ""
		anchors.left: parent.left
		anchors.verticalCenter: input.verticalCenter
		name: field.icon
		size: 15
		color: field.focused ? Filament.charge : Filament.inkMute
		Behavior on color { ColorAnimation { duration: Filament.quick } }
	}

	TextInput {
		id: input
		anchors.left: field.icon !== "" ? iconItem.right : parent.left
		anchors.leftMargin: field.icon !== "" ? 10 : 0
		anchors.right: parent.right
		y: 2
		height: field.fontSize + 10
		focus: true
		color: Filament.ink
		selectionColor: Qt.alpha(Filament.charge, 0.35)
		selectedTextColor: Filament.ink
		font.family: field.mono ? Filament.fontMono : Filament.fontUi
		font.pixelSize: field.fontSize
		verticalAlignment: TextInput.AlignVCenter
		selectByMouse: true
		clip: true
		cursorDelegate: Item {
			width: 8
			Spark {
				anchors.centerIn: parent
				size: 5
				breathing: true
				visible: input.activeFocus
			}
		}
		Keys.onReturnPressed: event => { event.accepted = true; field.accepted(); }
		Keys.onEnterPressed: event => { event.accepted = true; field.accepted(); }
		Keys.onEscapePressed: event => { event.accepted = true; field.escaped(); }

		FText {
			anchors.fill: parent
			text: field.placeholder
			tone: "faint"
			font.family: input.font.family
			font.pixelSize: field.fontSize
			visible: input.text.length === 0
			verticalAlignment: Text.AlignVCenter
		}
	}

	Wire {
		visible: field.showWire
		anchors.left: input.left
		anchors.right: parent.right
		y: input.y + input.height + 4
		height: 2
		cold: Filament.wireDim
		lit: field.focused ? Math.min(1, Math.max(0.06, (input.contentWidth + 6) / Math.max(1, width))) : 0
	}
}
