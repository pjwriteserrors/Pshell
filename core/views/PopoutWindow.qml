import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services

// A surface popped out into a window of its own (a Popout of its service).
// It exists only while it is open: Surfaces loads it then, so a closed one
// holds nothing. The compositor places it like any other window; closing it
// there closes the surface.
FloatingWindow {
	id: root

	required property Popout surface

	visible: true
	color: Theme.base

	// this window as niri knows it
	readonly property var niriWindow: Niri.windows.find(window => String(window.title) === root.title && /quickshell/i.test(String(window.app_id))) ?? null

	onVisibleChanged: if (!root.visible && root.surface.windowOpen) root.surface.windowOpen = false

	Binding {
		target: root.surface
		property: "focused"
		value: !!root.niriWindow?.is_focused
	}

	Connections {
		target: root.surface

		function onRaised() {
			if (root.niriWindow && !root.niriWindow.is_focused) Niri.focusWindow(root.niriWindow.id);
		}
	}
}
