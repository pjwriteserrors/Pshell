pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The Pshell icon theme follows the colours, niri's corner radius, the
// installed apps and its own setting (icons.json): when one of them changes
// it is drawn anew (scripts/icon_theme.py) and worn under its other name, so
// GTK and Qt load it. Only while it is worn; another icon theme is left
// alone. `dir` is the drawn theme's own directory while it is worn – a new
// one for every look, so no picture of the old one is kept – and AppIcons
// looks there first.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/icon_theme.py`
	readonly property string path: `${Paths.state}/icons.json`

	// ── settings (Studio › Icons & Pointer) ───────────────────────────────
	// the apps' own colours on the tiles instead of the palette
	property bool brands: false

	// ── state ─────────────────────────────────────────────────────────────
	property bool worn: false
	property string dir: ""
	readonly property bool building: applyProc.running

	function set(key, value) {
		root[key] = value;
		file.setText(JSON.stringify({ brands: root.brands }, null, "\t") + "\n");
		settle.restart();
	}

	// another icon theme was picked (Studio)
	function refresh() {
		settle.restart();
	}

	FileView {
		id: file

		path: root.path
		printErrors: false
		onLoaded: {
			try {
				root.brands = JSON.parse(text() || "{}").brands === true;
			} catch (error) {}
		}
	}

	// what the icons are drawn from (the setting comes from icons.json); an
	// app installed or removed changes the count
	readonly property var inputs: [String(Theme.bg), String(Theme.fg), String(Theme.primary), Theme.windowRadius, DesktopEntries.applications.values.length]

	onInputsChanged: settle.restart()
	Component.onCompleted: settle.restart()

	// a new wallpaper changes the colours several times in a row
	Timer {
		id: settle

		interval: 3000
		onTriggered: {
			if (applyProc.running) {
				settle.restart();
				return;
			}
			applyProc.command = ["python3", root.script, "apply", "--bg", String(Theme.bg), "--fg", String(Theme.fg),
				"--primary", String(Theme.primary), "--radius", String(Theme.windowRadius)];
			applyProc.running = true;
		}
	}

	Process {
		id: applyProc

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const out = JSON.parse(text.trim().split("\n").pop() || "{}");
					root.worn = out.worn === true;
					root.dir = String(out.root || "");
				} catch (error) {}
			}
		}
		stderr: StdioCollector {
			onStreamFinished: if (text.trim()) console.warn(`icon theme: ${text.trim()}`)
		}
	}
}
