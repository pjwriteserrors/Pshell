pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The 8BitDo Ultimate 2 Wireless (`ultimate` plugin): its three profiles –
// what every button does, sticks, triggers, vibration, motion, the light
// rings, macros – and how it is. scripts/ultimate/ultimate.py speaks to it;
// the pad keeps everything itself, the shell keeps nothing (but the first
// record it read, for *Put back*).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("ultimate")
	readonly property string script: `${Paths.scripts}/ultimate/ultimate.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false })
	readonly property bool online: root.device.online === true
	// the controller behind the dongle is on (and so its record is read)
	readonly property bool linked: root.online && root.device.linked === true && Array.isArray(root.device.profiles)
	property bool scanned: false
	property string error: ""
	// live, while the page watches
	property var held: []
	property var axes: ({})
	// recording a macro on the pad
	property string macroState: "idle"
	property int macroSteps: 0
	// "slot/index" -> [[ms, keys, trigger, left, right]]
	property var steps: ({})
	property bool watching: false
	signal saved

	readonly property var info: root.device.info ?? ({})
	readonly property var pad: root.device.pad ?? null
	readonly property int slot: root.device.slot ?? 3
	readonly property var profiles: root.device.profiles ?? []

	onWatchingChanged: root.send({ op: "watch", on: root.watching })

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function set(slot, key, value) {
		root.send({ op: "set", slot, key, value });
	}
	function setProfile(slot, on) {
		root.send({ op: "profile", slot, on });
	}
	function copy(from, to) {
		root.send({ op: "copy", from, to });
	}
	// { wallpaper?: bool, brightness?: 0–1 }
	function setLight(values) {
		root.send(Object.assign({ op: "light" }, values));
	}
	function setTheme(theme) {
		root.send({ op: "theme", theme });
	}
	function setMacro(slot, index, values) {
		root.send(Object.assign({ op: "macro", slot, index }, values));
	}
	function readSteps(slot, index) {
		root.send({ op: "steps", slot, index });
	}
	function record(slot, index) {
		root.send({ op: "record", slot, index });
	}
	function stopRecording() {
		root.send({ op: "record", stop: true });
	}
	function rumble(left, right, ms) {
		root.send({ op: "rumble", left, right, ms });
	}
	function restore() {
		root.send({ op: "restore" });
	}
	function refresh() {
		root.send({ op: "refresh" });
	}

	// ── names ──────────────────────────────────────────────────────────────
	readonly property var buttons: [
		{ id: "a", label: "A" }, { id: "b", label: "B" }, { id: "x", label: "X" }, { id: "y", label: "Y" },
		{ id: "lb", label: "LB" }, { id: "rb", label: "RB" }, { id: "lt", label: "LT" }, { id: "rt", label: "RT" },
		{ id: "l3", label: "L3" }, { id: "r3", label: "R3" }, { id: "select", label: "View" }, { id: "start", label: "Menu" },
		{ id: "star", label: "Star" }, { id: "home", label: "Home" },
		{ id: "up", label: "Up" }, { id: "down", label: "Down" }, { id: "left", label: "Left" }, { id: "right", label: "Right" },
		{ id: "pl", label: "PL" }, { id: "pr", label: "PR" }, { id: "l4", label: "L4" }, { id: "r4", label: "R4" }
	]
	readonly property var functions: [
		{ value: "a", label: "A" }, { value: "b", label: "B" }, { value: "x", label: "X" }, { value: "y", label: "Y" },
		{ value: "lb", label: "LB" }, { value: "rb", label: "RB" }, { value: "lt", label: "LT" }, { value: "rt", label: "RT" },
		{ value: "l3", label: "L3", detail: "Left stick click" }, { value: "r3", label: "R3", detail: "Right stick click" },
		{ value: "select", label: "View" }, { value: "start", label: "Menu" }, { value: "home", label: "Home" }, { value: "star", label: "Star" },
		{ value: "up", label: "D-pad up" }, { value: "down", label: "D-pad down" }, { value: "left", label: "D-pad left" }, { value: "right", label: "D-pad right" },
		{ value: "ls-up", label: "Left stick up" }, { value: "ls-down", label: "Left stick down" }, { value: "ls-left", label: "Left stick left" }, { value: "ls-right", label: "Left stick right" },
		{ value: "rs-up", label: "Right stick up" }, { value: "rs-down", label: "Right stick down" }, { value: "rs-left", label: "Right stick left" }, { value: "rs-right", label: "Right stick right" },
		{ value: "turbo", label: "Turbo", detail: "Hold it with a button: that button repeats" },
		{ value: "turbo-auto", label: "Auto turbo", detail: "Hold it with a button: that button repeats by itself" },
		{ value: "screenshot", label: "Screenshot" },
		{ value: "none", label: "Nothing", icon: "cancel" }
	]
	function functionLabel(value) {
		return root.functions.find(f => f.value === value)?.label ?? value;
	}
	function buttonLabel(id) {
		return root.buttons.find(b => b.id === id)?.label ?? id;
	}

	// ── the daemon ─────────────────────────────────────────────────────────
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
		case "input":
			root.held = data.held ?? [];
			root.axes = data.axes ?? {};
			break;
		case "pad":
			if (data.kind === "slot")
				Osd.show("ultimate", "Controller profile", data.slot >= 3 ? 0 : (data.slot + 1) / 3, data.slot >= 3 ? "Standard" : (data.name || `Profile ${data.slot + 1}`), "gamepad_variant");
			else if (data.kind === "battery" && root.watching)
				Osd.show("ultimate", "Controller", (data.level ?? 0) / 100, `${data.level} %`, "battery");
			break;
		case "macro":
			root.macroState = data.state ?? "idle";
			root.macroSteps = data.steps ?? 0;
			if (data.state === "recording" && !data.steps) Osd.show("ultimate-macro", "Recording on the controller", 1, "Press, then stop on the page", "record_rec");
			else if (data.state === "idle" && data.recorded) Osd.show("ultimate-macro", "Macro kept", 1, `${data.steps} steps`, "check");
			break;
		case "steps":
			root.steps = Object.assign({}, root.steps, { [`${data.slot}/${data.index}`]: data.steps ?? [] });
			break;
		case "saved":
			root.saved();
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	Timer {
		id: clearError

		interval: 6000
		onTriggered: root.error = ""
	}

	Process {
		id: daemon

		running: root.enabled
		stdinEnabled: true
		command: ["python3", "-u", root.script]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(line)
		}
		onRunningChanged: if (daemon.running && root.watching) root.send({ op: "watch", on: true })
		onExited: {
			root.device = { online: false };
			root.macroState = "idle";
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
