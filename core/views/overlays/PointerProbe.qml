import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core.services

// Where the pointer is, for an ultra macro (core/services/Apex.qml) or a
// mouse capture starting (core/services/MouseCapture.qml): an
// invisible catcher over a screen for the moment it takes the pointer to
// enter it (the daemon nudges it a pixel there and back), then gone.
PanelWindow {
	id: root

	required property var modelData

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-pointer-probe"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	function probed(x, y) {
		if (Apex.probing !== 0) Apex.probed(x, y);
		if (MouseCapture.probing) MouseCapture.probed(x, y);
	}

	MouseArea {
		id: catcher

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onEntered: root.probed(root.modelData.x + catcher.mouseX, root.modelData.y + catcher.mouseY)
		onPositionChanged: mouse => root.probed(root.modelData.x + mouse.x, root.modelData.y + mouse.y)
	}
}
