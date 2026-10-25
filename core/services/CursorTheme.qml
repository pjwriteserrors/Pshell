pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The Pshell cursor theme follows the colours and niri's corner radius: when
// they change it is drawn anew (scripts/cursor_theme.py) and niri is made to
// load it, and while the screen is recorded it wears its recording
// cursors. Only while it is worn; another cursor theme is left alone.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/cursor_theme.py`
	readonly property bool enabled: true

	// what the cursors are drawn from
	readonly property var inputs: [String(Theme.bg), String(Theme.fg), String(Theme.primary), String(Theme.danger), Theme.windowRadius]

	onInputsChanged: settle.restart()
	Component.onCompleted: settle.restart()

	// a new wallpaper changes the colours several times in a row
	Timer {
		id: settle

		interval: 2500
		onTriggered: {
			if (applyProc.running) {
				settle.restart();
				return;
			}
			applyProc.command = ["python3", root.script, "apply",
				"--bg", String(Theme.bg), "--fg", String(Theme.fg),
				"--primary", String(Theme.primary), "--danger", String(Theme.danger),
				"--radius", String(Theme.windowRadius)];
			applyProc.running = true;
		}
	}

	// while the screen is recorded the cursor carries a red dot: the
	// pointer is over other windows then, so only the theme can show it
	Connections {
		target: Recorder

		function onActiveChanged() {
			wearProc.running = false;
			wearProc.command = ["python3", root.script, "wear", Recorder.active ? "rec" : "normal"];
			wearProc.running = true;
		}
	}

	Process {
		id: wearProc
	}

	Process {
		id: applyProc

		stderr: StdioCollector {
			onStreamFinished: if (text.trim()) console.warn(`cursor theme: ${text.trim()}`)
		}
	}
}
