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

	// set while the window closes or comes back: it does not follow meanwhile
	property bool closing: false
	property bool showingAgain: false

	function follow() {
		if (root.closing) return;
		if (root.entry) content.active = true;
		if (!root.entry) root.visible = false;
		else if (!root.visible) root.showAgain();
	}

	// a window closed by the compositor still counts as wanted: asked to show
	// again it does nothing, unless it is told to hide first
	function showAgain() {
		root.showingAgain = true;
		root.visible = false;
		root.showingAgain = false;
		root.visible = true;
	}

	Component.onCompleted: root.follow()
	onEntryChanged: root.follow()

	// closed with the compositor's own means: nothing was chosen
	onVisibleChanged: {
		// the next question opens the window once this close is through
		if (!root.visible && root.entry && !root.showingAgain) {
			root.closing = true;
			Files.finishChoose(root.entry, { response: 1 });
			root.closing = false;
			if (root.entry) nextQuestion.restart();
			else root.visible = false;
		}
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

	Timer {
		id: nextQuestion

		interval: 150
		onTriggered: root.follow()
	}

	// not on the screen with a question open: nobody could answer it, and
	// every other app's would wait behind it
	Timer {
		running: root.entry !== null
		interval: 2000
		repeat: true
		onTriggered: {
			if (!root.visible || (Niri.ready && !Niri.windows.some(window => String(window.title).startsWith(Files.chooserTitle) && !String(window.title).endsWith("Open with") && /quickshell/i.test(String(window.app_id))))) root.showAgain();
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
		// from its file: named here, the file manager was compiled at every
		// start, whether it was opened or not
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("FilesView.qml"), { focus: true, chooserMode: true })
		onLoaded: {
			content.item.shown = Qt.binding(() => root.visible);
			if (root.visible) content.item.takeFocus();
		}
	}
}
