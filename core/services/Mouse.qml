pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Logitech mouse (`mouse` plugin): its settings, what its buttons do,
// live presses for the Mouse page. scripts/mouse/mouse.py speaks HID++ to it
// (no Solaar needed) and does what the rules say; actions of the shell come
// back here as events and run below. Everything set is kept in mouse.json:
//
//   devices: { <serial>: { dpi, dpiPresets, shiftDpi, ratchet, smartshift,
//              threshold, torque, wheelInvert, wheelHires, thumbInvert,
//              hapticOn, hapticLevel, force, seen } }
//   rules:   [{ id, control, trigger, app, mods, action, feel, repeat, on }]
//   options: { feedback, feedbackWave, holdMs, doubleMs, swipeDistance, thumbStep, apps }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("mouse")
	// the haptics plugin without the mouse plugin: the daemon only plays
	// (scripts/mouse/mouse.py, PSHELL_MOUSE_MODE=haptics) and leaves the mouse be
	readonly property bool hapticsOnly: !root.enabled && Plugins.on("haptics")
	readonly property string script: `${Paths.scripts}/mouse/mouse.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var devices: []
	property bool solaar: false
	property bool inCharge: false
	property bool running: daemon.running
	property bool scanned: false
	readonly property var device: root.devices.find(d => d.id === root.picked && d.online) ?? root.devices.find(d => d.online) ?? root.devices[0] ?? null
	readonly property var state: root.device?.state ?? ({})
	readonly property bool online: !!root.device && root.device.online === true
	property string picked: ""
	// the app with the focus, while the page watches
	property string focusApp: ""
	property var stats: ({ today: {}, total: {}, days: [] })
	property string error: ""

	// live, while the page watches: control -> held
	property var pressed: ({})
	// the movement of the held control since it went down
	property real moveX: 0
	property real moveY: 0
	property string moveControl: ""
	signal fired(string rule, string control, string trigger)
	signal pressedControl(string control, bool down)
	signal wheeled(string wheel, int delta)
	signal imported(int rules, int skipped)

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ devices: {}, rules: [], options: {} })
	property bool loaded: false
	readonly property var rules: root.config.rules ?? []
	readonly property var options: root.config.options ?? ({})
	readonly property var mine: root.device ? (root.config.devices?.[root.device.id] ?? {}) : ({})

	property bool watching: false
	onWatchingChanged: root.send({ op: "watch", on: root.watching })

	function option(key, fallback) {
		return root.options[key] ?? fallback;
	}

	function setOption(key, value) {
		const options = Object.assign({}, root.options);
		options[key] = value;
		root.config = Object.assign({}, root.config, { options });
		root.commit();
	}

	// a device setting: to the mouse at once, written when it rests
	function set(key, value) {
		if (!root.device) return;
		root.setMany({ [key]: value });
	}

	function setMany(values) {
		if (!root.device) return;
		const devices = Object.assign({}, root.config.devices);
		devices[root.device.id] = Object.assign({}, devices[root.device.id] ?? {}, values);
		root.config = Object.assign({}, root.config, { devices });
		root.send({ op: "set", device: root.device.id, values });
		saving.restart();
	}

	function value(key, fallback) {
		return root.mine[key] ?? fallback;
	}

	// ── rules ──────────────────────────────────────────────────────────────
	function ruleFor(control, trigger, app) {
		return root.rules.find(r => r.control === control && r.trigger === trigger && (r.app ?? "") === (app ?? "") && (r.mods ?? []).length === 0) ?? null;
	}

	// what applies in an app when it has nothing of its own
	function effective(control, trigger, app) {
		return root.ruleFor(control, trigger, app) ?? (app ? root.ruleFor(control, trigger, "") : null);
	}

	function newId() {
		return `r${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
	}

	function putRule(rule) {
		const rules = root.rules.slice();
		const at = rules.findIndex(r => r.id === rule.id);
		if (at >= 0) rules[at] = rule;
		else rules.push(rule);
		root.config = Object.assign({}, root.config, { rules });
		root.commit();
	}

	// the action of one trigger in one app (null takes the rule away)
	function assign(control, trigger, app, action, extra) {
		const old = root.ruleFor(control, trigger, app);
		if (!action) {
			if (old) root.removeRule(old.id);
			return;
		}
		const rule = Object.assign({ id: old?.id ?? root.newId(), control, trigger, app: app ?? "", mods: [], on: true }, old ?? {}, extra ?? {}, { action });
		root.putRule(rule);
	}

	function removeRule(id) {
		root.config = Object.assign({}, root.config, { rules: root.rules.filter(r => r.id !== id) });
		root.commit();
	}

	function toggleRule(id, on) {
		const rule = root.rules.find(r => r.id === id);
		if (rule) root.putRule(Object.assign({}, rule, { on }));
	}

	// the apps the page offers as places: those with rules, and added ones
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
	function play(waveform) {
		root.send({ op: "play", waveform, device: root.device?.id ?? "" });
	}

	function test(action) {
		if (action?.kind === "shell") root.runShell(action.id, action.value);
		else root.send({ op: "test", action });
	}

	function switchHost(index) {
		root.send({ op: "host", device: root.device?.id ?? "", index });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	// Solaar lets go: its settings and rules come along, it stops (the
	// page takes it out of niri's startup)
	function takeOver() {
		root.send({ op: "takeover" });
	}

	function giveBack() {
		Quickshell.execDetached(["sh", "-c", "setsid solaar -w hide >/dev/null 2>&1 &"]);
	}

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function commit() {
		saving.restart();
		pushing.restart();
	}

	function save() {
		file.setText(JSON.stringify(Object.assign({}, root.config, { profiles: root.snapshotProfiles() }), null, "\t") + "\n");
	}

	// ── profiles ───────────────────────────────────────────────────────────
	// A profile is a whole set of rules and device settings. The one in use is
	// the working set (config.rules, config.devices); the others wait in
	// config.profiles. One can follow apps (apps) or a running game (games):
	// it comes when they get the focus or start, the picked one comes back
	// when they lose it or end. Only such a change switches by itself – a
	// focus change that leaves the app-or-game situation as it was (a
	// workspace switch made by the very button press) keeps what was picked
	// by hand. Rules switching profiles (and those marked shared) are in all.
	readonly property var profiles: root.config.profiles ?? []
	readonly property string activeProfile: root.config.active ?? ""
	readonly property var active: root.profiles.find(p => p.id === root.activeProfile) ?? null
	readonly property bool gaming: GameMode.playing
	// game haptics play only while the game has the focus
	readonly property bool gameFocused: GameMode.focused
	// the game's processes (games_guard.py): the daemon finds its sound by them
	readonly property var gamePids: {
		const pids = new Set();
		const windows = Array.isArray(Games.windows) ? Games.windows : [];
		for (const w of windows) for (const pid of (Array.isArray(w.pids) ? w.pids : [])) pids.add(pid);
		return Array.from(pids);
	}
	readonly property string gamePidKey: (root.gamePids ?? []).join(",")
	// what the daemon learns a game's sounds under: Steam's app id (titles
	// change with the level), else the title
	readonly property string gameKey: {
		const windows = Array.isArray(Games.windows) ? Games.windows : [];
		const first = windows.length > 0 ? windows[0] : null;
		const app = String(first?.app ?? "");
		return /^steam_app_/.test(app) ? app : (GameMode.title || app);
	}
	// the focused game window (niri's id), for the eyes
	readonly property int gameWindow: {
		const windows = Array.isArray(Games.windows) ? Games.windows : [];
		const focused = windows.find(w => Number(w.id) === Niri.focusedId);
		return Number((focused ?? windows[0])?.id ?? 0);
	}
	function tellGaming() {
		root.send({ op: "gaming", on: root.gaming, focused: root.gameFocused, pids: root.gamePids, game: root.gameKey, window: root.gameWindow });
	}
	onGameWindowChanged: if (root.gaming) root.tellGaming()
	onGameKeyChanged: if (root.gaming) root.tellGaming()

	// what the daemon learned about the game's sounds (gamefeel.Memory):
	// {game, sounds, known, yours, muted, minutes, gain, clusters: [{id, n, share, lvl, state, keys}]}
	property var learning: ({})
	// the inside of the game haptics, while the page watches: every onset
	// with its verdict and reason (newest first, at most 40), the presses'
	// open windows, the meter's raw numbers
	property var onsets: []
	property var gate: ({ duty: 0, held: [], windows: [] })
	property var meter: ({})
	// the game's picture (gamefeel.Eyes): {on, window, frames, seen: {shake, hit, flash, hud, zone}, latest (with
	// zones: {id: [change, red, bright]} for the zones drawn by hand), hud: {cells, yours}, zones: how many are drawn,
	// grid, scene: the scene recognised (its id, "" none), scores: {scene: likeness 0..1}, pointer: X pointer found}
	property var eyes: ({})
	// ── the HUD by hand (settings/mouse/HudZones.qml, gamefeel.Eyes) ──────
	// Per game: scenes – a picture each, of the HUD as it looks in a fight,
	// a dialog, exploring (options.hudScenes[game]: [{id, name, picture}]) –
	// and zones drawn on them (options.hudZones[game]: [{id, scene, name, x,
	// y, w, h, when, key, feel, level, every}], fractions of the window).
	// Every zone fires whatever scene is up; the scenes are for drawing.
	readonly property var hudTable: root.option("hudZones", null) ?? ({})
	readonly property var hudZones: Array.isArray(root.hudTable[root.gameKey]) ? root.hudTable[root.gameKey] : []
	readonly property var hudSceneTable: root.option("hudScenes", null) ?? ({})
	readonly property var hudScenes: Array.isArray(root.hudSceneTable[root.gameKey]) ? root.hudSceneTable[root.gameKey] : []
	// the scene being drawn on (its id; "" → the first)
	property string hudSceneId: ""
	readonly property var hudScene: root.hudScenes.find(s => s.id === root.hudSceneId) ?? (root.hudScenes.length > 0 ? root.hudScenes[0] : null)
	// a scene's picture changed on disk (the Image reloads)
	property int hudPictureRev: 0
	readonly property string hudDir: `${Paths.cache}/hud`
	// zones picked on the frozen screen since the last draw began
	property int hudDrawn: 0

	function hudSafe(text) {
		return String(text).replace(/[^A-Za-z0-9_.-]+/g, "_").slice(0, 60) || "game";
	}

	function hudSaveZones(list) {
		const table = Object.assign({}, root.hudTable);
		if (list.length > 0) table[root.gameKey] = list;
		else delete table[root.gameKey];
		root.setOption("hudZones", table);
	}

	function hudSaveScenes(list) {
		const table = Object.assign({}, root.hudSceneTable);
		if (list.length > 0) table[root.gameKey] = list;
		else delete table[root.gameKey];
		root.setOption("hudScenes", table);
	}

	// a scene: its picture lives in the cache, named by game and scene
	function hudAddScene(name) {
		const id = `s${Date.now().toString(36)}`;
		const scene = { id, name: name || `Scene ${root.hudScenes.length + 1}`, picture: `${root.hudDir}/${root.hudSafe(root.gameKey)}-${id}.jpg` };
		root.hudSaveScenes(root.hudScenes.concat([scene]));
		root.hudSceneId = id;
		return scene;
	}

	function hudChangeScene(id, values) {
		root.hudSaveScenes(root.hudScenes.map(s => s.id === id ? Object.assign({}, s, values) : s));
	}

	// the scene goes with its zones and its picture
	function hudRemoveScene(id) {
		const scene = root.hudScenes.find(s => s.id === id);
		if (scene?.picture) Quickshell.execDetached(["rm", "-f", String(scene.picture)]);
		root.hudSaveZones(root.hudZones.filter(z => z.scene !== id));
		root.hudSaveScenes(root.hudScenes.filter(s => s.id !== id));
		if (root.hudSceneId === id) root.hudSceneId = "";
	}

	// the scene to draw on: the current one, made when there is none
	function hudSceneForDrawing() {
		return root.hudScene ?? root.hudAddScene("");
	}

	// what a zone reacts to: [{kind, feel, key, level, every, on}]; kinds
	// change, press, click, hover, red, bright, dark (an older zone's
	// when/feel/level/every is one trigger)
	readonly property var hudKinds: [
		{ value: "change", label: "Changes", icon: "swap_horizontal", feel: "SUBTLE COLLISION" },
		{ value: "press", label: "After a press", icon: "keyboard_outline", feel: "SUBTLE COLLISION" },
		{ value: "click", label: "Clicked", icon: "cursor_default_click_outline", feel: "SHARP COLLISION" },
		{ value: "hover", label: "Hovered", icon: "gesture_tap", feel: "WHISPER COLLISION" },
		{ value: "red", label: "Turns red", icon: "heart_pulse", feel: "SHARP STATE CHANGE" },
		{ value: "bright", label: "Brightens", icon: "white_balance_sunny", feel: "DAMP COLLISION" },
		{ value: "dark", label: "Darkens", icon: "weather_night", feel: "DAMP STATE CHANGE" }
	]
	readonly property string hudLiveScene: String(root.eyes?.scene ?? "")
	readonly property var hudScores: root.eyes?.scores ?? ({})

	// a list that came through a Repeater's modelData is a QVariantList, not an Array
	function hudList(value) {
		if (Array.isArray(value)) return value;
		if (value && typeof value === "object" && typeof value.length === "number") return Array.from({ length: value.length }, (_, i) => value[i]);
		return null;
	}

	function hudTriggers(zone) {
		if (!zone) return [];
		const list = root.hudList(zone.triggers);
		if (list) return list;
		return [{ kind: zone.when ?? "change", feel: zone.feel ?? "SUBTLE COLLISION", key: zone.key ?? "", keyName: zone.keyName ?? "", level: zone.level ?? 0, every: zone.every ?? 150, on: true }];
	}

	function hudTrigger(kind, values) {
		const base = root.hudKinds.find(k => k.value === kind) ?? root.hudKinds[0];
		return Object.assign({ kind: base.value, feel: base.feel, key: "", keyName: "", level: 0, every: 150, on: true }, values ?? {});
	}

	function hudAddZone(rect, values) {
		const scene = root.hudSceneForDrawing();
		const id = `z${Date.now().toString(36)}${root.hudZones.length}`;
		const given = Object.assign({}, values ?? {});
		const triggers = Array.isArray(given.triggers) ? given.triggers : [root.hudTrigger(given.when ?? "change", { feel: given.feel })];
		delete given.when;
		delete given.feel;
		const zone = Object.assign({ id, scene: scene.id, name: `Zone ${root.hudZones.length + 1}`, triggers }, rect, given);
		root.hudSaveZones(root.hudZones.concat([zone]));
		return id;
	}

	function hudSetTriggers(id, list) {
		root.hudSaveZones(root.hudZones.map(z => {
			if (z.id !== id) return z;
			const zone = Object.assign({}, z, { triggers: list });
			delete zone.when;
			delete zone.feel;
			delete zone.level;
			delete zone.every;
			delete zone.key;
			return zone;
		}));
	}

	function hudAddTrigger(id, kind) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone) return;
		root.hudSetTriggers(id, root.hudTriggers(zone).concat([root.hudTrigger(kind)]));
	}

	function hudChangeTrigger(id, index, values) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone) return;
		root.hudSetTriggers(id, root.hudTriggers(zone).map((t, i) => i === index ? Object.assign({}, t, values) : t));
	}

	// a reaction's follow-up steps: [{when, feel, key, within (ms), delay (ms)}]
	// – after it fired, each step waits for its event within its time, plays
	// its pattern and arms the next
	readonly property var hudSteps: [
		{ value: "clickAnywhere", label: "A click anywhere", icon: "cursor_default_click_outline" },
		{ value: "clickOutside", label: "A click elsewhere", icon: "cursor_default_click_outline" },
		{ value: "clickHere", label: "A click on it again", icon: "cursor_default_click" },
		{ value: "leave", label: "The pointer leaves", icon: "gesture_tap" },
		{ value: "press", label: "Any press", icon: "keyboard_outline" },
		{ value: "change", label: "It changes", icon: "swap_horizontal" },
		{ value: "delay", label: "After a moment", icon: "timer_outline" }
	]

	function hudStepsOf(trigger) {
		return root.hudList(trigger?.then) ?? [];
	}

	function hudAddStep(id, index, when) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone) return;
		const trigger = root.hudTriggers(zone)[index];
		if (!trigger) return;
		const step = { when: when || "clickAnywhere", feel: "DAMP COLLISION", key: "", keyName: "", within: 5000, delay: 500 };
		root.hudChangeTrigger(id, index, { then: root.hudStepsOf(trigger).concat([step]) });
	}

	function hudChangeStep(id, index, stepIndex, values) {
		const zone = root.hudZones.find(z => z.id === id);
		const trigger = zone ? root.hudTriggers(zone)[index] : null;
		if (!trigger) return;
		root.hudChangeTrigger(id, index, { then: root.hudStepsOf(trigger).map((s, i) => i === stepIndex ? Object.assign({}, s, values) : s) });
	}

	function hudRemoveStep(id, index, stepIndex) {
		const zone = root.hudZones.find(z => z.id === id);
		const trigger = zone ? root.hudTriggers(zone)[index] : null;
		if (!trigger) return;
		root.hudChangeTrigger(id, index, { then: root.hudStepsOf(trigger).filter((s, i) => i !== stepIndex) });
	}

	// reactions copied from a zone, to paste into others (this session)
	property var hudClipboard: []
	property string hudClipboardFrom: ""

	function hudCopyTriggers(id, index) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone) return;
		const all = root.hudTriggers(zone).map(t => JSON.parse(JSON.stringify(t)));
		root.hudClipboard = index === undefined || index === null || index < 0 ? all : all.filter((t, i) => i === index);
		root.hudClipboardFrom = zone.name;
	}

	// replace: the zone's reactions become the copied ones; else they are added
	function hudPasteTriggers(id, replace) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone || root.hudClipboard.length === 0) return;
		const copied = root.hudClipboard.map(t => JSON.parse(JSON.stringify(t)));
		root.hudSetTriggers(id, replace ? copied : root.hudTriggers(zone).concat(copied));
	}

	function hudPasteIntoScene(sceneId, replace) {
		if (root.hudClipboard.length === 0) return;
		const copied = () => root.hudClipboard.map(t => JSON.parse(JSON.stringify(t)));
		root.hudSaveZones(root.hudZones.map(z => {
			if ((z.scene ?? "") !== sceneId) return z;
			const zone = Object.assign({}, z, { triggers: replace ? copied() : root.hudTriggers(z).concat(copied()) });
			delete zone.when;
			delete zone.feel;
			delete zone.level;
			delete zone.every;
			delete zone.key;
			return zone;
		}));
	}

	function hudRemoveTrigger(id, index) {
		const zone = root.hudZones.find(z => z.id === id);
		if (!zone) return;
		root.hudSetTriggers(id, root.hudTriggers(zone).filter((t, i) => i !== index));
	}

	function hudChangeZone(id, values) {
		root.hudSaveZones(root.hudZones.map(z => z.id === id ? Object.assign({}, z, values) : z));
	}

	function hudRemoveZone(id) {
		root.hudSaveZones(root.hudZones.filter(z => z.id !== id));
	}

	// where the game's window sits on its output, logical px (a fullscreen
	// game: the whole output)
	function hudWindowRect() {
		const raw = Niri.windowMap?.[String(root.gameWindow)] ?? Niri.windowMap?.[root.gameWindow];
		const layout = raw?.layout ?? {};
		const size = layout.window_size ?? [0, 0];
		const tile = layout.tile_pos_in_workspace_view ?? [0, 0];
		const offset = layout.window_offset_in_tile ?? [0, 0];
		let width = Number(size[0]) || 0, height = Number(size[1]) || 0;
		if (width <= 0 || height <= 0) {
			const ws = Niri.workspaces.find(w => Number(w.id) === Number(raw?.workspace_id));
			const screen = Quickshell.screens.find(s => String(s.name) === String(ws?.output ?? ""));
			width = Number(screen?.width ?? 1920);
			height = Number(screen?.height ?? 1080);
		}
		return Qt.rect(Number(tile[0]) + Number(offset[0]), Number(tile[1]) + Number(offset[1]), width, height);
	}

	// draw zones on the real screen: the game's window comes to the front,
	// then it is frozen like a screenshot (Screenshot.hud) and every box
	// clicked or region dragged is a zone of the current scene; the frozen
	// window becomes the scene's picture
	function hudDraw() {
		if (root.gameWindow <= 0 || !Plugins.on("screenshot")) return false;
		root.hudSceneForDrawing();
		root.hudDrawn = 0;
		Niri.focusWindow(root.gameWindow);
		hudDrawTimer.restart();
		return true;
	}

	Timer {
		id: hudDrawTimer

		interval: 650
		onTriggered: {
			const scene = root.hudScene;
			if (!scene) return;
			Screenshot.hud(root.gameWindow, root.hudWindowRect(), String(scene.picture ?? ""));
		}
	}

	Connections {
		target: Screenshot

		function onHudPicked(output, logical) {
			const win = root.hudWindowRect();
			if (win.width <= 0 || win.height <= 0) return;
			const clamp = v => Math.max(0, Math.min(1, v));
			const x0 = clamp((logical.x - win.x) / win.width), y0 = clamp((logical.y - win.y) / win.height);
			const x1 = clamp((logical.x + logical.width - win.x) / win.width), y1 = clamp((logical.y + logical.height - win.y) / win.height);
			if (x1 - x0 < 0.003 || y1 - y0 < 0.003) return;
			root.hudAddZone({ x: Math.round(x0 * 10000) / 10000, y: Math.round(y0 * 10000) / 10000, w: Math.round((x1 - x0) * 10000) / 10000, h: Math.round((y1 - y0) * 10000) / 10000 });
			root.hudDrawn += 1;
		}

		function onHudPicture(path) {
			hudPictureSettle.restart();
		}
	}

	// magick needs a moment to write the picture
	Timer {
		id: hudPictureSettle

		interval: 900
		onTriggered: root.hudPictureRev += 1
	}

	// a sound that should not have been felt: never again (-1: the last one)
	function muteSound(cluster) {
		root.send({ op: "mute", cluster: cluster ?? -1 });
	}
	function forgetGame() {
		root.send({ op: "forget" });
	}
	// what the ears hear and every press, kept for tuning (~/.cache/pshell/ears-<game>.*)
	function recordEars(seconds) {
		root.send({ op: "record", seconds: seconds ?? 120 });
	}
	onGamingChanged: {
		root.tellGaming();
		root.followContext();
	}
	onGameFocusedChanged: root.tellGaming()
	onGamePidKeyChanged: if (root.gaming) root.tellGaming()
	onFocusAppChanged: root.followContext()
	// the profile the app or the game last asked for ("" none); a switch by
	// itself happens only when this changes
	property string autoProfile: ""
	// the one in use came by itself, not by hand
	readonly property bool automatic: root.autoProfile !== "" && root.autoProfile === root.activeProfile && root.autoProfile !== (root.config.profile ?? "")

	readonly property var profileIcons: ["mouse_variant", "gamepad_variant", "briefcase_outline", "palette_outline", "code_braces", "movie_open_outline", "music_note", "crosshairs", "leaf", "rocket_launch_outline"]

	function shared(rule) {
		return rule.shared === true || (rule.action?.kind === "shell" && ["profile", "profile-next"].includes(rule.action?.id));
	}

	function deviceSettings(devices) {
		const out = {};
		for (const serial of Object.keys(devices ?? {})) {
			const copy = Object.assign({}, devices[serial]);
			delete copy.seen;
			out[serial] = copy;
		}
		return out;
	}

	// the profiles with the one in use as it is now
	function snapshotProfiles() {
		return root.profiles.map(p => p.id === root.activeProfile ? Object.assign({}, p, { rules: root.rules.filter(r => !root.shared(r)), devices: root.deviceSettings(root.config.devices) }) : p);
	}

	function ensureProfiles() {
		if (root.profiles.length > 0) return;
		root.config = Object.assign({}, root.config, {
			profiles: [{ id: "everyday", name: "Everyday", icon: "mouse_variant", apps: [], games: false }],
			active: "everyday",
			profile: "everyday"
		});
	}

	// the profile the situation asks for: a running game's, the focused app's
	function autoTarget() {
		if (root.gaming) {
			const game = root.profiles.find(p => p.games === true);
			if (game) return game.id;
		}
		const app = (root.focusApp || "").toLowerCase();
		if (app) {
			const own = root.profiles.find(p => (p.apps ?? []).some(a => a.toLowerCase() === app));
			if (own) return own.id;
		}
		return "";
	}

	function followContext() {
		if (!root.loaded || root.profiles.length < 2) return;
		const auto = root.autoTarget();
		if (auto === root.autoProfile) return;
		root.autoProfile = auto;
		const want = auto || root.config.profile || root.activeProfile;
		if (want && want !== root.activeProfile) root.load(want, true);
	}

	// puts a profile in use: what is in use goes back into its own first
	function load(id, quiet) {
		const target = root.profiles.find(p => p.id === id);
		if (!target || id === root.activeProfile) return;
		const profiles = root.snapshotProfiles();
		const keep = root.rules.filter(r => root.shared(r));
		const keys = new Set(keep.map(r => `${r.control}/${r.trigger}/${r.app ?? ""}/${(r.mods ?? []).join("+")}`));
		const rules = (target.rules ?? []).filter(r => !keys.has(`${r.control}/${r.trigger}/${r.app ?? ""}/${(r.mods ?? []).join("+")}`)).concat(keep);
		const devices = {};
		for (const serial of new Set(Object.keys(root.config.devices ?? {}).concat(Object.keys(target.devices ?? {}))))
			devices[serial] = Object.assign({}, target.devices?.[serial] ?? root.config.devices?.[serial] ?? {}, { seen: root.config.devices?.[serial]?.seen });
		root.config = Object.assign({}, root.config, { profiles, rules, devices, active: id });
		root.commit();
		Osd.show("mouse", quiet ? "Mouse profile (automatic)" : "Mouse profile", 1, target.name, target.icon || "mouse_variant");
		root.play(quiet ? "SUBTLE COLLISION" : "DAMP STATE CHANGE");
		root.profileSwitched(target.name, quiet === true);
	}

	signal profileSwitched(string name, bool automatic)

	// by hand (the launcher, a button, the page)
	function useProfile(id) {
		const target = root.profiles.find(p => p.id === id || p.name.toLowerCase() === String(id).toLowerCase());
		if (!target) return false;
		root.config = Object.assign({}, root.config, { profile: target.id });
		if (target.id !== root.activeProfile) root.load(target.id, false);
		else root.commit();
		return true;
	}

	function nextProfile() {
		if (root.profiles.length < 2) return;
		const at = root.profiles.findIndex(p => p.id === root.activeProfile);
		root.useProfile(root.profiles[(at + 1) % root.profiles.length].id);
	}

	// a new one, starting as a copy of what is in use
	function newProfile(name, icon) {
		root.ensureProfiles();
		const id = `p${Date.now().toString(36)}`;
		const profiles = root.snapshotProfiles().concat([{ id, name: name || `Profile ${root.profiles.length + 1}`, icon: icon || "mouse_variant", apps: [], games: false, rules: root.rules.filter(r => !root.shared(r)), devices: root.deviceSettings(root.config.devices) }]);
		root.config = Object.assign({}, root.config, { profiles });
		root.useProfile(id);
		return id;
	}

	function editProfile(id, values) {
		root.config = Object.assign({}, root.config, { profiles: root.profiles.map(p => p.id === id ? Object.assign({}, p, values) : p) });
		root.commit();
		root.followContext();
	}

	function removeProfile(id) {
		if (root.profiles.length < 2) return;
		const rest = root.profiles.filter(p => p.id !== id);
		if (id === root.activeProfile) {
			root.config = Object.assign({}, root.config, { profile: rest[0].id });
			root.load(rest[0].id, true);
		}
		const next = root.config.profile === id ? rest[0].id : root.config.profile;
		root.config = Object.assign({}, root.config, { profiles: root.snapshotProfiles().filter(p => p.id !== id), profile: next });
		root.commit();
	}

	// ── live game haptics ─────────────────────────────────────────────────
	// the game's sound is heard (gamefeel.Ears), and which streams
	property bool rumbling: false
	property var hearing: []
	// the virtual controller is there for the game to rumble (gamefeel.Pad);
	// `padBlocked` names the real controller that keeps it away
	property bool padOn: false
	property string padBlocked: ""
	property int padPulses: 0
	// the presses of a game are read (Triggers in the daemon)
	property bool triggering: false
	signal triggered(string key, string label)
	// the sound meter: how far the last 20 ms stand out, 0.5 is the line
	property real bass: 0
	property real bassThreshold: 0.5
	signal hit(real strength)
	// a game event the mouse played: source "pad" | "sound" | "press",
	// kind "rumble" | "tick" | "thud" | "blast" | "shake" | "hit" | "flash" | "hud" | "zone" | "press", the waveform
	signal felt(string source, string kind, real strength, string wave, string label, int cluster)
	property var batteryLog: []
	// what the daemon last said it goes by (`ipc mouse state`)
	property var daemonState: ({})

	function ruleKeys() {
		const canonical = value => Array.isArray(value) ? value.map(canonical) : (value && typeof value === "object" ? Object.keys(value).sort().reduce((out, key) => Object.assign(out, { [key]: canonical(value[key]) }), {}) : value);
		return root.rules.filter(r => r.on !== false).map(r => `${r.control}/${r.trigger}/${r.app ?? ""}=${JSON.stringify(canonical(r.action))}`);
	}

	Timer {
		id: saving

		interval: 500
		onTriggered: root.save()
	}

	// the whole configuration goes over in one, a moment after the last change
	Timer {
		id: pushing

		interval: 60
		onTriggered: root.send({ op: "config", config: root.config })
	}

	FileView {
		id: file

		path: Paths.stateFile("mouse.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = {
					devices: data.devices && typeof data.devices === "object" ? data.devices : {},
					rules: Array.isArray(data.rules) ? data.rules : [],
					options: data.options && typeof data.options === "object" ? data.options : {},
					profiles: Array.isArray(data.profiles) ? data.profiles : [],
					active: String(data.active ?? ""),
					profile: String(data.profile ?? data.active ?? "")
				};
			} catch (error) {
				console.warn("Mouse: mouse.json is not valid JSON");
			}
			root.ensureProfiles();
			root.loaded = true;
		}
		onLoadFailed: {
			root.ensureProfiles();
			root.loaded = true;
		}
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
			root.inCharge = data.inCharge === true;
			root.scanned = true;
			break;
		case "solaar":
			root.solaar = data.running === true;
			break;
		case "battery":
			root.patch(data.device, { battery: data.battery });
			break;
		case "dpi":
			root.patch(data.device, { dpi: Object.assign({}, root.stateOf(data.device).dpi ?? {}, { value: data.value }) });
			if (!data.shifted) root.keep(data.device, { dpi: data.value });
			Osd.show("mouse", data.shifted ? "Precision" : "Mouse speed", Math.min(1, data.value / 4000), `${data.value} DPI`, "mouse");
			break;
		case "ratchet":
			root.patch(data.device, { smartshift: Object.assign({}, root.stateOf(data.device).smartshift ?? {}, { ratchet: data.ratchet }) });
			break;
		case "seen":
			root.keep(data.device, { seen: data.seen }, true);
			break;
		case "press":
			{
				const pressed = Object.assign({}, root.pressed);
				pressed[data.control] = data.down;
				root.pressed = pressed;
				if (data.down) {
					root.moveX = 0;
					root.moveY = 0;
					root.moveControl = data.control;
				}
				root.pressedControl(data.control, data.down);
			}
			break;
		case "move":
			root.moveControl = data.control;
			root.moveX = data.dx;
			root.moveY = data.dy;
			break;
		case "wheel":
			root.wheeled(data.wheel, data.delta);
			break;
		case "fired":
			root.fired(data.rule ?? "", data.control ?? "", data.trigger ?? "");
			break;
		case "state":
			root.daemonState = data;
			break;
		case "ears":
			root.rumbling = data.on === true;
			root.hearing = Array.isArray(data.streams) ? data.streams : [];
			break;
		case "learning":
			root.learning = data;
			break;
		case "eyes":
			root.eyes = data;
			break;
		case "onset":
			root.onsets = [data].concat(root.onsets.slice(0, 39));
			break;
		case "gate":
			root.gate = data;
			break;
		case "pad":
			root.padOn = data.on === true;
			root.padBlocked = String(data.blocked ?? "");
			root.padPulses = Number(data.pulses ?? 0);
			break;
		case "felt":
			root.felt(String(data.source ?? ""), String(data.kind ?? ""), Number(data.strength ?? 0), String(data.wave ?? ""), String(data.label ?? ""), Number(data.cluster ?? -1));
			if (data.source === "pad") root.padPulses += 1;
			if (data.source === "sound") root.hit(Number(data.strength ?? 0));
			break;
		case "triggers":
			root.triggering = data.on === true;
			break;
		case "trigger":
			root.triggered(data.key ?? "", data.label ?? "");
			break;
		case "bass":
			root.bass = data.level ?? 0;
			root.bassThreshold = data.threshold ?? 0;
			root.meter = data;
			break;
		case "batteryLog":
			root.batteryLog = data.log ?? [];
			break;
		case "latch":
			// a sticky key says nothing on screen: the pulse is enough
			break;
		case "focus":
			root.focusApp = data.app ?? "";
			break;
		case "stats":
			root.stats = { today: data.today ?? {}, total: data.total ?? {}, days: data.days ?? [] };
			break;
		case "action":
			root.runShell(data.id, data.value);
			break;
		case "imported":
			root.adopt(data);
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	function stateOf(id) {
		return root.devices.find(d => d.id === id)?.state ?? {};
	}

	function patch(id, values) {
		root.devices = root.devices.map(d => d.id === id || (!id && d.online) ? Object.assign({}, d, { state: Object.assign({}, d.state, values) }) : d);
	}

	// what the mouse changed itself (DPI cycling): kept without sending back
	function keep(id, values, quiet) {
		if (!id) return;
		const devices = Object.assign({}, root.config.devices);
		devices[id] = Object.assign({}, devices[id] ?? {}, values);
		root.config = Object.assign({}, root.config, { devices });
		saving.restart();
	}

	function adopt(data) {
		const devices = Object.assign({}, root.config.devices);
		for (const serial of Object.keys(data.devices ?? {}))
			devices[serial] = Object.assign({}, data.devices[serial], devices[serial] ?? {});
		const known = new Set(root.rules.map(r => `${r.control}/${r.trigger}/${r.app ?? ""}`));
		const rules = root.rules.concat((data.rules ?? []).filter(r => !known.has(`${r.control}/${r.trigger}/${r.app ?? ""}`)));
		root.config = Object.assign({}, root.config, { devices, rules });
		root.commit();
		root.imported((data.rules ?? []).length, (data.skipped ?? []).length);
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
			if (/^\{"(Window|Workspace)/.test(text)) daemon.write(`{"op":"niri","event":${text}}\n`);
		}
	}

	Process {
		id: daemon

		running: (root.enabled || root.hapticsOnly) && root.loaded
		stdinEnabled: true
		command: ["python3", "-u", root.script]
		environment: ({ PSHELL_NIRI_EVENTS: "stdin", PSHELL_MOUSE_MODE: root.hapticsOnly ? "haptics" : "" })
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(line)
		}
		onRunningChanged: if (daemon.running) {
			if (!root.hapticsOnly) root.send({ op: "config", config: root.config });
			root.tellGaming();
			// niri's events from the shell's own stream, the whole state first
			if (Niri.ready) for (const line of Niri.replay()) daemon.write(`{"op":"niri","event":${line}}\n`);
			if (root.watching) root.send({ op: "watch", on: true });
		}
		onExited: {
			root.devices = root.devices.map(d => Object.assign({}, d, { online: false }));
			if (root.enabled || root.hapticsOnly) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}

	// ── what a button can do ──────────────────────────────────────────────
	// the shell's own: run here, at once
	readonly property var shellActions: [
		{ id: "launcher", label: "Launcher", icon: "apps", group: "Shell", run: () => root.drawer("launcher") },
		{ id: "launcher-query", label: "Launcher with text", icon: "magnify", group: "Shell", hidden: true, run: value => root.launch(String(value ?? "")) },
		{ id: "radial", label: "Action ring", icon: "circle_slice_8", group: "Shell", detail: "The radial menu at the pointer", run: () => root.modal("radial") },
		{ id: "overview", label: "Overview panel", icon: "view_dashboard_outline", group: "Shell", run: () => root.drawer("overview") },
		{ id: "control", label: "Control center", icon: "tune_variant", group: "Shell", run: () => root.drawer("control", "main") },
		{ id: "notifications", label: "Notifications", icon: "bell_outline", group: "Shell", run: () => root.drawer("today") },
		{ id: "clipboard", label: "Clipboard history", icon: "clipboard_text_outline", group: "Shell", run: () => root.drawer("clipboard") },
		{ id: "media-panel", label: "Media panel", icon: "music_note", group: "Shell", run: () => root.drawer("media") },
		{ id: "files", label: "Files", icon: "folder_outline", group: "Shell", run: () => Files.toggle() },
		{ id: "power", label: "Power menu", icon: "power", group: "Shell", run: () => root.modal("power") },
		{ id: "lock", label: "Lock", icon: "lock", group: "Shell", run: () => Session.lock() },
		{ id: "dnd", label: "Do not disturb", icon: "bell_off_outline", group: "Shell", run: () => Notifs.toggleDnd() },
		{ id: "findmouse", label: "Find the pointer", icon: "crosshairs_gps", group: "Shell", run: () => FindMouse.show() },
		{ id: "settings", label: "Pshell settings", icon: "cog_outline", group: "Shell", run: () => root.modal("niri") },
		{ id: "shot-region", label: "Screenshot of a region", icon: "selection_drag", group: "Screenshot", run: () => Screenshot.region() },
		{ id: "shot-screen", label: "Screenshot of the screen", icon: "monitor", group: "Screenshot", run: () => Screenshot.screen() },
		{ id: "shot-window", label: "Screenshot of the window", icon: "application_outline", group: "Screenshot", run: () => Screenshot.window() },
		{ id: "picker", label: "Pick a colour", icon: "eyedropper", group: "Screenshot", run: () => Screenshot.picker() },
		{ id: "ocr", label: "Copy text from the screen", icon: "text_recognition", group: "Screenshot", run: () => Screenshot.ocr() },
		{ id: "play", label: "Play / pause", icon: "play_pause", group: "Media", run: () => Media.player?.togglePlaying() },
		{ id: "next", label: "Next track", icon: "skip_next", group: "Media", run: () => Media.player?.next() },
		{ id: "previous", label: "Previous track", icon: "skip_previous", group: "Media", run: () => Media.player?.previous() },
		{ id: "volume-up", label: "Volume up", icon: "volume_high", group: "Media", run: () => Audio.adjust(1) },
		{ id: "volume-down", label: "Volume down", icon: "volume_medium", group: "Media", run: () => Audio.adjust(-1) },
		{ id: "mute", label: "Mute", icon: "volume_off", group: "Media", run: () => Audio.toggleMute() },
		{ id: "mic-mute", label: "Mute the microphone", icon: "microphone_off", group: "Media", run: () => Audio.toggleMicMute() },
		{ id: "profile-next", label: "Next mouse profile", icon: "swap_horizontal", group: "Profiles", run: () => root.nextProfile() },
		{ id: "profile", label: "Mouse profile", icon: "account_switch_outline", group: "Profiles", hidden: true, run: value => root.useProfile(value) },
		{ id: "rumble", label: "Game haptics on / off", icon: "vibrate", group: "Profiles", run: () => root.setOption("rumble", root.option("rumble", "off") === "off" ? "always" : "off") }
	]

	// as the keybinds open them (core/Ipc.qml): on the focused screen, again closes
	function drawer(id, page) {
		if (Popups.current === id && (page === undefined || Popups.page === page)) {
			Popups.close();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.open(id, screen, page));
	}

	// the launcher on a query (">c "): again on the same one closes it
	function launch(query) {
		if (Popups.current === "launcher") {
			Popups.close();
			if (root.lastQuery === query) return;
		}
		root.lastQuery = query;
		Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", query));
	}

	property string lastQuery: ""

	function modal(kind) {
		if (Popups.modal === kind) {
			Popups.closeModal();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.openModal(kind, screen));
	}

	function runShell(id, value) {
		const action = root.shellActions.find(a => a.id === id);
		if (action) action.run(value);
	}

	// niri's: `niri msg action <name>`
	readonly property var niriActions: [
		{ id: "toggle-overview", label: "Overview", icon: "view_grid_outline", group: "Windows" },
		{ id: "focus-workspace-down", label: "Workspace below", icon: "arrow_down", group: "Workspaces" },
		{ id: "focus-workspace-up", label: "Workspace above", icon: "arrow_up", group: "Workspaces" },
		{ id: "move-column-to-workspace-down", label: "Window to the workspace below", icon: "arrow_down_bold", group: "Workspaces" },
		{ id: "move-column-to-workspace-up", label: "Window to the workspace above", icon: "arrow_up_bold", group: "Workspaces" },
		{ id: "focus-workspace-previous", label: "Last workspace", icon: "swap_vertical", group: "Workspaces" },
		{ id: "focus-column-left", label: "Window on the left", icon: "arrow_left", group: "Windows" },
		{ id: "focus-column-right", label: "Window on the right", icon: "arrow_right", group: "Windows" },
		{ id: "move-column-left", label: "Move the window left", icon: "arrow_left_bold", group: "Windows" },
		{ id: "move-column-right", label: "Move the window right", icon: "arrow_right_bold", group: "Windows" },
		{ id: "focus-monitor-next", label: "Next monitor", icon: "monitor_multiple", group: "Windows" },
		{ id: "maximize-column", label: "Maximize the column", icon: "arrow_expand_horizontal", group: "Windows" },
		{ id: "fullscreen-window", label: "Fullscreen", icon: "fullscreen", group: "Windows" },
		{ id: "toggle-window-floating", label: "Float / tile", icon: "picture_in_picture_top_right", group: "Windows" },
		{ id: "switch-preset-column-width", label: "Next column width", icon: "arrow_split_vertical", group: "Windows" },
		{ id: "center-column", label: "Center the column", icon: "format_horizontal_align_center", group: "Windows" },
		{ id: "close-window", label: "Close the window", icon: "close", group: "Windows" },
		{ id: "toggle-column-tabbed-display", label: "Tabs in the column", icon: "tab", group: "Windows" }
	]

	readonly property var mouseActions: [
		{ id: "dpi-cycle", label: "Next DPI stop", icon: "speedometer", detail: "Through the stops set under Pointer" },
		{ id: "dpi-shift", label: "Precision while held", icon: "crosshairs", detail: "Slower pointer while the button is down", lasting: true },
		{ id: "dpi-up", label: "Faster pointer", icon: "speedometer" },
		{ id: "dpi-down", label: "Slower pointer", icon: "speedometer_slow" },
		{ id: "ratchet", label: "Ratchet / free spin", icon: "cog_outline", detail: "What the SmartShift button does" },
		{ id: "smartshift", label: "SmartShift on / off", icon: "cog_transfer" },
		{ id: "haptic", label: "Haptic pulse", icon: "vibrate" }
	]

	readonly property var waveforms: ["SHARP STATE CHANGE", "DAMP STATE CHANGE", "SHARP COLLISION", "DAMP COLLISION", "SUBTLE COLLISION", "WHISPER COLLISION", "HAPPY ALERT", "ANGRY ALERT", "COMPLETED", "SQUARE", "WAVE", "FIREWORK", "MAD", "KNOCK", "JINGLE", "RINGING"]

	// what a control does when no rule takes it
	function nativeLabel(control) {
		return ({ middle: "Middle click", back: "Back", forward: "Forward", shift: "Ratchet / free spin", gesture: "Nothing", haptic: "Nothing", thumb: "Scroll sideways" })[control] ?? "Nothing";
	}

	// an action as words and a glyph
	function describe(action, control) {
		if (!action) return { label: root.nativeLabel(control), icon: "", plain: true };
		switch (action.kind) {
		case "default":
			return { label: root.nativeLabel(control), icon: "", plain: true };
		case "none":
			return { label: "Nothing", icon: "cancel", plain: false };
		case "shell": {
			if (action.id === "launcher-query") return { label: `Launcher: ${String(action.value ?? "").trim() || "…"}`, icon: "magnify" };
			if (action.id === "profile") {
				const p = root.profiles.find(x => x.id === action.value);
				return { label: `Profile: ${p?.name ?? action.value}`, icon: p?.icon ?? "account_switch_outline" };
			}
			const a = root.shellActions.find(x => x.id === action.id);
			return { label: a?.label ?? action.id, icon: a?.icon ?? "flash" };
		}
		case "niri": {
			const a = root.niriActions.find(x => x.id === action.action);
			return { label: a?.label ?? action.action, icon: a?.icon ?? "view_column_outline" };
		}
		case "mouse": {
			const a = root.mouseActions.find(x => x.id === action.op);
			let label = a?.label ?? action.op;
			if (action.op === "haptic") label = `Haptic: ${String(action.value || "SUBTLE COLLISION").toLowerCase()}`;
			if (action.op === "dpi-shift" && action.value) label = `Precision (${action.value} DPI)`;
			return { label, icon: a?.icon ?? "mouse" };
		}
		case "keys":
			return { label: action.label || (action.keys ?? []).map(k => k.length === 1 ? k.toUpperCase() : k.charAt(0).toUpperCase() + k.slice(1)).join(" + "), icon: "keyboard" };
		case "button":
			return { label: `${({ left: "Left", right: "Right", middle: "Middle", back: "Back", forward: "Forward" })[action.button] ?? action.button} click`, icon: "mouse" };
		case "scroll":
			return { label: `Scroll ${action.dir}`, icon: ({ up: "arrow_up", down: "arrow_down", left: "arrow_left", right: "arrow_right" })[action.dir] ?? "arrow_down" };
		case "command":
			return { label: action.label || String(action.command ?? "").split("/").pop(), icon: "console" };
		}
		return { label: "?", icon: "help_circle_outline" };
	}
}
