import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Messages of every provider in one place; the badge counts what is unread.
BarButton {
	id: root

	panelId: "messages"
	tooltip: Messages.unread > 0 ? `${Messages.unread} unread` : "Messages"
	padding: 9
	// popped out, the button brings up and puts away the window
	onClicked: Messages.windowed ? Messages.toggle() : toggle()

	Item {
		anchors.verticalCenter: parent.verticalCenter
		width: 20
		height: 20

		Glyph {
			anchors.centerIn: parent
			icon: Messages.unread > 0 ? "forum" : "forum_outline"
			size: 18
			color: root.active ? Theme.primary : Theme.text
		}

		Badge {
			x: 11
			y: -3
			count: Messages.unread
		}
	}
}
