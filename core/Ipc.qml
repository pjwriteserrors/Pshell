pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services

// Every IPC target used by keybinds and scripts (`scripts/ipc.sh <target>
// <function>`). Lives in the core so a style can never drop one.
Scope {
	id: root

	// identity of the checked-out style branch, read once per load; a reload
	// that fails keeps the old config and so still reports the old style,
	// which is how scripts/branch_styles.py notices and rolls back
	readonly property string styleId: {
		try {
			return String(JSON.parse(styleManifest.text() || "{}").name || "");
		} catch (error) {
			return "";
		}
	}
	property bool styleSwitching: false

	FileView {
		id: styleManifest

		path: `${Quickshell.shellDir}/.quickshell-style.json`
		blockLoading: true
	}

	IpcHandler {
		target: "styleSession"

		function state(): string {
			return JSON.stringify({
				locked: Session.locked,
				style: root.styleId,
				shellDir: Quickshell.shellDir,
				switching: root.styleSwitching
			});
		}
		function freeze(): void {
			root.styleSwitching = true;
			Quickshell.watchFiles = false;
		}
		function thaw(): void {
			root.styleSwitching = false;
		}
		// never reload from inside the call being answered: the handler is
		// part of the tree that is about to be torn down
		function reload(): void {
			styleReload.restart();
		}
	}

	Timer {
		id: styleReload

		interval: 1
		onTriggered: Quickshell.reload(true)
	}

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
			root.drawerOnFocused("launcher");
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

	// the plugin switches (>plugins)
	IpcHandler {
		target: "plugins"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("plugins", screen));
		}
		function close(): void {
			if (Popups.modal === "plugins") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("plugins");
		}
		function enable(id: string): void {
			Plugins.set(id, true);
		}
		function disable(id: string): void {
			Plugins.set(id, false);
		}
		function isOn(id: string): bool {
			return Plugins.on(id);
		}
		// every plugin that is on, one per line
		function list(): string {
			return Plugins.list.filter(plugin => Plugins.on(plugin.id)).map(plugin => plugin.id).join("\n");
		}
	}

	IpcHandler {
		target: "power"
		enabled: Plugins.on("power-menu")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("power", screen));
		}
		function close(): void {
			if (Popups.modal === "power") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("power");
		}
	}

	// quick actions around the pointer
	IpcHandler {
		target: "radial"
		enabled: Plugins.on("radial-menu")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("radial", screen));
		}
		function close(): void {
			if (Popups.modal === "radial") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("radial");
		}
	}

	IpcHandler {
		target: "screenshot"
		enabled: Plugins.on("screenshot")

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
		function live(): void {
			Screenshot.liveMode();
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
		enabled: Plugins.on("lock-screen")

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
			root.drawerOnFocused("today");
		}
		function toggleWeather(): void {
			root.drawerOnFocused("today");
		}
		function toggleNotifications(): void {
			root.drawerOnFocused("today");
		}
		function toggleMedia(): void {
			root.drawerOnFocused("media");
		}
		function toggleBluetooth(): void {
			if (!Plugins.on("bluetooth")) return;
			root.drawerOnFocused("control", "bluetooth");
		}
		function toggleNetwork(): void {
			if (!Plugins.on("network")) return;
			root.drawerOnFocused("control", "network");
		}
		function toggleResources(): void {
			if (!Plugins.on("system-monitor")) return;
			root.drawerOnFocused("control", "system");
		}
		function toggleControl(): void {
			root.drawerOnFocused("control", "main");
		}
		function toggleUpdates(): void {
			root.drawerOnFocused("updates");
		}
		function toggleOverview(): void {
			root.drawerOnFocused("overview");
		}
		function closeAll(): void {
			Popups.closeAll();
		}
		// any panel by id: control, today, timer, media, clipboard, ssh, notes, launcher
		function toggle(name: string): void {
			root.drawerOnFocused(name);
		}
		// a page of a panel, e.g. control audio
		function togglePage(name: string, page: string): void {
			root.drawerOnFocused(name, page);
		}
	}

	// names the song that is playing, in the media panel
	IpcHandler {
		target: "song"
		enabled: Plugins.on("song-detection")

		function detect(): void {
			if (Popups.current !== "media") Popups.withFocusedScreen(screen => Popups.open("media", screen));
			SongDetect.detect();
		}
		function cancel(): void {
			SongDetect.cancel();
		}
	}

	IpcHandler {
		target: "updates"
		enabled: Plugins.on("updates")

		function open(): void {
			root.drawerOnFocused("updates");
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
		enabled: Plugins.on("clipboard")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("clipboard", screen));
		}
		function close(): void {
			if (Popups.current === "clipboard") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("clipboard");
		}
	}

	IpcHandler {
		target: "qtrack"
		enabled: Plugins.on("qtrack")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("timer", screen));
		}
		function close(): void {
			if (Popups.current === "timer") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("timer");
		}
	}

	IpcHandler {
		target: "ssh"
		enabled: Plugins.on("ssh")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("ssh", screen));
		}
		function close(): void {
			if (Popups.current === "ssh") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("ssh");
		}
	}

	// ~/.local/bin/record reports here so the bar can show the recording
	IpcHandler {
		target: "shelf"
		enabled: Plugins.on("shelves")

		function toggle(): void {
			Shelf.toggle();
		}
		// a new shelf with what the clipboard holds
		function clipboard(): void {
			Shelf.fromClipboard();
		}
		function reopen(): void {
			Shelf.reopen("");
		}
		function closeAll(): void {
			Shelf.closeAll();
		}
		function add(path: string): void {
			Shelf.arrived(path);
		}
	}

	IpcHandler {
		target: "agents"
		enabled: Plugins.on("agents")

		// scripts/agent_hook.py: state is "busy" or "idle"
		function report(window: int, state: string, agent: string): void {
			Agents.report(window, state, agent);
		}
	}

	IpcHandler {
		target: "recording"
		enabled: Plugins.on("recording")

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
		enabled: Plugins.on("dnd")

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
		enabled: Plugins.on("keep-awake")

		function toggle(): void {
			KeepAwake.toggle();
		}
	}

	IpcHandler {
		target: "breaks"
		enabled: Plugins.on("breaks")

		function toggle(): void {
			root.drawerOnFocused("breaks");
		}
		function drink(): void {
			Breaks.drinkGlass();
		}
		function undrink(): void {
			Breaks.removeGlass();
		}
		function refill(): void {
			Breaks.refill();
		}
		function uncount(): void {
			Breaks.uncount();
		}
		function bottle(left: int): void {
			Breaks.setBottleLevel(left);
		}
		function headache(): void {
			Breaks.logHeadache();
		}
		function eyes(): void {
			Breaks.startEyeRest();
		}
		function stretch(): void {
			if (Popups.modal === "stretch") Breaks.finishStretch(false);
			else Breaks.startStretch();
		}
		function toggleReminders(): void {
			Breaks.setEnabled(!Breaks.enabled);
		}
	}

	IpcHandler {
		target: "phone"
		enabled: Plugins.on("kdeconnect")

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
		enabled: Plugins.on("sound")

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

	// Studio: wallpaper, motion, dress, styles, combinations
	IpcHandler {
		target: "studio"

		function open(page: string): void {
			Popups.withFocusedScreen(screen => Popups.openStudio(page, screen));
		}
		function close(): void {
			if (Popups.studioIndex >= 0) Popups.closeModal();
		}
		function toggle(page: string): void {
			if (Popups.studioIndex >= 0 && (page === "" || Popups.studioPages[Popups.studioIndex].id === page))
				Popups.closeModal();
			else
				Popups.withFocusedScreen(screen => Popups.openStudio(page, screen));
		}
	}
}
