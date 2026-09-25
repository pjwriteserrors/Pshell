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

	IpcHandler {
		target: "power"

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
			root.drawerOnFocused("control", "bluetooth");
		}
		function toggleNetwork(): void {
			root.drawerOnFocused("control", "network");
		}
		function toggleResources(): void {
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
	}

	IpcHandler {
		target: "updates"

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
		enabled: Host.has("qtrack")

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
		enabled: Host.has("ssh")

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
		enabled: Host.has("kdeconnect")

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
		target: "animationPicker"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("animation", screen));
		}
		function close(): void {
			if (Popups.modal === "animation") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("animation");
		}
	}
}
