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
		file.setText(JSON.stringify(root.config, null, "\t") + "\n");
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
					options: data.options && typeof data.options === "object" ? data.options : {}
				};
			} catch (error) {
				console.warn("Mouse: mouse.json is not valid JSON");
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
			root.devices = root.devices.map(d => Object.assign({}, d, { online: false }));
			if (root.enabled) revive.restart();
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
		{ id: "mic-mute", label: "Mute the microphone", icon: "microphone_off", group: "Media", run: () => Audio.toggleMicMute() }
	]

	// as the keybinds open them (core/Ipc.qml): on the focused screen, again closes
	function drawer(id, page) {
		if (Popups.current === id && (page === undefined || Popups.page === page)) {
			Popups.close();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.open(id, screen, page));
	}

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
