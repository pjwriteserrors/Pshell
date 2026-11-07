pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The PDFs' window. Built a few seconds after the shell starts and kept
// when it closes, so a document opens at once; it floats (dotfiles/niri/pshell.kdl)
// tall like a page on most of the screen. Slides are this window made fullscreen.
FloatingWindow {
	id: root

	title: Pdf.windowTitle
	visible: false
	implicitWidth: 1100
	implicitHeight: 900
	minimumSize: Qt.size(420, 360)
	color: Theme.base

	function follow() {
		if (Pdf.windowOpen) {
			if (!root.visible) root.size();
			content.active = true;
		}
		root.visible = Pdf.windowOpen;
	}

	// a page's shape, wide enough for the tools beside it, on most of the screen it opens on
	function size() {
		const screen = Popups.focusedScreen();
		if (!screen) return;
		const h = Math.round(screen.height * 0.86);
		const w = Math.round(Math.min(screen.width * 0.8, Math.max(900, h * 0.92)));
		root.implicitWidth = w;
		root.implicitHeight = h;
	}

	onVisibleChanged: {
		if (!root.visible && Pdf.windowOpen) Pdf.close();
		if (root.visible) {
			Sounds.play("open");
			if (content.item) content.item.takeFocus();
		}
		Pdf.watching = root.visible;
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Pdf

		function onWindowOpenChanged() {
			root.follow();
		}
	}

	Timer {
		running: true
		interval: 6000
		onTriggered: content.active = true
	}

	Loader {
		id: content

		anchors.fill: parent
		active: false
		asynchronous: !Pdf.windowOpen
		focus: true
		// by URL: QtQuick.Pdf comes with qt6-webengine; without it only this window is missing
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("PdfView.qml"), { focus: true })
		onLoaded: {
			content.item.shown = root.visible;
			if (root.visible) content.item.takeFocus();
		}
	}
}
