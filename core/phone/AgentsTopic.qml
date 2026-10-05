import QtQuick
import Quickshell
import qs.core.services

// agents: coding agents in terminals: which work, which wait for an answer.
Topic {
	id: topic

	name: "agents"

	data: topic.wanted ? ({
		agents: Niri.windows.map(window => {
			const busy = Agents.busy[Number(window.id)];
			const state = busy ? "busy" : (Agents.titleState(window.title) === "idle" ? "waiting" : "");
			if (state === "") return null;
			return {
				window: Number(window.id),
				agent: busy?.agent ?? "Claude",
				state: state,
				topic: Agents.topic(window.title),
				app: window.app_id || "",
				since: busy?.since ?? 0,
				focused: !!window.is_focused
			};
		}).filter(entry => entry !== null)
	}) : null

	function call(action, args, done) {
		const id = Number(args.window);
		if (!Niri.windows.some(w => Number(w.id) === id)) throw new Error("That window is gone");
		switch (action) {
		case "focus":
			Niri.focusWindow(id);
			return {};
		// types the answer into the agent's window and sends it
		case "reply":
			Niri.focusWindow(id);
			Quickshell.execDetached(["sh", "-c", 'sleep 0.25; wtype -- "$1"; sleep 0.05; wtype -k Return', "sh", String(args.text || "")]);
			return {};
		}
		throw new Error("unknown-action");
	}
}
