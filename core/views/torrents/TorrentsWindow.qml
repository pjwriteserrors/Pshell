import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views

// The torrent client's window; closing it leaves the downloads running in
// the daemon.
PopoutWindow {
	surface: Torrents.surface
	title: Torrents.running.length > 0 && Torrents.ratio >= 0 ? `Torrents · ${Math.floor(Torrents.ratio * 100)} %` : "Torrents"
	implicitWidth: 1180
	implicitHeight: 780
	minimumSize: Qt.size(820, 560)

	Component.onCompleted: {
		Sounds.play("open");
		view.takeFocus();
	}

	TorrentsView {
		id: view

		anchors.fill: parent
		windowed: true
	}
}
