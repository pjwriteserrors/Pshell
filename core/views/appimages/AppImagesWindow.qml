pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// The AppImages' window: what is installed, what lies around, and the
// install of one (a file dropped or opened, a link pasted). It floats
// (dotfiles/niri/pshell.kdl); its content is built when it first opens.
FloatingWindow {
	id: root

	title: AppImages.windowTitle
	visible: AppImages.windowOpen
	implicitWidth: 900
	implicitHeight: 680
	minimumSize: Qt.size(520, 440)
	color: Theme.base

	onVisibleChanged: {
		if (!root.visible && AppImages.windowOpen) AppImages.close();
		if (root.visible) {
			content.active = true;
			Sounds.play("open");
		}
		if (content.item) content.item.shown = root.visible;
	}

	Component.onCompleted: if (root.visible) content.active = true

	Shortcut {
		sequences: ["Ctrl+W", "Ctrl+Q"]
		enabled: root.visible
		onActivated: AppImages.close()
	}

	Loader {
		id: content

		anchors.fill: parent
		// built when it first opens, kept after
		active: false
		focus: true
		onActiveChanged: if (content.active) content.setSource(Qt.resolvedUrl("AppImagesView.qml"), { focus: true })
		onLoaded: content.item.shown = root.visible
	}
}
