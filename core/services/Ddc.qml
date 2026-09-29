pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Brightness of external monitors over DDC/CI (ddcutil). Monitors are
// detected at start and whenever the screen setup changes; levels are read
// when quick settings open. ddcutil is slow, so while a slider is dragged
// only the latest value per monitor is written once the previous write is
// done.
Singleton {
	id: root

	readonly property string script: `${Quickshell.shellDir}/scripts/ddc_brightness.sh`

	// [{ bus, connector, model, value (0..1), known }]
	property var monitors: []
	property var pending: ({})
	property var writing: ({})

	readonly property bool available: root.monitors.length > 0

	function detect() {
		if (Host.has("ddc") && !detectProc.running) detectProc.running = true;
	}

	// nothing found yet (ddcutil failed at start): look again
	function refresh() {
		if (root.monitors.length === 0) {
			root.detect();
			return;
		}
		if (readProc.running) return;
		readProc.command = ["bash", root.script, "get"].concat(root.monitors.map(m => String(m.bus)));
		readProc.running = true;
	}

	function update(bus, changes) {
		root.monitors = root.monitors.map(m => m.bus === bus ? Object.assign({}, m, changes) : m);
	}

	function set(bus, value) {
		const v = Math.max(0, Math.min(1, value));
		root.update(bus, { value: v, known: true });
		const next = Object.assign({}, root.pending);
		next[bus] = Math.round(v * 100);
		root.pending = next;
		root.flush(bus);
	}

	function flush(bus) {
		if (root.writing[bus] || root.pending[bus] === undefined) return;
		const level = root.pending[bus];
		const pending = Object.assign({}, root.pending);
		delete pending[bus];
		root.pending = pending;
		const writing = Object.assign({}, root.writing);
		writing[bus] = true;
		root.writing = writing;
		const proc = writer.createObject(root, { bus: bus });
		proc.command = ["ddcutil", "--bus", String(bus), "setvcp", "10", String(level), "--noverify"];
		proc.running = true;
	}

	// brightness keys: every monitor one step, the OSD shows the average
	function adjustAll(direction, showOsd) {
		if (root.monitors.length === 0) return;
		for (const monitor of root.monitors)
			root.set(monitor.bus, monitor.value + direction * 0.05);
		if (!showOsd) return;
		const average = root.monitors.reduce((sum, monitor) => sum + monitor.value, 0) / root.monitors.length;
		Osd.show("brightness", "Brightness", average, `${Math.round(average * 100)}%`, Brightness.icon(average));
	}

	function label(monitor) {
		return monitor.model || monitor.connector || `Bus ${monitor.bus}`;
	}

	Component {
		id: writer

		Process {
			property string bus: ""

			onExited: {
				const writing = Object.assign({}, root.writing);
				delete writing[bus];
				root.writing = writing;
				root.flush(bus);
				destroy();
			}
		}
	}

	Process {
		id: detectProc

		command: ["bash", root.script, "detect"]
		stdout: StdioCollector {
			onStreamFinished: {
				const found = [];
				for (const line of String(text).split("\n")) {
					const parts = line.split("\t");
					if (parts.length < 3 || parts[0] === "") continue;
					const old = root.monitors.find(m => m.bus === parts[0]);
					found.push({ bus: parts[0], connector: parts[1], model: parts[2].trim(), value: old?.value ?? 0.5, known: old?.known ?? false });
				}
				// left to right like the monitors are arranged
				const order = connector => Quickshell.screens.find(s => String(s.name) === connector)?.x ?? 1e9;
				found.sort((a, b) => order(a.connector) - order(b.connector));
				root.monitors = found;
				root.refresh();
			}
		}
	}

	Process {
		id: readProc

		stdout: StdioCollector {
			onStreamFinished: {
				for (const line of String(text).split("\n")) {
					const parts = line.split("\t");
					if (parts.length < 3) continue;
					const max = Math.max(1, Number(parts[2]));
					if (!root.writing[parts[0]]) root.update(parts[0], { value: Number(parts[1]) / max, known: true });
				}
			}
		}
	}

	// the screen setup changed (docking, profiles): look again
	Connections {
		target: Quickshell
		function onScreensChanged() {
			redetect.restart();
		}
	}

	Timer {
		id: redetect
		interval: 3000
		onTriggered: root.detect()
	}

	Component.onCompleted: root.detect()
}
