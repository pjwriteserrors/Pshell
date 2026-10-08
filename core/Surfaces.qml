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
// and may replace any view (style/views); which of them exist is decided
// here and by the plugin switches, never by the style.
Scope {
	// services that act on their own, without a surface to pull them in
	readonly property var background: [Agents, TimerGuard, ClipboardHints, Phone, Mail, Autocorrect, Screentime, Multicursor]

	// notifications and the shell's own messages
	Variants {
		model: Quickshell.screens

		Toasts {}
	}

	Variants {
		model: Plugins.on("osd") ? Quickshell.screens : []

		OsdPanel {}
	}

	Variants {
		model: Plugins.on("multicursor") ? Quickshell.screens : []

		CursorCount {}
	}

	Variants {
		model: Plugins.on("screenshot") ? Quickshell.screens : []

		ScreenshotOverlay {}
	}

	// pinned screenshots, always on top
	Variants {
		model: Plugins.on("pins") ? Quickshell.screens : []

		ScreenshotPins {}
	}

	// shelves (Dropover-like stashes), above the windows
	Variants {
		model: Plugins.on("shelves") ? Quickshell.screens : []

		Shelves {}
	}

	// commands for what is being dragged, around the pointer
	Variants {
		model: Plugins.on("drop-commands") ? Quickshell.screens : []

		CommandRing {}
	}

	// panels (one instance each, they follow the screen they are opened on)
	Launcher {}

	LazyLoader {
		active: Plugins.on("quick-settings")

		ControlCenter {}
	}

	LazyLoader {
		active: Plugins.on("notifications") || Plugins.on("calendar") || Plugins.on("weather")

		TodayPanel {}
	}

	LazyLoader {
		active: Plugins.on("breaks")

		BreaksPanel {}
	}

	LazyLoader {
		active: Plugins.on("screentime")

		ScreentimePanel {}
	}

	LazyLoader {
		active: Plugins.on("media")

		MediaPanel {}
	}

	LazyLoader {
		active: Plugins.on("clipboard")

		ClipboardPanel {}
	}

	LazyLoader {
		active: Plugins.on("tray")

		TrayMenuPanel {}
	}

	LazyLoader {
		active: Plugins.on("overview")

		OverviewPanel {}
	}

	LazyLoader {
		active: Plugins.on("updates")

		UpdatesPanel {}
	}

	LazyLoader {
		active: Plugins.on("qtrack")

		TimerPanel {}
	}

	LazyLoader {
		active: Plugins.on("qtrack")

		TrackingPanel {}
	}

	LazyLoader {
		active: Plugins.on("ssh")

		SshPanel {}
	}

	LazyLoader {
		active: Plugins.on("notes")

		NotesPanel {}
	}

	LazyLoader {
		active: Plugins.on("messages")

		MessagesPanel {}
	}

	// … and the same as a window of its own
	LazyLoader {
		active: Plugins.on("messages")

		MessagesWindow {}
	}

	LazyLoader {
		active: Plugins.on("fast-reader")

		ReaderPanel {}
	}

	// full-screen overlays
	PluginsWindow {}

	LazyLoader {
		active: Plugins.on("niri-settings")

		NiriSettingsWindow {}
	}

	LazyLoader {
		active: Plugins.on("power-menu")

		PowerMenu {}
	}

	LazyLoader {
		active: Plugins.on("radial-menu")

		RadialMenu {}
	}

	LazyLoader {
		active: Plugins.on("eye-rest")

		EyeRest {}
	}

	LazyLoader {
		active: Plugins.on("stretch")

		StretchBreak {}
	}

	// Studio
	LazyLoader {
		active: Plugins.on("studio-wallpaper")

		ThemePicker {}
	}

	LazyLoader {
		active: Plugins.on("studio-motion")

		AnimationPicker {}
	}

	LazyLoader {
		active: Plugins.on("studio-dress")

		DressPage {}
	}

	LazyLoader {
		active: Plugins.on("studio-styles")

		StylePage {}
	}

	LazyLoader {
		active: Plugins.on("studio-combinations")

		CombinationsPage {}
	}

	LazyLoader {
		active: Plugins.on("lock-screen")

		LockScreen {}
	}

	// the story of Bing's image of the day, on the wallpaper
	LazyLoader {
		active: Plugins.on("daily-caption")

		DailyCaption {}
	}

	// todo lists pinned to the desktop (bottom layer, primary screen)
	LazyLoader {
		active: Plugins.on("todos")

		TodoWidgets {}
	}

	LazyLoader {
		active: Plugins.on("rpg")

		Rpg {}
	}
}
