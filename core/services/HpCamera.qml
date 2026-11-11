pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The HP HD Camera built into the ProBook (plugin `hp-camera`): a colour
// camera and an IR camera with its emitter on one USB device.
// scripts/hpcamera/hpcamera.py finds it, puts back what is kept here
// whenever it comes again (the PC awake, the camera reset) and changes it
// on the page's word; ../webcam/stream.py owns the colour picture (preview,
// photos, virtual camera), scripts/hpcamera/ir.py the IR picture and the
// face (enrol, test, the lock screen's check). hpcamera.json:
//
//   saved:   { v4l2: {key: value}, xu: {sunplusN: value}, roi: {rect, auto}, ir: {metadata} }
//   view:    { zoom, cx, cy, follow, frameFace, mirror }
//   virtual: bool, size: [w, h], fps, photoDir
//   options: { preview, irPreview, irMode, enhanceAi, enhanceModel, faceUnlock, faceTries }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("hp-camera")
	readonly property string script: `${Paths.scripts}/hpcamera/hpcamera.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false })
	property bool scanned: false
	property var frame: null           // { path, n, crop, face, mirror }
	property var irFrame: null         // { path, n, lit, dark, face }
	property var streamState: ({})     // the colour picture: { streaming, readers, busyBy, loopback, virtual }
	property var irState: ({})         // { streaming, busyBy, task, lit, dark, mode, faces, modelError }
	property var face: ({})            // the last face event: { kind, result, samples, needed, hint, score }
	property var enhancing: ({})
	property var lastEnhance: []
	property var models: []
	property string error: ""
	property string lastShot: ""
	signal shot(string path, string kind)
	signal faceResult(string result)   // a check's answer: match, nomatch, notlive, noface, nofaces, busy, offline …

	readonly property bool online: root.device.online === true
	readonly property var controls: {
		const out = {};
		for (const c of root.device.controls ?? []) out[c.key] = c;
		return out;
	}
	readonly property var xu: root.device.xu ?? ({})
	readonly property var roi: root.device.roi ?? null
	readonly property var irControls: root.device.irControls ?? null
	readonly property var info: root.device.info ?? ({})
	readonly property var loopback: root.device.loopback ?? ({})
	readonly property var faces: root.irState.faces ?? root.device.irStream?.faces ?? []
	readonly property bool busyElsewhere: (root.streamState.busyBy ?? []).length > 0
	readonly property bool enrolling: root.irState.task === "enroll"

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
	readonly property bool irPreviewOn: root.options.irPreview ?? false
	readonly property string irMode: root.options.irMode ?? "lit"
	readonly property bool enhanceAi: root.options.enhanceAi ?? false
	readonly property string enhanceModel: root.options.enhanceModel || (root.models[0]?.name ?? "")
	readonly property bool faceUnlock: root.options.faceUnlock ?? false
	readonly property int faceTries: root.options.faceTries ?? 3
	// the lock screen may look for a face: the plugin on, the option on, a face enrolled
	readonly property bool faceReady: root.enabled && root.faceUnlock && root.faces.length > 0

	property bool watching: false
	onWatchingChanged: {
		root.send({ op: "watch", on: root.watching });
		root.sendPreviews();
		if (root.watching) root.send({ op: "models" });
		else if (root.irState.task === "enroll" || root.irState.task === "test") root.send({ op: "face-stop" });
	}

	function sendPreviews() {
		root.send({ op: "preview", on: root.watching && root.previewOn });
		root.send({ op: "ir-preview", on: root.watching && root.irPreviewOn, mode: root.irMode });
	}

	function control(key) {
		return root.controls[key] ?? null;
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
		if (key === "preview" || key === "irPreview" || key === "irMode") root.sendPreviews();
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
		root.keepSaved("xu", name, Math.round(value));
		root.queue("xu", name, Math.round(value));
	}

	function setIr(key, value) {
		root.keepSaved("ir", key, value);
		root.queue("ir", key, value);
	}

	// the spot the automatic exposure aims at, in fractions of the picture (null: all of it)
	function setSpot(fx, fy, fw, fh) {
		const max = root.roi?.max ?? [0, 0, 1280, 720];
		const rect = fx === null ? (root.roi?.default ?? [0, 0, max[2], max[3]])
			: [Math.round(fx * max[2]), Math.round(fy * max[3]), Math.max(1, Math.round(fw * max[2])), Math.max(1, Math.round(fh * max[3]))];
		root.keepSaved("roi", "rect", rect);
		root.queue("roi", "rect", rect);
	}

	function setSpotAuto(on) {
		root.keepSaved("roi", "auto", on ? 1 : 0);
		root.queue("roi", "auto", on ? 1 : 0);
	}

	// what the page shows: the kept value while it is on its way, else the camera's
	function shown(kind, key, fallback) {
		const kept = root.saved[kind]?.[key];
		if (kept !== undefined) return kept;
		if (kind === "v4l2") return root.controls[key]?.value ?? fallback;
		if (kind === "xu") return root.xu[key]?.value ?? fallback;
		if (kind === "roi") return root.roi?.[key] ?? fallback;
		if (kind === "ir") return root.irControls?.[key] ?? fallback;
		return fallback;
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
		if (on && !root.loopback.node) root.system(["loopback", "on", "hp"]);
		if (!on && root.loopback.node) root.system(["loopback", "off", "hp"]);
		root.sendConfig();
	}

	function setOutput(size, fps) {
		root.keep({ size: size ?? root.size, fps: fps ?? root.fps });
		root.sendConfig();
	}

	function photo(ofView) {
		root.send({ op: "photo", view: ofView === true });
	}

	function irPhoto() {
		root.send({ op: "ir-photo" });
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

	// ── the face ──────────────────────────────────────────────────────────
	function enroll(name) {
		root.face = { kind: "enroll", result: "progress", samples: 0, needed: 12, hint: "" };
		root.send({ op: "face-enroll", name });
	}

	function testFace() {
		root.face = { kind: "test", result: "working" };
		root.send({ op: "face-test" });
	}

	function stopFace() {
		root.send({ op: "face-stop" });
	}

	function deleteFace(id) {
		root.send({ op: "face-delete", id });
	}

	// the lock screen: look for an enrolled face for a few seconds; faceResult answers
	function checkFace(seconds) {
		if (!root.faceReady) return false;
		root.send({ op: "face-verify", seconds: seconds ?? 4 });
		return true;
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

		path: Paths.stateFile("hpcamera.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = typeof data === "object" && data ? data : {};
			} catch (error) {
				console.warn("HpCamera: hpcamera.json is not valid JSON");
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
			if (data.irStream) root.irState = data.irStream;
			break;
		case "frame":
			root.frame = data;
			break;
		case "irframe":
			root.irFrame = data;
			break;
		case "stream":
			root.streamState = data;
			break;
		case "ir":
			root.irState = data;
			break;
		case "face":
			if (data.kind === "verify") {
				root.faceResult(data.result ?? "error");
				break;
			}
			if (data.kind === "photo") break;
			root.face = data;
			if (data.result === "enrolled") Sounds.play("saved");
			break;
		case "photo":
			root.lastShot = data.path;
			Sounds.play("saved");
			root.shot(data.path, data.ir ? "ir" : "photo");
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
				root.sendPreviews();
			}
		}
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			onRead: line => {
				if (!line.startsWith("Corrupt JPEG data") && !line.includes("setPreferableTarget")) console.warn(line);
			}
		}
		onExited: {
			root.device = { online: false };
			root.frame = null;
			root.irFrame = null;
			root.streamState = {};
			root.irState = {};
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
