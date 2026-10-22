pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The SteelSeries Apex Pro TKL Gen 3 (`apex` plugin): actuation, Rapid Trigger,
// 2-in-1 action, what every key does, the onboard configs, the brightness and
// the OLED. scripts/apex/apex.py speaks to it; the keyboard keeps its settings
// itself (each change goes into its active config), the shell keeps only what
// needs a computer – in apex.json:
//
//   rules:   [{ id, control: "h<usage>", trigger, app, mods, action, on }]
//            a key bound to F13–F24 (usage 0x68–0x73) runs these
//   options: { oled, oledText, oledPicture, oledInvert, oledSeconds, oledDate,
//              oledNotify, oledNotifySeconds, holdMs, doubleMs, apps }
//   slot:    the config the keyboard runs here
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("apex")
	readonly property string script: `${Paths.scripts}/apex/apex.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false, configs: [] })
	readonly property bool online: root.device.online === true
	property bool scanned: false
	property bool running: daemon.running
	property string focusApp: ""
	property string error: ""
	// live, while the page watches: evdev code -> held; what the OLED shows (hex)
	property var keys: ({})
	property string screen: ""
	// ultra macros: id -> { name, options, length, keys, clicks, moves, words }
	property var macros: ({})
	property string macroState: "idle"
	property string macroId: ""
	// a probe for the pointer is out (its token), 0: none
	property int probing: 0
	signal fired(string rule, string control, string trigger)
	signal saved(int slot)

	readonly property var info: root.device.info ?? ({})
	readonly property int slot: root.device.slot ?? 0
	readonly property var analog: root.device.analog ?? []
	readonly property var bindable: root.device.bindable ?? []
	readonly property var bindings: root.device.bindings ?? ({})
	readonly property var keyState: root.device.keys ?? ({})
	readonly property var hidToEvdev: {
		const out = {};
		const map = root.device.evdevToHid ?? {};
		for (const code of Object.keys(map))
			if (!(map[code] in out)) out[map[code]] = Number(code);
		return out;
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ rules: [], options: {}, slot: 0 })
	property bool loaded: false
	readonly property var rules: root.config.rules ?? []
	readonly property var options: root.config.options ?? ({})

	property bool watching: false
	onWatchingChanged: {
		root.send({ op: "watch", on: root.watching });
		if (!root.watching) root.keys = {};
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

	// ── the keyboard ──────────────────────────────────────────────────────
	// keys: [hid], values: { act, second, release, sens, protect }
	function setKeys(keys, values) {
		if (!root.online || keys.length === 0) return;
		const state = Object.assign({}, root.keyState);
		for (const hid of keys)
			if (state[hid]) state[hid] = Object.assign({}, state[hid], values);
		root.device = Object.assign({}, root.device, { keys: state, dirty: true });
		root.send({ op: "keys", keys, values });
	}

	function setBrightness(level) {
		root.device = Object.assign({}, root.device, { brightness: level });
		root.send({ op: "brightness", level });
	}

	function switchSlot(slot) {
		root.send({ op: "slot", slot });
	}

	function rename(slot, name) {
		root.send({ op: "rename", slot, name });
	}

	function copySlot(from, to) {
		root.send({ op: "copy", from, to });
	}

	function restoreSlot(slot) {
		root.send({ op: "restore", slot });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	// ── what a key does ───────────────────────────────────────────────────
	// layer 0: on its own, 1: with the SteelSeries key, 2: pressed deeper.
	// What the keyboard can do by itself goes into it; the rest (per app,
	// double press, hold, the shell's actions) through an F13–F24 key that
	// the daemon answers.
	readonly property var hostUsages: [0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73]
	readonly property var triggerOf: ({ press: "click", double: "double", hold: "hold" })

	function blockOf(layer, hid) {
		return root.bindings[layer]?.[hid] ?? null;
	}

	function hostOf(layer, hid) {
		const block = root.blockOf(layer, hid);
		return block && block[0] === 0x51 && root.hostUsages.includes(block[1]) ? block[1] : 0;
	}

	// a binding as an action of the picker (null: what the key does by default)
	function actionOf(layer, hid) {
		const b = root.blockOf(layer, hid);
		if (!b) return null;
		const f = b[0];
		if (f === 0x51) {
			const usages = b.slice(1).filter(u => u !== 0);
			if (usages.length === 0) return layer === 0 ? { kind: "apex", op: "off" } : null;
			if (layer === 0 && usages.length === 1 && usages[0] === hid) return null;
			if (root.hostUsages.includes(usages[0])) return null;
			const codes = usages.map(u => root.hidToEvdev[u] ?? 0);
			return { kind: "keys", codes, keys: usages.map(u => root.hidName(u)), label: usages.map(u => root.hidName(u)).join(" + ") };
		}
		if (f === 0x00) return null;
		if (f === 0x61) {
			const usage = b[1] | (b[2] << 8);
			const name = Object.keys(root.consumer).find(k => root.consumer[k] === usage);
			return { kind: "apex", op: name ? `consumer:${name}` : `consumer:${usage}` };
		}
		if (f === 0x62) return { kind: "apex", op: `fw:${b[1].toString(16).padStart(2, "0")}.${b[2]}` };
		if (f >= 1 && f <= 5) return { kind: "button", button: ["", "left", "right", "middle", "back", "forward"][f] };
		if (f >= 0x31 && f <= 0x34) return { kind: "scroll", dir: ["up", "down", "left", "right"][f - 0x31] };
		if (f === 0x71) return { kind: "apex", op: "macro" };
		return { kind: "apex", op: `raw:${b.map(v => v.toString(16).padStart(2, "0")).join("")}` };
	}

	// can the keyboard do it by itself?
	function hardware(action) {
		if (!action || action.kind === "default") return true;
		switch (action.kind) {
		case "apex":
			return action.op === "off" || action.op.startsWith("fw:") || action.op.startsWith("consumer:");
		case "keys":
			if (action.latch || action.sustain) return false;
			{
				const map = root.device.evdevToHid ?? {};
				const codes = action.codes ?? [];
				return codes.length > 0 && codes.length <= 4 && codes.every(c => map[c] !== undefined);
			}
		case "button":
			return ["left", "right", "middle", "back", "forward"].includes(action.button ?? "middle");
		case "scroll":
			return Number(action.amount ?? 1) === 1;
		}
		return false;
	}

	function rulesOf(usage) {
		return root.rules.filter(r => r.control === `h${usage}`);
	}

	// control "k<hid>.<layer>", trigger press | double | hold: the picker's view
	function ruleFor(control, trigger, app) {
		const [hid, layer] = root.split(control);
		const usage = root.hostOf(layer, hid);
		if (usage) return root.rules.find(r => r.control === `h${usage}` && r.trigger === root.triggerOf[trigger] && (r.app ?? "") === (app ?? "")) ?? null;
		if (trigger !== "press" || (app ?? "") !== "") return null;
		const action = root.actionOf(layer, hid);
		return action ? { id: "", control, trigger, app: "", action } : null;
	}

	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function split(control) {
		const m = /^k(\d+)\.(\d)$/.exec(control ?? "");
		return m ? [Number(m[1]), Number(m[2])] : [0, 0];
	}

	function freeUsage() {
		const used = new Set((root.device.hostUsed ?? []).concat(root.rules.map(r => Number(String(r.control).slice(1)))));
		return root.hostUsages.find(u => !used.has(u)) ?? 0;
	}

	function newId() {
		return `a${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
	}

	function assign(control, trigger, app, action, extra) {
		const [hid, layer] = root.split(control);
		if (!hid) return;
		app = app ?? "";
		let usage = root.hostOf(layer, hid);
		const others = usage ? root.rulesOf(usage).filter(r => !(r.trigger === root.triggerOf[trigger] && (r.app ?? "") === app)) : [];
		if (!action) {
			const gone = usage ? root.rulesOf(usage).find(r => r.trigger === root.triggerOf[trigger] && (r.app ?? "") === app) : null;
			if ((gone?.action?.op ?? "").startsWith("ultra:")) {
				const rest = root.rulesOf(usage).filter(r => r.action?.op !== gone.action.op);
				root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.control !== `h${usage}` || r.action?.op !== gone.action.op) });
				root.commit();
				if (rest.length === 0) root.send({ op: "bind", layer, key: hid, action: { kind: "default" } });
				return;
			}
			if (!usage) {
				if (trigger === "press" && app === "") root.send({ op: "bind", layer, key: hid, action: { kind: "default" } });
				return;
			}
			// only a plain press left that the keyboard can do: back into the keyboard
			const back = others.length === 0 ? { kind: "default" } : (others.length === 1 && others[0].trigger === "click" && (others[0].app ?? "") === "" && root.hardware(others[0].action) ? others[0].action : null);
			root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.control !== `h${usage}` || (!back && !(r.trigger === root.triggerOf[trigger] && (r.app ?? "") === app))) });
			root.commit();
			if (back) root.send({ op: "bind", layer, key: hid, action: back });
			return;
		}
		// the keyboard alone
		if (trigger === "press" && app === "" && root.hardware(action) && others.length === 0) {
			if (usage) {
				root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.control !== `h${usage}`) });
				root.commit();
			}
			root.send({ op: "bind", layer, key: hid, action });
			return;
		}
		if (action.kind === "apex" && (action.op.startsWith("fw:") || action.op === "macro" || action.op.startsWith("raw:"))) {
			root.error = "Only as a plain press";
			clearError.restart();
			return;
		}
		// an ultra macro: tap plays, hold records – one rule each, one macro
		if (action.kind === "apex" && action.op === "ultra") {
			const same = usage ? root.rulesOf(usage).find(r => (r.action?.op ?? "").startsWith("ultra:") && (r.app ?? "") === app) : null;
			action = { kind: "apex", op: same?.action.op ?? `ultra:${root.newId()}` };
			trigger = "press";
		}
		// through the shell
		const rules = root.rules.slice();
		if (!usage) {
			usage = root.freeUsage();
			if (!usage) {
				root.error = "All twelve keys for the shell (F13–F24) are taken";
				clearError.restart();
				return;
			}
			// what it did so far stays its press
			const before = root.actionOf(layer, hid) ?? (layer === 0 ? { kind: "keys", codes: [root.hidToEvdev[hid] ?? 0], keys: [root.hidName(hid)], label: root.hidName(hid) } : null);
			if (before && !(trigger === "press" && app === "") && before.kind !== "apex")
				rules.push({ id: root.newId(), control: `h${usage}`, trigger: "click", app: "", mods: [], on: true, action: before });
			root.send({ op: "bind", layer, key: hid, host: usage });
		}
		const ultra = action.kind === "apex" && action.op.startsWith("ultra:");
		for (const t of ultra ? ["click", "hold"] : [root.triggerOf[trigger]]) {
			const old = rules.find(r => r.control === `h${usage}` && r.trigger === t && (r.app ?? "") === app);
			const rule = Object.assign({ id: old?.id ?? root.newId(), control: `h${usage}`, trigger: t, app, mods: [], on: true }, old ?? {}, extra ?? {}, { action });
			const at = rules.findIndex(r => r.id === rule.id);
			if (at >= 0) rules[at] = rule;
			else rules.push(rule);
		}
		root.config = Object.assign({}, root.config, { rules });
		root.commit();
	}

	function putRule(rule) {
		const rules = root.rules.slice();
		const at = rules.findIndex(r => r.id === rule.id);
		if (at >= 0) rules[at] = rule;
		else if (rule.id) rules.push(rule);
		root.config = Object.assign({}, root.config, { rules });
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

	function test(action) {
		if (action?.kind === "shell") Mouse.runShell(action.id, action.value);
		else root.send({ op: "test", action });
	}

	// ── ultra macros ──────────────────────────────────────────────────────
	function macro(id, what, values) {
		root.send({ op: "macro", id, do: what, values: values ?? {} });
	}

	function setMacro(id, values) {
		const macros = Object.assign({}, root.macros);
		if (macros[id]) macros[id] = Object.assign({}, macros[id], values.name !== undefined ? { name: values.name } : {}, { options: Object.assign({}, macros[id].options, values) });
		root.macros = macros;
		root.macro(id, "set", values);
	}

	function deleteMacro(id) {
		root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.action?.op !== `ultra:${id}`) });
		root.commit();
		root.macro(id, "delete");
	}

	// the keys an ultra macro is on
	function macroKeys(id) {
		const out = [];
		for (const layer of [0, 1, 2])
			for (const hid of Object.keys(root.bindings[layer] ?? {})) {
				const usage = root.hostOf(layer, Number(hid));
				if (usage && root.rulesOf(usage).some(r => r.action?.op === `ultra:${id}`)) out.push({ hid: Number(hid), layer, app: root.rulesOf(usage).find(r => r.action?.op === `ultra:${id}`)?.app ?? "" });
			}
		return out;
	}

	function probed(x, y) {
		if (!root.probing) return;
		const token = root.probing;
		root.probing = 0;
		root.send({ op: "probed", token, x, y });
	}

	// ── the OLED ──────────────────────────────────────────────────────────
	function storePicture(path, invert) {
		root.send({ op: "picture", path, invert: invert === true });
	}

	function clearStored() {
		root.send({ op: "picture", clear: true });
	}

	// a notification came (core/services/Notifs.qml)
	function notified(notification, critical) {
		if (!root.enabled || !root.online || root.option("oledNotify", "off") === "off") return;
		root.send({ op: "notify", app: notification.appName ?? "", summary: notification.summary ?? "", body: notification.body ?? "", critical });
	}

	Connections {
		target: root.enabled && root.option("oled", "own") === "media" ? Media : null

		function onTitleChanged() {
			mediaPush.restart();
		}
		function onPlayingChanged() {
			mediaPush.restart();
		}
		function onLengthChanged() {
			mediaPush.restart();
		}
	}

	Timer {
		id: mediaPush

		interval: 80
		onTriggered: root.send({ op: "media", title: Media.hasPlayer ? Media.title : "", artist: Media.artist, playing: Media.playing, position: Media.position, length: Media.length })
	}

	// the position drifts from the daemon's count after a seek
	Timer {
		interval: 5000
		repeat: true
		running: root.enabled && root.online && root.option("oled", "own") === "media" && Media.playing
		onTriggered: mediaPush.restart()
	}

	// ── the daemon ────────────────────────────────────────────────────────
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

		path: Paths.stateFile("apex.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = {
					rules: Array.isArray(data.rules) ? data.rules : [],
					options: data.options && typeof data.options === "object" ? data.options : {},
					slot: Number(data.slot ?? 0) || 0
				};
			} catch (error) {
				console.warn("Apex: apex.json is not valid JSON");
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
		case "slot":
			if (root.config.slot !== data.slot) {
				root.config = Object.assign({}, root.config, { slot: data.slot });
				saving.restart();
			}
			break;
		case "keyboard":
			root.onKeyboard(data);
			break;
		case "macros":
			root.macros = data.macros ?? {};
			break;
		case "macro":
			root.macroState = data.state ?? "idle";
			root.macroId = data.id ?? "";
			if (data.state === "recording") Osd.show("apex-macro", "Recording", 1, root.macros[data.id]?.name ?? "New macro", "record_rec");
			else if (data.state === "idle" && data.recorded) Osd.show("apex-macro", "Recorded", 1, root.macros[data.id]?.name ?? "", "check");
			break;
		case "probe":
			root.probing = data.token ?? 0;
			break;
		case "saved":
			root.saved(data.slot ?? 0);
			break;
		case "screen":
			root.screen = data.frame ?? "";
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
		case "action":
			Mouse.runShell(data.id, data.value);
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

	// what was changed on the keyboard itself
	function onKeyboard(data) {
		switch (data.kind) {
		case "brightness":
			Osd.show("apex", "Keyboard light", (data.level ?? 0) / 10, `${data.level}`, "keyboard");
			break;
		case "actuation":
			if (data.level) Osd.show("apex", "Actuation", data.level / 40, `${(data.level / 10).toFixed(1)} mm`, "keyboard");
			break;
		case "release":
			Osd.show("apex", "Rapid Trigger", data.mode === "off" ? 0 : 1, data.mode === "off" ? "Off" : "On", "flash");
			break;
		case "winlock":
			Osd.show("apex", "Windows key", data.on ? 0 : 1, data.on ? "Locked" : "Free", data.on ? "lock" : "lock_open_variant_outline");
			break;
		case "config":
			Osd.show("apex", "Keyboard config", ((data.slot ?? 0) + 1) / 5, root.device.configs?.[data.slot]?.name || `Config ${(data.slot ?? 0) + 1}`, "keyboard");
			break;
		}
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
			if (root.option("oled", "own") === "media") mediaPush.restart();
		}
		onExited: {
			root.device = { online: false, configs: [] };
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}

	// ── what a key can do (for the mouse's ActionPicker) ──────────────────
	readonly property var shellActions: Mouse.shellActions.filter(a => a.group !== "Profiles")
	readonly property var niriActions: Mouse.niriActions
	readonly property var profiles: []
	readonly property var waveforms: []
	readonly property var state: ({})

	readonly property var consumer: ({ play: 0xcd, next: 0xb5, previous: 0xb6, stop: 0xb7, mute: 0xe2, "volume-up": 0xe9, "volume-down": 0xea, calculator: 0x192, mail: 0x18a, browser: 0x196, files: 0x194 })

	readonly property var ownGroup: ({ id: "apex", label: "The keyboard", icon: "keyboard" })
	readonly property string ownKind: "apex"
	readonly property var ownActions: [
		{ id: "off", label: "Nothing", icon: "cancel" },
		{ id: "consumer:play", label: "Play / pause", icon: "play_pause" },
		{ id: "consumer:next", label: "Next track", icon: "skip_next" },
		{ id: "consumer:previous", label: "Previous track", icon: "skip_previous" },
		{ id: "consumer:stop", label: "Stop", icon: "stop" },
		{ id: "consumer:mute", label: "Mute", icon: "volume_off" },
		{ id: "consumer:volume-up", label: "Volume up", icon: "volume_high" },
		{ id: "consumer:volume-down", label: "Volume down", icon: "volume_medium" },
		{ id: "consumer:calculator", label: "Calculator", icon: "calculator" },
		{ id: "consumer:browser", label: "Browser", icon: "web" },
		{ id: "consumer:mail", label: "Mail", icon: "email_outline" },
		{ id: "consumer:files", label: "Files", icon: "folder_outline" },
		{ id: "fw:01.0", label: "Next config", icon: "account_switch_outline" },
		{ id: "fw:07.0", label: "Actuation deeper", icon: "arrow_collapse_down" },
		{ id: "fw:06.0", label: "Actuation higher", icon: "arrow_collapse_up" },
		{ id: "fw:08.0", label: "Rapid Trigger on / off", icon: "flash" },
		{ id: "fw:05.0", label: "Windows key lock", icon: "lock" },
		{ id: "fw:02.1", label: "Keyboard function 2", icon: "keyboard" },
		{ id: "fw:03.1", label: "Keys dimmer", icon: "brightness_5" },
		{ id: "fw:04.1", label: "Keys brighter", icon: "brightness_7" },
		{ id: "ultra", label: "Ultra macro", icon: "record_rec", detail: "Hold to record, tap to play" },
		{ id: "brightness-up", label: "Brighter keys", icon: "brightness_7" },
		{ id: "brightness-down", label: "Dimmer keys", icon: "brightness_5" },
		{ id: "config-previous", label: "Previous config", icon: "account_switch_outline" }
	]

	function nativeLabel(control) {
		const [hid, layer] = root.split(control);
		if (layer === 0) return root.hidName(hid);
		return "Nothing";
	}

	function suggestions(control, trigger) {
		const [hid, layer] = root.split(control);
		const out = [{ kind: "apex", op: "off" }, { kind: "shell", id: "launcher" }, { kind: "shell", id: "play" }, { kind: "shell", id: "shot-region" }, { kind: "niri", action: "toggle-overview" }];
		if (layer === 1) return [{ kind: "apex", op: "consumer:play" }, { kind: "apex", op: "fw:01.0" }, { kind: "apex", op: "fw:08.0" }].concat(out);
		return out;
	}

	function describe(action, control) {
		if (!action || action.kind === "default") return { label: root.nativeLabel(control), icon: "", plain: true };
		if (action.kind === "apex") {
			if (action.op === "macro") return { label: "Macro", icon: "record_rec" };
			if (action.op.startsWith("ultra:")) {
				const m = root.macros[action.op.slice(6)];
				return { label: m ? `${m.name} · ${(m.length / 1000).toFixed(1)} s` : "Ultra macro · hold to record", icon: "record_rec" };
			}
			const a = root.ownActions.find(x => x.id === action.op);
			return { label: a?.label ?? action.op, icon: a?.icon ?? "keyboard" };
		}
		return Mouse.describe(action, control);
	}

	// ── key names (the printed German ISO keys; usages beyond them by US name)
	readonly property var names: ({
		4: "A", 5: "B", 6: "C", 7: "D", 8: "E", 9: "F", 10: "G", 11: "H", 12: "I", 13: "J", 14: "K", 15: "L", 16: "M", 17: "N", 18: "O", 19: "P", 20: "Q", 21: "R", 22: "S", 23: "T", 24: "U", 25: "V", 26: "W", 27: "X", 28: "Z", 29: "Y",
		30: "1", 31: "2", 32: "3", 33: "4", 34: "5", 35: "6", 36: "7", 37: "8", 38: "9", 39: "0",
		40: "Enter", 41: "Esc", 42: "Backspace", 43: "Tab", 44: "Space", 45: "ß", 46: "´", 47: "Ü", 48: "+", 49: "\\", 50: "#", 51: "Ö", 52: "Ä", 53: "^", 54: ",", 55: ".", 56: "-", 57: "Caps Lock",
		58: "F1", 59: "F2", 60: "F3", 61: "F4", 62: "F5", 63: "F6", 64: "F7", 65: "F8", 66: "F9", 67: "F10", 68: "F11", 69: "F12", 70: "Print", 71: "Scroll Lock", 72: "Pause",
		73: "Insert", 74: "Home", 75: "Page Up", 76: "Delete", 77: "End", 78: "Page Down", 79: "Right", 80: "Left", 81: "Down", 82: "Up", 100: "<", 101: "Menu",
		104: "F13", 105: "F14", 106: "F15", 107: "F16", 108: "F17", 109: "F18", 110: "F19", 111: "F20", 112: "F21", 113: "F22", 114: "F23", 115: "F24",
		135: "Ro", 136: "Kana", 137: "Yen", 138: "Henkan", 139: "Muhenkan",
		224: "Ctrl", 225: "Shift", 226: "Alt", 227: "Super", 228: "Right Ctrl", 229: "Right Shift", 230: "AltGr", 231: "Right Super", 240: "SteelSeries"
	})

	function hidName(hid) {
		return root.names[hid] ?? `Key ${hid}`;
	}
}
