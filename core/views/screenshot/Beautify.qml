pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Screenshot beautifier: the rendered capture on a background, with padding,
// rounded corners, a shadow, an optional window / browser / phone frame, a
// canvas ratio and a 3D tilt. The preview is drawn at screen size; copy, save
// and pin draw the same picture again at the native size of the screenshot.
// Settings are remembered, named presets live in beautify-presets.json.
//
// Keys: Enter / Ctrl+C copy · Ctrl+S save (Shift keeps the view open)
//   Ctrl+P pin · Backspace / Ctrl+E back to the editor · Esc / q close
//   Tab / Shift+Tab background · a ratio · f frame · t tilt · b border
FocusScope {
	id: view

	required property string source
	required property string output
	required property real density
	property bool fromEditor: false
	// no frozen frame behind the view (opened from IPC)
	property bool plain: false

	// the source may be dropped while the view fades out
	property string shot: ""
	readonly property string shotUrl: Screenshot.fileUrl(view.shot)
	readonly property real imgW: probe.implicitWidth
	readonly property real imgH: probe.implicitHeight
	readonly property bool ready: probe.status === Image.Ready && view.imgW > 0

	onSourceChanged: if (view.source !== "") view.shot = view.source
	Component.onCompleted: {
		view.shot = view.source;
		view.load();
	}

	Image {
		id: probe

		visible: false
		source: view.shotUrl
		asynchronous: false
		cache: true
	}

	readonly property string wallpaperPath: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current/frame.png`

	// ── settings ───────────────────────────────────────────────────────────
	readonly property var defaults: ({
			bg: "g:aurora",
			grain: 0,
			padding: 72,
			inset: 0,
			radius: 14,
			shadow: 55,
			border: true,
			glow: false,
			reflection: false,
			frame: "none",
			dark: true,
			title: "",
			aspect: "auto",
			scale: 100,
			alignX: 0.5,
			alignY: 0.5,
			tilt: "none"
		})
	property var cfg: view.defaults
	property var presets: []
	property bool busy: false

	function set(key, value) {
		const next = Object.assign({}, view.cfg);
		next[key] = value;
		view.cfg = next;
		persistLater.restart();
	}

	function applyPreset(preset) {
		view.cfg = Object.assign({}, view.defaults, preset.cfg ?? {});
		persistLater.restart();
	}

	function savePreset(name) {
		const clean = String(name).trim();
		if (clean === "") return;
		view.presets = view.presets.filter(p => p.name !== clean).concat([{ name: clean, cfg: Object.assign({}, view.cfg) }]);
		view.persist();
	}

	function deletePreset(name) {
		view.presets = view.presets.filter(p => p.name !== name);
		view.persist();
	}

	function load() {
		try {
			const data = JSON.parse(store.text() || "{}");
			view.presets = Array.isArray(data.presets) ? data.presets.filter(p => p && p.name) : [];
			if (data.last) view.cfg = Object.assign({}, view.defaults, data.last);
		} catch (error) {
			view.presets = [];
		}
	}

	function persist() {
		persistLater.stop();
		store.setText(JSON.stringify({ last: view.cfg, presets: view.presets }, null, 2));
	}

	FileView {
		id: store

		path: Paths.stateFile("beautify-presets.json")
		blockLoading: true
		printErrors: false
	}

	// grain and checkerboard tiles, written once per session into tmpfs
	Process {
		running: true
		command: ["python3", "-c", `
import os, random, struct, sys, zlib
def png(path, n, pixel):
    if os.path.exists(path): return
    rows = b"".join(b"\\0" + b"".join(pixel(x, y) for x in range(n)) for y in range(n))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\\x89PNG\\r\\n\\x1a\\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path + ".tmp", "wb").write(data)
    os.replace(path + ".tmp", path)
def grain(x, y):
    v = random.choice((0, 255))
    return bytes((v, v, v, random.randint(0, 110)))
