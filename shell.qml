//@ pragma UseQApplication
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.bar
import qs.core.views.panels
import qs.core.views.overlays
import qs.core.views.rpg

// Shell entry point: one bar per screen, the panels that grow out of it,
// full-screen overlays, the lock screen and every IPC target used by
// keybinds and scripts (`scripts/ipc.sh <target> <function>`).
ShellRoot {
	id: shell

	Variants {
		model: Quickshell.screens

		Bar {}
	}

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
	TimerPanel {}
	MediaPanel {}
	ClipboardPanel {}
	SshPanel {}
	NotesPanel {}
	TrayMenuPanel {}
	OverviewPanel {}
	UpdatesPanel {}

	// full-screen overlays
	PowerMenu {}
	ThemePicker {}
	AnimationPicker {}
	LockScreen {}

	// todo lists pinned to the desktop (bottom layer, primary screen)
	TodoWidgets {}

	// productivity RPG: lives in its own window, not in the bar, no notifications
	RpgEngine {
		id: rpgGame

		statePath: Paths.stateFile("rpg-state.json")
		monitorPath: `${Quickshell.shellDir}/scripts/rpg-input-monitor.py`
	}

	RpgWindow {
		id: rpgWindow

		game: rpgGame
		foreground: Theme.fg
		background: Theme.bg
		accent: Theme.primary
		secondaryBoxColor: Theme.layer2
		secondaryBoxStrongColor: Theme.layer3
		secondaryInsetColor: Theme.layer1
	}

	Connections {
		target: Popups
		function onRpgWindowRequested() {
			rpgWindow.openWindow();
		}
	}

	Process {
		running: true
		command: ["bash", `${Quickshell.shellDir}/scripts/restore_theme.sh`]
	}

	// ── IPC ────────────────────────────────────────────────────────────────
	function drawerOnFocused(id, page) {
		if (Popups.current === id && (page === undefined || page === "" || Popups.page === page)) {
			Popups.close();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.open(id, screen, page));
	}

	function modalOnFocused(kind) {
		if (Popups.modal === kind) {
			Popups.closeModal();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.openModal(kind, screen));
	}

	IpcHandler {
		target: "launcher"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("launcher", screen));
		}
		function close(): void {
			if (Popups.current === "launcher") Popups.close();
		}
		function toggle(): void {
			shell.drawerOnFocused("launcher");
		}
		// opens on a preset query, e.g. ">t guten morgen" or ">todo "
		function search(query: string): void {
			Popups.withFocusedScreen(screen => {
				// reopening applies the query even when the launcher is already up
				if (Popups.current === "launcher") Popups.close();
				Popups.open("launcher", screen, "", query);
			});
		}
	}

	IpcHandler {
		target: "power"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("power", screen));
		}
		function close(): void {
			if (Popups.modal === "power") Popups.closeModal();
		}
		function toggle(): void {
			shell.modalOnFocused("power");
		}
	}

	IpcHandler {
		target: "screenshot"

		function region(): void {
			Screenshot.region();
		}
		function screen(): void {
			Screenshot.screen();
		}
		function window(): void {
			Screenshot.window();
		}
		function picker(): void {
			Screenshot.picker();
		}
		function ocr(): void {
			Screenshot.ocr();
		}
		function pin(): void {
			Screenshot.pinMode();
		}
		function unpinAll(): void {
			Screenshot.unpinAll();
		}
		function beautifyFile(path: string): void {
			Screenshot.beautifyFile(path);
		}
		function qr(): void {
			Screenshot.qr();
		}
		function scroll(): void {
			Screenshot.scroll();
		}
		function delayed(seconds: int): void {
			Screenshot.delayed(seconds);
		}
		function close(): void {
			Screenshot.cancel();
		}
	}

	IpcHandler {
		target: "lock"

		function lock(): void {
			Session.lock();
		}
		function isLocked(): bool {
			return Session.locked;
		}
	}

	IpcHandler {
		target: "panels"

		function toggleCalendar(): void {
			shell.drawerOnFocused("today");
		}
		function toggleWeather(): void {
			shell.drawerOnFocused("today");
		}
		function toggleNotifications(): void {
			shell.drawerOnFocused("today");
		}
		function toggleMedia(): void {
			shell.drawerOnFocused("media");
		}
		function toggleBluetooth(): void {
			shell.drawerOnFocused("control", "bluetooth");
		}
		function toggleNetwork(): void {
			shell.drawerOnFocused("control", "network");
		}
		function toggleResources(): void {
			shell.drawerOnFocused("control", "system");
		}
		function toggleControl(): void {
			shell.drawerOnFocused("control", "main");
		}
		function toggleUpdates(): void {
			shell.drawerOnFocused("updates");
		}
		function toggleOverview(): void {
			shell.drawerOnFocused("overview");
		}
		function closeAll(): void {
			Popups.closeAll();
		}
		// any panel by id: control, today, timer, media, clipboard, ssh, notes, launcher
		function toggle(name: string): void {
			shell.drawerOnFocused(name);
		}
	}

	IpcHandler {
		target: "updates"

		function open(): void {
			shell.drawerOnFocused("updates");
		}
		function check(): void {
			Updates.check();
		}
		function updateAll(): void {
			Updates.updateAll();
		}
		function update(name: string): void {
			Updates.updateOne(name);
		}
		function count(): int {
			return Updates.count;
		}
	}

	IpcHandler {
		target: "clipboard"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("clipboard", screen));
		}
		function close(): void {
			if (Popups.current === "clipboard") Popups.close();
		}
		function toggle(): void {
			shell.drawerOnFocused("clipboard");
		}
	}

	IpcHandler {
		target: "qtrack"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("timer", screen));
		}
		function close(): void {
			if (Popups.current === "timer") Popups.close();
		}
		function toggle(): void {
			shell.drawerOnFocused("timer");
		}
	}

	IpcHandler {
		target: "ssh"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("ssh", screen));
		}
		function close(): void {
			if (Popups.current === "ssh") Popups.close();
		}
		function toggle(): void {
			shell.drawerOnFocused("ssh");
		}
	}

	// ~/.local/bin/record reports here so the bar can show the recording
	IpcHandler {
		target: "recording"

		function started(file: string): void {
			Recorder.started(file);
		}
		function stopped(file: string): void {
			Recorder.stopped(file);
		}
		function stop(): void {
			Recorder.stop();
		}
	}

	IpcHandler {
		target: "dnd"

		function toggle(): void {
			Notifs.toggleDnd();
		}
		function on(): void {
			Notifs.setDnd(true);
		}
		function off(): void {
			Notifs.setDnd(false);
		}
		function active(): bool {
			return Notifs.dnd;
		}
	}

	IpcHandler {
		target: "keepawake"

		function toggle(): void {
			KeepAwake.toggle();
		}
	}

	IpcHandler {
		target: "phone"

		function sendClipboard(): void {
			KdeConnect.sendClipboard();
		}
		function sendText(text: string): void {
			KdeConnect.sendText(text);
		}
		function ring(): void {
			KdeConnect.ring();
		}
	}

	IpcHandler {
		target: "volume"

		function raise(): void {
			Audio.adjust(1);
		}
		function lower(): void {
			Audio.adjust(-1);
		}
		function muteToggle(): void {
			Audio.toggleMute();
		}
		function micMuteToggle(): void {
			Audio.toggleMicMute();
		}
	}

	IpcHandler {
		target: "brightness"

		function raise(): void {
			Brightness.adjust(1);
		}
		function lower(): void {
			Brightness.adjust(-1);
		}
	}

	IpcHandler {
		target: "theme"

		function reload(): void {
			Theme.reload();
		}
	}

	IpcHandler {
		target: "themeTask"

		function show(status: string, title: string, detail: string): void {
			Notifs.pushInternal(status, title, detail);
		}
	}

	IpcHandler {
		target: "animationPicker"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("animation", screen));
		}
		function close(): void {
			if (Popups.modal === "animation") Popups.closeModal();
		}
		function toggle(): void {
			shell.modalOnFocused("animation");
		}
	}

	IpcHandler {
		target: "rpg"

		// the game no longer has a bar popup: every entry point opens its window
		function open(): void {
			rpgWindow.openWindow();
		}
		function window(): void {
			rpgWindow.openWindow();
		}
		function windowTab(index: int): void {
			rpgWindow.showTab(index);
		}
		function windowClose(): void {
			rpgWindow.closeWindow();
		}
		function close(): void {
			rpgWindow.closeWindow();
		}
		function toggle(): void {
			if (rpgWindow.visible) rpgWindow.closeWindow();
			else rpgWindow.openWindow();
		}
		function tab(index: int): void {
			rpgWindow.showTab(index);
		}
		function start(): void {
			rpgGame.startExpedition();
		}
		function stop(): void {
			rpgGame.stopExpedition();
		}
	}
}
