import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views

// The streams window; what is followed goes on being looked at without it.
PopoutWindow {
	surface: Streams.surface
	title: Streams.liveCount > 0 ? `Streams · ${Streams.liveCount} live` : "Streams"
	// a good part of whatever screen it opens on
	implicitWidth: Math.max(1240, Math.round((Popups.focusedScreen()?.width ?? 1550) * 0.8))
	implicitHeight: Math.max(820, Math.round((Popups.focusedScreen()?.height ?? 1000) * 0.82))
	minimumSize: Qt.size(920, 600)

	Component.onCompleted: {
		Sounds.play("open");
		view.takeFocus();
	}

	StreamsView {
		id: view

		anchors.fill: parent
		windowed: true
	}
}
