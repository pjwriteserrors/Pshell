pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// Screenshot suite: freeze, select, annotate, copy/save, colour picker, OCR.
//
// A capture first freezes every output with grim (into $XDG_RUNTIME_DIR, which
// is tmpfs), then the per-screen overlays show the frozen frames for picking a
// region, a screen, a window, a colour or text. Regions open the editor on the
// screen they were taken on. Copied images only ever touch tmpfs and are
// deleted as soon as their toast is gone; saved ones go to ~/Pictures/Screenshots.
// Pins float a capture above all windows until they are closed (the image
// stays in tmpfs as long as the pin lives, nothing survives a restart). Live
// pins keep streaming the selected region of the window under it, also when
// that window is on another workspace (scripts/live_pin.py).
//
// While selecting, scripts/detect_boxes.py finds the boxes on the frozen
// frames (cards, buttons, images, panels, see `boxes`); the overlay offers
// the one under the cursor for a click instead of a drag.
//
// Also: delayed captures (a countdown that is never part of the frame), QR/
// barcode reading, a colour history (color-history.json) and palettes of a
// dragged region, scroll screenshots (a region grabbed repeatedly while the
// content scrolls, stitched by scripts/scroll_stitch.py) and a history of the
// last captures of this session (tmpfs, see `shots`, launcher >shots).
Singleton {
	id: root

	// ── settings (swappy's options, defaults follow ~/.config/swappy/config) ──
	readonly property string saveDir: `${Quickshell.env("HOME")}/Pictures/Screenshots`
	readonly property string filePrefix: "Screenshot_"
	readonly property string fileDateFormat: "yyyy-MM-dd_HH-mm-ss"
	property string defaultTool: "rect"
	// close the editor after copying or saving
	property bool earlyExit: true
	// save automatically when the editor closes without having saved
	property bool autoSave: false
	property int lineSize: 5
	property int textSize: 28
	property bool fillShape: false
	property bool transparent: false
	property int transparency: 50
	property color customColor: "#c17d11"
	// the editor remembers the last choices while the shell runs
	property string lastTool: root.defaultTool
	property color lastColor: "#ef4444"

	readonly property string script: `${Quickshell.shellDir}/scripts/screenshot.sh`
	readonly property string tmpDir: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/qs-screenshot`

	// ── session state ──────────────────────────────────────────────────────
	// idle | countdown | freezing | select | scroll | edit
	property string phase: "idle"
	// region | screen | window | pin | live | picker | ocr | qr | scroll
	property string mode: "region"
	// unique per capture, names the temp files (so no stale image cache hits)
	property string session: ""
	// when a panel or modal of the shell last closed (it may still be fading)
	property real surfaceClosedAt: 0
	// output name → frozen frame (file path)
	property var frozen: ({})
	// output name → boxes found on its frozen frame, native px [[x, y, w, h], ...]
	property var boxes: ({})
	// output that owns the keyboard while selecting
	property string activeScreen: ""

	// editor input
	property string editScreen: ""
	property string editSource: ""
	property rect editCrop: Qt.rect(0, 0, 0, 0)
	// whether the source is the frozen frame of editScreen (morphs out of it)
	property bool editFromFrozen: false

	readonly property var modes: ["region", "screen", "window", "pin", "live", "picker", "ocr", "qr", "scroll"]

	// delayed capture: the delay the current frame was taken with (0 = none)
	property int delaySeconds: 0
	// seconds left while phase === "countdown" (0 → the pill is gone)
	property int countdown: 0
	property string countdownScreen: ""

	// scroll screenshot: the region (logical px on scrollScreen) being grabbed
	property string scrollScreen: ""
	property rect scrollRect: Qt.rect(0, 0, 0, 0)
	property bool scrollStopping: false

	// picked colours, newest first (persisted)
	property var colorHistory: []
	readonly property int colorHistorySize: 12

	// captures of this session, newest first: [{ id, path, time }] (tmpfs)
	property var shots: []
	property int shotCounter: 0
	readonly property int shotsSize: 20
	readonly property string historyDir: `${root.tmpDir}/history`

	// pinned captures: [{ id, path, output, x, y, width, height, opacity, live, dir }], logical px
	property var pins: []
	property int pinCounter: 0
	// live pins: pin id → latest frame, pin id → helper process
	property var liveFrames: ({})
	property var liveProcs: ({})
	// PipeWire nodes of the screencasts behind live pins
	property var liveNodes: []

	// a capture went to the clipboard (the file is deleted with its toast)
	signal shotCopied(string path)

	// temp files shown in toasts: toastId → path, deleted when the toast leaves
	property var toastFiles: ({})
	property int exportCounter: 0
	property string lastSaveName: ""
	property int saveRepeat: 1

	function fileUrl(path) {
		return path ? `file://${path}` : "";
	}

	function frozenFor(name) {
		return root.frozen[String(name)] ?? "";
	}

	function boxesFor(name) {
		return root.boxes[String(name)] ?? [];
	}

	// ── entry points (IPC) ────────────────────────────────────────────────
	function region() {
		root.start("region");
	}
	function screen() {
		root.start("screen");
	}
	function window() {
		root.start("window");
	}
	function picker() {
		root.start("picker");
	}
	function ocr() {
		root.start("ocr");
	}
	function pinMode() {
		root.start("pin");
	}
	function liveMode() {
		root.start("live");
	}
	function qr() {
		root.start("qr");
	}
	function scroll() {
		root.start("scroll");
	}
	function delayed(seconds) {
		root.startDelayed(root.phase === "select" ? root.mode : "region", seconds);
	}

	function start(mode) {
		if (root.phase === "select") {
			if (root.mode === mode) root.cancel();
			else root.mode = mode;
			return;
		}
		if (root.phase === "countdown") {
			root.cancel();
			return;
		}
		// the scroll hotkey again finishes a scroll capture
		if (root.phase === "scroll") {
			if (mode === "scroll") root.stopScroll();
			else root.cancel();
			return;
		}
		if (root.phase !== "idle") return;
		root.delaySeconds = 0;
		if (mode === "ocr") {
			ocrCheck.running = true;
			return;
		}
		root.begin(mode);
	}

	function begin(mode) {
		root.session = String(Date.now());
		root.boxes = {};
		root.mode = mode;
		root.phase = "freezing";
		// surfaces of the shell would end up in the frozen frame while they fade out
		if (Popups.current !== "" || Popups.modal !== "") {
			Popups.closeAll();
			root.surfaceClosedAt = Date.now();
		}
		settle.interval = Math.max(1, root.surfaceClosedAt + Motion.long + 80 - Date.now());
		settle.restart();
	}

	// ── delayed capture ──────────────────────────────────────────────────
	// The countdown pill leaves the screen right before the freeze, so menus
	// and tooltips opened meanwhile are captured without it.
	function startDelayed(mode, seconds) {
		const delay = Math.max(0, Math.round(Number(seconds) || 0));
		if (root.phase === "select") {
			// the frozen frame is dropped, the countdown starts over the live screen
			root.phase = "countdown";
			root.cleanup();
		} else if (root.phase !== "idle" && root.phase !== "countdown") {
			return;
		}
		root.delaySeconds = delay;
		root.mode = root.modes.indexOf(mode) >= 0 ? mode : "region";
		if (delay === 0) {
			root.phase = "idle";
			root.begin(root.mode);
			return;
		}
		root.phase = "countdown";
		root.countdown = 0;
		Popups.withFocusedScreen(screen => {
			if (root.phase !== "countdown") return;
			root.countdownScreen = String(screen?.name ?? "");
			root.countdown = delay;
			countdownTick.restart();
		});
	}

	Timer {
		id: countdownTick

		interval: 1000
		repeat: true
		onTriggered: {
			if (root.phase !== "countdown") {
				countdownTick.stop();
				return;
			}
			root.countdown -= 1;
			if (root.countdown > 0) return;
			countdownTick.stop();
			// one or two frames for the compositor to drop the pill
			countdownDone.restart();
		}
	}

	Timer {
		id: countdownDone

		interval: 120
		onTriggered: {
			if (root.phase !== "countdown") return;
			root.phase = "idle";
			if (root.mode === "ocr") ocrCheck.running = true;
			else root.begin(root.mode);
		}
	}

	Connections {
		target: Popups

		function onCurrentChanged() {
			if (Popups.current === "") root.surfaceClosedAt = Date.now();
		}
		function onModalChanged() {
			if (Popups.modal === "") root.surfaceClosedAt = Date.now();
		}
	}

	Timer {
		id: settle

		onTriggered: Popups.withFocusedScreen(screen => {
			root.activeScreen = String(screen?.name ?? "");
			if (root.mode === "window") {
				root.captureWindow(root.focusedWindowId());
			} else if (root.mode === "screen") {
				root.freeze([root.activeScreen]);
			} else {
				root.freeze(Quickshell.screens.map(s => String(s.name)));
			}
		})
	}

	function freeze(outputs) {
		freezeProc.outputs = outputs;
		freezeProc.command = ["bash", root.script, "freeze", String(root.session)].concat(outputs);
		freezeProc.running = true;
	}

	Process {
		id: freezeProc

		property var outputs: []
		onExited: exitCode => {
			if (exitCode !== 0) {
				root.fail("Screenshot failed", "grim could not capture the screen");
				return;
			}
			const map = {};
			for (const output of freezeProc.outputs)
				map[output] = `${root.tmpDir}/frozen-${root.session}-${output}.ppm`;
			root.frozen = map;
			if (root.mode === "screen") {
				root.openEditor(root.activeScreen, map[root.activeScreen], null, true);
				Haptics.play("captured");
			} else {
				root.phase = "select";
				root.detectBoxes(freezeProc.outputs, map);
			}
		}
	}

	// the frames are searched in parallel, each one reports as soon as it is done
	function detectBoxes(outputs, map) {
		const args = [];
		for (const output of outputs) {
			const screen = Quickshell.screens.find(s => String(s.name) === output);
			args.push(output, map[output], String(screen?.devicePixelRatio || 1));
		}
		// a search of the previous capture may still be running
		boxesProc.running = false;
		boxesProc.tag = root.session;
		boxesProc.command = ["python3", `${Quickshell.shellDir}/scripts/detect_boxes.py`].concat(args);
		Qt.callLater(() => {
			if (boxesProc.tag === root.session) boxesProc.running = true;
		});
	}

	Process {
		id: boxesProc

		property string tag: ""
		stdout: SplitParser {
			onRead: line => {
				if (boxesProc.tag !== root.session || root.phase !== "select") return;
				const tab = line.indexOf("\t");
				if (tab < 0) return;
				try {
					const found = JSON.parse(line.slice(tab + 1));
					const next = Object.assign({}, root.boxes);
					next[line.slice(0, tab)] = found;
					root.boxes = next;
				} catch (e) {}
			}
		}
	}

	// ── windows ────────────────────────────────────────────────────────────
	function activeWindowOn(output) {
		const ws = Niri.workspaces.find(w => String(w.output) === String(output) && w.is_active);
		if (!ws || ws.active_window_id === null || ws.active_window_id === undefined) return null;
		return Niri.windows.find(w => Number(w.id) === Number(ws.active_window_id)) ?? null;
	}

	function focusedWindowId() {
		const focused = Niri.windows.find(w => w.is_focused);
		return focused ? Number(focused.id) : -1;
	}

	function outputOfWindow(id) {
		const window = Niri.windows.find(w => Number(w.id) === Number(id));
		const ws = window ? Niri.workspaces.find(w => Number(w.id) === Number(window.workspace_id)) : null;
		return String(ws?.output ?? root.activeScreen);
	}

	function captureWindow(id) {
		if (id < 0) {
			root.fail("No window to capture", "");
			return;
		}
		root.muteNiriUntil = Date.now() + 6000;
		root.muteNiriNotice();
		windowProc.output = root.outputOfWindow(id);
		windowProc.command = ["bash", root.script, "window", String(root.session), String(id)];
		windowProc.running = true;
	}

	// niri announces every window shot with a notification; ours is the editor
	property real muteNiriUntil: 0

	// only the ones pointing at our own temp files
	function isNiriShot(n) {
		return !!n && String(n.appName) === "niri" && `${n.image ?? ""} ${n.appIcon ?? ""}`.indexOf("/qs-screenshot/") >= 0;
	}

	function muteNiriNotice() {
		for (const toast of Notifs.toasts)
			if (root.isNiriShot(toast.notification)) Notifs.dismissToast(toast);
		let changed = false;
		const groups = [];
		for (const group of Notifs.groups) {
			const kept = group.notifications.filter(snap => !root.isNiriShot(snap));
			if (kept.length === group.notifications.length) {
				groups.push(group);
				continue;
			}
			changed = true;
			if (kept.length === 0) continue;
			groups.push(Object.assign({}, group, { notifications: kept, latestSnapshot: kept[0] }));
		}
		if (changed) Notifs.groups = groups;
	}

	// called by the overlay in window mode
	function selectWindow(output) {
		const window = root.activeWindowOn(output);
		if (!window) return;
		root.phase = "freezing";
		root.captureWindow(Number(window.id));
	}

	Process {
		id: windowProc

		property string output: ""
		stdout: StdioCollector {
			id: windowOut
		}
		onExited: exitCode => {
			const path = String(windowOut.text || "").trim();
			if (exitCode !== 0 || path === "") {
				root.fail("Window capture failed", "");
				return;
			}
			Haptics.play("captured");
			root.openEditor(windowProc.output, path, null, false);
		}
	}

	// ── selection results ──────────────────────────────────────────────────
	// rect is in native pixels of the frozen frame
	function selectRegion(output, rect, logical) {
		const source = root.frozenFor(output);
		if (source === "") return;
		if (root.mode === "pin") {
			root.pinRegion(output, source, rect, logical);
			return;
		}
		if (root.mode === "live") {
			root.livePinRegion(output, source, rect, logical);
			return;
		}
		if (root.mode === "ocr") {
			root.phase = "idle";
			root.runOcr(source, rect, false);
			return;
		}
		if (root.mode === "qr") {
			root.phase = "idle";
			root.runQr(source, rect);
			return;
		}
		if (root.mode === "picker") {
			root.phase = "idle";
			root.runPalette(source, rect);
			return;
		}
		if (root.mode === "scroll") {
			root.startScroll(output, logical);
			return;
		}
		Haptics.play("captured");
		root.openEditor(output, source, rect, true);
	}

	function openEditor(output, source, rect, fromFrozen) {
		Quickshell.execDetached(["mkdir", "-p", root.saveDir]);
		root.editScreen = String(output);
		root.editSource = source;
		root.editCrop = rect ? Qt.rect(Math.round(rect.x), Math.round(rect.y), Math.round(rect.width), Math.round(rect.height)) : Qt.rect(0, 0, 0, 0);
		root.editFromFrozen = fromFrozen;
		root.phase = "edit";
	}

	function pickColor(color, asRgb) {
		const c = Qt.color(color);
		const hex = `#${[c.r, c.g, c.b].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("")}`.toUpperCase();
		const rgb = `rgb(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)})`;
		const value = asRgb ? rgb : hex;
		root.cancel();
		Quickshell.execDetached(["wl-copy", value]);
		Haptics.play("colorPicked");
		root.rememberColor(hex);
		const swatch = `${root.tmpDir}/swatch-${root.session}.png`;
		swatchProc.value = value;
		swatchProc.path = swatch;
		swatchProc.command = ["bash", root.script, "swatch", hex, swatch];
		swatchProc.running = true;
	}

	Process {
		id: swatchProc

		property string value: ""
		property string path: ""
		onExited: exitCode => {
			const image = exitCode === 0 ? swatchProc.path : "";
			const id = Notifs.pushInternal("done", "Colour copied", swatchProc.value, { icon: "eyedropper", image: root.fileUrl(image) });
			if (image !== "") root.trackToastFile(id, image);
		}
	}

	// ── colour history ─────────────────────────────────────────────────────
	function rememberColor(hex) {
		const value = String(hex).toUpperCase();
		root.colorHistory = [value].concat(root.colorHistory.filter(c => c !== value)).slice(0, root.colorHistorySize);
		colorFile.setText(JSON.stringify(root.colorHistory));
	}

	FileView {
		id: colorFile

		path: Paths.stateFile("color-history.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: colorFile.reload()
		onLoaded: {
			try {
				const data = JSON.parse(String(colorFile.text() || "[]"));
				if (Array.isArray(data)) root.colorHistory = data.filter(c => /^#[0-9A-F]{6}$/i.test(String(c))).map(c => String(c).toUpperCase()).slice(0, root.colorHistorySize);
			} catch (error) {}
		}
	}

	// ── palette of a dragged region (picker mode) ─────────────────────────
	function runPalette(path, rect) {
		const strip = root.nextTempPath("palette");
		paletteProc.path = strip;
		paletteProc.command = ["bash", root.script, "palette", path].concat([rect.x, rect.y, Math.max(1, rect.width), Math.max(1, rect.height)].map(v => String(Math.round(v)))).concat([strip]);
		paletteProc.running = true;
	}

	Process {
		id: paletteProc

		property string path: ""
		stdout: StdioCollector {
			id: paletteOut
		}
		onExited: exitCode => {
			if (root.phase === "idle") root.cleanup();
			const colors = String(paletteOut.text || "").split("\n").map(c => c.trim().toUpperCase()).filter(c => /^#[0-9A-F]{6}$/.test(c));
			if (exitCode !== 0 || colors.length === 0) {
				root.fail("No colours found", "");
				return;
			}
			Quickshell.execDetached(["bash", root.script, "text", colors.join("\n")]);
			Haptics.play("colorPicked");
			const id = Notifs.pushInternal("done", `Palette copied · ${colors.length} colours`, colors.join("  "), { icon: "palette_swatch", image: root.fileUrl(paletteProc.path) });
			root.trackToastFile(id, paletteProc.path);
		}
	}

	// ── QR / barcodes ──────────────────────────────────────────────────────
	// rect: native crop inside the file, or null for the whole file
	function runQr(path, rect) {
		qrProc.command = ["bash", root.script, "qr", path].concat(rect ? [Math.round(rect.x), Math.round(rect.y), Math.max(1, Math.round(rect.width)), Math.max(1, Math.round(rect.height))].map(String) : []);
		qrProc.running = true;
	}

	function isUrl(text) {
		return /^(https?|ftp|mailto|tel|geo|file):\S+$/i.test(text) || /^www\.\S+\.\S+$/i.test(text);
	}

	Process {
		id: qrProc

		stdout: StdioCollector {
			id: qrOut
		}
		onExited: exitCode => {
			if (root.phase === "idle") root.cleanup();
			if (exitCode === 127) {
				Haptics.play("taskFailed");
				Notifs.pushInternal("error", "Code reading needs zbar", "Install zbar", { icon: "qrcode_scan" });
				return;
			}
			const codes = String(qrOut.text || "").split("\n").map(line => line.trim()).filter(line => line !== "");
			if (exitCode !== 0 || codes.length === 0) {
				Haptics.play("taskFailed");
				Notifs.pushInternal("error", "No code found", "", { icon: "qrcode_scan" });
				return;
			}
			const text = codes.join("\n");
			Quickshell.execDetached(["bash", root.script, "text", text]);
			Haptics.play("copied");
			const link = codes.length === 1 && root.isUrl(codes[0]) ? (codes[0].startsWith("www.") ? `https://${codes[0]}` : codes[0]) : "";
			const actions = [];
			if (link !== "") actions.push({ label: "Open", icon: "open_in_new", run: () => Quickshell.execDetached(["xdg-open", link]) });
			actions.push({ label: "Copy", icon: "content_copy", run: () => Quickshell.execDetached(["bash", root.script, "text", text]) });
			Notifs.pushInternal("done", codes.length > 1 ? `${codes.length} codes copied` : "Code copied", text.length > 220 ? `${text.slice(0, 220)}…` : text, {
				icon: "qrcode_scan",
				actions: actions,
				duration: link !== "" ? 8000 : 5000
			});
		}
	}

	// ── OCR ────────────────────────────────────────────────────────────────
	Process {
		id: ocrCheck

		command: ["bash", root.script, "ocr-check"]
		onExited: exitCode => {
			if (exitCode === 0) root.begin("ocr");
			else root.ocrMissing();
		}
	}

	function ocrMissing() {
		Haptics.play("taskFailed");
		Notifs.pushInternal("error", "Text recognition needs tesseract", "Install tesseract, tesseract-data-deu and tesseract-data-eng", { icon: "text_recognition", duration: 8000 });
	}

	// rect: native crop inside the file, or null for the whole file
	function runOcr(path, rect, deleteAfter) {
		ocrProc.deleteAfter = deleteAfter ? path : "";
		ocrProc.command = ["bash", root.script, "ocr", path].concat(rect ? [Math.round(rect.x), Math.round(rect.y), Math.max(1, Math.round(rect.width)), Math.max(1, Math.round(rect.height))].map(String) : []);
		ocrProc.running = true;
	}

	Process {
		id: ocrProc

		property string deleteAfter: ""
		stdout: StdioCollector {
			id: ocrOut
		}
		onExited: exitCode => {
			if (ocrProc.deleteAfter !== "") Quickshell.execDetached(["rm", "-f", ocrProc.deleteAfter]);
			else if (root.phase === "idle") root.cleanup();
			if (exitCode === 127) {
				root.ocrMissing();
				return;
			}
			const text = String(ocrOut.text || "").replace(/\f/g, "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
			if (exitCode !== 0 || text === "") {
				Haptics.play("taskFailed");
				Notifs.pushInternal("error", "No text found", "", { icon: "text_recognition" });
				return;
			}
			Quickshell.execDetached(["bash", root.script, "text", text]);
			Haptics.play("copied");
			const lines = text.split("\n").length;
			Notifs.pushInternal("done", lines > 1 ? `Text copied · ${lines} lines` : "Text copied", text.length > 220 ? `${text.slice(0, 220)}…` : text, { icon: "text_recognition" });
		}
	}

	// ── pins ───────────────────────────────────────────────────────────────
	// straight from the selection: cut the region out of the frozen frame
	function pinRegion(output, source, rect, logical) {
		const path = root.nextTempPath("pin");
		cropProc.output = output;
		cropProc.path = path;
		cropProc.logical = logical ?? Qt.rect(0, 0, 0, 0);
		cropProc.command = ["bash", root.script, "crop", source].concat([rect.x, rect.y, Math.max(1, rect.width), Math.max(1, rect.height)].map(v => String(Math.round(v)))).concat([path]);
		cropProc.running = true;
		root.phase = "idle";
	}

	Process {
		id: cropProc

		property string output: ""
		property string path: ""
		property rect logical: Qt.rect(0, 0, 0, 0)
		onExited: exitCode => {
			root.cleanup();
			if (exitCode === 0) root.pin(cropProc.path, cropProc.output, cropProc.logical);
			else root.fail("Screenshot could not be pinned", "");
		}
	}

	// logical: where the capture sits on the output (empty rect → centred)
	function pin(path, output, logical, fromHistory) {
		if (!fromHistory) root.remember(path);
		root.pinCounter += 1;
		const r = logical ?? Qt.rect(0, 0, 0, 0);
		root.pins = root.pins.concat([{
			id: root.pinCounter,
			path: path,
			output: String(output),
			x: r.x,
			y: r.y,
			width: r.width,
			height: r.height
		}]);
		Haptics.play("pinned");
	}

	function unpin(id) {
		const pin = root.pins.find(p => p.id === id);
		if (!pin) return;
		root.pins = root.pins.filter(p => p.id !== id);
		if (pin.live) {
			root.stopLive(id);
			Quickshell.execDetached(["rm", "-rf", pin.dir]);
		} else {
			Quickshell.execDetached(["rm", "-f", pin.path]);
		}
	}

	function unpinAll() {
		for (const pin of root.pins)
			if (pin.live) root.stopLive(pin.id);
		root.pins = [];
		root.liveFrames = {};
		Quickshell.execDetached(["bash", root.script, "unpin-all"]);
	}

	// dropped on another screen, or resized: the pin keeps its look there
	function movePin(id, output, x, y, width, height, opacity) {
		root.pins = root.pins.map(p => p.id !== id ? p : Object.assign({}, p, { output: String(output), x: x, y: y, width: width, height: height, opacity: opacity }));
	}

	// a pin back into the editor (the pin goes away, the editor takes over)
	function editPin(id) {
		const pin = root.pins.find(p => p.id === id);
		if (!pin || root.phase !== "idle") return;
		const path = pin.live ? (root.liveFrames[id] ?? "") : pin.path;
		if (path === "") return;
		root.pins = root.pins.filter(p => p.id !== id);
		if (pin.live) {
			root.stopLive(id);
			Quickshell.execDetached(["rm", "-f", `${pin.dir}/frozen.ppm`]);
		}
		root.session = String(Date.now());
		root.openEditor(pin.output, path, null, false);
	}

	// ── live pins ──────────────────────────────────────────────────────────
	// The region is looked up in a screencast of every window on the active
	// workspace of that output; the helper keeps the one that shows it.
	function livePinRegion(output, source, rect, logical) {
		const ws = Niri.workspaces.find(w => String(w.output) === String(output) && w.is_active);
		const windows = ws ? Niri.windows.filter(w => Number(w.workspace_id) === Number(ws.id)).map(w => String(w.id)) : [];
		root.phase = "idle";
		if (windows.length === 0) {
			root.cleanup();
			root.fail("No window under the selection", "");
			return;
		}
		root.pinCounter += 1;
		const id = root.pinCounter;
		const dir = `${root.tmpDir}/pin-live-${root.session}-${id}`;
		const r = logical ?? Qt.rect(0, 0, 0, 0);
		root.pins = root.pins.concat([{ id: id, path: "", output: String(output), x: r.x, y: r.y, width: r.width, height: r.height, live: true, dir: dir }]);
		const helper = liveHelper.createObject(root, { pinId: id });
		// a hard link keeps the frozen frame for the helper when the capture is cleaned up
		helper.command = ["bash", "-c", 'dir=$1 src=$2 script=$3; shift 3; mkdir -p "$dir" && ln -f "$src" "$dir/frozen.ppm" && exec python3 "$script" "$dir/frozen.ppm" "$1" "$2" "$3" "$4" "$dir" "${@:5}"',
			"sh", dir, source, `${Quickshell.shellDir}/scripts/live_pin.py`].concat([rect.x, rect.y, Math.max(1, rect.width), Math.max(1, rect.height)].map(v => String(Math.round(v)))).concat(windows);
		helper.running = true;
		const procs = Object.assign({}, root.liveProcs);
		procs[id] = helper;
		root.liveProcs = procs;
		root.cleanup();
		Haptics.play("pinned");
	}

	function isLive(id) {
		return !!root.liveProcs[id];
	}

	function stopLive(id) {
		const helper = root.liveProcs[id];
		if (helper) helper.running = false;
	}

	function liveLine(helper, line) {
		const space = line.indexOf(" ");
		const kind = space < 0 ? line : line.slice(0, space);
		const value = space < 0 ? "" : line.slice(space + 1);
		if (kind === "frame") {
			const frames = Object.assign({}, root.liveFrames);
			frames[helper.pinId] = value;
			root.liveFrames = frames;
		} else if (kind === "node") {
			helper.nodes = helper.nodes.concat([Number(value)]);
			root.liveNodes = root.liveNodes.concat([Number(value)]);
		} else if (kind === "drop") {
			helper.nodes = helper.nodes.filter(node => node !== Number(value));
			root.liveNodes = root.liveNodes.filter(node => node !== Number(value));
		} else if (kind === "lost" && !root.liveFrames[helper.pinId]) {
			root.unpin(helper.pinId);
			Haptics.play("taskFailed");
			Notifs.pushInternal("error", "No window under the selection", "", { icon: "alert_circle" });
		}
	}

	// the helper is gone (window closed, pin removed): the pin keeps its last frame
	function liveEnded(helper) {
		root.liveNodes = root.liveNodes.filter(node => !helper.nodes.includes(node));
		const procs = Object.assign({}, root.liveProcs);
		delete procs[helper.pinId];
		root.liveProcs = procs;
		helper.destroy();
	}

	Component {
		id: liveHelper

		Process {
			id: helper

			property int pinId: -1
			property var nodes: []

			// the helper stops its cast when stdin closes, so it stays open
			stdinEnabled: true
			stdout: SplitParser {
				onRead: line => root.liveLine(helper, line)
			}
			onExited: root.liveEnded(helper)
		}
	}

	function copyFile(path) {
		Quickshell.execDetached(["bash", root.script, "copy", path]);
		Haptics.play("copied");
	}

	function saveCopyOf(path) {
		const target = root.nextSavePath();
		keepProc.target = target;
		keepProc.command = ["sh", "-c", 'mkdir -p "$1" && cp "$2" "$3"', "sh", root.saveDir, path, target];
		keepProc.running = true;
	}

	// ── export results (the editor renders the PNG) ───────────────────────
	function nextTempPath(kind) {
		root.exportCounter += 1;
		return `${root.tmpDir}/${kind}-${root.session}-${root.exportCounter}.png`;
	}

	function nextSavePath() {
		const base = `${root.filePrefix}${Qt.formatDateTime(new Date(), root.fileDateFormat)}`;
		// several saves within one second get a counter
		root.saveRepeat = base === root.lastSaveName ? root.saveRepeat + 1 : 1;
		root.lastSaveName = base;
		return `${root.saveDir}/${base}${root.saveRepeat > 1 ? `_${root.saveRepeat}` : ""}.png`;
	}

	// a PNG in tmpfs was rendered: put it on the clipboard, drop it later
	function copied(path) {
		root.remember(path);
		Quickshell.execDetached(["bash", root.script, "copy", path]);
		Haptics.play("copied");
		root.shotCopied(path);
		const id = Notifs.pushInternal("done", "Screenshot copied", "", {
			icon: "content_copy",
			image: root.fileUrl(path),
			actions: [{
				label: "Save",
				icon: "content_save",
				run: () => {
					const target = root.nextSavePath();
					keepProc.target = target;
					keepProc.command = ["sh", "-c", 'mkdir -p "$1" && cp "$2" "$3"', "sh", root.saveDir, path, target];
					keepProc.running = true;
				}
			}]
		});
		root.trackToastFile(id, path);
	}

	Process {
		id: keepProc

		property string target: ""
		onExited: exitCode => {
			if (exitCode === 0) root.announceSaved(keepProc.target);
			else root.fail("Screenshot could not be saved", "");
		}
	}

	function saved(path) {
		root.remember(path);
		root.announceSaved(path);
	}

	function announceSaved(path) {
		Haptics.play("saved");
		Notifs.pushInternal("done", "Screenshot saved", path.split("/").pop(), {
			icon: "content_save",
			image: root.fileUrl(path),
			actions: [
				{ label: "Open", icon: "open_in_new", run: () => Quickshell.execDetached(["xdg-open", path]) },
				{ label: "Folder", icon: "folder_open", run: () => Quickshell.execDetached(["xdg-open", root.saveDir]) },
				{ label: "Copy", icon: "content_copy", run: () => Quickshell.execDetached(["bash", root.script, "copy", path]) }
			]
		});
	}

	function exportFailed() {
		root.fail("Screenshot could not be rendered", "");
	}

	function trackToastFile(id, path) {
		const next = Object.assign({}, root.toastFiles);
		next[id] = path;
		root.toastFiles = next;
	}

	Connections {
		target: Notifs

		function onGroupsChanged() {
			if (Date.now() < root.muteNiriUntil) root.muteNiriNotice();
		}
		function onToastsChanged() {
			if (Date.now() < root.muteNiriUntil && Notifs.toasts.some(t => root.isNiriShot(t.notification))) root.muteNiriNotice();
			const ids = Object.keys(root.toastFiles);
			if (ids.length === 0) return;
			const alive = new Set(Notifs.toasts.map(t => String(t.toastId)));
			const next = {};
			for (const id of ids) {
				if (alive.has(id)) next[id] = root.toastFiles[id];
				else Quickshell.execDetached(["rm", "-f", root.toastFiles[id]]);
			}
			root.toastFiles = next;
		}
	}

	// ── capture history (this session, tmpfs) ───────────────────────────
	// a copy is taken right away: the exported file may be a temp file that
	// goes with its toast or pin. The entry appears once the copy exists.
	property var historyQueue: []

	function remember(path) {
		if (!path) return;
		root.shotCounter += 1;
		root.historyQueue = root.historyQueue.concat([{
			id: root.shotCounter,
			source: String(path),
			path: `${root.historyDir}/shot-${root.session || Date.now()}-${root.shotCounter}.png`
		}]);
		root.nextHistoryCopy();
	}

	function nextHistoryCopy() {
		if (historyProc.running || root.historyQueue.length === 0) return;
		const job = root.historyQueue[0];
		root.historyQueue = root.historyQueue.slice(1);
		historyProc.job = job;
		historyProc.command = ["bash", root.script, "history-add", job.source, job.path];
		historyProc.running = true;
	}

	Process {
		id: historyProc

		property var job: null
		onExited: exitCode => {
			const job = historyProc.job;
			if (exitCode === 0 && job) {
				const next = [{
					id: job.id,
					path: job.path,
					time: Date.now()
				}].concat(root.shots);
				for (const old of next.slice(root.shotsSize))
					Quickshell.execDetached(["rm", "-f", old.path]);
				root.shots = next.slice(0, root.shotsSize);
			}
			root.nextHistoryCopy();
		}
	}

	function forgetShot(id) {
		const shot = root.shots.find(s => s.id === id);
		if (!shot) return;
		root.shots = root.shots.filter(s => s.id !== id);
		Quickshell.execDetached(["rm", "-f", shot.path]);
	}

	function copyShot(path) {
		Quickshell.execDetached(["bash", root.script, "copy", path]);
		Haptics.play("copied");
		root.shotCopied(path);
		Notifs.pushInternal("done", "Screenshot copied", "", { icon: "content_copy", image: root.fileUrl(path) });
	}

	function saveShot(path) {
		root.saveCopyOf(path);
	}

	// pins own (and delete) their file, so they get a copy
	function pinShot(path) {
		Popups.withFocusedScreen(screen => {
			const target = root.nextTempPath("pin");
			pinCopyProc.output = String(screen?.name ?? "");
			pinCopyProc.path = target;
			pinCopyProc.command = ["cp", path, target];
			pinCopyProc.running = true;
		});
	}

	Process {
		id: pinCopyProc

		property string output: ""
		property string path: ""
		onExited: exitCode => {
			if (exitCode === 0) root.pin(pinCopyProc.path, pinCopyProc.output, Qt.rect(0, 0, 0, 0), true);
			else root.fail("Screenshot could not be pinned", "");
		}
	}

	function editShot(path) {
		if (root.phase !== "idle") return;
		Popups.withFocusedScreen(screen => {
			if (root.phase !== "idle") return;
			root.session = String(Date.now());
			root.openEditor(String(screen?.name ?? ""), path, null, false);
		});
	}

	// ── scroll screenshot ──────────────────────────────────────────────────
	// The region is grabbed live (grim -g) while the user scrolls; the overlay
	// only draws a frame outside of it. Enter / Stop stitches the frames.
	function startScroll(output, logical) {
		const screen = Quickshell.screens.find(s => String(s.name) === String(output));
		if (!screen || !logical || logical.width < 8 || logical.height < 8) {
			root.fail("Scroll screenshot failed", "");
			return;
		}
		// a copy: the rect handed in stays bound to the overlay's selection
		const r = Qt.rect(Math.round(logical.x), Math.round(logical.y), Math.round(logical.width), Math.round(logical.height));
		root.scrollScreen = String(output);
		root.scrollRect = r;
		root.scrollStopping = false;
		root.phase = "scroll";
		// the live screen shows through from now on
		root.frozen = {};
		Quickshell.execDetached(["bash", root.script, "clean"]);
		scrollProc.cancelled = false;
		scrollProc.tag = root.session;
		scrollProc.command = ["bash", root.script, "scroll-capture", root.session, `${Math.round(screen.x + r.x)},${Math.round(screen.y + r.y)} ${r.width}x${r.height}`];
		scrollProc.running = true;
	}

	function stopScroll() {
		if (root.phase !== "scroll" || root.scrollStopping) return;
		root.scrollStopping = true;
		Quickshell.execDetached(["touch", `${root.tmpDir}/scroll-${scrollProc.tag}/stop`]);
	}

	Process {
		id: scrollProc

		property bool cancelled: false
		property string tag: ""
		onExited: exitCode => {
			if (scrollProc.cancelled) {
				Quickshell.execDetached(["bash", root.script, "scroll-drop", scrollProc.tag]);
				return;
			}
			if (exitCode !== 0) {
				Quickshell.execDetached(["bash", root.script, "scroll-drop", scrollProc.tag]);
				root.fail("Scroll screenshot failed", "grim could not capture the region");
				return;
			}
			root.scrollStopping = true;
			stitchProc.path = `${root.tmpDir}/scroll-${scrollProc.tag}.png`;
			stitchProc.command = ["bash", root.script, "scroll-stitch", scrollProc.tag, stitchProc.path];
			stitchProc.running = true;
		}
	}

	Process {
		id: stitchProc

		property string path: ""
		onExited: exitCode => {
			if (root.phase !== "scroll") {
				Quickshell.execDetached(["rm", "-f", stitchProc.path]);
				return;
			}
			if (exitCode !== 0) {
				root.fail("Scroll screenshot failed", "");
				return;
			}
			Haptics.play("captured");
			root.openEditor(root.scrollScreen, stitchProc.path, null, false);
		}
	}

	// ── beautify ───────────────────────────────────────────────────────────
	// The rendered (annotated) PNG is set on a background with a frame, a
	// shadow and so on (overlays/screenshot/Beautify.qml). Coming from the
	// editor it stays loaded but hidden, so "back" keeps every annotation.
	// Sources in tmpDir belong to the beautifier and go when it closes.
	property string beautySource: ""
	property string beautyScreen: ""
	property bool beautyFromEditor: false

	function beautify(path, output) {
		if (!path || (root.phase !== "edit" && root.phase !== "idle" && root.phase !== "beautify")) return;
		if (root.beautySource !== "" && root.beautySource !== path) root.dropBeautySource(root.beautySource);
		if (root.phase === "idle") root.session = String(Date.now());
		root.beautyFromEditor = root.phase === "edit" || (root.phase === "beautify" && root.beautyFromEditor);
		root.beautySource = String(path);
		root.beautyScreen = String(output || root.editScreen);
		root.phase = "beautify";
	}

	// any PNG (IPC), on the focused output
	function beautifyFile(path) {
		if (root.phase !== "idle" || !path) return;
		Popups.withFocusedScreen(screen => root.beautify(String(path), String(screen?.name ?? "")));
	}

	function backToEditor() {
		if (root.phase !== "beautify") return;
		if (!root.beautyFromEditor) {
			root.cancel();
			return;
		}
		root.dropBeautySource(root.beautySource);
		root.phase = "edit";
	}

	// the view still shows the image while it fades out
	function dropBeautySource(path) {
		if (!path || path.indexOf(`${root.tmpDir}/`) !== 0 || path === root.editSource) return;
		Quickshell.execDetached(["sh", "-c", 'sleep 1; rm -f "$1"', "sh", path]);
	}

	onPhaseChanged: if (root.phase === "idle" && root.beautySource !== "") {
		root.dropBeautySource(root.beautySource);
		root.beautySource = "";
	}

	// ── closing ────────────────────────────────────────────────────────────
	function fail(title, detail) {
		root.cancel();
		Haptics.play("taskFailed");
		Notifs.pushInternal("error", title, detail, { icon: "alert_circle" });
	}

	function cancel() {
		if (scrollProc.running) {
			scrollProc.cancelled = true;
			Quickshell.execDetached(["touch", `${root.tmpDir}/scroll-${scrollProc.tag}/stop`]);
		}
		countdownTick.stop();
		root.countdown = 0;
		root.scrollStopping = false;
		root.phase = "idle";
		root.cleanup();
	}

	function closeEditor() {
		root.cancel();
	}

	// frozen frames go away with the overlay; the frames are dropped a bit
	// later so the closing animation can still show them
	function cleanup() {
		cleanTimer.restart();
	}

	Timer {
		id: cleanTimer

		interval: Motion.long + 200
		onTriggered: {
			if (root.phase !== "idle" && root.phase !== "countdown") return;
			root.frozen = {};
			root.boxes = {};
			// a pin that was taken back into the editor, a stitched scroll shot
			if (root.editSource.indexOf("/pin-") >= 0 || root.editSource.indexOf("/scroll-") >= 0) Quickshell.execDetached(["rm", "-f", root.editSource]);
			root.editSource = "";
			Quickshell.execDetached(["bash", root.script, "clean"]);
		}
	}

	Component.onCompleted: {
		Quickshell.execDetached(["bash", root.script, "clean"]);
		Quickshell.execDetached(["bash", root.script, "unpin-all"]);
		Quickshell.execDetached(["bash", root.script, "history-reset"]);
	}
}
