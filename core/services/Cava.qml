pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One cava for every visualizer (style/widgets/ExternalCava.qml): it runs
// while one of them is active, with as many bars and frames as the most
// demanding asks for; each of them groups the bars it gets into its own.
Singleton {
	id: root

	// key → { bars, framerate } of the visualizers that are active
	property var wants: ({})
	readonly property int bars: Object.values(root.wants).reduce((most, want) => Math.max(most, want.bars), 0)
	readonly property int framerate: Object.values(root.wants).reduce((most, want) => Math.max(most, want.framerate), 0)
	readonly property bool active: root.bars > 0
	// what cava runs with; it restarts only when this changes
	readonly property string spec: root.active ? `${root.bars}@${root.framerate}` : ""
	// 0 … 1 each, `bars` of them
	property var values: []
	property string inputMethod: "pipewire"
	property bool restarting: false
	readonly property string config: `${Paths.runtime}/cava.conf`

	function want(key, bars, framerate) {
		const next = Object.assign({}, root.wants);
		next[key] = { bars: Math.max(1, bars), framerate: Math.max(1, framerate) };
		root.wants = next;
	}

	function release(key) {
		if (!(key in root.wants)) return;
		const next = Object.assign({}, root.wants);
		delete next[key];
		root.wants = next;
	}

	// `count` values out of the shared ones, each the mean of its group
	function grouped(count) {
		const source = root.values;
		if (count <= 0 || source.length === 0) return [];
		if (source.length === count) return source;
		const out = [];
		for (let i = 0; i < count; i += 1) {
			const from = Math.floor(i * source.length / count);
			const to = Math.max(from + 1, Math.floor((i + 1) * source.length / count));
			let sum = 0;
			for (let j = from; j < to; j += 1) sum += source[j];
			out.push(sum / (to - from));
		}
		return out;
	}

	function parse(frame) {
		const out = [];
		for (const part of String(frame).split(";")) {
			if (part === "") continue;
			const value = Number(part);
			if (!Number.isNaN(value))
				out.push(Math.min(1, Math.pow(Math.max(0, Math.min(1, value / 100)), 0.7) * 1.18));
		}
		return out;
	}

	onSpecChanged: {
		// a restart for the new demand is no failure of the input
		root.restarting = proc.running;
		proc.running = false;
		if (!root.active) {
			root.values = [];
			return;
		}
		root.writeConfig();
	}

	function writeConfig() {
		if (!root.active) return;
		configFile.setText(["[general]", `framerate = ${root.framerate}`, `bars = ${root.bars}`, "autosens = 1",
			"[input]", `method = ${root.inputMethod}`,
			"[output]", "method = raw", "raw_target = /dev/stdout", "data_format = ascii", "ascii_max_range = 100",
			"bar_delimiter = 59", "channels = mono", "mono_option = average", ""].join("\n"));
	}

	FileView {
		id: configFile

		path: root.config
		printErrors: false
		onSaved: if (root.active) proc.running = true
	}

	Process {
		id: proc

		command: ["cava", "-p", root.config]
		stdout: SplitParser {
			onRead: data => {
				const parsed = root.parse(data);
				if (parsed.length > 0) root.values = parsed;
			}
		}
		onExited: {
			if (root.restarting) {
				root.restarting = false;
				return;
			}
			if (!root.active) return;
			// older setups: pulse's monitor when PipeWire's input is missing
			if (root.inputMethod === "pipewire") {
				root.inputMethod = "pulse";
				root.writeConfig();
			}
		}
	}
}
