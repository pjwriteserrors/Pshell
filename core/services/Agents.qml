pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Coding agents in terminals. A window runs a busy agent while its title
// carries Claude Code's spinner (◐ ◑, ✳ when it waits for input) or while a
// hook reported it busy (scripts/agent_hook.py, used by Codex). When a turn
// that ran for a long time ends in a window that is not in front, a
// notification says so; clicking it focuses the window.
Singleton {
	id: root

	readonly property int minimumSeconds: 180

	// window id → { since, agent, source: "title" | "hook" }
	property var busy: ({})

	function titleState(title) {
		const t = String(title || "");
		if (/^[◐◑◒◓] /.test(t)) return "busy";
		if (/^✳ /.test(t)) return "idle";
		return "";
	}

	function topic(title) {
		return String(title || "").replace(/^[◐◑◒◓✳] /, "").trim();
	}

	function start(id, agent, source) {
		if (root.busy[id]) return;
		const next = Object.assign({}, root.busy);
		next[id] = { since: Date.now(), agent: agent, source: source };
		root.busy = next;
	}

	function finish(id) {
		const entry = root.busy[id];
		if (!entry) return;
		const next = Object.assign({}, root.busy);
		delete next[id];
		root.busy = next;
		const seconds = (Date.now() - entry.since) / 1000;
		const window = Niri.windows.find(w => Number(w.id) === Number(id));
		if (!window || seconds < root.minimumSeconds) return;
		if (window.is_focused && !Session.locked) return;
		root.announce(window, entry.agent, seconds);
	}

	function announce(window, agent, seconds) {
		const minutes = Math.round(seconds / 60);
		const proc = notifier.createObject(root, { windowId: Number(window.id) });
		proc.command = ["notify-send", "--app-name", agent, "--icon", window.app_id || "utilities-terminal",
			"--action", "default=Show", "--wait", `${agent} is done`, `${root.topic(window.title) || window.app_id} · ${minutes} min`];
		proc.running = true;
	}

	// the hook of an agent that shows no spinner (Codex)
	function report(windowId, state, agent) {
		const id = Number(windowId);
		if (!Niri.windows.some(w => Number(w.id) === id)) return;
		if (state === "busy") root.start(id, agent || "Agent", "hook");
		else if (root.busy[id]?.source === "hook") root.finish(id);
	}

	function sync() {
		const seen = {};
		for (const window of Niri.windows) {
			const id = Number(window.id);
			seen[id] = true;
			const state = root.titleState(window.title);
			if (state === "busy") root.start(id, "Claude", "title");
			else if (root.busy[id]?.source === "title") root.finish(id);
		}
		let gone = false;
		const next = {};
		for (const id in root.busy) {
			if (seen[id]) next[id] = root.busy[id];
			else gone = true;
		}
		if (gone) root.busy = next;
	}

	Connections {
		target: Niri
		function onWindowsChanged() {
			root.sync();
		}
	}

	Component {
		id: notifier

		Process {
			id: proc

			property int windowId: -1

			stdout: SplitParser {
				onRead: line => {
					if (line.trim() === "default") Niri.focusWindow(proc.windowId);
				}
			}
			onExited: proc.destroy()
		}
	}
}
