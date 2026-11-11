pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The colours of the wallpaper: which engine makes them (the Pshell's own,
// scripts/palette, or wallust), the style and mode worn, and the tuning of
// every style. Kept in palette.json, which the theme scripts read too.
//
// Settings › Colours tunes a draft: palette.py serve shows it on the
// wallpaper worn (only while the page asks for it), Apply keeps the draft and
// puts the colours on again (apply_theme_selection.sh --colours-only).
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/palette/palette.py`
	readonly property string currentMedia: `${Paths.themeState}/current/media`
	readonly property string currentEntryFile: `${Paths.themeState}/current-theme-dir`

	readonly property var styleNames: ({ vivid: "Vivid", muted: "Muted", pastel: "Pastel", pro: "Professional", mono: "Mono" })
	readonly property var modes: ["dark", "light"]

	// what palette.json says
	property string engine: "pshell"
	property string style: "vivid"
	property string mode: "dark"
	property var tuned: ({})
	// the styles with their defaults (palette.py defaults)
	property var defaults: ({})
	readonly property var styles: Object.keys(root.defaults)

	// ── the draft ──────────────────────────────────────────────────────────
	// style → params as the sliders have them, not kept until apply()
	property var draft: ({})
	readonly property bool dirty: JSON.stringify(root.cleaned(root.draft)) !== JSON.stringify(root.cleaned(root.tuned))

	function params(style) {
		return Object.assign({}, root.defaults[style] ?? {}, root.tuned[style] ?? {}, root.draft[style] ?? {});
	}

	function isDefault(style) {
		const p = root.params(style);
		const d = root.defaults[style] ?? {};
		return Object.keys(d).every(key => Math.abs(Number(p[key]) - Number(d[key])) < 0.0005);
	}

	function setParam(style, key, value) {
		const next = Object.assign({}, root.draft);
		next[style] = Object.assign({}, root.params(style), { [key]: value });
		root.draft = next;
		previewing.restart();
	}

	function resetStyle(style) {
		const next = Object.assign({}, root.draft);
		next[style] = Object.assign({}, root.defaults[style] ?? {});
		root.draft = next;
		previewing.restart();
	}

	function discard() {
		root.draft = {};
		previewing.restart();
	}

	// only what differs from a style's defaults
	function cleaned(map) {
		const out = {};
		for (const style of Object.keys(root.defaults)) {
			const d = root.defaults[style];
			const p = Object.assign({}, d, root.tuned[style] ?? {}, map[style] ?? {});
			const diff = {};
			for (const key of Object.keys(d))
				if (Math.abs(Number(p[key]) - Number(d[key])) >= 0.0005) diff[key] = Math.round(Number(p[key]) * 1000) / 1000;
			if (Object.keys(diff).length > 0) out[style] = diff;
		}
		return out;
	}

	function save() {
		file.setText(JSON.stringify({ engine: root.engine, style: root.style, mode: root.mode, styles: root.tuned }, null, "\t") + "\n");
	}

	function setEngine(name) {
		if (name === root.engine || !["pshell", "wallust"].includes(name)) return;
		root.engine = name;
		root.save();
		root.recolour();
	}

	function choose(style, mode) {
		if (root.styles.includes(style)) root.style = style;
		if (root.modes.includes(mode)) root.mode = mode;
		root.save();
		root.recolour();
	}

	// the draft kept, with the style and mode to wear; the colours put on again
	function apply(style, mode) {
		root.tuned = root.cleaned(root.draft);
		root.draft = {};
		if (root.styles.includes(style)) root.style = style;
		if (root.modes.includes(mode)) root.mode = mode;
		root.save();
		root.recolour();
	}

	function recolour() {
		if (recolourProc.running) {
			root.recolourAgain = true;
			return;
		}
		recolourProc.running = true;
	}
	property bool recolourAgain: false
	readonly property bool applying: recolourProc.running

	function load(text) {
		try {
			const data = JSON.parse(text || "{}");
			root.engine = data.engine === "wallust" ? "wallust" : "pshell";
			if (typeof data.style === "string") root.style = data.style;
			if (typeof data.mode === "string") root.mode = data.mode;
			root.tuned = data.styles && typeof data.styles === "object" ? data.styles : {};
		} catch (error) {}
	}

	FileView {
		id: file

		path: Paths.stateFile("palette.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.load(text())
		onLoadFailed: root.load("{}")
	}

	Process {
		running: true
		command: ["python3", root.script, "defaults"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.defaults = JSON.parse(text).styles ?? {};
				} catch (error) {}
			}
		}
	}

	Process {
		id: recolourProc

		command: ["bash", "-c", "entry=$(cat \"$1\" 2>/dev/null) && [ -n \"$entry\" ] && exec bash \"$2\" \"$entry\" --colours-only", "_", root.currentEntryFile, `${Paths.scripts}/apply_theme_selection.sh`]
		onExited: {
			if (root.recolourAgain) {
				root.recolourAgain = false;
				recolourProc.running = true;
			}
		}
	}

	// ── preview ────────────────────────────────────────────────────────────
	// every style x mode of the wallpaper worn, with the draft: style → mode →
	// scheme ({background, foreground, colors, roles, accents})
	property var preview: ({})
	property bool previewWanted: false
	property int requestId: 0

	onPreviewWantedChanged: if (root.previewWanted) previewing.restart()
	onDefaultsChanged: if (root.previewWanted) previewing.restart()

	function requestPreview() {
		if (!root.previewWanted || root.styles.length === 0) return;
		root.requestId += 1;
		const overrides = {};
		for (const style of root.styles) overrides[style] = root.params(style);
		server.write(JSON.stringify({ id: root.requestId, media: root.currentMedia, all: true, overrides }) + "\n");
	}

	function handle(line) {
		let reply;
		try {
			reply = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (reply.id !== root.requestId || !reply.cells) return;
		const out = {};
		for (const cell of reply.cells) {
			out[cell.style] = out[cell.style] ?? {};
			out[cell.style][cell.mode] = cell;
		}
		root.preview = out;
	}

	Timer {
		id: previewing

		interval: 30
		onTriggered: root.requestPreview()
	}

	Process {
		id: server

		running: root.previewWanted
		stdinEnabled: true
		command: ["python3", "-u", root.script, "serve"]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onRunningChanged: if (running) previewing.restart()
	}

	// a new wallpaper: its preview
	FileView {
		path: `${Paths.themeState}/current-theme-dir`
		watchChanges: true
		printErrors: false
		onFileChanged: {
			reload();
			if (root.previewWanted) previewing.restart();
		}
	}
}
