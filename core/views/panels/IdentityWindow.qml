import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views
import qs.core.views.panels.identity

// The identity as a window of its own, to keep it beside the form that is
// being filled in.
PopoutWindow {
	surface: Identities.surface
	title: "Identity"
	implicitWidth: 940
	implicitHeight: 660
	minimumSize: Qt.size(780, 640)

	IdentityView {
		anchors.fill: parent
		anchors.margins: Theme.panelPadding
	}
}
