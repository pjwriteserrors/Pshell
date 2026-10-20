pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import qs.core.views.breaks
import qs.core.views.files
import qs.core.views.games
import qs.core.views.identity
import qs.core.views.launcher
import qs.core.views.media
import qs.core.views.messages
import qs.core.views.overlays
import qs.core.views.panels
import qs.core.views.printer
import qs.core.views.rpg
import qs.core.views.screenshot
import qs.core.views.screentime
import qs.core.views.settings
import qs.core.views.shelf
import qs.core.views.ssh
import qs.core.views.studio
import qs.core.views.todos
import qs.core.views.torrents
import qs.core.views.tracking
import qs.core.views.vm
import qs.core.views.watch
// last, so a view of the same name in style/views wins
import qs.style.views

// Every surface of every feature. The style draws the frame they hang from
// and may replace any view (style/views); which of them exist is decided
// here and by the plugin switches, never by the style.
Scope {
	// services that act on their own, without a surface to pull them in
	readonly property var background: [Polkit, Agents, TimerGuard, Clipboard, ClipboardHints, Phone, Mail, WhatsApp, Autocorrect, Screentime, Multicursor, Sounds, FindMouse]

	// the wallpaper, under everything
	Variants {
		model: Wallpaper.enabled ? Quickshell.screens : []

		WallpaperLayer {}
	}

	// and its copy in the niri overview, between the workspaces
	Variants {
		model: Wallpaper.enabled ? Quickshell.screens : []

		WallpaperLayer {
			backdrop: true
		}
	}

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

	// what the swipes of a held mouse button do
	Variants {
		model: Plugins.on("mouse") ? Quickshell.screens : []

		GestureHud {}
	}

	// edges that lead to another PC: the mouse goes over when pushed on
	Variants {
		model: Kvm.enabled ? Kvm.strips : []

		KvmEdge {}
	}

	// the overlays of a screen exist while they are wanted, and a moment
	// after for their way out: four screens of them cost memory for nothing
	Hold {
		id: finding
		when: FindMouse.active
	}

	Hold {
		id: capturing
		when: Screenshot.phase !== "idle"
	}

	Hold {
		id: shelving
		when: Shelf.shelves.length > 0 || Shelf.locating !== ""
	}

	Hold {
		id: dropping
		when: DropCommands.active
	}

	Hold {
		id: pinning
		when: Screenshot.pins.length > 0
	}

	// the light on a pointer that is shaken
	Variants {
		model: Plugins.on("find-mouse") && finding.held ? Quickshell.screens : []

		MouseFinder {}
	}

	Variants {
		model: Plugins.on("screenshot") && capturing.held ? Quickshell.screens : []

		ScreenshotOverlay {}
	}

	// pinned screenshots, always on top
	Variants {
		model: Plugins.on("pins") && pinning.held ? Quickshell.screens : []

		ScreenshotPins {}
	}

	// shelves (Dropover-like stashes), above the windows
	Variants {
		model: Plugins.on("shelves") && shelving.held ? Quickshell.screens : []

		Shelves {}
	}

	// commands for what is being dragged, around the pointer
	Variants {
		model: Plugins.on("drop-commands") && dropping.held ? Quickshell.screens : []

		CommandRing {}
	}

	// panels (one instance each, they follow the screen they are opened on).
	// Each is built when it first opens and kept a while after it closed
	// (Popups.wanted); the launcher, the control centre and today stay
	// built, they open all the time and have to be there at once.
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
		active: Plugins.on("breaks") && Popups.wanted("breaks")

		BreaksPanel {}
	}

	LazyLoader {
		active: Plugins.on("screentime") && Popups.wanted("screentime")

		ScreentimePanel {}
	}

	LazyLoader {
		active: Plugins.on("watch") && Popups.wanted("watch")

		WatchPanel {}
	}

	LazyLoader {
		active: Plugins.on("printer") && Popups.wanted("printer")

		PrinterPanel {}
	}

	// popped out, and the camera's feed
	LazyLoader {
		active: Plugins.on("printer") && !Printer.surface.panelled && Printer.windowOpen

		PrinterWindow {}
	}

	LazyLoader {
		active: Plugins.on("printer") && Printer.camera

		CameraWindow {}
	}

	LazyLoader {
		active: Plugins.on("media") && Popups.wanted("media")

		MediaPanel {}
	}

	LazyLoader {
		active: Plugins.on("clipboard") && Popups.wanted("clipboard")

		ClipboardPanel {}
	}

	LazyLoader {
		active: Plugins.on("tray") && Popups.wanted("tray")

		TrayMenuPanel {}
	}

	LazyLoader {
		active: Plugins.on("overview") && Popups.wanted("overview")

		OverviewPanel {}
	}

	LazyLoader {
		active: Plugins.on("updates") && Popups.wanted("updates")

		UpdatesPanel {}
	}

	LazyLoader {
		active: Plugins.on("qtrack") && Popups.wanted("timer")

		TimerPanel {}
	}

	LazyLoader {
		active: Plugins.on("qtrack") && Popups.wanted("tracking")

		TrackingPanel {}
	}

	LazyLoader {
		active: Plugins.on("ssh") && Popups.wanted("ssh")

		SshPanel {}
	}

	LazyLoader {
		active: Plugins.on("notes") && Popups.wanted("notes")

		NotesPanel {}
	}

	LazyLoader {
		active: Plugins.on("messages") && Popups.wanted("messages")

		MessagesPanel {}
	}

	// … and the same as a window of its own
	LazyLoader {
		active: Plugins.on("messages") && !Messages.surface.panelled && Messages.windowOpen

		MessagesWindow {}
	}

	LazyLoader {
		active: Plugins.on("identities") && Popups.wanted("identity")

		IdentityPanel {}
	}

	// … and the same as a window of its own
	LazyLoader {
		active: Plugins.on("identities") && !Identities.surface.panelled && Identities.windowOpen

		IdentityWindow {}
	}

	LazyLoader {
		active: Plugins.on("fast-reader") && Popups.wanted("reader")

		ReaderPanel {}
	}

	// full-screen overlays
	LazyLoader {
		active: Popups.wanted("plugins")

		PluginsWindow {}
	}

	LazyLoader {
		active: Plugins.on("niri-settings") && Popups.wanted("niri")

		SettingsWindow {}
	}

	LazyLoader {
		active: Plugins.on("power-menu") && Popups.wanted("power")

		PowerMenu {}
	}

	LazyLoader {
		active: Plugins.on("vm-launcher") && Popups.wanted("vm")

		VmLauncher {}
	}

	LazyLoader {
		active: Plugins.on("games") && Popups.wanted("games")

		GameLibrary {}
	}

	// … and as a panel under the bar
	LazyLoader {
		active: Plugins.on("games-bar") && Popups.wanted("gamebar")

		GamesPanel {}
	}

	// the file manager, a window of its own
	LazyLoader {
		active: Plugins.on("filemanager")

		FilesWindow {}
	}

	// the torrent client's window; the downloads run in its daemon
	LazyLoader {
		active: Plugins.on("torrents") && !Torrents.surface.panelled && Torrents.windowOpen

		TorrentsWindow {}
	}

	// under the bar, from the magnet in the bar
	LazyLoader {
		active: Plugins.on("torrents-bar") && Popups.wanted("torrents")

		TorrentsPanel {}
	}

	LazyLoader {
		active: Plugins.on("radial-menu")

		RadialMenu {}
	}

	LazyLoader {
		active: Plugins.on("eye-rest") && Popups.wanted("eyerest")

		EyeRest {}
	}

	LazyLoader {
		active: Plugins.on("stretch") && Popups.wanted("stretch")

		StretchBreak {}
	}

	// Studio
	LazyLoader {
		active: Plugins.on("studio-wallpaper") && Popups.wanted("theme")

		ThemePicker {}
	}

	LazyLoader {
		active: Plugins.on("studio-motion") && Popups.wanted("animation")

		AnimationPicker {}
	}

	LazyLoader {
		active: Plugins.on("studio-dress") && Popups.wanted("dress")

		DressPage {}
	}

	LazyLoader {
		active: Plugins.on("studio-styles") && Popups.wanted("styles")

		StylePage {}
	}

	LazyLoader {
		active: Plugins.on("studio-combinations") && Popups.wanted("combinations")

		CombinationsPage {}
	}

	LazyLoader {
		active: Plugins.on("studio-sounds") && Popups.wanted("sounds")

		SoundPackPage {}
	}

	// a program asks for an administrator's password
	LazyLoader {
		active: Polkit.active

		PolkitDialog {}
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

	// the editor of a todo list, a window of its own while it is open
	LazyLoader {
		active: Plugins.on("todos") && Todos.editorOpen

		TodoEditor {}
	}

	// the useless fact of the day, a card on the desktop
	LazyLoader {
		active: Plugins.on("useless-fact")

		UselessFact {}
	}

	LazyLoader {
		active: Plugins.on("rpg")

		Rpg {}
	}
}
