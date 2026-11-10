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
// cursor, the pointer held in a window, several text cursors, and one small
// sign for the first of: the machine in trouble, a fingerprint wanted, a
// password on the clipboard, the mouse nearly empty, offline, a restart
// due, another PC's mouse here, a break due, do not disturb, kept awake, a
// download – worn as variants of the theme. Only while it is worn; another
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
	readonly property var markKeys: ["rec", "privacy", "share", "caps", "capture", "multi", "alert", "finger", "secret",
		"battery", "offline", "reboot", "guest", "breaks", "dnd", "awake", "downloads"]
	readonly property var markDefaults: root.markKeys.reduce((all, key) => Object.assign(all, { [key]: true }), {})
	property var marks: root.markDefaults
	property bool loaded: false

	readonly property bool marking: root.markKeys.some(key => root.marks[key])

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
				root.marks = Object.assign({}, root.markDefaults, data.marks ?? {});
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
	// cursor_theme.py wears one sign of these (the first by its own order)
	readonly property var shown: [
		root.marks.rec && Recorder.active ? "rec" : "",
		root.marks.privacy && Privacy.mic ? "mic" : "",
		root.marks.privacy && Privacy.camera ? "cam" : "",
		root.marks.share && Privacy.sharing ? "share" : "",
		root.marks.caps && Input.capsLock ? "caps" : "",
		root.marks.capture && MouseCapture.active ? "capture" : "",
		root.marks.multi && Multicursor.active && Multicursor.cursors > 0 ? "multi" : "",
		root.marks.alert && root.distressHeld ? "alert" : "",
		root.marks.finger && Fingerprint.enabled && Fingerprint.fingerNeeded && Fingerprint.busy === "" ? "finger" : "",
		root.marks.secret && root.secret ? "secret" : "",
		root.marks.battery && root.mouseEmpty ? "battery" : "",
		root.marks.offline && root.offlineHeld ? "offline" : "",
		root.marks.reboot && Updates.rebootNeeded ? "reboot" : "",
		root.marks.guest && Kvm.mode === "guest" ? "guest" : "",
		root.marks.breaks && Breaks.stretchDue ? "break" : "",
		root.marks.dnd && Notifs.dnd ? "dnd" : "",
		root.marks.awake && KeepAwake.holding ? "awake" : "",
		root.marks.downloads && root.downloadHeld && root.downloadLevel > 0 ? `down${root.downloadLevel}` : ""
	].filter(mark => mark !== "")

	// the machine in trouble: as the task manager's alerts see it (the
	// processor near its limit, memory running out), or a disk nearly full
	readonly property bool distress: {
		const temps = TaskManager.temps;
		const temp = Number(temps.cpu) || 0;
		const limit = Math.min(95, (Number(temps.cpuCrit) || 100) - 5);
		const memory = TaskManager.memory;
		return (temp > 0 && temp >= limit) || (memory.total > 0 && memory.available < memory.total * 0.06)
			|| SysStats.disks.some(disk => disk.usage >= 0.97);
	}
	readonly property bool mouseEmpty: SysStats.mouseFound && SysStats.mouseLevel <= 0.1 && !["Charging", "Full"].includes(SysStats.mouseStatus)
	// quarters of what is downloading (browser downloads first, else torrents)
	readonly property int downloadLevel: {
		const ratio = Downloads.running.length > 0 ? Downloads.ratio : (Torrents.running.length > 0 ? Torrents.ratio : null);
		if (ratio === null) return 0;
		return ratio < 0 ? 1 : Math.max(1, Math.min(4, Math.ceil(ratio * 4)));
	}

	// held a while before they show, so a short blip does not swap the theme
	property bool distressHeld: false
	property bool offlineHeld: false
	property bool downloadHeld: false
	readonly property bool offlineNow: Network.enabled && !Network.online

	onDistressChanged: distressHold.restart()
	onOfflineNowChanged: offlineHold.restart()
	onDownloadLevelChanged: if ((root.downloadLevel > 0) !== root.downloadHeld) downloadHold.restart()

	Timer {
		id: distressHold

		interval: 10000
		onTriggered: root.distressHeld = root.distress
	}

	Timer {
		id: offlineHold

		interval: 5000
		onTriggered: root.offlineHeld = root.offlineNow
	}

	Timer {
		id: downloadHold

		interval: 3000
		onTriggered: root.downloadHeld = root.downloadLevel > 0
	}

	// a password on the clipboard: what password managers mark as secret
	// (wl-paste says so without the text being read)
	property bool secret: false

	Process {
		running: root.loaded && root.marks.secret
		command: ["wl-paste", "--watch", "sh", "-c", "echo \"${CLIPBOARD_STATE:-data}\""]
		stdout: SplitParser {
			onRead: line => root.secret = line.trim() === "sensitive"
		}
		onRunningChanged: if (!running) root.secret = false
	}
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
