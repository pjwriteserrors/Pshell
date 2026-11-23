pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Audient EVO4 (`evo4` plugin): gain and output volume as its knobs
// have them (ALSA, live), 48V, mute and stereo link per input, output mute
// and link, the loopback mix. scripts/evo4/evo4.py speaks to it; what is
// picked here is kept in evo4.json and written again each time the EVO4
// comes – it forgets it without power. Everything but the knobs and the
// output mute takes the card away for half a second (docs/evo4.md).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("evo4")
	readonly property string script: `${Paths.scripts}/evo4/evo4.py`

	property var device: ({ online: false })
	readonly property bool online: root.device.online === true
	property bool scanned: false
	property bool loaded: false
	property bool busy: false
	property string error: ""
	property bool watching: false

	readonly property var knobs: root.device.knobs ?? ({})
	readonly property var hw: root.device.hw ?? null
	readonly property bool known: root.hw !== null
	readonly property bool stuck: root.device.stuck === true

	// { device: { phantom: [b, b], mute: [b, b], inputLink, outputLink, loopback: [12 × dB | null] } }
	property var config: ({ device: {} })
	readonly property var wanted: root.config.device ?? ({})

	// the loopback mix: unit 60's points are source × 2 + side (0 left, 1 right)
	readonly property var sources: [
		{ id: "in1", label: "Input 1" },
		{ id: "in2", label: "Input 2" },
		{ id: "out-l", label: "Output L" },
		{ id: "out-r", label: "Output R" },
		{ id: "loop-l", label: "Loopback playback L" },
		{ id: "loop-r", label: "Loopback playback R" }
	]

	onWatchingChanged: root.send({ op: "watch", on: root.watching })

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	// what the page shows: what was picked, else what the device said
	function value(key, index) {
		const want = root.wanted[key];
		const have = root.hw ? root.hw[key] : undefined;
		const pick = v => (index === undefined ? v : (Array.isArray(v) ? v[index] : undefined));
		const w = pick(want);
		return w !== undefined ? w : pick(have);
	}

	function set(key, value, index) {
		const device = Object.assign({}, root.wanted);
		if (index === undefined) {
			device[key] = value;
		} else {
			const size = key === "loopback" ? 12 : 2;
			const list = Array.isArray(device[key]) && device[key].length === size ? device[key].slice()
				: (root.hw && Array.isArray(root.hw[key]) ? root.hw[key].slice() : new Array(size).fill(null));
			list[index] = value;
			device[key] = list;
		}
		root.config = Object.assign({}, root.config, { device });
		root.commit();
		root.send(index === undefined ? { op: "set", key, value } : { op: "set", key, value, index });
	}
	function mix(source, side) {
		const v = root.value("loopback", source * 2 + side);
		return v === undefined ? null : v;
	}
	function setMix(source, side, db) {
		root.set("loopback", db, source * 2 + side);
	}
	function setGain(index, db) {
		root.send({ op: "gain", index, db });
	}
	function setVolume(db) {
		root.send({ op: "volume", db });
	}
	function setOutMute(on) {
		root.send({ op: "outMute", on });
	}
	function read() {
		root.send({ op: "read" });
	}
	function refresh() {
		root.send({ op: "refresh" });
	}

	function commit() {
		saving.restart();
		pushing.restart();
	}

	Timer {
		id: saving

		interval: 400
		onTriggered: file.setText(JSON.stringify(root.config, null, "\t") + "\n")
	}

	Timer {
		id: pushing

		interval: 60
		onTriggered: root.send({ op: "config", config: root.config })
	}

	FileView {
		id: file

		path: Paths.stateFile("evo4.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = { device: data.device && typeof data.device === "object" ? data.device : {} };
			} catch (error) {
				console.warn("Evo4: evo4.json is not valid JSON");
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "device":
			root.device = data;
			root.scanned = true;
			break;
		case "session":
			root.busy = data.busy === true;
			break;
		case "adopt": {
			// what the device has that was not picked here (48V pressed on it, the first read)
			const device = Object.assign({}, root.wanted);
			for (const key of ["phantom", "mute", "inputLink", "outputLink", "loopback"])
				if (key in data) device[key] = data[key];
			root.config = Object.assign({}, root.config, { device });
			root.commit();
			break;
		}
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	Timer {
		id: clearError

		interval: 8000
		onTriggered: root.error = ""
	}

	Process {
		id: daemon

		running: root.enabled && root.loaded
		stdinEnabled: true
		command: ["python3", "-u", root.script]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(line)
		}
		onRunningChanged: if (daemon.running) {
			root.send({ op: "config", config: root.config });
			if (root.watching) root.send({ op: "watch", on: true });
		}
		onExited: {
			root.device = { online: false };
			root.busy = false;
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
