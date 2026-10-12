import QtQuick
import qs.style.theme
import qs.style.widgets

// No chat is open: the backdrop, and a word on it.
ChatStage {
	id: root

	Rectangle {
		anchors.centerIn: parent
		width: idle.implicitWidth + 56
		height: idle.implicitHeight + 44
		radius: Theme.radius.huge
		color: root.dressed ? Qt.alpha(Theme.bg, 0.72) : "transparent"

		EmptyState {
			id: idle

			anchors.centerIn: parent
			icon: "forum_outline"
			title: "No chat selected"
		}
	}
}
