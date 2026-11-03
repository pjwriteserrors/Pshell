pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// An Amazfit watch on Zepp OS (`amazfit` plugin), made on the Active 2 NFC
// Square: what it offers over plain GATT (battery, device information, its
// clock, heart rate, its HID keys and the report the report map leaves out)
// and, with the auth key it was paired with, everything over Zepp OS – every
// setting, alarms, faces, apps, menus, reminders, the calendar, canned
// replies, notifications from the PC, music, find, weather, world clocks.
// scripts/amazfit/amazfit.py speaks to it; amazfit.json (state dir, 0600):
//
//   rules:   [{ id, control, trigger: "click", app, mods, action, on }]
//   options: { key, address, autoConnect, syncTime, buttons, liveHr, notify,
//              notifyDnd, music, weather, worldClocks, canned, user, apps,
//              lowBattery, findSound, dndSync }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("amazfit")
	readonly property string script: `${Paths.scripts}/amazfit/amazfit.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false, present: false })
	readonly property bool online: root.device.online === true
	readonly property bool present: root.device.present === true
	property bool scanned: false
	readonly property string name: root.device.name || "Amazfit watch"
	readonly property var battery: root.zepp.battery?.level ?? root.device.battery ?? null
	readonly property bool charging: root.zepp.battery?.charging === true
	readonly property var info: root.device.info ?? ({})
	readonly property var clock: root.device.clock ?? null
	readonly property string zeppState: root.device.zepp?.state ?? "idle"
	readonly property bool zeppReady: root.zeppState === "ready"
	readonly property bool keySet: root.device.zepp?.keySet === true
	property int hr: 0
	property real hrAt: 0
	property var keys: ({})
	property string hidden: ""
	property string focusApp: ""
	property string error: ""
	property bool connecting: false
	// over Zepp OS: config, battery, info, alarms, faces, face, apps, canned,
	// reminders, calendar, menus, caps, services, steps, musicOpen
	property var zepp: ({})
	signal fired(string rule, string control, string trigger)
	signal acked(string what, bool ok)

	// the catalogue of settings, shared with the phone app
	property var catalog: ({ groups: {}, args: [], menu: {}, shortcuts: {}, control: {}, faces: {}, languages: {}, vibrations: {} })

	FileView {
		path: `${Paths.scripts}/amazfit/zepp/catalog.json`
		blockLoading: true
		onLoaded: {
			try {
				root.catalog = JSON.parse(text());
			} catch (error) {
				console.warn("Amazfit: catalog.json is not valid JSON");
			}
		}
	}

	function argOf(groupName, code) {
		return root.catalog.args.find(a => a.group === groupName && a.code === code) ?? null;
	}

	function groupId(groupName) {
		return root.catalog.groups[groupName]?.id ?? -1;
	}

	// a setting as the watch reported it: { code, type, value, min, max, allowed, maxLength, key }
	function setting(groupName, key) {
		const g = root.zepp.config?.[groupName];
		if (!g) return null;
		for (const code in g.args)
			if (g.args[code].key === key) return g.args[code];
		return null;
	}

	function settingValue(groupName, key, fallback) {
		return root.setting(groupName, key)?.value ?? fallback;
	}

	function setSetting(groupName, code, value) {
		const config = Object.assign({}, root.zepp.config ?? {});
		const g = config[groupName];
		if (g?.args?.[String(code)]) {
			const args = Object.assign({}, g.args);
			args[String(code)] = Object.assign({}, args[String(code)], { value });
			config[groupName] = Object.assign({}, g, { args });
			root.zepp = Object.assign({}, root.zepp, { config });
		}
		root.call("set_config", { group: root.groupId(groupName), items: [[code, value]] });
	}

	// a menu item's name: the catalogue's, else its id
	function itemName(kind, id) {
		const table = kind === "shortcuts" ? root.catalog.shortcuts : (kind === "control" ? root.catalog.control : root.catalog.menu);
		const name = table?.[id] ?? root.catalog.menu?.[id] ?? "";
		return name ? name.replace(/_/g, " ").replace(/^./, c => c.toUpperCase()) : id;
	}

	// what the watch measured: fetched after it connects and every 30 min
	property bool fetching: false
	property real healthAt: 0
	property string imported: ""

	function fetchHealth() {
		root.send({ op: "fetch" });
	}

	function importGadgetbridge(path) {
		root.send({ op: "import", path: String(path).replace(/^file:\/\//, "").replace(/^~/, Quickshell.env("HOME")) });
	}

	// telling hidden settings apart: remember, change one on the watch, compare
	property string comparing: ""   // "", "waiting", "ready", "done"
	property var changes: []

	function remember() {
		root.comparing = "waiting";
		root.changes = [];
		root.send({ op: "snapshot" });
	}

	function compare() {
		root.comparing = "waiting";
		root.send({ op: "compare" });
	}

	// a name the user gave a hidden setting ("gg/cc" → text)
	function nameOf(groupName, code) {
		const id = `${Number(root.groupId(groupName)).toString(16).padStart(2, "0")}/${Number(code).toString(16).padStart(2, "0")}`;
		return root.option("names", {})[id] ?? "";
	}

	function setName(id, text) {
		const names = Object.assign({}, root.option("names", {}));
		if (text.trim()) names[id] = text.trim();
		else delete names[id];
		root.setOption("names", names);
	}

	function call(name, args) {
		root.send({ op: "zepp", call: name, args: args ?? {} });
	}

	// ── the watch ──────────────────────────────────────────────────────────
	function connect() {
		root.connecting = true;
		connectingOff.restart();
		root.send({ op: "connect" });
	}

	function disconnect() {
		root.send({ op: "disconnect" });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	function syncTime() {
		root.send({ op: "time" });
	}

	function findWatch(on) {
		root.send({ op: "find", on });
	}

	function liveHr(on) {
		root.send({ op: "hr", on });
	}

	function press(control) {
		root.send({ op: "press", control });
	}

	function setKey(text) {
		const hex = String(text ?? "").trim().replace(/^0x/i, "").toLowerCase();
		root.setOption("key", hex);
	}

	Timer {
		id: connectingOff

		interval: 30000
		onTriggered: root.connecting = false
	}

	onOnlineChanged: root.connecting = false

	// ── notifications from the PC (Notifs calls this) ──────────────────────
	property var forwarded: ({})

	function notified(notification) {
		if (!root.enabled || !root.zeppReady || !root.option("notify", true)) return;
		if (root.option("notifyDnd", true) && Notifs.dnd && notification.urgency !== NotificationUrgency.Critical) return;
		const muted = root.option("notifyMuted", []);
		if (muted.includes(String(notification.appName))) return;
		const id = Math.abs(Number(notification.id)) % 2147483647;
		const map = Object.assign({}, root.forwarded);
		map[id] = notification;
		root.forwarded = map;
		root.send({
			op: "notify",
			id,
			title: String(notification.summary || notification.appName || ""),
			body: String(notification.body || "").replace(/<[^>]+>/g, ""),
			app: String(notification.desktopEntry || notification.appName || "dev.pshell"),
			source: String(notification.appName || "Pshell"),
			reply: notification.hasInlineReply === true
		});
		notification.closed.connect(() => {
			if (root.forwarded[id]) {
				const m = Object.assign({}, root.forwarded);
				delete m[id];
				root.forwarded = m;
				root.send({ op: "unnotify", id });
			}
		});
	}

	function onWatchEvent(data) {
		switch (data.type) {
		case "dismiss":
			{
				const n = root.forwarded[data.id];
				if (n) {
					const m = Object.assign({}, root.forwarded);
					delete m[data.id];
					root.forwarded = m;
					n.dismiss();
				}
			}
			break;
		case "reply":
			{
				const n = root.forwarded[data.id];
				if (n?.hasInlineReply) n.sendInlineReply(data.text ?? "");
			}
			break;
		case "sleep":
			root.asleep = data.asleep === true;
			break;
		}
	}

	property bool asleep: false

	// ── music: what plays, while the watch's music app is open ────────────
	readonly property bool musicOpen: root.zepp.musicOpen === true

	function pushMusic() {
		if (!root.musicOpen || !root.option("music", true)) return;
		root.send({
			op: "music",
			state: Media.playing ? "playing" : "paused",
			artist: Media.artist,
			track: Media.hasPlayer ? (Media.player.trackTitle || Media.title) : "",
			album: Media.player?.trackAlbum ?? "",
			position: Math.round(Media.position),
			duration: Math.round(Media.length),
			volume: Math.round((Audio.volume ?? 0) * 100)
		});
	}

	onMusicOpenChanged: root.pushMusic()

	Connections {
		target: Media
		enabled: root.musicOpen

		function onTitleChanged() {
			musicPush.restart();
		}
		function onPlayingChanged() {
			musicPush.restart();
		}
		function onArtistChanged() {
			musicPush.restart();
		}
	}

	Timer {
		id: musicPush

		interval: 150
		onTriggered: root.pushMusic()
	}

	// ── the watch looks for the PC ────────────────────────────────────────
	property bool finding: false
	property var findNote: null

	function startFinding() {
		if (root.finding) return;
		root.finding = true;
		findCount.count = 0;
		findRing.restart();
		root.findNote = Notifs.post({
			app: root.name,
			summary: `${root.name} is looking for this PC`,
			body: "Here it is.",
			icon: "watch",
			urgency: NotificationUrgency.Critical,
			actions: [{ text: "Found", identifier: "default", invoke: () => root.stopFinding(true) }]
		});
	}

	function stopFinding(tell) {
		if (!root.finding) return;
		root.finding = false;
		findRing.stop();
		if (tell) root.send({ op: "found" });
		root.findNote?.close?.();
		root.findNote = null;
	}

	Timer {
		id: findRing

		interval: 2200
		repeat: true
		triggeredOnStart: true
		onTriggered: {
			if (root.option("findSound", true)) Quickshell.execDetached(["paplay", "/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga"]);
			if (root.finding && findCount.count++ > 30) root.stopFinding(true);
		}
	}

	QtObject {
		id: findCount

		property int count: 0
	}

	// ── Do not disturb, both ways ─────────────────────────────────────────
	Connections {
		target: Notifs
		enabled: root.zeppReady && root.option("dndSync", false)

		function onDndChanged() {
			root.send({ op: "silent", on: Notifs.dnd });
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

	// ── what a key does ───────────────────────────────────────────────────
	readonly property var controls: [
		{ id: "play", label: "Play / pause", detail: "HID key · music app", icon: "play_pause" },
		{ id: "next", label: "Next", detail: "HID key · music app", icon: "skip_next" },
		{ id: "previous", label: "Previous", detail: "HID key · music app", icon: "skip_previous" },
		{ id: "volup", label: "Volume up", detail: "HID key · music app · camera shutter", icon: "volume_plus" },
		{ id: "voldown", label: "Volume down", detail: "HID key · music app", icon: "volume_minus" },
		{ id: "mute", label: "Mute", detail: "HID key", icon: "volume_off" },
		{ id: "stop", label: "Stop", detail: "HID key", icon: "stop" },
		{ id: "eject", label: "Eject", detail: "HID key", icon: "eject" },
		{ id: "pause", label: "Pause", detail: "Zepp OS music app", icon: "pause" },
		{ id: "keyboard", label: "Keyboard report", detail: "HID report 1, left out of the report map", icon: "keyboard" },
		{ id: "findphone", label: "Find my phone", detail: "Zepp OS: the watch looks for this PC", icon: "cellphone_sound" }
	]
	readonly property var nativeNames: ({ play: "Play / pause", pause: "Play / pause", next: "Next track", previous: "Previous track", volup: "Volume up", voldown: "Volume down", mute: "Mute", stop: "Play / pause", eject: "Nothing", keyboard: "Nothing", findphone: "Ring this PC" })

	function ruleFor(control, trigger, app) {
		return root.rules.find(r => r.control === control && r.trigger === "click" && (r.app ?? "") === (app ?? "")) ?? null;
	}

	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function newId() {
		return `w${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
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
		else if (action?.kind === "amazfit") root.ownOp(action.op);
		else root.send({ op: "test", action });
	}

	// the page's own actions, when a key or the shell runs them
	function ownOp(op) {
		switch (op) {
		case "findwatch":
			root.findWatch(true);
			stopFind.restart();
			break;
		case "findphone":
			root.startFinding();
			break;
		case "time":
			root.syncTime();
			break;
		case "battery":
			Osd.show("amazfit", root.name, (root.battery ?? 0) / 100, root.battery === null ? "Battery not known" : `Battery ${root.battery} %`, "watch");
			break;
		case "hr":
			Osd.show("amazfit", root.name, Math.min(1, root.hr / 200), root.hr ? `${root.hr} bpm` : "No heart rate shared", "heart_pulse");
			break;
		case "dnd":
			Notifs.dndManual = !Notifs.dndManual;
			break;
		}
	}

	Timer {
		id: stopFind

		interval: 8000
		onTriggered: root.findWatch(false)
	}

	// ── what a key can do (for the mouse's ActionPicker) ─────────────────
	readonly property var shellActions: Mouse.shellActions.filter(a => a.group !== "Profiles")
	readonly property var niriActions: Mouse.niriActions
	readonly property var state: ({})
	readonly property var profiles: []
	readonly property var ownGroup: ({ id: "amazfit", label: "The watch", icon: "watch" })
	readonly property string ownKind: "amazfit"
	readonly property var ownActions: [
		{ id: "findwatch", label: "Make the watch vibrate", icon: "watch_vibrate" },
		{ id: "findphone", label: "Ring this PC", icon: "cellphone_sound" },
		{ id: "time", label: "Set the watch's time", icon: "clock_check_outline" },
		{ id: "battery", label: "Show the watch's battery", icon: "battery" },
		{ id: "hr", label: "Show the heart rate", icon: "heart_pulse" },
		{ id: "dnd", label: "Do not disturb on the PC", icon: "bell_off" }
	]

	function nativeLabel(control) {
		return root.nativeNames[control] ?? control;
	}

	function suggestions(control, trigger) {
		return [
			{ kind: "shell", id: "play" }, { kind: "shell", id: "next" }, { kind: "shell", id: "previous" },
			{ kind: "shell", id: "volume-up" }, { kind: "shell", id: "volume-down" }, { kind: "shell", id: "screenshot" },
			{ kind: "niri", action: "toggle-overview" }, { kind: "amazfit", op: "dnd" }
		];
	}

	function describe(action, control) {
		if (!action || action.kind === "default") return { label: root.nativeLabel(control), icon: "", plain: true };
		if (action.kind === "amazfit") {
			const a = root.ownActions.find(x => x.id === action.op);
			return { label: a?.label ?? action.op, icon: a?.icon ?? "watch" };
		}
		return Mouse.describe(action, control);
	}

	// ── the battery, told once when it runs low ──────────────────────────
	property var lastBattery: null

	onBatteryChanged: {
		const was = root.lastBattery;
		root.lastBattery = root.battery;
		const low = root.option("lowBattery", 15);
		if (root.battery === null || was === null || low <= 0) return;
		if (root.battery <= low && was > low)
			Notifs.post({ app: root.name, summary: `${root.name}: battery ${root.battery} %`, body: "About " + Math.max(1, Math.round(root.battery / 100 * 10)) + " days left with the usual use.", icon: "watch" });
	}

	// ── the daemon ────────────────────────────────────────────────────────
	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function commit() {
		saving.restart();
		pushing.restart();
	}

	// what the daemon gets: the kept config plus where the weather is
	function pushed() {
		const options = Object.assign({}, root.options);
		if (isFinite(Weather.latitude) && isFinite(Weather.longitude) && root.option("weatherOn", true))
			options.weather = { lat: Weather.latitude, lon: Weather.longitude, name: Weather.location || Weather.city || "Here" };
		return Object.assign({}, root.config, { options });
	}

	Connections {
		target: Weather
		enabled: daemon.running

		function onLatitudeChanged() {
			pushing.restart();
		}
	}

	Timer {
		id: saving

		interval: 400
		onTriggered: {
			file.setText(JSON.stringify(root.config, null, "\t") + "\n");
			Quickshell.execDetached(["chmod", "600", Paths.stateFile("amazfit.json")]);
		}
	}

	Timer {
		id: pushing

		interval: 60
		onTriggered: root.send({ op: "config", config: root.pushed() })
	}

	FileView {
		id: file

		path: Paths.stateFile("amazfit.json")
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
				console.warn("Amazfit: amazfit.json is not valid JSON");
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
			if (data.hidden) root.hidden = data.hidden;
			if (!data.online && Object.keys(root.zepp).length) root.zepp = {};
			break;
		case "zepp":
			{
				const z = Object.assign({}, root.zepp);
				z[data.part] = data.value;
				root.zepp = z;
			}
			break;
		case "hr":
			root.hr = data.bpm ?? 0;
			root.hrAt = Date.now();
			break;
		case "key":
			{
				const keys = Object.assign({}, root.keys);
				if (data.down) keys[data.control] = true;
				else delete keys[data.control];
				root.keys = keys;
			}
			break;
		case "report":
			root.hidden = data.data ?? "";
			break;
		case "fired":
			root.fired(data.rule ?? "", data.control ?? "", data.trigger ?? "");
			break;
		case "action":
			Mouse.runShell(data.id, data.value);
			break;
		case "amazfit":
			root.ownOp(data.op ?? "");
			break;
		case "find":
			if (data.phase === "start" || data.phase === "mode") root.startFinding();
			else if (data.phase === "stop") root.stopFinding(false);
			break;
		case "event":
			root.onWatchEvent(data);
			break;
		case "music":
			root.pushMusic();
			break;
		case "silent":
			if (data.query) root.send({ op: "silent", on: Notifs.dnd });
			else if (root.option("dndSync", false)) Notifs.dndManual = data.on === true;
			break;
		case "ack":
			root.acked(data.what ?? "", data.ok !== false);
			break;
		case "health":
			// into the watch's health history, which the phone app and >watch both see
			Phone.call("health", "add", { days: data.days ?? [], nights: data.nights ?? [], battery: root.battery, synced: Math.floor(Date.now() / 1000) }, result => root.healthAt = Date.now());
			break;
		case "fetching":
			root.fetching = data.on === true;
			break;
		case "imported":
			root.imported = `${data.days ?? 0} days, ${data.nights ?? 0} nights from Gadgetbridge`;
			break;
		case "snapshot":
			root.comparing = "ready";
			root.changes = [];
			break;
		case "compared":
			root.comparing = "done";
			root.changes = data.changes ?? [];
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
			root.send({ op: "config", config: root.pushed() });
			if (Niri.ready) for (const line of Niri.replay()) if (/^\{"Window/.test(line)) daemon.write(`{"op":"niri","event":${line}}\n`);
			if (root.watching) root.send({ op: "watch", on: true });
		}
		onExited: {
			root.device = { online: false, present: false };
			root.zepp = {};
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
