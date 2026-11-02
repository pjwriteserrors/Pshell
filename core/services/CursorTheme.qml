pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The Pshell cursor theme follows the colours, niri's corner radius, the
// season and its own settings (cursor.json): when one of them changes it is
// drawn anew (scripts/cursor_theme.py) and niri is made to load it. Over
// every window the pointer carries marks of what is going on – recording,
// a microphone or camera in use, the screen shared, Caps Lock on the text
// cursor – worn as variants of the theme. Only while it is worn; another
// cursor theme is left alone.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/cursor_theme.py`
	readonly property string path: `${Paths.state}/cursor.json`
	readonly property bool enabled: true

	// ── settings (Studio › Icons & Pointer) ───────────────────────────────
	// "full" | "subtle" | "off"
	property string animations: "full"
	// details in the accent, or in the outline's colour
	property bool accent: true
	// "niri" or a radius of its own
	property var round: "niri"
	// "auto" (by the date) or "off"
	property string seasons: "auto"
	// which marks the pointer carries
	property var marks: ({ rec: true, privacy: true, share: true, caps: true })
	property bool loaded: false

	readonly property bool marking: root.marks.rec || root.marks.privacy || root.marks.share || root.marks.caps

	function set(key, value) {
		root[key] = value;
		root.save();
		settle.restart();
	}

	// drawn anew now and then: the size niri asks for changed (Studio)
	function refresh() {
		settle.restart();
	}

	function setMark(key, on) {
		const next = Object.assign({}, root.marks);
		next[key] = on;
		root.marks = next;
		root.save();
	}

	function save() {
		file.setText(JSON.stringify({ animations: root.animations, accent: root.accent, round: root.round, seasons: root.seasons, marks: root.marks }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: root.path
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.animations = ["full", "subtle", "off"].includes(data.animations) ? data.animations : "full";
				root.accent = data.accent !== false;
				root.round = data.round ?? "niri";
				root.seasons = data.seasons === "off" || data.seasons === false ? "off" : "auto";
				root.marks = Object.assign({ rec: true, privacy: true, share: true, caps: true }, data.marks ?? {});
			} catch (error) {}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// ── the look ───────────────────────────────────────────────────────────
	// what the cursors are drawn from (the settings come from cursor.json)
	readonly property var inputs: [String(Theme.bg), String(Theme.fg), String(Theme.primary), String(Theme.danger), Theme.windowRadius]

	onInputsChanged: settle.restart()
	Component.onCompleted: settle.restart()

	function colours() {
		return ["--bg", String(Theme.bg), "--fg", String(Theme.fg), "--primary", String(Theme.primary),
			"--danger", String(Theme.danger), "--warning", String(Theme.warning), "--success", String(Theme.success)];
	}

	// a new wallpaper changes the colours several times in a row
	Timer {
		id: settle

		interval: 2500
		onTriggered: {
			if (applyProc.running || wearProc.running) {
				settle.restart();
				return;
			}
			applyProc.command = ["python3", root.script, "apply"].concat(root.colours(), ["--radius", String(Theme.windowRadius)]);
			applyProc.running = true;
		}
	}

	// the season turns with the date: looked at every hour (nothing is drawn
	// unless it did)
	Timer {
		interval: 3600 * 1000
		repeat: true
		running: root.seasons !== "off"
		onTriggered: settle.restart()
	}

	Process {
		id: applyProc

		stderr: StdioCollector {
			onStreamFinished: if (text.trim()) console.warn(`cursor theme: ${text.trim()}`)
		}
		onExited: if (root.worn !== root.wanted) wearing.restart()
	}

	// ── marks ──────────────────────────────────────────────────────────────
	readonly property var shown: [
		root.marks.rec && Recorder.active ? "rec" : "",
		root.marks.privacy && Privacy.mic ? "mic" : "",
		root.marks.privacy && Privacy.camera ? "cam" : "",
		root.marks.share && Privacy.sharing ? "share" : "",
		root.marks.caps && Input.capsLock ? "caps" : ""
	].filter(mark => mark !== "")
	readonly property string wanted: root.shown.join(",")
	// what was last put on
	property string worn: ""

	Binding {
		target: Privacy
		property: "watched"
		value: root.marks.privacy || root.marks.share
	}

	onWantedChanged: if (root.loaded) wearing.restart()
	onLoadedChanged: if (root.loaded && root.wanted !== root.worn) wearing.restart()

	// marks that flicker (a light switched twice) are put on once
	Timer {
		id: wearing

		interval: 250
		onTriggered: {
			if (applyProc.running || wearProc.running) {
				wearing.restart();
				return;
			}
			root.worn = root.wanted;
			wearProc.command = ["python3", root.script, "wear", "--marks", root.wanted].concat(root.colours());
			wearProc.running = true;
		}
	}

	Process {
		id: wearProc

		stderr: StdioCollector {
			onStreamFinished: if (text.trim()) console.warn(`cursor marks: ${text.trim()}`)
		}
		onExited: if (root.worn !== root.wanted) wearing.restart()
	}
}
