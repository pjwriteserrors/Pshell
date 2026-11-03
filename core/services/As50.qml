pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// The Avantree AS50 (`as50` plugin), a Bluetooth headset without a vendor
// channel: connection, battery, its own volume (AVRCP), the codec, the
// microphone (FastStream's back channel or HFP), latency, what its buttons
// do. scripts/as50/as50.py speaks to BlueZ, PipeWire and the buttons' input
// device; volume and the microphone's gain are set here on its nodes.
// as50.json:
//
//   rules:   [{ id, control: "play" | "next" | "previous" | "redial", trigger: "click", app, mods, action, on }]
//   options: { buttons, tap, music, latency: { port: ms }, output, takeOver,
//              takeOverEvery, volumeOsd, lowBattery, eq, apps, addresses }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("as50")
	readonly property string script: `${Paths.scripts}/as50/as50.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false, present: false })
	readonly property bool online: root.device.online === true
	readonly property bool present: root.device.present === true
	property bool scanned: false
	property string focusApp: ""
	property string error: ""
	// live, while the page watches: control -> held; the microphone in dBFS; HFP lines
	property var keys: ({})
	property real level: -90
	property real peak: -90
	property bool silent: false
	property var hfpLines: []
	property bool connecting: false
	signal fired(string rule, string control, string trigger)

	readonly property string address: root.device.address ?? ""
	readonly property string name: root.device.alias || root.device.name || "Avantree AS50"
	readonly property var battery: root.device.battery ?? root.device.hfp?.battery ?? null
	readonly property var transport: root.device.transport ?? null
	readonly property var pw: root.device.pipewire ?? ({})
	readonly property var audioProfiles: root.pw.profiles ?? []
	readonly property string profile: root.pw.profile ?? ""
	readonly property var ports: root.pw.ports ?? ({})
	// what the ActionPicker lists as "Profiles" (the mouse's): none here
	readonly property var profiles: []

	// the codec as the page names it
	readonly property var codecs: [
		{ profile: "a2dp-sink", label: "AAC", detail: "Best sound · ~200 ms late" },
		{ profile: "a2dp-sink-sbc_xq", label: "SBC-XQ", detail: "Near AAC · ~150 ms" },
		{ profile: "a2dp-sink-sbc", label: "SBC", detail: "Every device · ~150 ms" },
		{ profile: "a2dp-sink-faststream", label: "FastStream", detail: "Low latency for games and video · ~40 ms" }
	]
	readonly property var micModes: [
		{ profile: "", label: "Off", detail: "Music only" },
		{ profile: "a2dp-sink-faststream_duplex", label: "Mic + music", detail: "FastStream both ways: stereo sound stays, the mic in 16 kHz" },
		{ profile: "headset-head-unit", label: "Call", detail: "HFP: mono 8 kHz sound, the headset's call mode" }
	]
	readonly property bool micOn: root.profile === "a2dp-sink-faststream_duplex" || root.profile === "headset-head-unit"
	readonly property string musicProfile: root.option("music", "") || (root.micOn ? "a2dp-sink" : root.profile)

	// ── its PipeWire nodes ────────────────────────────────────────────────
	readonly property PwNode sink: root.online && root.pw.sink ? ((Pipewire.nodes?.values ?? []).find(n => n.name === root.pw.sink) ?? null) : null
	readonly property PwNode source: root.online && root.pw.source ? ((Pipewire.nodes?.values ?? []).find(n => n.name === root.pw.source) ?? null) : null

	PwObjectTracker {
		objects: [root.sink, root.source].filter(n => n)
	}

	readonly property real volume: root.sink?.audio?.volume ?? 0
	readonly property bool muted: !!root.sink?.audio?.muted
	readonly property real micVolume: root.source?.audio?.volume ?? 0
	readonly property bool micMuted: !!root.source?.audio?.muted
	readonly property bool isOutput: !!root.sink && Pipewire.defaultAudioSink === root.sink
	readonly property bool isInput: !!root.source && Pipewire.defaultAudioSource === root.source
	// the headset's own volume, 0–127; its buttons move it in 16 steps
	readonly property var raw: root.transport?.volume ?? null

	function setVolume(value) {
		if (!root.sink?.audio) return;
		root.sink.audio.muted = false;
		root.sink.audio.volume = Math.max(0, Math.min(1, value));
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
		if (root.pw.sourceId !== undefined) Quickshell.execDetached(["wpctl", "set-default", String(root.pw.sourceId)]);
	}

	// ── the headset ────────────────────────────────────────────────────────
	function connect() {
		root.connecting = true;
		connectingOff.restart();
		root.send({ op: "connect" });
	}

	function disconnect() {
		root.send({ op: "disconnect" });
	}

	Timer {
		id: connectingOff

		interval: 30000
		onTriggered: root.connecting = false
	}

	onOnlineChanged: root.connecting = false

	function setProfile(name) {
		root.device = Object.assign({}, root.device, { pipewire: Object.assign({}, root.pw, { profile: name }) });
		root.send({ op: "profile", name });
	}

	// the codec for music: kept, and put on again each time it connects
	function setMusic(profile) {
		root.setOption("music", profile);
		if (!root.micOn) root.setProfile(profile);
	}

	function setMic(profile) {
		root.setProfile(profile || root.musicProfile || "a2dp-sink");
	}

	function setRaw(value) {
		root.send({ op: "volume", raw: Math.round(value) });
	}

	function rename(text) {
		root.send({ op: "alias", name: text.trim() });
	}

	function setTrusted(on) {
		root.send({ op: "trusted", on });
	}

	function latencyOf(port) {
		return Math.round((root.ports[port]?.latency ?? 0) / 1000);
	}

	function setLatency(port, ms) {
		const latency = Object.assign({}, root.option("latency", {}));
		latency[port] = ms;
		root.setOption("latency", latency);
		root.send({ op: "latency", port, ms });
	}

	function refresh() {
		root.send({ op: "refresh" });
		autoswitchRead.running = true;
	}

	// WirePlumber's own switch to call mode while an app records: one for
	// every Bluetooth headset, kept in its settings
	property var autoswitch: null

	function setAutoswitch(on) {
		root.autoswitch = on;
		Quickshell.execDetached(["wpctl", "settings", "--save", "bluetooth.autoswitch-to-headset-profile", on ? "true" : "false"]);
	}

	Process {
		id: autoswitchRead

		running: root.enabled
		command: ["wpctl", "settings", "bluetooth.autoswitch-to-headset-profile"]
		stdout: StdioCollector {
			onStreamFinished: {
				const m = /Value:\s*(true|false)/.exec(text);
				root.autoswitch = m ? m[1] === "true" : null;
			}
		}
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ rules: [], options: {} })
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

	// ── what a button does ────────────────────────────────────────────────
	readonly property var controlNames: ({ play: "⏯ press", next: "+ held", previous: "− held", redial: "⏯ pressed twice" })
	readonly property var nativeNames: ({ play: "Play / pause", next: "Next track", previous: "Previous track", redial: "Nothing" })

	function ruleFor(control, trigger, app) {
		return root.rules.find(r => r.control === control && r.trigger === "click" && (r.app ?? "") === (app ?? "")) ?? null;
	}

	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function newId() {
		return `a${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
	}

	function assign(control, trigger, app, action, extra) {
		app = app ?? "";
		const rest = root.rules.filter(r => !(r.control === control && r.trigger === "click" && (r.app ?? "") === app));
		if (action && !(action.kind === "default" && app === "")) {
			const old = root.ruleFor(control, "click", app);
			rest.push(Object.assign({ id: old?.id ?? root.newId(), control, trigger: "click", app, mods: [], on: true }, old ?? {}, extra ?? {}, { action }));
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
		else if (action?.kind === "as50") root.ownOp(action.op);
		else root.send({ op: "test", action });
	}

	// the page's own actions, when a button or the shell runs them
	function ownOp(op) {
		switch (op) {
		case "mic":
			root.setMic(root.micOn ? "" : root.option("micMode", "a2dp-sink-faststream_duplex"));
			Osd.show("as50-mic", "Microphone", root.micOn ? 0 : 1, root.micOn ? "Off" : "On", root.micOn ? "microphone_off" : "microphone");
			break;
		case "mic-mute":
			root.setMicMuted(!root.micMuted);
			Osd.show("as50-mic", "Microphone", root.micMuted ? 0 : 1, root.micMuted ? "Muted" : "On", root.micMuted ? "microphone_off" : "microphone");
			break;
		case "mute":
			root.setMuted(!root.muted);
			Osd.show("as50", root.name, root.muted ? 0 : root.volume, root.muted ? "Muted" : `${Math.round(root.volume * 100)} %`, root.muted ? "volume_off" : "headphones");
			break;
		case "codec":
			{
				const at = root.codecs.findIndex(c => c.profile === root.profile);
				const next = root.codecs[(at + 1) % root.codecs.length];
				root.setMusic(next.profile);
				Osd.show("as50", root.name, 1, next.label, "headphones");
			}
			break;
		case "output":
			root.useAsOutput();
			break;
		case "battery":
			Osd.show("as50", root.name, (root.battery ?? 0) / 100, root.battery === null ? "Battery not known" : `Battery ${root.battery} %`, "battery");
			break;
		case "disconnect":
			root.disconnect();
			break;
		}
	}

	// ── what a button can do (for the mouse's ActionPicker) ──────────────
	readonly property var shellActions: Mouse.shellActions.filter(a => a.group !== "Profiles")
	readonly property var niriActions: Mouse.niriActions
	readonly property var state: ({})
	readonly property var ownGroup: ({ id: "as50", label: "The headset", icon: "headphones" })
	readonly property string ownKind: "as50"
	readonly property var ownActions: [
		{ id: "mic", label: "Microphone on / off", icon: "microphone" },
		{ id: "mic-mute", label: "Mute the microphone", icon: "microphone_off" },
		{ id: "mute", label: "Mute the headset", icon: "volume_off" },
		{ id: "codec", label: "Next codec", icon: "tune_vertical" },
		{ id: "output", label: "Use the headset", icon: "headphones" },
		{ id: "battery", label: "Show the battery", icon: "battery" },
		{ id: "disconnect", label: "Disconnect", icon: "bluetooth_off" }
	]

	function nativeLabel(control) {
		return root.nativeNames[control] ?? control;
	}

	function suggestions(control, trigger) {
		return [
			{ kind: "shell", id: "play" }, { kind: "shell", id: "next" }, { kind: "shell", id: "previous" },
			{ kind: "as50", op: "mic-mute" }, { kind: "as50", op: "mic" }, { kind: "niri", action: "toggle-overview" }
		];
	}

	function describe(action, control) {
		if (!action || action.kind === "default") return { label: root.nativeLabel(control), icon: "", plain: true };
		if (action.kind === "as50") {
			const a = root.ownActions.find(x => x.id === action.op);
			return { label: a?.label ?? action.op, icon: a?.icon ?? "headphones" };
		}
		return Mouse.describe(action, control);
	}

	// ── the battery, told once when it runs low ──────────────────────────
	property var lastBattery: null

	onBatteryChanged: {
		const was = root.lastBattery;
		root.lastBattery = root.battery;
		const low = root.option("lowBattery", 20);
		if (root.battery === null || was === null || low <= 0) return;
		if (root.battery <= low && was > low)
			Notifs.post({ app: root.name, summary: `${root.name}: battery ${root.battery} %`, body: "About " + Math.max(1, Math.round(root.battery / 100 * 35)) + " h left. It charges on the dock or over USB-C.", icon: "audio-headset" });
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

		path: Paths.stateFile("as50.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = {
					rules: Array.isArray(data.rules) ? data.rules : [],
					options: data.options && typeof data.options === "object" ? data.options : {}
				};
			} catch (error) {
				console.warn("As50: as50.json is not valid JSON");
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
		case "volume":
			if (data.by === "headset" && root.option("volumeOsd", true) && !root.watching)
				Osd.show("as50", root.name, data.raw / 127, `${Math.round(data.raw / 127 * 16)} / 16`, "headphones");
			root.device = Object.assign({}, root.device, { transport: Object.assign({}, root.transport ?? {}, { volume: data.raw }) });
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
			root.silent = data.silent === true;
			break;
		case "hfp":
			root.hfpLines = root.hfpLines.concat([{ line: data.line ?? "", at: Date.now() }]).slice(-8);
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
		case "as50":
			root.ownOp(data.op ?? "");
			break;
		case "state":
			root.daemonState = data;
			break;
		case "error":
			root.error = data.message ?? "";
			root.connecting = false;
			clearError.restart();
			break;
		}
	}

	property var daemonState: ({})

	Timer {
		id: clearError

		interval: 8000
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
			root.device = { online: false, present: false };
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
