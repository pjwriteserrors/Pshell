import QtQuick
import qs.style.theme
import qs.core.services

// Renaming in place: the name without its extension is picked, Enter or a
// click elsewhere keeps the new name, Escape keeps the old one.
Rectangle {
	id: root

	property bool active: false
	property string path: ""
	property string name: ""
	property bool dir: false
	property var pane: null
	property bool centered: false
	property int fontSize: Theme.size.label

	implicitHeight: input.implicitHeight + 10
	height: implicitHeight
	radius: Theme.radius.small
	color: Theme.layer2
	border.width: 1.5
	border.color: Theme.primary

	property bool done: false

	function finish(keep) {
		if (root.done) return;
		root.done = true;
		const name = input.text.trim();
		if (root.pane) root.pane.renaming = "";
		if (keep && name !== "" && name !== root.name) {
			Files.rename(root.path, name);
		}
	}

	onActiveChanged: {
		if (!root.active) return;
		root.done = false;
		input.text = root.name;
		Qt.callLater(() => {
			input.forceActiveFocus();
			const dot = root.dir ? -1 : root.name.lastIndexOf(".");
			input.select(0, dot > 0 ? dot : root.name.length);
		});
	}

	TextInput {
		id: input

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		anchors.margins: 6
		horizontalAlignment: root.centered ? TextInput.AlignHCenter : TextInput.AlignLeft
		color: Theme.text
		selectionColor: Qt.alpha(Theme.primary, 0.45)
		selectedTextColor: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: root.fontSize
		clip: true
		selectByMouse: true

		Keys.onReturnPressed: root.finish(true)
		Keys.onEnterPressed: root.finish(true)
		Keys.onEscapePressed: root.finish(false)
		// the name stays in the field: these keys are the field's, not the view's
		Keys.onPressed: event => {
			if (event.key === Qt.Key_Tab) {
				root.finish(true);
				event.accepted = true;
			} else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_A) {
				input.selectAll();
				event.accepted = true;
			}
		}
		onActiveFocusChanged: if (!activeFocus && root.active) root.finish(true)
	}
}
