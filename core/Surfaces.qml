pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import qs.core.views.panels
import qs.core.views.overlays
import qs.core.views.rpg

// Every surface of every feature. The style draws the frame they hang from;
// which features exist is decided here and in the host profile, never by the
// style.
Scope {
	Variants {
		model: Quickshell.screens

		Toasts {}
	}

	Variants {
		model: Quickshell.screens

		OsdPanel {}
	}

	Variants {
		model: Quickshell.screens

		ScreenshotOverlay {}
	}

	// pinned screenshots, always on top
	Variants {
		model: Quickshell.screens

		ScreenshotPins {}
	}

	// panels (one instance each, they follow the screen they are opened on)
	Launcher {}
	ControlCenter {}
	TodayPanel {}
	MediaPanel {}
	ClipboardPanel {}
	TrayMenuPanel {}
	OverviewPanel {}
	UpdatesPanel {}

	// full-screen overlays
	PowerMenu {}
	ThemePicker {}
	AnimationPicker {}
	LockScreen {}

	LazyLoader {
		active: Host.has("qtrack")

		TimerPanel {}
	}

	LazyLoader {
		active: Host.has("ssh")

		SshPanel {}
	}

	LazyLoader {
		active: Host.has("notes")

		NotesPanel {}
	}

	// todo lists pinned to the desktop (bottom layer, primary screen)
	LazyLoader {
		active: Host.has("todos")

		TodoWidgets {}
	}

	LazyLoader {
		active: Host.has("rpg")

		Rpg {}
	}
}
