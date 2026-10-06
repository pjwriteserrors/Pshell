pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.messages

// Messages under the bar: what reaches the user, provider by provider, as
// chats (messages/MessagesView.qml). Popped out, the same lives in a window
// of its own (MessagesWindow.qml).
Drawer {
	id: root

	panelId: "messages"
	panelWidth: Math.min(1120, (root.screen?.width ?? 1920) - 80)
	contentHeight: 740

	onPanelOpened: view.entered(Popups.page)

	MessagesView {
		id: view

		anchors.fill: parent
	}
}
