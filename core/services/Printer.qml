pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The 3D printer (an Anycubic Kobra S1 in LAN mode) through
// scripts/printer/printer.py: what it does, the slots of its ACE, its light
// and camera, and the jobs – G-code that OrcaSlicer exported into the inbox,
// each moved into a folder of its own and turned into a 3D part for the
// panel. A new job opens the panel; it prints once a slot is picked for each
// filament. The prints that ended make the statistics.
// Where the printer is, the folders and how the panel shows are kept in
// printer.json; the prints that ended in printer-history.json.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("printer")
	// the layer on the nozzle, in the 3D part and in the pictures alike
	readonly property color hot: "#ff8a30"

	property string address: ""
	property string inbox: "~/Prints/inbox"
	property string jobsDir: "~/Prints/jobs"
	// what the printer does before a print: { leveling, flow, vibration }
	property var options: ({ leveling: true, flow: false, vibration: false })
	property bool loaded: false
	readonly property bool configured: root.address !== ""

	// ── surface: a panel under the bar, or a window of its own ───────────
	property bool windowed: false
	property bool windowOpen: false
	readonly property bool shown: root.windowed ? root.windowOpen : Popups.current === "printer"
	// "print" | "ace" | "stats"
	property string tab: "print"

	// ── the printer ───────────────────────────────────────────────────────
	property bool online: false
	property string error: ""
	property string name: "Printer"
	property string firmware: ""
	// "free" | "busy"
	property string state: ""
	property var temps: ({})
	// the job on the printer: { progress, curr_layer, total_layers, remain_time (min), print_time (min), filename, state, pause }
	property var project: null
	property var lastProject: null
	// 1 silent · 2 standard · 3 sport
	property int speed: 2
	property int fan: 0
	property bool light: false
	property string cameraUrl: ""
	property bool camera: false
	property var boxes: []
	readonly property var slots: root.boxes.reduce((all, box) => all.concat(box.slots), [])
	readonly property var ace: root.boxes.length > 0 ? root.boxes[0] : null
	readonly property bool drying: Number(root.ace?.drying?.status ?? 0) === 1

	// the last ten minutes of temperatures, one sample each 5 s
	property var nozzleLog: []
	property var bedLog: []

	// ── jobs and history ──────────────────────────────────────────────────
	// newest first: { id, name, file, added, status, meta, shape, frames, marks, preview, remote, rendering }
	property var jobs: []
	// id → { done, total } while a preview renders
	property var renders: ({})
	property var uploads: ({})
	// the job the panel shows; a new one takes it over
	property string selected: ""
	// oldest first: { name, job, ended, minutes, result, progress, layers, grams, filaments }
	property var history: []

	readonly property var ended: ["finished", "stoped", "stopped", "canceled", "failed"]
	readonly property bool printing: root.project !== null && !root.ended.includes(String(root.project.state ?? ""))
	readonly property bool paused: root.printing && (Number(root.project.pause ?? 0) === 1 || root.project.state === "paused")
	readonly property real progress: root.printing ? Number(root.project.progress ?? 0) / 100 : 0
	readonly property int layer: root.printing ? Number(root.project.curr_layer ?? 0) : 0
	readonly property int layers: root.printing ? Number(root.project.total_layers ?? 0) : 0
	readonly property real secondsLeft: root.printing ? Number(root.project.remain_time ?? 0) * 60 : 0
	readonly property var printingJob: root.printing ? (root.jobs.find(job => job.remote && job.remote === root.project.filename) ?? null) : null

	readonly property var stateWords: ({
		preheating: "Heating up",
		auto_leveling: "Levelling the bed",
		vibrating: "Measuring vibration",
		flow_calibrating: "Calibrating flow",
		printing: "Printing",
		pausing: "Pausing",
		paused: "Paused",
		resuming: "Resuming",
		resumed: "Printing",
		stopping: "Stopping",
		stoped: "Stopped",
		failed: "Failed",
		finished: "Finished",
		updated: "Printing"
	})
	readonly property string status: {
		if (!root.configured) return "Not set up";
		if (!root.online) return "Offline";
		if (root.printing) return root.stateWords[root.project.state] ?? "Printing";
		return root.state === "busy" ? "Busy" : "Ready";
	}
	readonly property var speeds: [
		{ value: "1", label: "Silent", icon: "volume_low" },
		{ value: "2", label: "Standard", icon: "speedometer_medium" },
		{ value: "3", label: "Sport", icon: "speedometer" }
	]
	// what the ACE dries at: material, °C, minutes
	readonly property var dryPresets: [
		{ label: "PLA", temp: 45, minutes: 240 },
		{ label: "PETG", temp: 55, minutes: 360 },
		{ label: "TPU", temp: 50, minutes: 360 },
		{ label: "ABS", temp: 60, minutes: 360 }
	]

	// ── statistics ────────────────────────────────────────────────────────
	readonly property var stats: {
		const items = root.history;
		const done = items.filter(item => item.result === "finished");
		const minutes = items.reduce((sum, item) => sum + Number(item.minutes || 0), 0);
		const grams = items.reduce((sum, item) => sum + Number(item.grams || 0), 0);
		// grams by colour and material, the biggest first
		const byColour = {};
		for (const item of items)
			for (const filament of item.filaments ?? []) {
				const key = `${(filament.color ?? []).join(",")}|${filament.type ?? ""}`;
				byColour[key] = byColour[key] ?? { color: filament.color, type: filament.type, grams: 0 };
				byColour[key].grams += Number(filament.grams || 0);
			}
		const colours = Object.values(byColour).filter(entry => entry.grams > 0).sort((a, b) => b.grams - a.grams);
		// the last fourteen days, oldest first
		const days = [];
		const today = new Date();
		today.setHours(0, 0, 0, 0);
		for (let i = 13; i >= 0; i -= 1) {
			const start = today.getTime() - i * 86400000;
			const those = items.filter(item => item.ended >= start && item.ended < start + 86400000);
			days.push({ start, count: those.length, minutes: those.reduce((sum, item) => sum + Number(item.minutes || 0), 0), failed: those.filter(item => item.result !== "finished").length });
		}
		const longest = items.reduce((best, item) => Number(item.minutes || 0) > Number(best?.minutes ?? -1) ? item : best, null);
		return {
			count: items.length,
			finished: done.length,
			rate: items.length > 0 ? done.length / items.length : 0,
			minutes,
			grams,
			colours,
			days,
			longest,
			average: done.length > 0 ? done.reduce((sum, item) => sum + Number(item.minutes || 0), 0) / done.length : 0
		};
	}

	function job(id) {
		return root.jobs.find(entry => entry.id === id) ?? null;
	}

	// a job's name without what the slicer adds: "Hanger+(Tape)_PLA_0.2_43m37s.gcode" → "Hanger (Tape)"
	function title(job) {
		return root.nameOf(job?.name ?? "");
	}

	function nameOf(file) {
		const name = String(file ?? "").replace(/\.gcode(\.3mf)?$/i, "").replace(/_(PLA|PETG|ABS|ASA|TPU|PA|PC)[^_]*_[\d.]+_(\d+[dhms])+$/i, "");
		return name.replace(/[+_]/g, " ").replace(/\s+/g, " ").trim();
	}

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	function pause() {
		root.send({ op: "pause" });
	}

	function resume() {
		root.send({ op: "resume" });
	}

	function stop() {
		root.send({ op: "stop" });
	}

	function setSpeed(mode) {
		root.speed = mode;
		root.send({ op: "speed", mode });
	}

	function setLight(on) {
		root.light = on;
		root.send({ op: "light", on });
	}

	// the printer streams only while asked to; the feed window follows
	function setCamera(on) {
		root.camera = on;
		root.send({ op: "camera", on });
	}

	function dry(preset) {
		root.send({ op: "dry", on: true, temp: preset.temp, minutes: preset.minutes });
	}

	function stopDrying() {
		root.send({ op: "dry", on: false });
	}

	function forget(id) {
		if (root.selected === id) root.selected = "";
		root.send({ op: "forget", id });
	}

	// mapping: [{ tool, slot }] – one ACE slot for each filament of the file
	function start(id, mapping) {
		root.send({ op: "print", id, mapping, settings: root.options });
	}

	function setOption(key, value) {
		const next = Object.assign({}, root.options);
		next[key] = value;
		root.options = next;
		root.save();
	}

	function setAddress(address) {
		root.address = String(address || "").trim();
		root.save();
	}

	function save() {
		settings.setText(JSON.stringify({ address: root.address, inbox: root.inbox, jobs: root.jobsDir, options: root.options, windowed: root.windowed }, null, "\t") + "\n");
	}

	// ── surface ───────────────────────────────────────────────────────────
	function open() {
		if (!root.enabled) return;
		if (root.windowed) root.windowOpen = true;
		else Popups.withFocusedScreen(screen => Popups.open("printer", screen));
	}

	function close() {
		if (root.windowed) root.windowOpen = false;
		else if (Popups.current === "printer") Popups.close();
	}

	function toggle() {
		if (root.shown) root.close();
		else root.open();
	}

	function show(id) {
		root.selected = id;
		root.tab = "print";
		root.open();
	}

	function popOut() {
		if (Popups.current === "printer") Popups.close();
		root.windowed = true;
		root.windowOpen = true;
		root.save();
	}

	function dock() {
		root.windowOpen = false;
		root.windowed = false;
		root.save();
		root.open();
	}

	// ── helpers for the views ─────────────────────────────────────────────
	// the slot that fits a filament best: the same material first, then the nearest colour
	function suggest(filament, taken) {
		const loaded = root.slots.filter(slot => slot.type !== "");
		if (loaded.length === 0) return -1;
		const material = String(filament.type || "").toLowerCase();
		const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
		let best = -1;
		let bestScore = Infinity;
		for (const slot of loaded) {
			const type = String(slot.type).toLowerCase();
			const same = type === material ? 0 : (type.startsWith(material) || material.startsWith(type) ? 120 : 400);
			const score = same + distance(slot.color, filament.color) + ((taken ?? []).includes(slot.slot) ? 60 : 0);
			if (score < bestScore) {
				bestScore = score;
				best = slot.slot;
			}
		}
		return best;
	}

	function suggestAll(job) {
		const out = [];
		for (const filament of job?.meta?.filaments ?? []) {
			const slot = root.suggest(filament, out.map(pick => pick.slot));
			out.push({ tool: filament.tool, slot });
		}
		return out;
	}

	function slot(index) {
		return root.slots.find(slot => slot.slot === index) ?? null;
	}

	// the picture of a layer (1-based, as the printer counts) from above
	function frameIndex(job, layer) {
		const marks = job?.marks ?? [];
		if (marks.length === 0) return -1;
		const wanted = Math.max(0, layer - 1);
		let low = 0;
		let high = marks.length - 1;
		while (low < high) {
			const middle = (low + high) >> 1;
			if (marks[middle] >= wanted) high = middle;
			else low = middle + 1;
		}
		return low;
	}

	function frameUrl(job, kind, index) {
		if (!job || index < 0) return "";
		return `file://${job.preview}/${kind}-${String(index).padStart(3, "0")}.png`;
	}

	function rgb(color) {
		const c = color ?? [128, 128, 128];
		return Qt.rgba(c[0] / 255, c[1] / 255, c[2] / 255, 1);
	}

	function duration(seconds) {
		const total = Math.max(0, Math.round(seconds / 60));
		const hours = Math.floor(total / 60);
		return hours > 0 ? `${hours} h ${String(total % 60).padStart(2, "0")} min` : `${total} min`;
	}

	function grams(value) {
		return value >= 1000 ? `${(value / 1000).toFixed(2)} kg` : `${Math.round(value)} g`;
	}

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.ev) {
		case "ready":
			daemon.write(JSON.stringify({
				address: root.address,
				inbox: root.inbox,
				jobs: root.jobsDir,
				cache: `${Paths.cache}/printer`,
				history: Paths.stateFile("printer-history.json")
			}) + "\n");
			break;
		case "conn":
			root.online = !!data.online;
			root.error = data.error ?? "";
			if (data.name) root.name = data.name;
			if (data.camera) root.cameraUrl = data.camera;
			break;
		case "status":
			if (data.temps) root.temps = Object.assign({}, root.temps, data.temps);
			if (data.state !== undefined) {
				root.state = data.state;
				root.firmware = data.firmware ?? root.firmware;
				root.project = data.project ?? null;
				if (data.last) root.lastProject = data.last;
				if (data.speed) root.speed = data.speed;
				if (data.fan !== undefined && data.fan !== null) root.fan = data.fan;
			}
			break;
		case "progress":
			if (root.project) {
				const next = Object.assign({}, root.project);
				for (const key of ["progress", "curr_layer", "total_layers", "remain_time", "print_time", "filename"])
					if (data[key] !== undefined && data[key] !== null) next[key] = data[key];
				root.project = next;
			}
			break;
		case "light":
			root.light = !!data.on;
			break;
		case "ace":
			root.boxes = data.boxes ?? [];
			break;
		case "jobs":
			root.jobs = data.jobs ?? [];
			if (root.selected !== "" && !root.job(root.selected)) root.selected = "";
			break;
		case "history":
			root.history = data.items ?? [];
			break;
		case "render": {
			const next = Object.assign({}, root.renders);
			if (data.done >= data.total) delete next[data.id];
			else next[data.id] = { done: data.done, total: data.total };
			root.renders = next;
			break;
		}
		case "upload": {
			const next = Object.assign({}, root.uploads);
			if (data.sent >= data.size) delete next[data.id];
			else next[data.id] = { sent: data.sent, size: data.size };
			root.uploads = next;
			break;
		}
		case "arrived":
			root.show(data.id);
			break;
		case "started":
			Notifs.pushInternal("done", "Print sent", root.title(root.job(data.id)), { icon: "printer_3d" });
			break;
		case "ended": {
			const name = root.nameOf(data.name);
			const actions = [{ label: "Show", icon: "printer_3d", run: () => root.open() }];
			if (data.result === "finished")
				Notifs.pushInternal("done", "Print finished", `${name} · ${root.duration(Number(data.minutes) * 60)}`, { icon: "printer_3d", sound: "taskDone", actions, duration: 15000 });
			else
				Notifs.pushInternal("error", data.result === "failed" ? "Print failed" : "Print stopped", `${name} · at ${data.progress} %`, { icon: "printer_3d", actions, duration: 15000 });
			break;
		}
		case "answer":
			if (data.code && data.code !== 200)
				Notifs.pushInternal("error", "Printer", `${data.action}: ${data.msg || data.code}`, { icon: "printer_3d" });
			break;
		case "error":
			if (["print", "render", "inbox", "light", "camera", "dry", "speed", "pause", "resume", "stop"].includes(data.what))
				Notifs.pushInternal("error", data.what === "print" ? "Print failed" : "Printer", data.msg ?? "", { icon: "printer_3d" });
			break;
		}
	}

	// the feed closes when the printer goes away
	onOnlineChanged: if (!root.online) root.camera = false

	FileView {
		id: settings

		path: Paths.stateFile("printer.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.address = String(data.address ?? "");
				if (data.inbox) root.inbox = data.inbox;
				if (data.jobs) root.jobsDir = data.jobs;
				if (data.options && typeof data.options === "object") root.options = Object.assign({}, root.options, data.options);
				root.windowed = data.windowed === true;
			} catch (error) {}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	Process {
		id: daemon

		running: root.enabled && root.loaded && root.configured
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/printer/printer.py`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: {
			root.online = false;
			if (root.enabled && root.configured) revive.restart();
		}
	}

	// a daemon that died comes back; a new address means a new one
	onAddressChanged: if (daemon.running) daemon.running = false
	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && root.configured && !daemon.running) daemon.running = true
	}

	Timer {
		interval: 5000
		repeat: true
		running: root.online
		onTriggered: {
			root.nozzleLog = root.nozzleLog.concat([Number(root.temps.curr_nozzle_temp ?? 0)]).slice(-120);
			root.bedLog = root.bedLog.concat([Number(root.temps.curr_hotbed_temp ?? 0)]).slice(-120);
		}
	}
}
