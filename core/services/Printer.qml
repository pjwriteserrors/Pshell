pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The 3D printer (an Anycubic Kobra S1 in LAN mode) through
// scripts/printer/printer.py: what it does, the slots of its ACE, and the
// jobs – G-code that OrcaSlicer exported into the inbox, each moved into a
// folder of its own and rendered layer by layer for the panel. A new job
// opens the panel; it prints once a slot is picked for each filament.
// Where the printer is and the folders are kept in printer.json.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("printer")
	// the layer on the nozzle, in the pictures as well (scripts/printer/gcode.py HOT)
	readonly property color hot: "#ff8a30"

	property string address: ""
	property string inbox: "~/Prints/inbox"
	property string jobsDir: "~/Prints/jobs"
	// what the printer does before a print: { leveling, flow, vibration }
	property var options: ({ leveling: true, flow: false, vibration: false })
	property bool loaded: false
	readonly property bool configured: root.address !== ""

	property bool online: false
	property string error: ""
	property string name: "Printer"
	property string firmware: ""
	// "free" | "busy"
	property string state: ""
	property var temps: ({})
	// the job on the printer: { progress, curr_layer, total_layers, remain_time (min), filename, state, pause }
	property var project: null
	property var boxes: []
	readonly property var slots: root.boxes.reduce((all, box) => all.concat(box.slots), [])

	// newest first: { id, name, file, added, status, meta, frames, marks, preview, remote, rendering }
	property var jobs: []
	// id → { done, total } while a preview renders
	property var renders: ({})
	property var uploads: ({})
	// the job the panel shows; a new one takes it over
	property string selected: ""

	readonly property bool printing: root.project !== null && !["finished", "stoped", "canceled"].includes(String(root.project.state ?? ""))
	readonly property bool paused: root.printing && Number(root.project.pause ?? 0) === 1
	readonly property real progress: root.printing ? Number(root.project.progress ?? 0) / 100 : 0
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
		finished: "Finished",
		updated: "Printing"
	})
	readonly property string status: {
		if (!root.configured) return "Not set up";
		if (!root.online) return "Offline";
		if (root.printing) return root.stateWords[root.project.state] ?? "Printing";
		return root.state === "busy" ? "Busy" : "Ready";
	}

	// a job's name without what the slicer adds: "Hanger+(Tape)_PLA_0.2_43m37s.gcode" → "Hanger (Tape)"
	function title(job) {
		const name = String(job?.name ?? "").replace(/\.gcode$/i, "").replace(/_(PLA|PETG|ABS|ASA|TPU|PA|PC)[^_]*_[\d.]+_(\d+[dhms])+$/i, "");
		return name.replace(/[+_]/g, " ").replace(/\s+/g, " ").trim();
	}

	function job(id) {
		return root.jobs.find(entry => entry.id === id) ?? null;
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
		settings.setText(JSON.stringify({ address: root.address, inbox: root.inbox, jobs: root.jobsDir, options: root.options }, null, "\t") + "\n");
	}

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

	// the picture of a job at a layer (1-based, as the printer counts)
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
		return hours > 0 ? `${hours} h ${total % 60} min` : `${total} min`;
	}

	function openPanel() {
		Popups.withFocusedScreen(screen => Popups.open("printer", screen));
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
				cache: `${Paths.cache}/printer`
			}) + "\n");
			break;
		case "conn":
			root.online = !!data.online;
			root.error = data.error ?? "";
			if (data.name) root.name = data.name;
			break;
		case "status":
			if (data.temps) root.temps = Object.assign({}, root.temps, data.temps);
			if (data.state !== undefined) {
				root.state = data.state;
				root.firmware = data.firmware ?? root.firmware;
				root.project = data.project ?? null;
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
		case "ace":
			root.boxes = data.boxes ?? [];
			break;
		case "jobs":
			root.jobs = data.jobs ?? [];
			if (root.selected !== "" && !root.job(root.selected)) root.selected = "";
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
			root.selected = data.id;
			root.openPanel();
			break;
		case "started":
			Notifs.pushInternal("done", "Print sent", root.job(data.id)?.name ?? "", { icon: "printer_3d" });
			break;
		case "answer":
			if (data.code && data.code !== 200)
				Notifs.pushInternal("error", "Printer", `${data.action}: ${data.msg || data.code}`, { icon: "printer_3d" });
			break;
		case "error":
			if (data.what === "print" || data.what === "render" || data.what === "inbox")
				Notifs.pushInternal("error", data.what === "print" ? "Print failed" : "Printer", data.msg ?? "", { icon: "printer_3d" });
			break;
		}
	}

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
			if (daemon.running === false && root.enabled && root.configured) revive.restart();
		}
	}

	// a daemon that died comes back; a new address means a new one
	onAddressChanged: if (daemon.running) daemon.running = false
	Timer {
		id: revive

		interval: 4000
		onTriggered: if (root.enabled && root.configured && !daemon.running) daemon.running = true
	}
}
