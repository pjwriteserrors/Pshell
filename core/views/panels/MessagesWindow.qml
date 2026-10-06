pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.core.views.panels.messages

// Messages as a window of its own, for keeping it beside the work instead of
// under the bar. The compositor places it like any other window.
FloatingWindow {
	id: root

	title: "Messages"
	visible: false
	implicitWidth: 1180
	implicitHeight: 800
	minimumSize: Qt.size(400, 420)
	color: Theme.base

	function follow() {
		root.visible = Messages.windowed && Messages.windowOpen;
	}

	// closed with the compositor's own means
	onVisibleChanged: {
		if (root.visible) view.entered(Messages.page);
		else if (Messages.windowOpen) Messages.windowOpen = false;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Messages
		function onWindowOpenChanged() {
			root.follow();
		}
		function onWindowedChanged() {
			root.follow();
		}
		// asked for again while it is up: a new chat, the settings
		function onAskedChanged() {
			if (root.visible) view.entered(Messages.page);
		}
	}

	MessagesView {
		id: view

		anchors.fill: parent
		anchors.margins: Theme.panelPadding
	}
}