png(sys.argv[1], 128, grain)
png(sys.argv[2], 16, lambda x, y: bytes((244, 244, 246, 255)) if (x < 8) == (y < 8) else bytes((216, 216, 220, 255)))
`, `${Screenshot.tmpDir}/beautify-grain.png`, `${Screenshot.tmpDir}/beautify-checker.png`]
		onExited: exitCode => {
			if (exitCode !== 0) return;
			view.noiseUrl = Screenshot.fileUrl(`${Screenshot.tmpDir}/beautify-grain.png`);
			view.checkerUrl = Screenshot.fileUrl(`${Screenshot.tmpDir}/beautify-checker.png`);
		}
	}

	Timer {
		id: persistLater

		interval: 600
		onTriggered: view.persist()
	}

	// ── catalogues ─────────────────────────────────────────────────────────
	readonly property var gradients: [
		{ id: "aurora", kind: "mesh", base: "#0b1030", blobs: [[0.12, 0.18, 0.62, "#1fd1b9"], [0.88, 0.12, 0.6, "#7b5cff"], [0.72, 0.98, 0.72, "#ff4fa3"], [0.05, 0.95, 0.5, "#2b6bff"]] },
		{ id: "peach", kind: "mesh", base: "#ffd9c4", blobs: [[0.08, 0.1, 0.7, "#ff9a8b"], [0.92, 0.18, 0.6, "#ffc3a0"], [0.5, 1.02, 0.7, "#b8a2ff"], [0.98, 0.92, 0.42, "#ffe29f"]] },
		{ id: "lagoon", kind: "mesh", base: "#d6f1ff", blobs: [[0, 0, 0.7, "#7ee8fa"], [1, 0.1, 0.6, "#a0c4ff"], [0.3, 1, 0.7, "#b9fbc0"], [0.92, 0.92, 0.5, "#cdb4ff"]] },
		{ id: "ember", kind: "mesh", base: "#1a0710", blobs: [[0.2, 0.22, 0.6, "#ff5e3a"], [0.82, 0.18, 0.55, "#ff2a68"], [0.62, 0.95, 0.7, "#ffb347"], [0.04, 0.92, 0.45, "#8e2de2"]] },
		{ id: "nebula", kind: "mesh", base: "#07060f", blobs: [[0.25, 0.75, 0.62, "#5b21b6"], [0.78, 0.3, 0.58, "#0ea5e9"], [0.55, 0.55, 0.35, "#ec4899"]] },
		{ id: "sunset", kind: "linear", angle: 135, stops: [[0, "#ff7e5f"], [1, "#feb47b"]] },
		{ id: "ocean", kind: "linear", angle: 135, stops: [[0, "#2e3192"], [1, "#1bffff"]] },
		{ id: "violet", kind: "linear", angle: 135, stops: [[0, "#8e2de2"], [1, "#4a00e0"]] },
		{ id: "candy", kind: "linear", angle: 120, stops: [[0, "#ff9a9e"], [0.5, "#fad0c4"], [1, "#fbc2eb"]] },
		{ id: "mint", kind: "linear", angle: 135, stops: [[0, "#d4fc79"], [1, "#96e6a1"]] },
		{ id: "forest", kind: "linear", angle: 150, stops: [[0, "#134e5e"], [1, "#71b280"]] },
		{ id: "dusk", kind: "linear", angle: 160, stops: [[0, "#0f2027"], [0.5, "#203a43"], [1, "#2c5364"]] },
		{ id: "cosmic", kind: "linear", angle: 135, stops: [[0, "#ff00cc"], [1, "#333399"]] },
		{ id: "cloud", kind: "linear", angle: 180, stops: [[0, "#fdfbfb"], [1, "#e2e6ec"]] },
		{ id: "graphite", kind: "linear", angle: 135, stops: [[0, "#232526"], [1, "#44474a"]] }
	]

	// generated from the wallust palette, they follow the theme
	readonly property var themed: {
		const c = v => Qt.color(v).toString();
		const p = Theme.primary;
		const s = Theme.secondary;
		const t = Theme.tertiary;
		return [
			{ id: "t0", kind: "linear", angle: 135, stops: [[0, c(p)], [1, c(s)]] },
			{ id: "t1", kind: "mesh", base: c(Qt.darker(Theme.bg, 1.15)), blobs: [[0.1, 0.15, 0.62, c(p)], [0.92, 0.2, 0.55, c(s)], [0.6, 1, 0.7, c(t)]] },
			{ id: "t2", kind: "linear", angle: 160, stops: [[0, c(Theme.bg)], [1, c(Qt.darker(p, 1.3))]] },
			{ id: "t3", kind: "mesh", base: c(Qt.tint("#ffffff", Qt.alpha(p, 0.18))), blobs: [[0, 0, 0.7, c(Qt.tint("#ffffff", Qt.alpha(p, 0.55)))], [1, 0.3, 0.6, c(Qt.tint("#ffffff", Qt.alpha(s, 0.5)))], [0.4, 1, 0.7, c(Qt.tint("#ffffff", Qt.alpha(t, 0.5)))]] }
		];
	}

	readonly property var solids: ["#ffffff", "#eceef1", "#1c1c1f", "#000000", "primary", "secondary", "tertiary"]

	readonly property var bgKeys: view.gradients.map(g => `g:${g.id}`).concat(view.themed.map(g => `g:${g.id}`)).concat(view.solids.map(c => `c:${c}`)).concat(["wall", "wallblur", "none"])

	function solidColor(name) {
		if (name === "primary") return Qt.color(Theme.primary).toString();
		if (name === "secondary") return Qt.color(Theme.secondary).toString();
		if (name === "tertiary") return Qt.color(Theme.tertiary).toString();
		return name;
	}

	function resolveBg(key) {
		const k = String(key);
		if (k.startsWith("g:")) {
			const id = k.slice(2);
			return view.gradients.concat(view.themed).find(g => g.id === id) ?? view.gradients[0];
		}
		if (k.startsWith("c:")) return { kind: "solid", color: view.solidColor(k.slice(2)) };
		if (k === "wall") return { kind: "image", path: view.wallpaperPath, blur: 0 };
		if (k === "wallblur") return { kind: "image", path: view.wallpaperPath, blur: 1 };
		return { kind: "none" };
	}

	readonly property var bgSpec: view.resolveBg(view.cfg.bg)
	// the most vivid colour of the background, a bit brighter
	readonly property color glowColor: {
		const b = view.bgSpec;
		let colours = [Theme.primary];
		if (b.kind === "mesh") colours = b.blobs.map(x => x[3]);
		else if (b.kind === "linear") colours = b.stops.map(x => x[1]);
		else if (b.kind === "solid") colours = [b.color];
		let best = Qt.color(colours[0]);
		for (const c of colours.map(x => Qt.color(x)))
			if (c.hsvSaturation * c.hsvValue > best.hsvSaturation * best.hsvValue) best = c;
		return Qt.hsva(best.hsvHue, Math.min(1, best.hsvSaturation), Math.min(1, best.hsvValue * 1.25 + 0.1), 1);
	}

	readonly property var ratios: ({ auto: 0, "16:9": 16 / 9, "4:3": 4 / 3, "3:2": 1.5, "1:1": 1, "4:5": 0.8, "9:16": 9 / 16, x: 16 / 9, linkedin: 1.91 })
	readonly property var aspects: [
		{ value: "auto", label: "Auto" },
		{ value: "16:9", label: "16:9" },
		{ value: "4:3", label: "4:3" },
		{ value: "3:2", label: "3:2" },
		{ value: "1:1", label: "1:1" },
		{ value: "4:5", label: "4:5" },
		{ value: "9:16", label: "9:16" },
		{ value: "x", label: "X" },
		{ value: "linkedin", label: "LinkedIn" }
	]
	// [x°, y°, z°, block scale]
	readonly property var tilts: ({ none: [0, 0, 0, 1], left: [6, 24, 0, 0.84], right: [6, -24, 0, 0.84], back: [30, 0, 0, 0.86], float: [18, -16, 5, 0.82] })
	readonly property var tiltList: [
		{ value: "none", label: "None" },
		{ value: "left", label: "Left" },
		{ value: "right", label: "Right" },
		{ value: "back", label: "Back" },
		{ value: "float", label: "Float" }
	]
	readonly property var frames: [
		{ value: "none", label: "None", icon: "crop_free" },
		{ value: "mac", label: "Window", icon: "apple" },
		{ value: "browser", label: "Browser", icon: "web" },
		{ value: "phone", label: "Phone", icon: "cellphone" }
	]

	function cycle(list, current, step) {
		const i = list.indexOf(current);
		return list[(Math.max(0, i) + step + list.length) % list.length];
	}

	// ── geometry (native px) ───────────────────────────────────────────────
	readonly property var target: {
		const c = view.cfg;
		const t = view.tilts[c.tilt] ?? view.tilts.none;
		return {
			padding: Number(c.padding),
			inset: Number(c.inset),
			radius: Number(c.radius),
			shadow: Number(c.shadow) / 100,
			scale: Number(c.scale) / 100 * t[3],
			ax: Number(c.alignX),
			ay: Number(c.alignY),
			bar: c.frame === "mac" ? 32 : (c.frame === "browser" ? 44 : 0),
			bezel: c.frame === "phone" ? 12 : 0,
			phone: c.frame === "phone",
			windowed: c.frame === "mac" || c.frame === "browser",
			ratio: view.ratios[c.aspect] ?? 0,
			rx: t[0],
			ry: t[1],
			rz: t[2]
		};
	}

	function geometry(v, size) {
		const u = view.density;
		const inset = v.inset * u;
		const bar = v.bar * u;
		const bezel = v.bezel * u;
		const pad = v.padding * u;
		const radius = v.radius * u;
		const cw = view.imgW + 2 * inset;
		const ch = view.imgH + 2 * inset;
		const bw = cw + 2 * bezel;
		const bh = ch + 2 * bezel + bar;
		let W = bw + 2 * pad;
		let H = bh + 2 * pad;
		if (v.ratio > 0) {
			if (W / H > v.ratio) H = W / v.ratio;
			else W = H * v.ratio;
		}
		if (size) {
			W = size.width;
			H = size.height;
		}
		const s = v.scale;
		const screenRadius = v.phone ? Math.max(radius, 30 * u) : (v.windowed ? 0 : radius);
		return {
			u: u,
			iw: view.imgW,
			ih: view.imgH,
			inset: inset,
			bar: bar,
			bezel: bezel,
			cw: cw,
			ch: ch,
			bw: bw,
			bh: bh,
			W: Math.round(W),
			H: Math.round(H),
			s: s,
			bx: pad + (W - 2 * pad - bw * s) * v.ax - bw * (1 - s) / 2,
			by: pad + (H - 2 * pad - bh * s) * v.ay - bh * (1 - s) / 2,
			screenRadius: screenRadius,
			outerRadius: v.phone ? screenRadius + bezel : radius,
			shadow: v.shadow,
			rx: v.rx,
			ry: v.ry,
			rz: v.rz
		};
	}

	readonly property var exact: view.geometry(view.target, null)

	// the preview animates every number towards the target
	property bool animate: false
	Timer {
		running: view.ready
		interval: 60
		onTriggered: view.animate = true
	}

	component Smooth: NumberAnimation {
		duration: Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}

	QtObject {
		id: live

		property real padding: view.target.padding
		property real inset: view.target.inset
		property real radius: view.target.radius
		property real shadow: view.target.shadow
		property real scale: view.target.scale
		property real ax: view.target.ax
		property real ay: view.target.ay
		property real bar: view.target.bar
		property real bezel: view.target.bezel
		property real rx: view.target.rx
		property real ry: view.target.ry
		property real rz: view.target.rz
		property real w: view.exact.W
		property real h: view.exact.H

		Behavior on padding { enabled: view.animate; Smooth {} }
		Behavior on inset { enabled: view.animate; Smooth {} }
		Behavior on radius { enabled: view.animate; Smooth {} }
		Behavior on shadow { enabled: view.animate; Smooth {} }
		Behavior on scale { enabled: view.animate; Smooth {} }
		Behavior on ax { enabled: view.animate; Smooth {} }
		Behavior on ay { enabled: view.animate; Smooth {} }
		Behavior on bar { enabled: view.animate; Smooth {} }
		Behavior on bezel { enabled: view.animate; Smooth {} }
		Behavior on rx { enabled: view.animate; SpatialAnim {} }
		Behavior on ry { enabled: view.animate; SpatialAnim {} }
		Behavior on rz { enabled: view.animate; SpatialAnim {} }
		Behavior on w { enabled: view.animate; Smooth {} }
		Behavior on h { enabled: view.animate; Smooth {} }
	}

	readonly property var shown: view.geometry({
		padding: live.padding,
		inset: live.inset,
		radius: live.radius,
		shadow: live.shadow,
		scale: live.scale,
		ax: live.ax,
		ay: live.ay,
		bar: live.bar,
		bezel: live.bezel,
		phone: view.target.phone,
		windowed: view.target.windowed,
		ratio: 0,
		rx: live.rx,
		ry: live.ry,
		rz: live.rz
	}, Qt.size(live.w, live.h))

	// ── export ─────────────────────────────────────────────────────────────
	property var pending: null

	function render(path, done) {
		if (view.busy || !view.ready) return;
		view.persist();
		view.busy = true;
		view.pending = { path: path, done: done };
		exporter.active = true;
		grabLater.restart();
	}

	Timer {
		id: grabLater

		interval: 48
		onTriggered: {
			const job = view.pending;
			const item = exporter.item;
			const finish = ok => {
				exporter.active = false;
				view.busy = false;
				view.pending = null;
				job.done(ok);
			};
			if (!item) {
				finish(false);
				return;
			}
			const ok = item.grabToImage(result => finish(result.saveToFile(job.path)), Qt.size(item.width, item.height));
			if (!ok) finish(false);
		}
	}

	function copy(stay) {
		const path = Screenshot.nextTempPath("copy");
		view.render(path, ok => {
			if (!ok) {
				Screenshot.exportFailed();
				return;
			}
			Screenshot.copied(path);
			if (Screenshot.earlyExit && !stay) view.close();
		});
	}

	function save(stay) {
		const path = Screenshot.nextSavePath();
		Quickshell.execDetached(["mkdir", "-p", Screenshot.saveDir]);
		view.render(path, ok => {
			if (!ok) {
				Screenshot.fail("Screenshot could not be saved", path);
				return;
			}
			Screenshot.saved(path);
			if (Screenshot.earlyExit && !stay) view.close();
		});
	}

	function pin() {
		if (!Plugins.on("pins")) return;
		const path = Screenshot.nextTempPath("pin");
		const output = view.output;
		view.render(path, ok => {
			if (!ok) {
				Screenshot.exportFailed();
				return;
			}
			Screenshot.pin(path, output, Qt.rect(0, 0, 0, 0));
			view.close();
		});
	}

	function close() {
		view.persist();
		Screenshot.cancel();
	}

	function back() {
		view.persist();
		if (view.fromEditor) Screenshot.backToEditor();
		else view.close();
	}

	// ── keyboard ───────────────────────────────────────────────────────────
	readonly property bool typing: titleField.focused || nameField.focused

	Keys.onPressed: event => {
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
		const key = event.key;
		event.accepted = true;
		if (view.typing) {
			if (key === Qt.Key_Escape || key === Qt.Key_Return || key === Qt.Key_Enter) {
				if (nameField.focused && key !== Qt.Key_Escape) view.savePreset(nameField.text);
				panel.naming = false;
				view.forceActiveFocus();
			} else {
				event.accepted = false;
			}
			return;
		}
		if (ctrl) {
			if (key === Qt.Key_C) view.copy(shift);
			else if (key === Qt.Key_S) view.save(shift);
			else if (key === Qt.Key_P) view.pin();
			else if (key === Qt.Key_E) view.back();
			else if (key === Qt.Key_W) view.close();
			else event.accepted = false;
			return;
		}
		switch (key) {
		case Qt.Key_Escape:
		case Qt.Key_Q:
			view.close();
			return;
		case Qt.Key_Return:
		case Qt.Key_Enter:
			view.copy(shift);
			return;
		case Qt.Key_Backspace:
			if (view.fromEditor) view.back();
			return;
		case Qt.Key_Tab:
		case Qt.Key_Backtab:
			view.set("bg", view.cycle(view.bgKeys, view.cfg.bg, key === Qt.Key_Backtab || shift ? -1 : 1));
			return;
		case Qt.Key_A:
			view.set("aspect", view.cycle(view.aspects.map(a => a.value), view.cfg.aspect, shift ? -1 : 1));
			return;
		case Qt.Key_F:
			view.set("frame", view.cycle(view.frames.map(f => f.value), view.cfg.frame, shift ? -1 : 1));
			return;
		case Qt.Key_T:
			view.set("tilt", view.cycle(view.tiltList.map(f => f.value), view.cfg.tilt, shift ? -1 : 1));
			return;
		case Qt.Key_B:
			view.set("border", !view.cfg.border);
			return;
		}
		event.accepted = false;
	}

	// ── generated textures: edge colour, grain, checkerboard ───────────────
	property color edge: "#ffffff"
	property string noiseUrl: ""
	property string checkerUrl: ""

	// clicks outside the controls leave text fields
	MouseArea {
		anchors.fill: parent
		onPressed: view.forceActiveFocus()
	}

	Rectangle {
		anchors.fill: parent
		visible: view.plain
		color: Qt.alpha(Theme.bg, 0.72)
	}

	// ── preview ────────────────────────────────────────────────────────────
	readonly property real areaX: 40
	readonly property real areaY: 40
	readonly property real areaW: panel.x - 40 - view.areaX
	readonly property real areaH: actionBar.y - 24 - view.areaY
	readonly property real fit: Math.max(0.01, Math.min(view.areaW / Math.max(1, view.shown.W), view.areaH / Math.max(1, view.shown.H), 1 / Math.max(0.01, view.density)))
	property bool entered: false

	Timer {
		running: view.ready
		interval: 16
		onTriggered: view.entered = true
	}

	Item {
		id: stage

		x: Math.round(view.areaX + (view.areaW - width) / 2)
		y: Math.round(view.areaY + (view.areaH - height) / 2)
		width: preview.width
		height: preview.height
		visible: view.ready
		opacity: view.entered ? 1 : 0
		scale: view.entered ? 1 : 0.94

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		RectangularShadow {
			anchors.fill: parent
			blur: 40
			offset.y: 12
			color: Qt.rgba(0, 0, 0, 0.45)
			opacity: view.cfg.bg === "none" ? 0 : 1

			Behavior on opacity {
				Anim {}
			}
		}

		// transparency shows as a checkerboard (only here, never exported)
		Image {
			anchors.fill: parent
			source: view.checkerUrl
			fillMode: Image.Tile
			opacity: view.cfg.bg === "none" ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {}
			}
		}

		BeautyCanvas {
			id: preview

			g: view.shown
			k: view.fit
			source: view.shotUrl
			bg: view.bgSpec
			frame: view.cfg.frame
			dark: view.cfg.dark
			title: view.cfg.title
			border: view.cfg.border
			glow: view.cfg.glow
			glowColor: view.glowColor
			reflection: view.cfg.reflection
			grain: view.cfg.grain / 100
			edge: view.edge
			noiseUrl: view.noiseUrl
			animated: view.animate
		}
	}

	// the export copy at native size; drawn once per export
	Item {
		width: 0
		height: 0
		clip: true

		Loader {
			id: exporter

			active: false
			sourceComponent: BeautyCanvas {
				g: view.exact
				k: 1
				source: view.shotUrl
				bg: view.bgSpec
				frame: view.cfg.frame
				dark: view.cfg.dark
				title: view.cfg.title
				border: view.cfg.border
				glow: view.cfg.glow
				glowColor: view.glowColor
				reflection: view.cfg.reflection
				grain: view.cfg.grain / 100
				edge: view.edge
				noiseUrl: view.noiseUrl
				animated: false
			}
		}
	}

	// ── action bar ─────────────────────────────────────────────────────────
	component Divider: Rectangle {
		anchors.verticalCenter: parent?.verticalCenter
		width: 1
		height: 22
		color: Theme.outline
	}

	component BarButton: IconButton {
		anchors.verticalCenter: parent?.verticalCenter
		implicitWidth: 38
		implicitHeight: 38
		iconSize: 19
	}

	Rectangle {
		id: actionBar

		anchors.horizontalCenter: stageArea.horizontalCenter
		y: view.entered ? view.height - height - 24 : view.height + 20
		width: actionRow.implicitWidth + 20
		height: 52
		radius: height / 2
		color: Theme.base

		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}

		RectangularShadow {
			anchors.fill: parent
			z: -1
			radius: parent.radius
			blur: 30
			offset.y: 8
			color: Theme.shadow
		}

		Row {
			id: actionRow

			anchors.centerIn: parent
			spacing: 6

			BarButton {
				visible: view.fromEditor
				icon: "arrow_left"
				onClicked: view.back()
			}

			Divider {
				visible: view.fromEditor
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				leftPadding: 8
				rightPadding: 8
				tabular: true
				text: `${view.exact.W} × ${view.exact.H}`
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			Divider {}

			BarButton {
				visible: Plugins.on("pins")
				icon: "pin_outline"
				onClicked: view.pin()
			}

			BarButton {
				icon: "content_save"
				onClicked: view.save(false)
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				height: 38
				variant: "filled"
				icon: "content_copy"
				text: "Copy"
				busy: view.busy
				onActivated: view.copy(false)
			}

			BarButton {
				icon: "close"
				onClicked: view.close()
			}
		}
	}

	Item {
		id: stageArea

		x: view.areaX
		width: view.areaW
		height: 1
	}

	// ── control panel ──────────────────────────────────────────────────────
	component Section: SectionLabel {
		topPadding: 6
	}

	component Slider: PillSlider {
		id: slider

		property string key: ""
		property real from: 0
		property real to: 100
		property string unit: ""

		width: parent?.width ?? 0
		height: 34
		value: (Number(view.cfg[slider.key]) - slider.from) / (slider.to - slider.from)
		stepSize: 1 / (slider.to - slider.from)
		valueText: `${Math.round(Number(view.cfg[slider.key]))}${slider.unit}`
		onMoved: value => view.set(slider.key, Math.round(slider.from + value * (slider.to - slider.from)))
	}

	component Tile: Item {
		id: tile

		property string key: ""
		property var spec: view.resolveBg(tile.key)
		readonly property bool current: view.cfg.bg === tile.key

		width: 34
		height: 34

		Rectangle {
			anchors.centerIn: parent
			width: tile.current ? 34 : 28
			height: width
			radius: tile.current ? 12 : 10
			color: "transparent"
			border.width: 2
			border.color: tile.current ? Theme.text : "transparent"

			Behavior on width {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		ClippingRectangle {
			id: face

			anchors.centerIn: parent
			width: tileMouse.containsMouse ? 28 : 26
			height: width
			radius: 8
			color: Theme.layer2

			Behavior on width {
				SpatialAnim {
					duration: Motion.short
				}
			}

			Image {
				anchors.fill: parent
				visible: tile.spec.kind === "none"
				source: view.checkerUrl
				fillMode: Image.Tile
			}

			BeautyBackground {
				anchors.fill: parent
				spec: tile.spec
			}
		}

		MouseArea {
			id: tileMouse

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: view.set("bg", tile.key)
		}
	}

	component Choice: Chip {
		property string key: ""
		property string value: ""

		selected: String(view.cfg[key]) === value
		onClicked: view.set(key, value)
	}

	component Switch: Chip {
		property string key: ""

		selected: !!view.cfg[key]
		onClicked: view.set(key, !view.cfg[key])
	}

	Rectangle {
		id: panel

		property bool naming: false
		readonly property real inner: panel.width - 36

		x: view.entered ? view.width - width - 20 : view.width + 20
		y: Math.round((view.height - height) / 2)
		width: 324
		height: Math.min(view.height - 40, controls.implicitHeight + 36)
		radius: Theme.radius.huge
		color: Theme.base

		Behavior on x {
			SpatialAnim {
				duration: Motion.long
			}
		}

		RectangularShadow {
			anchors.fill: parent
			z: -1
			radius: parent.radius
			blur: 30
			offset.y: 8
			color: Theme.shadow
		}

		// generators hide underneath the panel
		Canvas {
			id: edgeReader

			property string loaded: ""

			z: -2
			x: 20
			y: 20
			width: 1
			height: 1
			canvasSize: Qt.size(48, 48)

			function follow() {
				if (edgeReader.loaded === view.shotUrl) return;
				if (edgeReader.loaded !== "") edgeReader.unloadImage(edgeReader.loaded);
				edgeReader.loaded = view.shotUrl;
				if (view.shotUrl !== "") edgeReader.loadImage(view.shotUrl);
			}

			Component.onCompleted: edgeReader.follow()
			onImageLoaded: edgeReader.requestPaint()
			onPaint: {
				if (edgeReader.loaded === "" || !edgeReader.isImageLoaded(edgeReader.loaded)) return;
				const n = 48;
				const ctx = edgeReader.getContext("2d");
				ctx.clearRect(0, 0, n, n);
				ctx.drawImage(edgeReader.loaded, 0, 0, n, n);
				const d = ctx.getImageData(0, 0, n, n).data;
				// most common colour along the border (quantised buckets)
				const buckets = {};
				let best = null;
				for (let y = 0; y < n; y += 1) {
					for (let x = 0; x < n; x += 1) {
						if (x > 1 && y > 1 && x < n - 2 && y < n - 2) continue;
						const i = (y * n + x) * 4;
						const key = `${d[i] >> 4},${d[i + 1] >> 4},${d[i + 2] >> 4}`;
						const b = buckets[key] ?? (buckets[key] = { n: 0, r: 0, g: 0, b: 0 });
						b.n += 1;
						b.r += d[i];
						b.g += d[i + 1];
						b.b += d[i + 2];
						if (!best || b.n > best.n) best = b;
					}
				}
				if (best) view.edge = Qt.rgba(best.r / best.n / 255, best.g / best.n / 255, best.b / best.n / 255, 1);
			}

			Connections {
				target: view

				function onShotUrlChanged() {
					edgeReader.follow();
				}
			}
		}

		Flickable {
			id: scroller

			anchors.fill: parent
			anchors.margins: 18
			anchors.rightMargin: 12
			contentHeight: controls.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			ThinScrollBar.vertical: ThinScrollBar {}

			Column {
				id: controls

				width: panel.inner
				spacing: 10

				// ── presets ────────────────────────────────────────────────
				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: view.presets

						delegate: Chip {
							id: presetChip

							required property var modelData

							text: presetChip.modelData.name
							icon: presetChip.hovered ? "close" : "bookmark_outline"
							acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
							onClicked: view.applyPreset(presetChip.modelData)
							onRightClicked: view.deletePreset(presetChip.modelData.name)
							onMiddleClicked: view.deletePreset(presetChip.modelData.name)

							MouseArea {
								x: 6
								width: 24
								height: parent.height
								cursorShape: Qt.PointingHandCursor
								onClicked: view.deletePreset(presetChip.modelData.name)
							}
						}
					}

					Chip {
						visible: !panel.naming
						icon: "bookmark_plus_outline"
						text: view.presets.length === 0 ? "Preset" : ""
						onClicked: {
							panel.naming = true;
							nameField.text = "";
							nameField.focusInput();
						}
					}
				}

				Field {
					id: nameField

					width: parent.width
					height: panel.naming ? 36 : 0
					visible: height > 0
					icon: "bookmark_outline"
					placeholder: "Name"
					onAccepted: {
						view.savePreset(nameField.text);
						panel.naming = false;
						view.forceActiveFocus();
					}
				}

				// ── background ─────────────────────────────────────────────
				Section {
					text: "Background"
				}

				Flow {
					width: parent.width
					spacing: 4

					Repeater {
						model: view.gradients.concat(view.themed)

						delegate: Tile {
							required property var modelData

							key: `g:${modelData.id}`
						}
					}

					Repeater {
						model: view.solids

						delegate: Tile {
							required property string modelData

							key: `c:${modelData}`
						}
					}

					Tile {
						key: "wall"
					}

					Tile {
						key: "wallblur"
					}

					Tile {
						key: "none"
					}
				}

				Slider {
					key: "grain"
					icon: "grain"
					label: "Grain"
					to: 60
					unit: "%"
				}

				// ── layout ─────────────────────────────────────────────────
				Section {
					text: "Canvas"
				}

				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: view.aspects

						delegate: Choice {
							required property var modelData

							key: "aspect"
							value: modelData.value
							text: modelData.label
						}
					}
				}

				Row {
					width: parent.width
					spacing: 10

					Column {
						width: parent.width - alignPad.width - 10
						spacing: 8

						Slider {
							key: "padding"
							icon: "arrow_expand_all"
							label: "Padding"
							to: 200
						}

						Slider {
							key: "scale"
							icon: "magnify_plus_outline"
							label: "Scale"
							from: 40
							to: 100
							unit: "%"
						}
					}

					// where the screenshot sits when there is room
					Grid {
						id: alignPad

						anchors.verticalCenter: parent.verticalCenter
						columns: 3
						spacing: 4

						Repeater {
							model: 9

							delegate: Rectangle {
								id: cell

								required property int index
								readonly property real ax: (cell.index % 3) / 2
								readonly property real ay: Math.floor(cell.index / 3) / 2
								readonly property bool current: Math.abs(view.cfg.alignX - cell.ax) < 0.01 && Math.abs(view.cfg.alignY - cell.ay) < 0.01

								width: 20
								height: 20
								radius: 6
								color: cell.current ? Theme.primary : (cellMouse.containsMouse ? Theme.layer3 : Theme.layer2)

								Behavior on color {
									ColorAnim {}
								}

								MouseArea {
									id: cellMouse

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: {
										const next = Object.assign({}, view.cfg, { alignX: cell.ax, alignY: cell.ay });
										view.cfg = next;
										persistLater.restart();
									}
								}
							}
						}
					}
				}

				// ── style ──────────────────────────────────────────────────
				Section {
					text: "Style"
				}

				Slider {
					key: "radius"
					icon: "rounded_corner"
					label: "Radius"
					to: 40
				}

				Slider {
					key: "inset"
					icon: "border_inside"
					label: "Inset"
					to: 120
				}

				Slider {
					key: "shadow"
					icon: "box_shadow"
					label: "Shadow"
					unit: "%"
				}

				Flow {
					width: parent.width
					spacing: 6

					Switch {
						key: "border"
						icon: "border_outside"
						text: "Border"
					}

					Switch {
						key: "glow"
						icon: "flare"
						text: "Glow"
					}

					Switch {
						key: "reflection"
						icon: "flip_vertical"
						text: "Reflection"
					}
				}

				// ── frame ──────────────────────────────────────────────────
				Section {
					text: "Frame"
				}

				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: view.frames

						delegate: Choice {
							required property var modelData

							key: "frame"
							value: modelData.value
							text: modelData.label
							icon: modelData.icon
						}
					}
				}

				Segmented {
					width: parent.width
					height: 34
					visible: view.cfg.frame !== "none"
					current: view.cfg.dark ? "dark" : "light"
					options: [
						{ value: "light", label: "Light", icon: "white_balance_sunny" },
						{ value: "dark", label: "Dark", icon: "weather_night" }
					]
					onSelected: value => view.set("dark", value === "dark")
				}

				Field {
					id: titleField

					width: parent.width
					height: 36
					visible: view.cfg.frame === "mac" || view.cfg.frame === "browser"
					icon: view.cfg.frame === "browser" ? "web" : "format_text"
					placeholder: view.cfg.frame === "browser" ? "URL" : "Title"
					text: view.cfg.title
					onEdited: text => view.set("title", text)
				}

				// ── tilt ───────────────────────────────────────────────────
				Section {
					text: "Tilt"
				}

				Flow {
					width: parent.width
					spacing: 6

					Repeater {
						model: view.tiltList

						delegate: Choice {
							required property var modelData

							key: "tilt"
							value: modelData.value
							text: modelData.label
						}
					}
				}

				Item {
					width: 1
					height: 4
				}
			}
		}
	}
}
