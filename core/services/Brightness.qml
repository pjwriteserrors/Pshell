pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Brightness keys: the laptop panel via brightnessctl, external monitors
// via DDC, whichever this host has.
Singleton {
	id: root

	property real value: 0
	// the panel answered brightnessctl
	property bool found: false
	readonly property bool wanted: Plugins.on("backlight")
	readonly property bool available: root.wanted && root.found
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
		if (Plugins.on("backlight")) {
			Quickshell.execDetached(["brightnessctl", "set", direction > 0 ? "5%+" : "5%-"]);
			refreshTimer.restart();
		}
		if (Plugins.on("ddc"))
			Ddc.adjustAll(direction, !Plugins.on("backlight"));
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
				root.found = max > 0;
				const progress = Number(match[1]) / Math.max(1, max);
				root.value = progress;
				if (root.showOsdOnRead)
					Osd.show("brightness", "Brightness", progress, `${Math.round(progress * 100)}%`, root.icon(progress));
				root.showOsdOnRead = false;
			}
		}
	}

	onWantedChanged: if (root.wanted) root.refresh(false)
	Component.onCompleted: if (root.wanted) root.refresh(false)
}
