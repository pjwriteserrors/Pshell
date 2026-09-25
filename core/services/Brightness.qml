pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Backlight via brightnessctl (laptop panel). External monitors are handled
// by the niri keybinds (ddcutil) – this service only mirrors the OSD.
Singleton {
	id: root

	property real value: 0
	property bool available: false
	property bool showOsdOnRead: false

	function icon(progress) {
		if (progress < 0.34) return "brightness_5";
		if (progress < 0.67) return "brightness_6";
		return "brightness_7";
	}

	function refresh(showOsd = false) {
		root.showOsdOnRead = root.showOsdOnRead || showOsd;
		if (!readProc.running) readProc.running = true;
	}

	function adjust(direction) {
		Quickshell.execDetached(["brightnessctl", "set", direction > 0 ? "5%+" : "5%-"]);
		refreshTimer.restart();
	}

	function set(value) {
		const v = Math.max(0.01, Math.min(1, value));
		root.value = v;
		Quickshell.execDetached(["brightnessctl", "-q", "set", `${Math.round(v * 100)}%`]);
	}

	Timer {
		id: refreshTimer
		interval: 70
		onTriggered: root.refresh(true)
	}

	Process {
		id: readProc
		command: ["sh", "-lc", "current=$(brightnessctl g 2>/dev/null || echo 0); max=$(brightnessctl m 2>/dev/null || echo 0); printf '%s/%s\\n' \"$current\" \"$max\""]
		stdout: StdioCollector {
			onStreamFinished: {
				const match = String(text).trim().match(/^(\d+)\/(\d+)$/);
				if (!match) return;
				const max = Number(match[2]);
				root.available = max > 0;
				const progress = Number(match[1]) / Math.max(1, max);
				root.value = progress;
				if (root.showOsdOnRead)
					Osd.show("brightness", "Brightness", progress, `${Math.round(progress * 100)}%`, root.icon(progress));
				root.showOsdOnRead = false;
			}
		}
	}

	Component.onCompleted: root.refresh(false)
}
