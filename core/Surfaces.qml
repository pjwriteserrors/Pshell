pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import qs.core.views.panels
import qs.core.views.overlays
import qs.core.views.rpg
import qs.core.views.overlays.studio
// last, so a view of the same name in style/views wins
import qs.style.views

// Every surface of every feature. The style draws the frame they hang from
// and may replace any view (style/views); which features exist is decided
// here and in the host profile, never by the style.
Scope {
	// services that act on their own, without a surface to pull them in
	readonly property var background: [Agents, TimerGuard, ClipboardHints]

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

	// shelves (Dropover-like stashes), above the windows
	Variants {
		model: Quickshell.screens

		Shelves {}
	}

	// commands for what is being dragged, around the pointer
	Variants {
		model: Quickshell.screens

		CommandRing {}
	}

	// panels (one instance each, they follow the screen they are opened on)
	Launcher {}
	ControlCenter {}
	TodayPanel {}
	BreaksPanel {}
	MediaPanel {}
	ClipboardPanel {}
	TrayMenuPanel {}
	OverviewPanel {}
	UpdatesPanel {}

	// full-screen overlays
	PowerMenu {}
	RadialMenu {}
	EyeRest {}
	StretchBreak {}

	// Studio
	ThemePicker {}
	AnimationPicker {}
	DressPage {}
	StylePage {}
	CombinationsPage {}

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

	// the story of Bing's image of the day, on the wallpaper
	DailyCaption {}

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
