pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The pictures of the day of Bing, NASA (APOD), Wallhaven and MoeWalls, for
// the theme picker (plugin `studio-wallpaper`). scripts/wallpaper_of_day.py
// fetches what is new every two hours and whenever the picker opens, and
// keeps each picture in ~/.local/state/quickshell-theme/daily with its
// preview and its wallust colours: the picker shows them without waiting.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("studio-wallpaper")
	readonly property string script: `${Quickshell.shellDir}/scripts/wallpaper_of_day.py`
	// the library entry a picture of the day is worn as
	readonly property string themeDir: `${Host.wallpapers}/Wallpaper of the day`
	readonly property var sources: [
		{ id: "bing", label: "Bing" },
		{ id: "apod", label: "NASA" },
		{ id: "wallhaven", label: "Wallhaven" },
		{ id: "moewalls", label: "MoeWalls" }
	]

	// by source: what wallpaper_of_day.py keeps (title, credit, theme_path,
	// media_path, preview_path, media_type, …)
	property var entries: ({})
	// by source: true while it is asked, and why the last asking failed
	property var asking: ({})
	property var errors: ({})
	// { provider, candidate_id } of the picture the desktop wears, or {}
	property var applied: ({})
	property real asked: 0
	readonly property bool fetching: fetcher.running
	// the picture being made bigger (or taken back), how far, and why the
	// last one failed
	property string growing: ""
	property bool shrinking: false
	property real growProgress: 0
	property string growText: ""
	property string growError: ""

	// an entry that was made bigger or taken back; `worn` when the desktop
	// wears it and should be painted again
	signal grown(var entry)

	function wears(entry) {
		return !!entry && root.applied.provider === entry.provider && root.applied.candidate_id === entry.candidate_id;
	}

	// what is kept, without asking anyone
	function reload() {
		lister.running = true;
	}

	// asks every source for what is new; `force` skips the ten minutes that
	// otherwise lie between two askings
	function refresh(force) {
		if (!root.enabled || fetcher.running) return;
		if (!force && Date.now() - root.asked < 600000) return;
		root.asked = Date.now();
		const asking = {};
		for (const source of root.sources) asking[source.id] = true;
		root.asking = asking;
		root.errors = {};
		fetcher.running = true;
	}

	function receive(line) {
		let answer;
		try {
			answer = JSON.parse(line);
		} catch (error) {
			return;
		}
		const asking = Object.assign({}, root.asking);
		delete asking[answer.provider];
		root.asking = asking;
		if (answer.entry) {
			const entries = Object.assign({}, root.entries);
			entries[answer.provider] = answer.entry;
			root.entries = entries;
		} else {
			const errors = Object.assign({}, root.errors);
			errors[answer.provider] = String(answer.error || "");
			root.errors = errors;
		}
	}

	// a small picture made as big as the largest screen by Real-ESRGAN on the
	// Radeon; `back` takes it back to the downloaded one
	function upscale(provider, back) {
		if (grower.running) return;
		root.growing = provider;
		root.shrinking = !!back;
		root.growProgress = 0;
		root.growText = back ? "Taking the original back" : "Starting";
		root.growError = "";
		grower.command = ["python3", root.script, back ? "--original" : "--upscale", provider];
		grower.running = true;
	}

	function cancelUpscale() {
		grower.running = false;
	}

	Process {
		id: grower

		command: ["true"]
		stdout: SplitParser {
			onRead: line => {
				const match = String(line).match(/^progress ([0-9.]+) (.*)$/);
				if (match) {
					root.growProgress = Math.max(0, Math.min(1, Number(match[1])));
					root.growText = match[2];
					return;
				}
				let answer;
				try {
					answer = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (!answer.entry) return;
				const entries = Object.assign({}, root.entries);
				entries[answer.entry.provider] = answer.entry;
				root.entries = entries;
				root.grown(answer.entry);
			}
		}
		stderr: StdioCollector {
			onStreamFinished: {
				const said = String(text).trim().split("\n").pop() || "";
				if (said !== "") root.growError = said.replace(/^wallpaper of the day: /, "");
			}
		}
		onExited: root.growing = ""
	}

	Process {
		id: lister

		command: ["python3", root.script, "--list"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(text);
					const entries = {};
					for (const entry of data.entries) entries[entry.provider] = entry;
					root.entries = entries;
					root.applied = data.applied ?? {};
				} catch (error) {}
			}
		}
	}

	Process {
		id: fetcher

		command: ["python3", root.script, "--fetch-all"]
		onExited: root.asking = {}
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
	}

	Timer {
		interval: 20000
		running: root.enabled
		onTriggered: root.refresh(true)
	}

	Timer {
		interval: 7200000
		running: root.enabled
		repeat: true
		onTriggered: root.refresh(true)
	}

	Component.onCompleted: root.reload()
}
