pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.identity

// A made-up identity under the bar (identity/IdentityView.qml). Popped out,
// the same lives in a window of its own (IdentityWindow.qml).
Drawer {
	id: root

	panelId: "identity"
	panelWidth: Math.min(900, (root.screen?.width ?? 1920) - 80)
	centered: true
	contentHeight: 600

	IdentityView {
		anchors.fill: parent
	}
}
