pragma Singleton

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io

// Short, quiet sounds for what happens: the buttons and shortcuts of the
// shell (`buttons`) and what the system does on its own (`system`) – a
// notification, a USB stick, a monitor, an error. Features name the moment
// (`Sounds.play("copied")`, or Haptics.play, which hands every moment on);
// the table below picks the file from assets/sounds (scripts/build_sounds.py).
//
// What plays is set on the Sounds page of the settings: everything, only one
// of the two kinds, or nothing, how loud, and each moment on its own
// (sounds.json). Sounds never pile up: a moment of a higher rank cuts what
// still plays below it and keeps the lower ones quiet for a moment, so a
// notification is all that is heard when a device brings one along.
Singleton {
	id: root

	// rank: 0 a press, 1 a surface, 2 the result of an action, 3 the system,
	// 4 something went wrong, 5 a notification
	readonly property var moments: [
		{ id: "click", kind: "buttons", file: "tick", rank: 0, icon: "cursor_default_click", title: "Buttons", subtitle: "A button, a tile or a row is pressed" },
		{ id: "toggleOn", kind: "buttons", file: "tick-up", rank: 0, icon: "toggle_switch", title: "Switch on", subtitle: "A switch or a quick setting goes on" },
		{ id: "toggleOff", kind: "buttons", file: "tick-down", rank: 0, icon: "toggle_switch_off", title: "Switch off", subtitle: "A switch or a quick setting goes off" },
		{ id: "select", kind: "buttons", file: "tap", rank: 0, icon: "gesture_tap", title: "Choice", subtitle: "One of a few options is picked" },
		{ id: "open", kind: "buttons", file: "pop-up", rank: 1, icon: "arrow_expand", title: "Panel opens", subtitle: "Launcher, the panels under the bar and the shell's windows" },
		{ id: "close", kind: "buttons", file: "pop-down", rank: 1, icon: "arrow_collapse", title: "Panel closes", subtitle: "One of them goes away again" },
		{ id: "volume", kind: "buttons", file: "pop", rank: 1, icon: "volume_high", title: "Volume keys", subtitle: "Plays at the new volume, so it can be heard how loud it is", repeat: 150 },
		{ id: "workspace", kind: "buttons", file: "tap", rank: 1, icon: "view_grid_outline", title: "Workspaces", subtitle: "The focus moves to another workspace", fallback: false },
		{ id: "captured", kind: "buttons", file: "pluck-low", rank: 2, icon: "camera", title: "Screenshot", subtitle: "A shot is taken" },
		{ id: "copied", kind: "buttons", file: "pluck", rank: 2, icon: "content_copy", title: "Copied", subtitle: "A shot, a colour, a translation is copied or saved" },
		{ id: "pinned", kind: "buttons", file: "pluck", rank: 2, icon: "pin", title: "Pinned", subtitle: "A shot is pinned or something lands on a shelf" },
		{ id: "recordingStarted", kind: "buttons", file: "chime-up", rank: 2, icon: "record_rec", title: "Recording starts", subtitle: "The screen recording begins" },
		{ id: "recordingStopped", kind: "buttons", file: "chime-down", rank: 2, icon: "stop_circle_outline", title: "Recording stops", subtitle: "The recording is saved" },
		{ id: "dndOn", kind: "buttons", file: "chime-down", rank: 2, icon: "bell_off", title: "Do not disturb on", subtitle: "Notifications go quiet" },
		{ id: "dndOff", kind: "buttons", file: "chime-up", rank: 2, icon: "bell_outline", title: "Do not disturb off", subtitle: "Notifications are back" },
		{ id: "listDone", kind: "buttons", file: "ready", rank: 2, icon: "check_all", title: "List done", subtitle: "The last item of a todo list is ticked" },

		{ id: "notification", kind: "system", file: "notify", rank: 5, icon: "bell_ring", title: "Notification", subtitle: "Cuts every other sound; quiet while do not disturb is on" },
		{ id: "notificationCritical", kind: "system", file: "notify-urgent", rank: 5, icon: "bell_alert", title: "Urgent notification", subtitle: "Plays during do not disturb as well" },
		{ id: "usbIn", kind: "system", file: "connect", rank: 3, icon: "usb", title: "USB device plugged in", subtitle: "A stick, a keyboard, a phone …", repeat: 1500 },
		{ id: "usbOut", kind: "system", file: "disconnect", rank: 3, icon: "usb", title: "USB device removed", subtitle: "Pulled out or powered off", repeat: 1500 },
		{ id: "driveMounted", kind: "system", file: "ready", rank: 3, icon: "usb_flash_drive", title: "Drive ready", subtitle: "A USB stick or card is mounted and can be opened" },
		{ id: "driveUnmounted", kind: "system", file: "eject", rank: 3, icon: "eject", title: "Drive ejected", subtitle: "Unmounted – safe to pull out" },
		{ id: "displayIn", kind: "system", file: "display-on", rank: 3, icon: "monitor", title: "Monitor connected", subtitle: "A screen shows up" },
		{ id: "displayOut", kind: "system", file: "display-off", rank: 3, icon: "monitor_off", title: "Monitor disconnected", subtitle: "A screen goes away" },
		{ id: "bluetoothIn", kind: "system", file: "connect", rank: 3, icon: "bluetooth_connect", title: "Bluetooth connected", subtitle: "Headphones, a mouse, a controller …" },
		{ id: "bluetoothOut", kind: "system", file: "disconnect", rank: 3, icon: "bluetooth_off", title: "Bluetooth disconnected", subtitle: "A device drops off" },
		{ id: "phoneIn", kind: "system", file: "connect", rank: 3, icon: "cellphone", title: "Phone connected", subtitle: "The phone app is there", plugin: "phone" },
		{ id: "phoneOut", kind: "system", file: "disconnect", rank: 3, icon: "cellphone", title: "Phone gone", subtitle: "The phone app lost the shell", plugin: "phone" },
		{ id: "chargerIn", kind: "system", file: "ready", rank: 3, icon: "power_plug", title: "Charger plugged in", subtitle: "The battery charges", plugin: "battery" },
		{ id: "chargerOut", kind: "system", file: "pop-down", rank: 3, icon: "power_plug_off", title: "Charger pulled", subtitle: "Back on battery", plugin: "battery" },
		{ id: "batteryLow", kind: "system", file: "warn", rank: 4, icon: "battery_alert", title: "Battery low", subtitle: "At 15 % and again at 5 %", plugin: "battery" },
		{ id: "networkUp", kind: "system", file: "tick-up", rank: 3, icon: "wifi", title: "Online", subtitle: "The network is back", fallback: false },
		{ id: "networkDown", kind: "system", file: "tick-down", rank: 3, icon: "wifi_off", title: "Offline", subtitle: "The network is gone", fallback: false },
		{ id: "error", kind: "system", file: "error", rank: 4, icon: "alert_circle_outline", title: "Error", subtitle: "Something failed, a wrong password, niri said no" },
		{ id: "attention", kind: "system", file: "warn", rank: 4, icon: "alert", title: "Question", subtitle: "Something waits for an answer (a Bluetooth pairing …)" },
		{ id: "taskDone", kind: "system", file: "ready", rank: 3, icon: "check_all", title: "Done", subtitle: "Updates, a sent mail, a longer job that finished" },
		{ id: "download", kind: "system", file: "ready", rank: 3, icon: "download", title: "Download finished", subtitle: "The browser has the file", plugin: "downloads" },
		{ id: "reminder", kind: "system", file: "reminder", rank: 3, icon: "cup_water", title: "Reminder", subtitle: "Time to stretch, drink or rest the eyes", plugin: "breaks" },
		{ id: "locked", kind: "system", file: "lock", rank: 3, icon: "lock", title: "Locked", subtitle: "The screen locks", plugin: "lock-screen" },
		{ id: "unlocked", kind: "system", file: "unlock", rank: 3, icon: "lock_open_variant", title: "Unlocked", subtitle: "Welcome back", plugin: "lock-screen" },
		{ id: "startup", kind: "system", file: "startup", rank: 3, icon: "power", title: "Start", subtitle: "Once when the session starts, not on a reload" }
	].filter(moment => !moment.plugin || Plugins.on(moment.plugin))

	readonly property var byId: {
		const map = {};
		for (const moment of root.moments) map[moment.id] = moment;
		return map;
	}

	// other names features use for one of the moments (those of Haptics)
	readonly property var aliases: ({
		saved: "copied",
		colorPicked: "copied",
		sent: "taskDone",
		taskFailed: "error",
		wrongPassword: "error"
	})

	// ── settings (sounds.json) ─────────────────────────────────────────────
	// "all" | "buttons" | "system" | "off"
	property string mode: "all"
	property real volume: 0.6
	// while do not disturb is on, the system is quiet but for errors, urgent
	// notifications and what waits for an answer
	property bool quietDnd: true
	// moment → on, where it differs from the moment's fallback
	property var switches: ({})

	readonly property bool active: Plugins.on("sounds") && root.mode !== "off"

	function kindOn(kind) {
		return root.active && (root.mode === "all" || root.mode === kind);
	}

	function fallback(id) {
		return root.byId[id]?.fallback !== false;
	}

	function enabled(id) {
		const switched = root.switches[id];
		return switched !== undefined ? switched === true : root.fallback(id);
	}

	// would play now, mode and switch considered
	function audible(id) {
		const moment = root.byId[id];
		return !!moment && root.kindOn(moment.kind) && root.enabled(id);
	}

	readonly property bool modified: Object.keys(root.switches).length > 0

	function setMode(mode) {
		root.mode = mode;
		root.save();
	}

	function setVolume(volume) {
		root.volume = Math.max(0, Math.min(1, volume));
		saving.restart();
	}

	function setQuietDnd(on) {
		root.quietDnd = !!on;
		root.save();
	}

	function setEnabled(id, on) {
		const next = Object.assign({}, root.switches);
		if (!!on === root.fallback(id)) delete next[id];
		else next[id] = !!on;
		root.switches = next;
		root.save();
	}

	function resetSwitches() {
		root.switches = {};
		root.save();
	}

	function save() {
		file.setText(JSON.stringify({ mode: root.mode, volume: root.volume, quietDnd: root.quietDnd, switches: root.switches }, null, "\t") + "\n");
	}

	function load(text) {
		try {
			const data = JSON.parse(text || "{}");
			root.mode = ["all", "buttons", "system", "off"].includes(data.mode) ? data.mode : "all";
			root.volume = typeof data.volume === "number" ? Math.max(0, Math.min(1, data.volume)) : 0.6;
			root.quietDnd = data.quietDnd !== false;
			root.switches = data.switches && typeof data.switches === "object" && !Array.isArray(data.switches) ? data.switches : {};
		} catch (error) {
			console.warn("Sounds: sounds.json is not valid JSON");
		}
	}

	// a slider writes once it rests
	Timer {
		id: saving

		interval: 400
		onTriggered: root.save()
	}

	FileView {
		id: file

		path: Paths.stateFile("sounds.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.load(text())
	}

	// ── playing ────────────────────────────────────────────────────────────
	function play(event) {
		if (!root.active) return;
		const id = root.aliases[event] ?? event;
		const moment = root.byId[id];
		if (!moment || !root.audible(id)) return;
		if (moment.kind === "system" && root.quietDnd && Notifs.dnd && id !== "notificationCritical" && moment.rank < 4) return;
		root.sound(moment);
	}

	// the moment's sound whatever the settings say (the settings page)
	function preview(id) {
		const moment = root.byId[id];
		if (moment) root.sound(moment, true);
	}

	// the last sound: what plays, and since when it keeps lower ones quiet
	property var last: ({ rank: -1, at: 0, effect: null })
	property var heard: ({})

	function hold(rank) {
		return rank >= 5 ? 1200 : (rank >= 3 ? 400 : (rank === 2 ? 250 : 80));
	}

	function sound(moment, forced) {
		const effect = root.effects[moment.file];
		if (!effect) return;
		const now = Date.now();
		if (!forced) {
			// the same moment again right away (a hub with three devices, two
			// features reporting one error)
			if (now - (root.heard[moment.id] ?? 0) < (moment.repeat ?? 120)) return;
			if (now - root.last.at < root.hold(root.last.rank) && root.last.rank > moment.rank) return;
		}
		if (root.last.effect && root.last.effect !== effect && root.last.rank < moment.rank && root.last.effect.playing) root.last.effect.stop();
		const heard = Object.assign({}, root.heard);
		heard[moment.id] = now;
		root.heard = heard;
		root.last = { rank: moment.rank, at: now, effect: effect };
		effect.stop();
		effect.play();
	}

	// a loudness that sounds even along the slider
	readonly property real gain: Math.pow(root.volume, 1.6)

	// file name → SoundEffect, one each, loaded once
	property var effects: ({})

	Instantiator {
		model: {
			const files = [];
			for (const moment of root.moments)
				if (!files.includes(moment.file)) files.push(moment.file);
			return files;
		}

		delegate: SoundEffect {
			required property string modelData

			source: `file://${Paths.assets}/sounds/${modelData}.wav`
			volume: root.gain
		}

		onObjectAdded: (index, object) => {
			const effects = Object.assign({}, root.effects);
			effects[object.modelData] = object;
			root.effects = effects;
		}
		onObjectRemoved: (index, object) => {
			const effects = Object.assign({}, root.effects);
			delete effects[object.modelData];
			root.effects = effects;
		}
	}

	// ── what the system does on its own ─────────────────────────────────────
	// The watchers below learn how things are for a few seconds after the
	// shell starts before they say anything, so a reload is silent.
	property bool settled: false

	Timer {
		running: true
		interval: 5000
		onTriggered: root.settled = true
	}

	// A list of names that changed: what came, what went
	function compare(before, after, cameId, wentId) {
		if (!root.settled || before === after) return;
		const old = before === "" ? [] : before.split("\n");
		const now = after === "" ? [] : after.split("\n");
		if (now.some(name => !old.includes(name))) root.play(cameId);
		else if (old.some(name => !now.includes(name))) root.play(wentId);
	}

	// monitors
	readonly property string screenNames: Quickshell.screens.map(screen => String(screen.name)).sort().join("\n")
	property string knownScreens: root.screenNames
	onScreenNamesChanged: {
		root.compare(root.knownScreens, root.screenNames, "displayIn", "displayOut");
		root.knownScreens = root.screenNames;
	}

	// Bluetooth devices
	readonly property string bluetoothDevices: Plugins.on("bluetooth") ? Bluetooth.connected.map(device => device.address).sort().join("\n") : ""
	property string knownBluetooth: root.bluetoothDevices
	onBluetoothDevicesChanged: {
		if (Plugins.on("bluetooth")) root.compare(root.knownBluetooth, root.bluetoothDevices, "bluetoothIn", "bluetoothOut");
		root.knownBluetooth = root.bluetoothDevices;
	}

	// the network
	readonly property bool online: Plugins.on("network") && Network.type !== "offline"
	onOnlineChanged: if (root.settled && Plugins.on("network")) root.play(root.online ? "networkUp" : "networkDown")

	// niri, or the key binds, said no to a change of the settings window
	readonly property bool refused: Plugins.on("niri-settings") && (NiriSettings.error !== "" || Keybinds.error !== "")
	onRefusedChanged: if (root.refused) root.play("error")

	// the lock screen
	readonly property bool locked: Session.locked
	onLockedChanged: if (root.settled) root.play(root.locked ? "locked" : "unlocked")

	// the phone app
	readonly property bool phone: Plugins.on("phone") && Phone.connected
	onPhoneChanged: if (root.settled) root.play(root.phone ? "phoneIn" : "phoneOut")

	// the charger and the battery
	readonly property string battery: Plugins.on("battery") ? SysStats.batteryStatus : ""
	readonly property bool charging: root.battery !== "" && root.battery !== "Discharging"
	onChargingChanged: if (root.settled && root.battery !== "") root.play(root.charging ? "chargerIn" : "chargerOut")
	readonly property int batteryStep: {
		if (root.battery !== "Discharging" || SysStats.batteryPercent < 0) return 0;
		return SysStats.batteryPercent <= 5 ? 2 : (SysStats.batteryPercent <= 15 ? 1 : 0);
	}
	onBatteryStepChanged: if (root.settled && root.batteryStep > 0) root.play("batteryLow")

	// the focused workspace
	readonly property string workspace: {
		const focused = Niri.workspaces.find(ws => ws.focused);
		return focused ? String(focused.id) : "";
	}
	onWorkspaceChanged: if (root.settled && root.workspace !== "") root.play("workspace")

	// panels and modals; reminders that open one bring their own sound
	readonly property string surface: Popups.modal !== "" ? `modal:${Popups.modal}` : (Popups.current !== "" ? Popups.current : "")
	property string knownSurface: ""
	onSurfaceChanged: {
		const before = root.knownSurface;
		root.knownSurface = root.surface;
		if (!root.settled) return;
		const quiet = ["modal:eyerest", "modal:stretch"];
		if (quiet.includes(before) || quiet.includes(root.surface)) return;
		if (before === "" && root.surface !== "") root.play("open");
		else if (before !== "" && root.surface === "") root.play("close");
	}

	// USB devices: udev tells about every one that comes or goes, a line
	// each ("UDEV [12.3] add /devices/…/1-2 (usb)"); only whole devices, not
	// their interfaces, and what a hub brings along counts once (`repeat`)
	Process {
		running: root.kindOn("system") && (root.enabled("usbIn") || root.enabled("usbOut"))
		command: ["udevadm", "monitor", "--udev", "--subsystem-match=usb/usb_device"]
		stdout: SplitParser {
			onRead: line => {
				const action = (String(line).match(/^UDEV\s+\[[^\]]*\]\s+(\w+)/) ?? [])[1];
				if (action === "add") root.play("usbIn");
				else if (action === "remove") root.play("usbOut");
			}
		}
	}

	// drives: a removable one mounted where file managers mount them
	Process {
		running: root.kindOn("system") && (root.enabled("driveMounted") || root.enabled("driveUnmounted"))
		command: ["findmnt", "--poll", "--pairs", "--noheadings", "--output", "ACTION,SOURCE,TARGET"]
		stdout: SplitParser {
			onRead: line => {
				const field = name => (String(line).match(new RegExp(`${name}="([^"]*)"`)) ?? [])[1] ?? "";
				if (!/^\/dev\/(sd|mmcblk)/.test(field("SOURCE"))) return;
				if (!/^\/(run\/media|media|mnt)\//.test(field("TARGET"))) return;
				if (field("ACTION") === "mount") root.play("driveMounted");
				else if (field("ACTION") === "umount") root.play("driveUnmounted");
			}
		}
	}

	// once a session: the runtime directory is new after every login
	Process {
		id: greeting

		running: true
		command: ["sh", "-c", 'mkdir -p "$1" && if [ -e "$1/sounds-greeted" ]; then echo no; else touch "$1/sounds-greeted"; echo yes; fi', "sh", Paths.runtime]
		stdout: StdioCollector {
			onStreamFinished: if (String(text).trim() === "yes") greet.start()
		}
	}

	// after the effects have loaded and the screen has come up
	Timer {
		id: greet

		interval: 1500
		onTriggered: root.play("startup")
	}
}
