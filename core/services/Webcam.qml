pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Logitech Webcam C310 (plugin `webcam`). scripts/webcam/webcam.py
// finds it, puts back what is kept here whenever it comes again (plugged in,
// the PC awake) and changes it on the page's word; stream.py owns the
// picture: the page's preview, photos, RAW and the virtual camera (zoom,
// pan, a face followed, mirrored) – the real camera only open while one of
// them needs it. webcam.json:
//
//   saved:   { v4l2: {key: value}, xu: {name: value}, led: {mode, frequency}, mic: {gain, muted} }
//   view:    { zoom, cx, cy, follow, frameFace, mirror }
//   virtual: bool, size: [w, h], fps, photoDir
//   options: { preview, enhanceAi, enhanceModel }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("webcam")
	readonly property string script: `${Paths.scripts}/webcam/webcam.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false })
	property bool scanned: false
	property var frame: null           // { path, n, crop: [x, y, w, h], face, mirror }
	property var streamState: ({})    // { streaming, readers, busyBy, loopback, virtual }
	property var enhancing: ({})      // { status, step, changes, message }
	property var lastEnhance: []      // the changes the last Enhance made, for Undo
	property var models: []
	property real level: -100
	property real peak: -100
	property bool levelOn: false
	property string error: ""
	property string lastShot: ""
	signal shot(string path, string kind)

	readonly property bool online: root.device.online === true
	readonly property var controls: {
		const out = {};
		for (const c of root.device.controls ?? []) out[c.key] = c;
		return out;
	}
	readonly property var xu: root.device.xu ?? ({})
	readonly property var led: root.device.led ?? ({ state: "missing" })
	readonly property var mic: root.device.mic ?? null
	readonly property var info: root.device.info ?? ({})
	readonly property var loopback: root.device.loopback ?? ({})
	readonly property bool busyElsewhere: (root.streamState.busyBy ?? []).length > 0

	function control(key) {
		return root.controls[key] ?? null;
	}

	function value(key, fallback) {
		return root.controls[key]?.value ?? fallback;
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ saved: {}, view: {}, options: {} })
	property bool loaded: false
	readonly property var saved: root.config.saved ?? ({})
	readonly property var view: Object.assign({ zoom: 1, cx: 0.5, cy: 0.5, follow: false, frameFace: false, mirror: false }, root.config.view ?? {})
	readonly property bool virtual: root.config.virtual === true
	readonly property var size: root.config.size ?? [1280, 720]
	readonly property int fps: root.config.fps ?? 30
	readonly property string photoDir: root.config.photoDir || `${Quickshell.env("HOME")}/Pictures/Webcam`
	readonly property var options: root.config.options ?? ({})
	readonly property bool previewOn: root.options.preview ?? true
	readonly property bool enhanceAi: root.options.enhanceAi ?? false
	readonly property string enhanceModel: root.options.enhanceModel || (root.models[0]?.name ?? "")

	property bool watching: false
	onWatchingChanged: {
		root.send({ op: "watch", on: root.watching });
		root.send({ op: "preview", on: root.watching && root.previewOn });
		root.send({ op: "level", on: false });
		root.levelOn = false;
		if (root.watching) root.send({ op: "models" });
	}

	function keep(patch) {
		root.config = Object.assign({}, root.config, patch);
		saving.restart();
	}

	function keepSaved(kind, key, value) {
		const saved = Object.assign({}, root.saved);
		const part = Object.assign({}, saved[kind] ?? {});
		if (value === undefined) delete part[key];
		else part[key] = value;
		saved[kind] = part;
		root.keep({ saved });
	}

	function setOption(key, value) {
		const options = Object.assign({}, root.options);
		options[key] = value;
		root.keep({ options });
		if (key === "preview") root.send({ op: "preview", on: root.watching && value });
	}

	// ── changes ───────────────────────────────────────────────────────────
	// writes coalesce: a slider sends its latest value every 60 ms, not every step
	property var pending: ({})

	function queue(kind, key, value) {
		const pending = Object.assign({}, root.pending);
		pending[`${kind}:${key}`] = { op: "set", kind, key, value };
		root.pending = pending;
		if (!flush.running) flush.start();
	}

	Timer {
		id: flush

		interval: 60
		onTriggered: {
			const pending = root.pending;
			root.pending = {};
			for (const k in pending) root.send(pending[k]);
		}
	}

	function setControl(key, value) {
		root.keepSaved("v4l2", key, Math.round(value));
		root.queue("v4l2", key, Math.round(value));
	}

	function setXu(name, value) {
		root.keepSaved("xu", name, value);
		root.queue("xu", name, value);
	}

	// what the page shows: the kept value while it is on its way, else the camera's
	function shown(kind, key, fallback) {
		const kept = root.saved[kind]?.[key];
		if (kept !== undefined) return kept;
		if (kind === "v4l2") return root.controls[key]?.value ?? fallback;
		if (kind === "xu") return root.xu[key]?.value ?? fallback;
		return fallback;
	}

	function setLed(mode, frequency) {
		const led = { mode: mode ?? root.led.mode ?? 3, frequency: frequency ?? root.led.frequency ?? 10 };
		root.keep({ saved: Object.assign({}, root.saved, { led }) });
		root.send({ op: "set", kind: "led", key: "led", value: led });
	}

	function setMic(key, value) {
		root.keepSaved("mic", key, value);
		root.queue("mic", key, value);
	}

	function resetAll() {
		root.keep({ saved: {} });
		root.send({ op: "reset" });
	}

	function setView(patch) {
		const view = Object.assign({}, root.view, patch);
		root.config = Object.assign({}, root.config, { view });
		root.send(Object.assign({ op: "view" }, patch));
		saving.restart();
	}

	function setVirtual(on) {
		root.keep({ virtual: on });
		if (on && !root.loopback.node) root.system(["loopback", "on"]);
		root.sendConfig();
	}

	function setOutput(size, fps) {
		root.keep({ size: size ?? root.size, fps: fps ?? root.fps });
		root.sendConfig();
	}

	function photo(ofView) {
		root.send({ op: "photo", view: ofView === true });
	}

	function raw() {
		root.send({ op: "raw" });
	}

	function enhance() {
		root.enhancing = { status: "working", step: "" };
		root.send({ op: "enhance", ai: root.enhanceAi, model: root.enhanceModel });
	}

	function cancelEnhance() {
		root.enhancing = Object.assign({}, root.enhancing, { step: "Stopping …" });
		root.send({ op: "enhance-stop" });
	}

	function undoEnhance() {
		for (const c of root.lastEnhance) root.setControl(c.key, c.from);
		root.lastEnhance = [];
		root.enhancing = {};
	}

	function setLevel(on) {
		root.levelOn = on;
		root.send({ op: "level", on });
		if (!on) {
			root.level = -100;
			root.peak = -100;
		}
	}

	function useAsMicrophone() {
		root.send({ op: "default-mic" });
	}

	function system(args) {
		root.send({ op: "system", args });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	Timer {
		id: saving

		interval: 400
		onTriggered: file.setText(JSON.stringify(root.config, null, "\t") + "\n")
	}

	FileView {
		id: file

		path: Paths.stateFile("webcam.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = typeof data === "object" && data ? data : {};
			} catch (error) {
				console.warn("Webcam: webcam.json is not valid JSON");
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// ── the daemon ────────────────────────────────────────────────────────
	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function sendConfig() {
		root.send({ op: "config", saved: root.saved, view: root.view, virtual: root.virtual, size: root.size, fps: root.fps, photoDir: root.photoDir });
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
			if (data.stream) root.streamState = data.stream;
			break;
		case "frame":
			root.frame = data;
			break;
		case "stream":
			root.streamState = data;
			break;
		case "photo":
		case "raw":
			root.lastShot = data.preview ?? data.path;
			Sounds.play("saved");
			root.shot(data.path, data.event);
			break;
		case "enhance":
			root.enhancing = data;
			if (data.status === "cancelled") root.enhancing = {};
			if (data.status === "done" || data.status === "failed") {
				const changes = data.changes ?? [];
				for (const c of changes) root.keepSaved("v4l2", c.key, c.to);
				root.lastEnhance = changes;
			}
			break;
		case "models":
			root.models = data.models ?? [];
			break;
		case "level":
			root.level = data.db ?? -100;
			root.peak = data.peak ?? -100;
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
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
		onStarted: {
			root.sendConfig();
			if (root.watching) {
				root.send({ op: "watch", on: true });
				root.send({ op: "preview", on: root.previewOn });
			}
		}
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			// libjpeg's word on the padding before the camera's resync markers
			onRead: line => {
				if (!line.startsWith("Corrupt JPEG data") && !line.includes("setPreferableTarget")) console.warn(line);
			}
		}
		onExited: {
			root.device = { online: false };
			root.frame = null;
			root.streamState = {};
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
