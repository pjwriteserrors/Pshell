pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The text editor (plugin "editor", scripts/editor/): a process of its own, as
// Quickshell cannot host a web view. It wears the shell's tokens, written here
// to editor-theme.json whenever the theme moves, and tells what it holds in
// editor-status.json.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("editor")
	readonly property bool isDefault: root.enabled && Plugins.on("editor-default")
	readonly property string program: `${Paths.scripts}/editor/app.py`

	property bool running: false
	property int tabs: 0
	property int unsaved: 0
	property int words: 0
	property string title: ""
	// the focused window's cursor stands in running text (Autocorrect)
	property bool prose: false

	function open(path, line) {
		if (!root.enabled) return;
		const target = line > 0 ? `${path}:${line}` : path;
		Quickshell.execDetached(["python3", root.program].concat(target ? [target] : []));
	}
	function scratch() {
		if (root.enabled) Quickshell.execDetached(["python3", root.program, "--scratch"]);
	}
	function terminal(script) {
		Quickshell.execDetached(Terminal.command({ title: "Pshell Editor" }, ["bash", script]));
	}

	// ── the look ───────────────────────────────────────────────────────
	function css(color) {
		return `rgba(${Math.round(color.r * 255)},${Math.round(color.g * 255)},${Math.round(color.b * 255)},${color.a.toFixed(3)})`;
	}
	readonly property string tokens: JSON.stringify({
		bg: root.css(Theme.base), fg: root.css(Theme.text), primary: root.css(Theme.primary),
		secondary: root.css(Theme.secondary), tertiary: root.css(Theme.tertiary), onPrimary: root.css(Theme.onPrimary),
		danger: root.css(Theme.danger), warning: root.css(Theme.warning), success: root.css(Theme.success),
		layer1: root.css(Theme.layer1), layer2: root.css(Theme.layer2), layer3: root.css(Theme.layer3),
		primarySoft: root.css(Theme.primarySoft), primaryContainer: root.css(Theme.primaryContainer),
		textMuted: root.css(Theme.textMuted), textSubtle: root.css(Theme.textSubtle), textFaint: root.css(Theme.textFaint),
		outline: root.css(Theme.outline), shadow: root.css(Theme.shadow), scrim: root.css(Theme.scrim),
		font: `"${Theme.fontFamily}", sans-serif`, mono: `"${Theme.monoFamily}", monospace`,
		"r-s": `${Theme.radius.small}px`, "r-m": `${Theme.radius.medium}px`, "r-l": `${Theme.radius.large}px`, "r-h": `${Theme.radius.huge}px`
	})
	onTokensChanged: themeTimer.restart()
	onEnabledChanged: {
		themeTimer.restart();
		root.applyDefault();
		if (root.enabled) warmTimer.restart();
		else Quickshell.execDetached(["python3", root.program, "--quit"]);
	}
	onIsDefaultChanged: root.applyDefault()
	Component.onCompleted: {
		themeTimer.restart();
		root.applyDefault();
		if (root.enabled) warmTimer.restart();
	}

	// the editor started a while after the shell, its window loaded hidden: it opens at once
	Timer {
		id: warmTimer

		interval: 8000
		onTriggered: if (root.enabled) Quickshell.execDetached(["python3", root.program, "--warm"])
	}

	Timer {
		id: themeTimer

		interval: 120
		onTriggered: if (root.enabled) themeFile.setText(root.tokens)
	}
	FileView {
		id: themeFile

		path: Paths.stateFile("editor-theme.json")
		printErrors: false
		blockLoading: false
	}

	// ── what it holds ──────────────────────────────────────────────────
	FileView {
		id: statusFile

		path: root.enabled ? `${Paths.runtime}/editor-status.json` : ""
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			try {
				const data = JSON.parse(statusFile.text());
				root.running = !!data.open;
				root.tabs = Number(data.tabs ?? 0);
				root.unsaved = Number(data.unsaved ?? 0);
				root.words = Number(data.words ?? 0);
				root.title = String(data.title ?? "");
			} catch (error) {
				root.running = false;
			}
		}
	}

	FileView {
		id: proseFile

		path: root.enabled ? `${Paths.runtime}/editor-prose.json` : ""
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			try {
				root.prose = !!JSON.parse(proseFile.text()).prose;
			} catch (error) {
				root.prose = false;
			}
		}
		onLoadFailed: root.prose = false
	}

	// ── as an app of the desktop ───────────────────────────────────────
	property bool entryInstalled: false
	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/editor/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}
	Process {
		id: defaultProc
	}
}
