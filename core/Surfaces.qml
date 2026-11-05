pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import qs.core.views.breaks
import qs.core.views.downloads
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
import qs.core.views.switcher
import qs.core.views.taskmgr
import qs.core.views.studio
import qs.core.views.todos
import qs.core.views.torrents
import qs.core.views.streams
import qs.core.views.tray
import qs.core.views.tracking
import qs.core.views.world
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

	// the wallpaper, under everything (a video's players cover it)
	Variants {
		model: Wallpaper.enabled && !Wallpaper.covered ? Quickshell.screens : []

		WallpaperLayer {}
	}

	// above a video's player while a change leaves it
	Variants {
		model: Wallpaper.enabled && Wallpaper.curtain ? Quickshell.screens : []

		WallpaperLayer {
			curtain: true
		}
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
		id: lasering
		when: Laser.active
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

	// Alt+Tab: kept a minute after it closed, the next Alt+Tab comes soon
	Hold {
		id: switching
		when: Switcher.open
		keep: 60000
	}

	View {
		view: "switcher/SwitcherWindow"
		available: Plugins.on("window-switcher")
		when: switching.held
	}

	// the pointer grown while it is shaken
	ScreenView {
		view: "overlays/MouseFinder"
		available: Plugins.on("find-mouse")
		when: finding.held
	}

	// the laser pointer, for presentations
	ScreenView {
		view: "overlays/LaserPointer"
		available: Plugins.on("laser-pointer")
		when: lasering.held
	}

	// where the pointer is, for an ultra macro of the Apex keyboard
	ScreenView {
		view: "overlays/PointerProbe"
		available: Plugins.on("apex")
		when: Apex.probing !== 0
	}

	ScreenView {
		view: "screenshot/ScreenshotOverlay"
		available: Plugins.on("screenshot")
		when: capturing.held
	}

	// pinned screenshots, always on top
	ScreenView {
		view: "screenshot/ScreenshotPins"
		available: Plugins.on("pins")
		when: pinning.held
	}

	// shelves (Dropover-like stashes), above the windows
	ScreenView {
		view: "shelf/Shelves"
		available: Plugins.on("shelves")
		when: shelving.held
	}

	// windows parked on the right edges, and the edges while a window is dragged
	ScreenView {
		view: "parking/ParkedTabs"
		available: Plugins.on("parked-windows")
		when: Parking.any
	}

	ScreenView {
		view: "overlays/ParkingEdge"
		available: Plugins.on("parked-windows")
		when: Parking.armed
	}

	// the app trays on the edges of the screens (by id: a changed tray is not built again)
	ScreenView {
		view: "tray/AppTrayWindow"
		available: AppTray.enabled
		when: AppTray.loaded
		model: AppTray.trays.map(tray => tray.id)
	}

	// commands for what is being dragged, around the pointer
	ScreenView {
		view: "overlays/CommandRing"
		available: Plugins.on("drop-commands")
		when: dropping.held
	}

	// panels (one instance each, they follow the screen they are opened on).
	// Each is built when it first opens and kept a while after it closed
	// (Popups.wanted); the launcher, the control centre and today stay
	// built, they open all the time and have to be there at once.
	Launcher {}

	View {
		view: "panels/ControlCenter"
		available: Plugins.on("quick-settings")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	View {
		view: "panels/TodayPanel"
		available: Plugins.on("notifications") || Plugins.on("calendar") || Plugins.on("weather")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	View {
		view: "breaks/BreaksPanel"
		available: Plugins.on("breaks")
		when: Popups.wanted("breaks")
	}

	View {
		view: "screentime/ScreentimePanel"
		available: Plugins.on("screentime")
		when: Popups.wanted("screentime")
	}

	View {
		view: "watch/WatchPanel"
		available: Plugins.on("watch")
		when: Popups.wanted("watch")
	}

	View {
		view: "printer/PrinterPanel"
		available: Plugins.on("printer")
		when: Popups.wanted("printer")
	}

	// popped out, and the camera's feed
	View {
		view: "printer/PrinterWindow"
		available: Plugins.on("printer")
		when: !Printer.surface.panelled && Printer.windowOpen
	}

	View {
		view: "printer/CameraWindow"
		available: Plugins.on("printer")
		when: Printer.camera
	}

	View {
		view: "media/MediaPanel"
		available: Plugins.on("media")
		when: Popups.wanted("media")
	}

	View {
		view: "panels/ClipboardPanel"
		available: Plugins.on("clipboard")
		when: Popups.wanted("clipboard")
	}

	View {
		view: "panels/TrayMenuPanel"
		available: Plugins.on("tray")
		when: Popups.wanted("tray")
	}

	View {
		view: "panels/OverviewPanel"
		available: Plugins.on("overview")
		when: Popups.wanted("overview")
	}

	View {
		view: "panels/UpdatesPanel"
		available: Plugins.on("updates")
		when: Popups.wanted("updates")
	}

	View {
		view: "panels/TimerPanel"
		available: Plugins.on("qtrack")
		when: Popups.wanted("timer")
	}

	View {
		view: "tracking/TrackingPanel"
		available: Plugins.on("qtrack")
		when: Popups.wanted("tracking")
	}

	View {
		view: "ssh/SshPanel"
		available: Plugins.on("ssh")
		when: Popups.wanted("ssh")
	}

	View {
		view: "panels/NotesPanel"
		available: Plugins.on("notes")
		when: Popups.wanted("notes")
	}

	View {
		view: "messages/MessagesPanel"
		available: Plugins.on("messages")
		when: Popups.wanted("messages")
	}

	// … and the same as a window of its own
	View {
		view: "messages/MessagesWindow"
		available: Plugins.on("messages")
		when: !Messages.surface.panelled && Messages.windowOpen
	}

	View {
		view: "identity/IdentityPanel"
		available: Plugins.on("identities")
		when: Popups.wanted("identity")
	}

	// … and the same as a window of its own
	View {
		view: "identity/IdentityWindow"
		available: Plugins.on("identities")
		when: !Identities.surface.panelled && Identities.windowOpen
	}

	View {
		view: "panels/ReaderPanel"
		available: Plugins.on("fast-reader")
		when: Popups.wanted("reader")
	}

	// full-screen overlays
	View {
		view: "overlays/PluginsWindow"
		when: Popups.wanted("plugins")
	}

	View {
		view: "settings/SettingsWindow"
		available: Plugins.on("niri-settings")
		when: Popups.wanted("niri")
	}

	View {
		view: "overlays/PowerMenu"
		available: Plugins.on("power-menu")
		when: Popups.wanted("power")
	}

	View {
		view: "vm/VmLauncher"
		available: Plugins.on("vm-launcher")
		when: Popups.wanted("vm")
	}

	View {
		view: "games/GameLibrary"
		available: Plugins.on("games")
		when: Popups.wanted("games")
	}

	// … and as a panel under the bar
	View {
		view: "games/GamesPanel"
		available: Plugins.on("games-bar")
		when: Popups.wanted("gamebar")
	}

	// the file manager, a window of its own
	View {
		view: "files/FilesWindow"
		available: Plugins.on("filemanager")
	}

	// every app's file chooser (and the shell's own), a window beside it
	View {
		view: "files/ChooserWindow"
		available: Plugins.on("filemanager")
	}

	// "Open with" for every app
	View {
		view: "files/OpenWithWindow"
		available: Plugins.on("filemanager")
		when: Files.appChoosing !== null
	}

	// the downloads under the bar, with their statistics
	View {
		view: "downloads/DownloadsPanel"
		available: Plugins.on("downloads")
		when: Popups.wanted("downloads")
	}

	// the torrent client's window; the downloads run in its daemon
	View {
		view: "torrents/TorrentsWindow"
		available: Plugins.on("torrents")
		when: !Torrents.surface.panelled && Torrents.windowOpen
	}

	// what is followed: its window, or under the bar …
	View {
		view: "streams/StreamsWindow"
		available: Plugins.on("streams")
		when: !Streams.surface.panelled && Streams.windowOpen
	}

	View {
		view: "streams/StreamsPanel"
		available: Plugins.on("streams-bar")
		when: Popups.wanted("streams")
	}

	// the player, in a window of its own unless the streams window is open
	View {
		view: "streams/PlayerWindow"
		available: Plugins.on("streams")
		when: !!Streams.player && !Streams.playerInside
	}

	// … and the next episode coming up, in a corner of the screen
	View {
		view: "streams/NextUpOverlay"
		available: Plugins.on("streams")
		when: !!Streams.upNext
	}

	// the task manager's window (Ctrl+Shift+Escape)
	View {
		view: "taskmgr/TaskManagerWindow"
		available: Plugins.on("task-manager")
		when: !TaskManager.surface.panelled && TaskManager.windowOpen
	}

	View {
		view: "taskmgr/TaskManagerPanel"
		available: Plugins.on("task-manager-bar")
		when: Popups.wanted("taskmgr")
	}

	// under the bar, from the magnet in the bar
	View {
		view: "torrents/TorrentsPanel"
		available: Plugins.on("torrents-bar")
		when: Popups.wanted("torrents")
	}

	View {
		view: "overlays/RadialMenu"
		available: Plugins.on("radial-menu")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	View {
		view: "overlays/EyeRest"
		available: Plugins.on("eye-rest")
		when: Popups.wanted("eyerest")
	}

	View {
		view: "overlays/StretchBreak"
		available: Plugins.on("stretch")
		when: Popups.wanted("stretch")
	}

	// Studio
	View {
		view: "studio/ThemePicker"
		available: Plugins.on("studio-wallpaper")
		when: Popups.wanted("theme")
	}

	View {
		view: "studio/AnimationPicker"
		available: Plugins.on("studio-motion")
		when: Popups.wanted("animation")
	}

	View {
		view: "studio/DressPage"
		available: Plugins.on("studio-dress")
		when: Popups.wanted("dress")
	}

	View {
		view: "studio/StylePage"
		available: Plugins.on("studio-styles")
		when: Popups.wanted("styles")
	}

	View {
		view: "studio/CombinationsPage"
		available: Plugins.on("studio-combinations")
		when: Popups.wanted("combinations")
	}

	View {
		view: "studio/SoundPackPage"
		available: Plugins.on("studio-sounds")
		when: Popups.wanted("sounds")
	}

	// a program asks for an administrator's password
	View {
		view: "overlays/PolkitDialog"
		when: Polkit.active
	}

	View {
		view: "overlays/LockScreen"
		available: Plugins.on("lock-screen")
	}

	// the story of Bing's image of the day, on the wallpaper
	View {
		view: "overlays/DailyCaption"
		available: Plugins.on("daily-caption")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	// todo lists pinned to the desktop (bottom layer, primary screen)
	View {
		view: "todos/TodoWidgets"
		available: Plugins.on("todos")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	// the editor of a todo list, a window of its own while it is open
	View {
		view: "todos/TodoEditor"
		available: Plugins.on("todos")
		when: Todos.editorOpen
	}

	// the useless fact of the day, a card on the desktop
	View {
		view: "overlays/UselessFact"
		available: Plugins.on("useless-fact")
		// not needed in the first moment
		when: Views.started
		asynchronous: true
	}

	View {
		view: "rpg/Rpg"
		available: Plugins.on("rpg")
	}

	View {
		view: "world/WorldWindow"
		available: Plugins.on("world")
		when: World.windowLoaded
	}

	ScreenView {
		view: "world/WorldWallpaper"
		available: Plugins.on("world")
		when: World.wallpaperLoaded
	}
}
