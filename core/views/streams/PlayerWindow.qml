import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The player when the streams window is not open: closing it stops the video.
FloatingWindow {
	id: root

	visible: true
	color: "black"
	title: Streams.player?.title ? `${Streams.player.title} – Player` : "Player"
	implicitWidth: Math.max(1100, Math.round((Popups.focusedScreen()?.width ?? 1500) * 0.7))
	implicitHeight: Math.round(root.implicitWidth * 9 / 16)
	onVisibleChanged: if (!root.visible) view.leave()

	PlayerView {
		id: view

		anchors.fill: parent
		Component.onCompleted: view.takeFocus()
	}
}
