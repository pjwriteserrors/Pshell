pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// The Sennheiser PC 8.2 USB (`headset` plugin): sidetone, volume and balance,
// the microphone, the audio profile and what its two buttons do.
// scripts/headset/headset.py speaks to it (ALSA's mixer for the sidetone,
// evdev for the buttons, a tap on the microphone); volume, balance and the
// microphone's gain are PipeWire's and set here on its nodes. headset.json:
//
//   rules:   [{ id, control: "up" | "down", trigger, app, mods, action, on }]
//   options: { cableNotice, apps }
//   devices: { <serial>: { sidetone, sidetoneOn } }   written again each time
//            the headset comes – it forgets them without power
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("headset")
	readonly property string script: `${Paths.scripts}/headset/headset.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false })
	readonly property bool online: root.device.online === true
	property bool scanned: false
	property string focusApp: ""
	property string error: ""
	property var mixer: ({})
	// live, while the page watches: "up" | "down" -> held; the microphone in dBFS
	property var keys: ({})
	property real level: -90
	property real peak: -90
	// the switch on the cable: true muted, false live, null not known (nothing listens)
	property var cable: null
	signal fired(string rule, string control, string trigger)

	readonly property string serial: root.device.serial ?? ""
	readonly property var scales: root.device.scales ?? ({})
	readonly property var own: root.device.own ?? ({ sidetone: 18, sidetoneOn: true })
	readonly property var pw: root.device.pipewire ?? ({})
	readonly property var profiles: root.pw.profiles ?? []
	readonly property string profile: root.pw.profile ?? ""
	readonly property bool access: root.device.access === true

	// ── its PipeWire nodes ────────────────────────────────────────────────
	readonly property PwNode sink: root.online && root.pw.sink ? ((Pipewire.nodes?.values ?? []).find(n => n.name === root.pw.sink) ?? null) : null
	readonly property PwNode source: root.online && root.pw.source ? ((Pipewire.nodes?.values ?? []).find(n => n.name === root.pw.source) ?? null) : null

	PwObjectTracker {
		objects: [root.sink, root.source].filter(n => n)
	}

	readonly property var volumes: root.sink?.audio?.volumes ?? []
	readonly property real volume: {
		let v = -1;
		for (let i = 0; i < root.volumes.length; i++) v = Math.max(v, root.volumes[i]);
		return v >= 0 ? v : (root.sink?.audio?.volume ?? 0);
	}
	// −1 all left … 1 all right
	readonly property real balance: {
		const v = root.volumes;
		if (v.length < 2 || Math.max(v[0], v[1]) <= 0) return 0;
		return v[1] < v[0] ? -(1 - v[1] / v[0]) : (1 - v[0] / v[1]);
	}
	readonly property bool muted: !!root.sink?.audio?.muted
	readonly property real micVolume: root.source?.audio?.volume ?? 0
	readonly property bool micMuted: !!root.source?.audio?.muted
	readonly property bool isOutput: !!root.sink && Pipewire.defaultAudioSink === root.sink
	readonly property bool isInput: !!root.source && Pipewire.defaultAudioSource === root.source
	// muted on the cable – only known while something listens, and not while PipeWire mutes it itself
	readonly property bool cableMuted: root.cable === true && !root.micMuted && root.micVolume > 0

	function setVolume(value) {
		if (!root.sink?.audio) return;
		const v = Math.max(0, Math.min(1, value));
		root.sink.audio.muted = false;
		root.setChannels(v, root.balance);
	}

	function setBalance(value) {
		root.setChannels(root.volume, Math.max(-1, Math.min(1, value)));
	}

	function setChannels(v, b) {
		if (!root.sink?.audio) return;
		if (root.volumes.length < 2) {
			root.sink.audio.volume = v;
			return;
		}
		root.sink.audio.volumes = [v * Math.min(1, 1 - b), v * Math.min(1, 1 + b)];
	}

	function setMuted(on) {
		if (root.sink?.audio) root.sink.audio.muted = on;
	}

	function setMicVolume(value) {
		if (root.source?.audio) root.source.audio.volume = Math.max(0, Math.min(1, value));
	}

	function setMicMuted(on) {
		if (root.source?.audio) root.source.audio.muted = on;
	}

	function useAsOutput() {
		if (root.pw.sink) Quickshell.execDetached(["pactl", "set-default-sink", root.pw.sink]);
	}

	function useAsInput() {
		if (root.pw.source) Quickshell.execDetached(["pactl", "set-default-source", root.pw.source]);
	}

	// ── the headset ────────────────────────────────────────────────────────
	readonly property int sidetone: root.mixer.sidetone ?? 18
	readonly property bool sidetoneOn: root.mixer.sidetoneOn !== false

	function sidetoneDb(step) {
		const s = root.scales.sidetone ?? [0, 30, -57, -12];
		if (s[2] === null || s[1] === s[0]) return null;
		return s[2] + (step - s[0]) * (s[3] - s[2]) / (s[1] - s[0]);
	}

	function setSidetone(level) {
		root.mixer = Object.assign({}, root.mixer, { sidetone: level, sidetoneOn: true });
		root.send({ op: "sidetone", level, on: true });
	}

	function setSidetoneOn(on) {
		root.mixer = Object.assign({}, root.mixer, { sidetoneOn: on });
		root.send({ op: "sidetone", on });
	}

	function resetSidetone() {
		root.send({ op: "sidetone", level: root.own.sidetone, on: root.own.sidetoneOn });
	}

	function setProfile(name) {
		root.device = Object.assign({}, root.device, { pipewire: Object.assign({}, root.pw, { profile: name }) });
		root.send({ op: "profile", name });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	function allowAccess() {
		accessProc.running = true;
	}

	Process {
		id: accessProc

		command: ["pkexec", "bash", `${Paths.scripts}/headset/setup-access.sh`]
		onExited: code => {
			if (code !== 0) {
				root.error = "No access";
				clearError.restart();
			}
			// the daemon opens the buttons again when it finds the headset anew
			daemon.running = false;
		}
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ rules: [], options: {}, devices: {} })
	property bool loaded: false
	readonly property var rules: root.config.rules ?? []
	readonly property var options: root.config.options ?? ({})

	property bool watching: false
	onWatchingChanged: {
		root.send({ op: "watch", on: root.watching });
		if (!root.watching) {
			root.keys = {};
			root.level = -90;
			root.peak = -90;
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

	// the sidetone as it is now goes with this headset
	function remember(data) {
		if (!data.serial || data.sidetone === undefined) return;
		const devices = Object.assign({}, root.config.devices ?? {});
		const was = devices[data.serial] ?? {};
		if (was.sidetone === data.sidetone && was.sidetoneOn === data.sidetoneOn) return;
		devices[data.serial] = Object.assign({}, was, { sidetone: data.sidetone, sidetoneOn: data.sidetoneOn });
		root.config = Object.assign({}, root.config, { devices });
		saving.restart();
	}

	// ── what a button does ────────────────────────────────────────────────
	// control "up" | "down"; the page's trigger press | double | hold
	readonly property var triggerOf: ({ press: "click", double: "double", hold: "hold" })
	readonly property var controlNames: ({ up: "Volume up", down: "Volume down" })

	function ruleFor(control, trigger, app) {
		const t = root.triggerOf[trigger] ?? trigger;
		return root.rules.find(r => r.control === control && r.trigger === t && (r.app ?? "") === (app ?? "")) ?? null;
	}

	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function newId() {
		return `h${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
	}

	function assign(control, trigger, app, action, extra) {
		const t = root.triggerOf[trigger] ?? trigger;
		app = app ?? "";
		const rest = root.rules.filter(r => !(r.control === control && r.trigger === t && (r.app ?? "") === app));
		if (action && !(action.kind === "default" && t === "click" && app === "")) {
			const old = root.ruleFor(control, trigger, app);
			rest.push(Object.assign({ id: old?.id ?? root.newId(), control, trigger: t, app, mods: [], on: true }, old ?? {}, extra ?? {}, { action }));
		}
		root.config = Object.assign({}, root.config, { rules: rest });
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
		else if (action?.kind === "headset") root.headsetOp(action.op);
		else root.send({ op: "test", action });
	}

	// the headset's actions that are PipeWire's
	function headsetOp(op) {
		switch (op) {
		case "mic-mute":
			root.setMicMuted(!root.micMuted);
			Osd.show("headset-mic", "Microphone", root.micMuted ? 0 : 1, root.micMuted ? "Muted" : "On", root.micMuted ? "microphone_off" : "microphone");
			break;
		case "mute":
			root.setMuted(!root.muted);
			Osd.show("headset", "Headset", root.muted ? 0 : root.volume, root.muted ? "Muted" : `${Math.round(root.volume * 100)} %`, root.muted ? "volume_off" : "headphones");
			break;
		case "output":
			root.useAsOutput();
			root.useAsInput();
			break;
		case "volume-up":
		case "volume-down":
		case "sidetone":
		case "sidetone-up":
		case "sidetone-down":
			root.send({ op: "test", action: { kind: "headset", op } });
			break;
		}
	}

	// ── what a button can do (for the mouse's ActionPicker) ──────────────
	readonly property var shellActions: Mouse.shellActions.filter(a => a.group !== "Profiles")
	readonly property var niriActions: Mouse.niriActions
	readonly property var state: ({})
	readonly property var ownGroup: ({ id: "headset", label: "The headset", icon: "headset" })
	readonly property string ownKind: "headset"
	readonly property var ownActions: [
		{ id: "volume-up", label: "Volume up", icon: "volume_high" },
		{ id: "volume-down", label: "Volume down", icon: "volume_medium" },
		{ id: "mute", label: "Mute the headset", icon: "volume_off" },
		{ id: "mic-mute", label: "Mute the microphone", icon: "microphone_off" },
		{ id: "sidetone", label: "Sidetone on / off", icon: "account_voice" },
		{ id: "sidetone-up", label: "Sidetone louder", icon: "account_voice" },
		{ id: "sidetone-down", label: "Sidetone quieter", icon: "account_voice" },
		{ id: "output", label: "Use the headset", icon: "headset" }
	]

	function nativeLabel(control) {
		return root.controlNames[control] ?? control;
	}

	function suggestions(control, trigger) {
		return [
			{ kind: "headset", op: "mic-mute" }, { kind: "headset", op: "sidetone" }, { kind: "shell", id: "play" },
			{ kind: "shell", id: "next" }, { kind: "headset", op: control === "up" ? "volume-up" : "volume-down" }, { kind: "niri", action: "toggle-overview" }
		];
	}

	function describe(action, control) {
		if (!action || action.kind === "default") return { label: root.nativeLabel(control), icon: "", plain: true };
		if (action.kind === "headset") {
			const a = root.ownActions.find(x => x.id === action.op);
			return { label: a?.label ?? action.op, icon: a?.icon ?? "headset" };
		}
		return Mouse.describe(action, control);
	}

	// ── the cable's switch, told while another program records ───────────
	readonly property bool recording: root.enabled && root.online && root.option("cableNotice", true) && !!root.pw.source
		&& (Pipewire.linkGroups?.values ?? []).some(g => !!g.source && g.source.name === root.pw.source && root.foreignStream(g.target))

	function foreignStream(node) {
		return !!node && node.isStream && !/^(python|quickshell|qs$|gst|cava|wf-recorder|pw-record|pw-cat)/i.test(String(node.name || ""));
	}

	onRecordingChanged: root.send({ op: "listen", on: root.recording })

	function onCable(muted) {
		const was = root.cable;
		root.cable = muted;
		if (muted === null || was === null || muted === was || !root.recording || root.watching) return;
		if (root.micMuted) return;
		Osd.show("headset-mic", "Microphone", muted ? 0 : 1, muted ? "Muted on the cable" : "On", muted ? "microphone_off" : "microphone");
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

		path: Paths.stateFile("headset.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = {
					rules: Array.isArray(data.rules) ? data.rules : [],
					options: data.options && typeof data.options === "object" ? data.options : {},
					devices: data.devices && typeof data.devices === "object" ? data.devices : {}
				};
			} catch (error) {
				console.warn("Headset: headset.json is not valid JSON");
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
			root.mixer = data.mixer ?? {};
			if (!data.online) root.cable = null;
			else if (data.cable !== undefined) root.cable = data.cable;
			break;
		case "mixer":
			{
				const before = root.mixer;
				root.mixer = data;
				if (root.online) root.remember(data);
				if (data.by === "action") {
					if (data.sidetoneOn !== before.sidetoneOn && data.sidetone === before.sidetone)
						Osd.show("headset", "Sidetone", data.sidetoneOn ? 1 : 0, data.sidetoneOn ? "On" : "Off", "account_voice");
					else
						Osd.show("headset", "Sidetone", data.sidetone / 30, `${Math.round(root.sidetoneDb(data.sidetone))} dB`, "account_voice");
				}
			}
			break;
		case "key":
			{
				const keys = Object.assign({}, root.keys);
				if (data.down) keys[data.control] = true;
				else delete keys[data.control];
				root.keys = keys;
			}
			break;
		case "level":
			root.level = data.db ?? -90;
			root.peak = data.peak ?? -90;
			break;
		case "cable":
			root.onCable(data.muted ?? null);
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
		case "headset":
			root.headsetOp(data.op ?? "");
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
			if (root.recording) root.send({ op: "listen", on: true });
		}
		onExited: {
			root.device = { online: false };
			root.cable = null;
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
