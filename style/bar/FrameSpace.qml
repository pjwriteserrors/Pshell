import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core.services

// Keeps the windows out of one edge of the screen frame (BottomCorners
// draws it). Nothing to see or to click.
PanelWindow {
	id: root

	// { screen, edge: "top" | "bottom" | "left" | "right" }
	required property var modelData
	readonly property string edge: modelData.edge
	screen: modelData.screen

	anchors {
		top: root.edge !== "bottom"
		bottom: root.edge !== "top"
		left: root.edge !== "right"
		right: root.edge !== "left"
	}
	implicitWidth: Corners.frame
	implicitHeight: Corners.frame
	exclusiveZone: Corners.frame
	color: "transparent"
	WlrLayershell.namespace: "shell-frame"
	WlrLayershell.layer: WlrLayer.Bottom
	mask: Region {}
}
