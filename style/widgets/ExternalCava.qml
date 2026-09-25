pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// cava in raw ascii mode; only runs while `active`.
Item {
	id: root

	property int bars: 32
	property bool active: false
	property var values: []
	property string inputMethod: "pipewire"

	visible: false

	function normalized(frame) {
		const out = [];
		for (const part of String(frame).trim().split(/[;,\s]+/).filter(Boolean)) {
			const value = Number(part);
			if (!Number.isNaN(value))
				out.push(Math.max(0, Math.min(1, Math.pow(Math.max(0, Math.min(1, value / 100)), 0.7) * 1.18)));
		}
		return out;
	}

	function command(method) {
		const lines = ["[general]", "framerate = 60", `bars = ${root.bars}`, "autosens = 1", "[input]", `method = ${method}`,
			"[output]", "method = raw", "raw_target = /dev/stdout", "data_format = ascii", "ascii_max_range = 100", "channels = mono", "mono_option = average"];
		const escaped = lines.map(line => `'${line.replace(/'/g, `'"'"'`)}'`).join(" ");
		return ["sh", "-c", `tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; printf '%s\\n' ${escaped} > "$tmp"; exec cava -p "$tmp"`];
	}

	onActiveChanged: {
		if (!active) {
			const zeros = [];
			for (let i = 0; i < root.bars; i += 1) zeros.push(0);
			root.values = zeros;
		}
	}

	Process {
		id: proc

		running: root.active
		command: root.command(root.inputMethod)
		stdout: SplitParser {
			onRead: data => {
				const parsed = root.normalized(data);
				if (parsed.length > 0) root.values = parsed;
			}
		}
		onExited: {
			if (!root.active) return;
			if (root.inputMethod === "pipewire") {
				root.inputMethod = "pulse";
				retry.restart();
			}
		}
	}

	Timer {
		id: retry
		interval: 300
		onTriggered: if (root.active) proc.running = true
	}
}
