pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Logitech keyboard (`keyboard` plugin): its special keys, backlight,
// Fn keys, locked keys, platform, Easy-Switch. scripts/keyboard/keyboard.py
// speaks HID++ to it (the mouse's driver and rule engine) and does what the
// rules say; actions of the shell come back here and run with the mouse's.
// The keyboard may be away: the daemon waits for it. Kept in keyboard.json:
//
//   devices: { <serial>: { on, mode, level, away, near, powered, fnSwap,
//              disabled: [names], platform, seen } }
//   rules:   [{ id, control, trigger, app, mods, action, on }]
//   options: { flash: "off" | "critical" | "all", flashPattern, holdMs, doubleMs, apps }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("keyboard")
	readonly property string script: `${Paths.scripts}/keyboard/keyboard.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var devices: []
	property bool solaar: false
	property var solaarKeys: []
	property bool running: daemon.running
	property bool scanned: false
	readonly property var device: root.devices.find(d => d.online) ?? root.devices[0] ?? null
	readonly property var state: root.device?.state ?? ({})
	readonly property bool online: !!root.device && root.device.online === true
	property string focusApp: ""
	property string error: ""
	property var batteryLog: []
	// live, while the page watches: control -> held; evdev code -> held
	property var pressed: ({})
	property var keys: ({})
	// the level a flash shows right now (-1: none)
	property int glow: -1
	signal fired(string rule, string control, string trigger)
	signal imported(int rules, int skipped, bool restarted)

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ devices: {}, rules: [], options: {} })
	property bool loaded: false
	readonly property var rules: root.config.rules ?? []
	readonly property var options: root.config.options ?? ({})
	readonly property var mine: root.device ? (root.config.devices?.[root.device.id] ?? {}) : ({})

	property bool watching: false
	onWatchingChanged: {
		root.send({ op: "watch", on: root.watching });
		if (!root.watching) {
			root.keys = {};
			root.pressed = {};
		}
	}

	function option(key, fallback) {
		return root.options[key] ?? fallback;
	}

	function setOption(key, value) {
		const options = Object.assign({}, root.options);
		options[key] = value;
		root.config = Object.assign({}, root.config, { options });
		root.commit();
	}

	function set(key, value) {
		root.setMany({ [key]: value });
	}

	// a device setting: to the keyboard at once, written when it rests
	function setMany(values) {
		if (!root.device) return;
		const devices = Object.assign({}, root.config.devices);
		devices[root.device.id] = Object.assign({}, devices[root.device.id] ?? {}, values);
		root.config = Object.assign({}, root.config, { devices });
		root.patch(root.device.id, { backlight: Object.assign({}, root.state.backlight ?? {}, ...["on", "mode", "level", "away", "near", "powered"].filter(k => k in values).map(k => ({ [k]: values[k] }))) });
		root.send({ op: "set", device: root.device.id, values });
		saving.restart();
	}

	function value(key, fallback) {
		return root.mine[key] ?? fallback;
	}

	// ── rules (the same shape as the mouse's) ─────────────────────────────
	function ruleFor(control, trigger, app) {
		return root.rules.find(r => r.control === control && r.trigger === trigger && (r.app ?? "") === (app ?? "") && (r.mods ?? []).length === 0) ?? null;
	}

	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function putRule(rule) {
		const rules = root.rules.slice();
		const at = rules.findIndex(r => r.id === rule.id);
		if (at >= 0) rules[at] = rule;
		else rules.push(rule);
		root.config = Object.assign({}, root.config, { rules });
		root.commit();
	}

	function assign(control, trigger, app, action, extra) {
		const old = root.ruleFor(control, trigger, app);
		if (!action) {
			if (old) root.removeRule(old.id);
			return;
		}
		const id = old?.id ?? `k${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
		root.putRule(Object.assign({ id, control, trigger, app: app ?? "", mods: [], on: true }, old ?? {}, extra ?? {}, { action }));
	}

	function removeRule(id) {
		root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.id !== id) });
		root.commit();
	}

	readonly property var apps: {
		const out = [];
		for (const app of root.option("apps", []).concat(root.rules.map(r => r.app ?? "")))
			if (app && !out.includes(app)) out.push(app);
		return out;
	}

	function addApp(app) {
		const apps = root.option("apps", []).slice();
		if (!app || apps.includes(app)) return;
		apps.push(app);
		root.setOption("apps", apps);
	}

	function removeApp(app) {
		root.config = Object.assign({}, root.config, {
			rules: root.rules.filter(r => (r.app ?? "") !== app),
			options: Object.assign({}, root.options, { apps: root.option("apps", []).filter(a => a !== app) })
		});
		root.commit();
	}

	// ── doing things ──────────────────────────────────────────────────────
	function test(action) {
		if (action?.kind === "shell") Mouse.runShell(action.id, action.value);
		else root.send({ op: "test", action });
	}

	function flash(pattern) {
		root.send({ op: "flash", pattern: pattern ?? root.option("flashPattern", "pulse") });
	}

	function switchHost(index) {
		root.send({ op: "host", device: root.device?.id ?? "", index });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	function takeOver() {
		root.send({ op: "takeover" });
	}

	// a notification came (core/services/Notifs.qml)
	function notified(critical) {
		const when = root.option("flash", "off");
		if (!root.enabled || !root.online || when === "off" || (when === "critical" && !critical)) return;
		root.flash();
	}

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
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

		path: Paths.stateFile("keyboard.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = {
					devices: data.devices && typeof data.devices === "object" ? data.devices : {},
					rules: Array.isArray(data.rules) ? data.rules : [],
					options: data.options && typeof data.options === "object" ? data.options : {}
				};
			} catch (error) {
				console.warn("Keyboard: keyboard.json is not valid JSON");
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// ── the daemon ────────────────────────────────────────────────────────
	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "devices":
			root.devices = data.devices ?? [];
			root.solaar = data.solaar === true;
			root.solaarKeys = data.solaarKeys ?? [];
			root.scanned = true;
			break;
		case "solaar":
			root.solaar = data.running === true;
			root.solaarKeys = data.keys ?? [];
			break;
		case "battery":
			root.patch(data.device, { battery: data.battery });
			break;
		case "backlight":
			root.patch(data.device, { backlight: data.backlight });
			if (data.values) root.keep(data.device, data.values);
			if (data.backlight?.on) Osd.show("keyboard", "Keyboard light", data.backlight.level / Math.max(1, (data.backlight.levels ?? 8) - 1), data.backlight.mode === "auto" ? "Auto" : `${data.backlight.level}`, "keyboard");
			else Osd.show("keyboard", "Keyboard light", 0, "Off", "keyboard_off");
			break;
		case "glow":
			root.glow = data.level ?? -1;
			break;
		case "fnSwap":
			root.patch(data.device, { fnSwap: data.on });
			root.keep(data.device, { fnSwap: data.on });
			break;
		case "locks":
			root.patch(data.device, { locks: data.locks });
			break;
		case "seen":
			root.keep(data.device, { seen: data.seen });
			break;
		case "press":
			{
				const pressed = Object.assign({}, root.pressed);
				pressed[data.control] = data.down;
				root.pressed = pressed;
			}
			break;
		case "key":
			{
				const keys = Object.assign({}, root.keys);
				if (data.down) keys[data.code] = true;
				else delete keys[data.code];
				root.keys = keys;
			}
			break;
		case "fired":
			root.fired(data.rule ?? "", data.control ?? "", data.trigger ?? "");
			break;
		case "focus":
			root.focusApp = data.app ?? "";
			break;
		case "batteryLog":
			root.batteryLog = data.log ?? [];
			break;
		case "action":
			Mouse.runShell(data.id, data.value);
			break;
		case "imported":
			root.adopt(data);
			break;
		case "state":
			root.daemonState = data;
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	property var daemonState: ({})

	function patch(id, values) {
		root.devices = root.devices.map(d => d.id === id || (!id && d.online) ? Object.assign({}, d, { state: Object.assign({}, d.state, values) }) : d);
	}

	// what the keyboard or a key changed itself: kept without sending back
	function keep(id, values) {
		if (!id) return;
		const devices = Object.assign({}, root.config.devices);
		devices[id] = Object.assign({}, devices[id] ?? {}, values);
		root.config = Object.assign({}, root.config, { devices });
		saving.restart();
	}

	function adopt(data) {
		const known = new Set(root.rules.map(r => `${r.control}/${r.trigger}/${r.app ?? ""}`));
		const rules = root.rules.concat((data.rules ?? []).filter(r => !known.has(`${r.control}/${r.trigger}/${r.app ?? ""}`)));
		root.config = Object.assign({}, root.config, { rules });
		root.commit();
		root.imported((data.rules ?? []).length, (data.skipped ?? []).length, data.restarted === true);
	}

	Timer {
		id: clearError

		interval: 6000
		onTriggered: root.error = ""
	}

	Connections {
		target: Niri
		enabled: daemon.running

		function onLine(text, event) {
			if (/^\{"Window/.test(text)) daemon.write(`{"op":"niri","event":${text}}\n`);
		}
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
			if (Niri.ready) for (const line of Niri.replay()) if (/^\{"Window/.test(line)) daemon.write(`{"op":"niri","event":${line}}\n`);
			if (root.watching) root.send({ op: "watch", on: true });
		}
		onExited: {
			root.devices = root.devices.map(d => Object.assign({}, d, { online: false }));
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}

	// ── what a key can do ─────────────────────────────────────────────────
	// the shell's and niri's are the mouse's (core/services/Mouse.qml)
	readonly property var shellActions: Mouse.shellActions.filter(a => a.group !== "Profiles")
	readonly property var niriActions: Mouse.niriActions
	readonly property var profiles: []

	readonly property var ownGroup: ({ id: "keyboard", label: "The keyboard", icon: "keyboard" })
	readonly property string ownKind: "keyboard"
	readonly property var ownActions: [
		{ id: "backlight-up", label: "Brighter keys", icon: "brightness_7" },
		{ id: "backlight-down", label: "Dimmer keys", icon: "brightness_5" },
		{ id: "backlight-toggle", label: "Key light on / off", icon: "lightbulb_outline" },
		{ id: "backlight-auto", label: "Key light auto / manual", icon: "brightness_auto" },
		{ id: "backlight-max", label: "Key light full", icon: "lightbulb_on" },
		{ id: "flash", label: "Flash the key light", icon: "flash" },
		{ id: "fn-swap", label: "Swap the Fn keys", icon: "keyboard_f1" }
	]

	// what a key does when no rule takes it
	function nativeLabel(control) {
		return root.keyInfo(control)?.label ?? "Its own";
	}

	function suggestions(control, trigger) {
		const s = {
			emoji: [{ kind: "shell", id: "clipboard" }, { kind: "shell", id: "launcher" }, { kind: "shell", id: "radial" }],
			screenshot: [{ kind: "shell", id: "shot-region" }, { kind: "shell", id: "shot-window" }, { kind: "shell", id: "ocr" }, { kind: "shell", id: "picker" }],
			lock: [{ kind: "shell", id: "lock" }, { kind: "shell", id: "power" }, { kind: "shell", id: "dnd" }],
			menu: [{ kind: "shell", id: "launcher" }, { kind: "niri", action: "toggle-overview" }, { kind: "shell", id: "radial" }],
			calculator: [{ kind: "shell", id: "launcher" }, { kind: "command", command: "gnome-calculator" }],
			dictation: [{ kind: "shell", id: "mic-mute" }, { kind: "shell", id: "notifications" }],
			"backlight-up": [{ kind: "keyboard", op: "backlight-up" }, { kind: "keyboard", op: "backlight-max" }],
			"backlight-down": [{ kind: "keyboard", op: "backlight-down" }, { kind: "keyboard", op: "backlight-toggle" }]
		};
		const fallback = [{ kind: "shell", id: "launcher" }, { kind: "niri", action: "toggle-overview" }, { kind: "shell", id: "play" }, { kind: "shell", id: "shot-region" }];
		return s[control] ?? fallback;
	}

	// the special keys: where they sit (F-row position from the keyboard, 0
	// for the ones beside it) and the evdev code they send on their own
	readonly property var keyList: [
		{ id: "brightness-down", label: "Screen darker", icon: "brightness_5", codes: [224] },
		{ id: "brightness-up", label: "Screen brighter", icon: "brightness_7", codes: [225] },
		{ id: "backlight-down", label: "Key light down", icon: "keyboard_close", codes: [229] },
		{ id: "backlight-up", label: "Key light up", icon: "keyboard", codes: [230] },
		{ id: "dictation", label: "Dictation", icon: "microphone", codes: [586, 582] },
		{ id: "emoji", label: "Emoji", icon: "emoticon_outline", codes: [585] },
		{ id: "mic-mute", label: "Microphone", icon: "microphone_off", codes: [248, 190] },
		{ id: "previous", label: "Previous track", icon: "skip_previous", codes: [165] },
		{ id: "play", label: "Play / pause", icon: "play_pause", codes: [164] },
		{ id: "next", label: "Next track", icon: "skip_next", codes: [163] },
		{ id: "mute", label: "Mute", icon: "volume_off", codes: [113] },
		{ id: "volume-down", label: "Volume down", icon: "volume_medium", codes: [114] },
		{ id: "volume-up", label: "Volume up", icon: "volume_high", codes: [115] },
		{ id: "screenshot", label: "Screenshot", icon: "selection_drag", codes: [99] },
		{ id: "menu", label: "Menu", icon: "menu", codes: [127] },
		{ id: "lock", label: "Lock", icon: "lock", codes: [152] },
		{ id: "calculator", label: "Calculator", icon: "calculator", codes: [140] }
	]

	function keyInfo(control) {
		return root.keyList.find(k => k.id === control) ?? null;
	}

	readonly property var waveforms: []

	// an action as words and a glyph
	function describe(action, control) {
		if (!action || action.kind === "default") return { label: root.nativeLabel(control), icon: "", plain: true };
		if (action.kind === "keyboard") {
			const a = root.ownActions.find(x => x.id === action.op);
			return { label: a?.label ?? action.op, icon: a?.icon ?? "keyboard" };
		}
		return Mouse.describe(action, control);
	}
}
