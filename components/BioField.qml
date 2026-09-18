pragma ComponentBehavior: Bound

import QtQuick

// Somewhere to type. No box: the text sits on a bone line that lights along its
// whole length while the field has the keyboard, so focus is visible without
// anything being outlined.
Item {
	id: field

	property alias text: input.text
	property alias placeholder: ghost.text
	property alias echoMode: input.echoMode
	property alias inputItem: input
	property bool clearOnAccept: false

	signal accepted(string value)
	signal edited(string value)

	implicitHeight: 30
	implicitWidth: 160

	function take() { input.forceActiveFocus(); }

	TextInput {
		id: input
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.bottomMargin: Bio.s2
		verticalAlignment: TextInput.AlignVCenter
		font.family: Bio.sans
		font.pixelSize: Bio.sizeBody
		color: Bio.text
		selectionColor: Qt.alpha(Bio.organ, 0.35)
		selectedTextColor: Bio.text
		selectByMouse: true
		clip: true

		onTextChanged: field.edited(text)
		onAccepted: {
			field.accepted(text);
			if (field.clearOnAccept) text = "";
		}
	}

	BioText {
		id: ghost
		anchors.left: input.left
		anchors.verticalCenter: input.verticalCenter
		role: "body"
		tone: "faint"
		visible: input.text === ""
	}

	// The line under it, and the live one that grows over it from the left.
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Bio.ribThin
		color: Bio.boneFaint
	}

	Rectangle {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		width: input.activeFocus ? parent.width : 0
		height: Bio.rib
		color: Bio.organ

		Behavior on width {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}
	}
}
