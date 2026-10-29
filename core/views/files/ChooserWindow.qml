pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The file chooser of every app (through the portal, scripts/files/portal.py)
// and of the shell itself (Files.pick): the file manager in a window of its
// own, with a bar that asks what the app asks. It is up while a question
// waits; the file manager's own window stays as it was.
FloatingWindow {
	id: root

	readonly property var entry: Files.choosing
	readonly property bool saving: root.entry?.method === "SaveFile" || root.entry?.method === "SaveFiles"

	// niri floats it by this title (dotfiles/niri/pshell.kdl)
	title: root.entry ? `${Files.chooserTitle} – ${root.entry.title || (root.saving ? "Save" : "Open")}` : Files.chooserTitle
	visible: false
	implicitWidth: 1120
	implicitHeight: 740
	minimumSize: Qt.size(640, 440)
	color: Theme.base

	function follow() {
		if (root.entry) content.active = true;
		root.visible = root.entry !== null;
	}

	Component.onCompleted: root.follow()
	onEntryChanged: root.follow()

	// closed with the compositor's own means: nothing was chosen
	onVisibleChanged: {
		if (!root.visible && root.entry) Files.finishChoose(root.entry, { response: 1 });
		if (root.visible) {
			Sounds.play("open");
			if (content.item) {
				content.item.shown = true;
				content.item.takeFocus();
			}
		} else if (content.item) {
			content.item.shown = false;
		}
	}

	// built ahead of time, after the file manager's own window
	Timer {
		running: true
		interval: 8000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !root.entry
		focus: true
		sourceComponent: FilesView {
			focus: true
			chooserMode: true
			shown: root.visible
		}
		onLoaded: if (root.visible) content.item.takeFocus()
	}
}
