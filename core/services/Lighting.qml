pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The OpenRGB devices and what each of them shows: the wallpaper (the theme
// hooks openrgb and openrgb-leds, scripts/apply_lighting.py), the screen live
// (scripts/lighting_live.py) or nothing. Set on the Lighting page of the
// Pshell settings and kept in lighting.json, which both scripts read.
//
// Live costs only while a device is live: the process runs then and stops
// by itself once none is. niri hands it a frame only when the screen changed.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/apply_lighting.py`
	readonly property bool enabled: Plugins.on("hook-openrgb") || Plugins.on("hook-openrgb-leds")

	// ── settings (lighting.json) ───────────────────────────────────────────
	// device id ("keyboard", "gpu", "argb", "device:<name>") → "live" | "off";
	// missing means the wallpaper
	property var modes: ({})
	// the output that is mirrored; "" is the largest
	property string output: ""
	property int fps: 15
	// how much of the last colour stays each frame (0: none, jumps at once)
	property real smoothing: 0.5
	property bool loaded: false

	readonly property var modeNames: ["wallpaper", "live", "off"]

	function modeOf(id) {
		return root.modes[id] ?? "wallpaper";
	}

	function setMode(id, mode) {
		if (!root.modeNames.includes(mode) || root.modeOf(id) === mode) return;
		const next = Object.assign({}, root.modes);
		if (mode === "wallpaper") delete next[id];
		else next[id] = mode;
		root.modes = next;
		root.save();
		// the devices that left live (or went dark) get their colours back
		refreshing.restart();
	}

	function setOutput(name) {
		root.output = name;
		root.save();
	}

	function setFps(fps) {
		root.fps = Math.max(1, Math.min(60, Math.round(fps)));
		root.save();
	}

	function setSmoothing(value) {
		root.smoothing = Math.max(0, Math.min(0.95, value));
		saving.restart();
	}

	function save() {
		file.setText(JSON.stringify({ modes: root.modes, output: root.output, fps: root.fps, smoothing: root.smoothing }, null, "\t") + "\n");
	}

	function load(text) {
		try {
			const data = JSON.parse(text || "{}");
			const modes = {};
			if (data.modes && typeof data.modes === "object" && !Array.isArray(data.modes))
				for (const id of Object.keys(data.modes))
					if (data.modes[id] === "live" || data.modes[id] === "off") modes[id] = data.modes[id];
			root.modes = modes;
			root.output = typeof data.output === "string" ? data.output : "";
			root.fps = typeof data.fps === "number" ? Math.max(1, Math.min(60, Math.round(data.fps))) : 15;
			root.smoothing = typeof data.smoothing === "number" ? Math.max(0, Math.min(0.95, data.smoothing)) : 0.5;
		} catch (error) {
			console.warn("Lighting: lighting.json is not valid JSON");
		}
		root.loaded = true;
	}

	// a slider writes once it rests
	Timer {
		id: saving

		interval: 400
		onTriggered: root.save()
	}

	FileView {
		id: file

		path: Paths.stateFile("lighting.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.load(text())
	}

	// ── devices ────────────────────────────────────────────────────────────
	// [{ id, kind, name, present, mode }] (apply_lighting.py --devices)
	property var devices: []
	property bool scanned: false
	// whether an OpenRGB server answered the last scan
	property bool server: true
	readonly property bool scanning: scanProc.running

	function scan() {
		if (root.enabled && !scanProc.running) scanProc.running = true;
	}

	Process {
		id: scanProc

		command: ["python3", root.script, "--devices"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text) || "{}");
					root.devices = Array.isArray(data.devices) ? data.devices : [];
					root.server = data.server !== false;
				} catch (error) {
					root.devices = [];
					root.server = false;
				}
				root.scanned = true;
			}
		}
	}

	// ── static colours ─────────────────────────────────────────────────────
	// several clicks in a row are one run, and the live process (it reads
	// the settings once a second) has let go of the device before
	Timer {
		id: refreshing

		interval: 1500
		onTriggered: {
			if (refreshProc.running) {
				refreshing.restart();
				return;
			}
			refreshProc.running = true;
		}
	}

	Process {
		id: refreshProc

		command: ["python3", root.script, "--refresh"]
	}

	// keyboard and LEDs keep their colours: put back when the keyboard is
	// plugged in again and after a restart of the OpenRGB server
	Process {
		running: root.enabled
		command: ["python3", root.script, "--watch"]
	}

	// ── live ───────────────────────────────────────────────────────────────
	readonly property bool liveWanted: root.enabled && Object.keys(root.modes).some(id => root.modes[id] === "live")
	readonly property bool liveRunning: liveProc.running

	onLiveWantedChanged: {
		retry.stop();
		liveProc.running = root.liveWanted;
	}

	Process {
		id: liveProc

		command: ["python3", root.script, "--live"]
		stderr: SplitParser {
			onRead: line => console.warn(line)
		}
		// it ends by itself once no device is live; a crash is retried
		onExited: (code, status) => {
			if (root.liveWanted) retry.restart();
		}
	}

	Timer {
		id: retry

		interval: 5000
		onTriggered: if (root.liveWanted && !liveProc.running) liveProc.running = true
	}
}
