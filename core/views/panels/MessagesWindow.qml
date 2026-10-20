import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views
import qs.core.views.panels.messages

// Messages as a window of its own, for keeping it beside the work instead of
// under the bar.
PopoutWindow {
	surface: Messages.surface
	title: "Messages"
	implicitWidth: 1180
	implicitHeight: 800
	minimumSize: Qt.size(400, 420)

	Component.onCompleted: view.entered(Messages.page)

	// asked for again while it is up: a new chat, the settings
	Connections {
		target: Messages

		function onAskedChanged() {
			view.entered(Messages.page);
		}
	}

	MessagesView {
		id: view

		anchors.fill: parent
		anchors.margins: Theme.panelPadding
	}
}
