pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.core.views.panels.identity

// The identity as a window of its own, to keep it beside the form that is
// being filled in. The compositor places it like any other window.
FloatingWindow {
	id: root

	title: "Identity"
	visible: false
	implicitWidth: 940
	implicitHeight: 660
	minimumSize: Qt.size(780, 640)
	color: Theme.base

	function follow() {
		root.visible = Identities.windowed && Identities.windowOpen;
	}

	// closed with the compositor's own means
	onVisibleChanged: if (!root.visible && Identities.windowOpen) Identities.windowOpen = false

	Component.onCompleted: root.follow()

	Connections {
		target: Identities
		function onWindowOpenChanged() {
			root.follow();
		}
		function onWindowedChanged() {
			root.follow();
		}
	}

	IdentityView {
		anchors.fill: parent
		anchors.margins: Theme.panelPadding
	}
}
