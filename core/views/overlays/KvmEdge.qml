import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A strip one pixel wide on an edge that leads to another PC (Kvm.qml). It
// only says when the pointer is on it and where along it; the daemon counts
// the push from the mouse itself. Above windows, below fullscreen ones, so a
// game at the edge never sends the mouse away.
PanelWindow {
	id: root

	// "output|side|back"
	required property string modelData
	readonly property var parts: root.modelData.split("|")
	readonly property string output: root.parts[0]
	readonly property string side: root.parts[1]
	readonly property bool vertical: root.side === "left" || root.side === "right"
	readonly property bool hovered: area.containsMouse
	property real lastSent: 0

	screen: Quickshell.screens.find(screen => String(screen.name) === root.output) ?? null
	anchors.left: root.side !== "right"
	anchors.right: root.side !== "left"
	anchors.top: root.side !== "bottom"
	anchors.bottom: root.side !== "top"
	implicitWidth: 1
	implicitHeight: 1
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-kvm-edge"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	function report(inside) {
		const pos = root.vertical ? area.mouseY / Math.max(1, area.height) : area.mouseX / Math.max(1, area.width);
		root.lastSent = Date.now();
		Kvm.edge(root.output, root.side, Math.min(1, Math.max(0, pos)), inside);
	}

	// the edge lights up while the pointer pushes on it
	Rectangle {
		anchors.fill: parent
		color: Theme.primary
		opacity: root.hovered ? 0.85 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: 160
			}
		}
	}

	MouseArea {
		id: area

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onEntered: root.report(true)
		onExited: root.report(false)
		onPositionChanged: if (Date.now() - root.lastSent > 80) root.report(true)
	}

	Component.onDestruction: if (root.hovered) Kvm.edge(root.output, root.side, 0.5, false)
}
