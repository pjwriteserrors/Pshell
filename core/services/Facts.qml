pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The useless fact of the day (plugin `useless-fact`), from
// uselessfacts.jsph.pl. Asked for when the shell starts and every hour; the
// last one is kept in useless-fact.json of the state dir together with where
// its card lies on the desktop, so it is there without waiting and offline.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("useless-fact")
	readonly property string url: "https://uselessfacts.jsph.pl/api/v2/facts/today"

	property string text: ""
	property string source: ""
	property string sourceUrl: ""
	// where the card lies; -1 until it was moved
	property real x: -1
	property real y: -1
	property bool loaded: false

	function refresh() {
		if (!root.enabled || !root.loaded || fetcher.running) return;
		fetcher.running = true;
	}

	function move(x, y) {
		root.x = Math.round(x);
		root.y = Math.round(y);
		root.save();
	}

	function save() {
		stateFile.setText(JSON.stringify({
			text: root.text,
			source: root.source,
			sourceUrl: root.sourceUrl,
			x: root.x,
			y: root.y
		}, null, 2));
	}

	function restore(raw) {
		try {
			const data = JSON.parse(raw);
			root.text = String(data.text || "");
			root.source = String(data.source || "");
			root.sourceUrl = String(data.sourceUrl || "");
			root.x = Number.isFinite(data.x) ? data.x : -1;
			root.y = Number.isFinite(data.y) ? data.y : -1;
		} catch (error) {}
		root.loaded = true;
	}

	FileView {
		id: stateFile

		path: Paths.stateFile("useless-fact.json")
		printErrors: false
		onLoaded: root.restore(text())
		onLoadFailed: root.loaded = true
	}

	Process {
		id: fetcher

		command: ["curl", "-fsSL", "--max-time", "20", root.url]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const fact = JSON.parse(text);
					const said = String(fact.text || "").trim();
					if (said === "" || said === root.text) return;
					root.text = said;
					root.source = String(fact.source || "");
					root.sourceUrl = String(fact.source_url || "");
					root.save();
				} catch (error) {}
			}
		}
	}

	Timer {
		interval: 3600000
		running: root.enabled && root.loaded
		repeat: true
		triggeredOnStart: true
		onTriggered: root.refresh()
	}
}
