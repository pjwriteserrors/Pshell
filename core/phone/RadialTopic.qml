import QtQuick
import Quickshell
import qs.core.services

// radial: the radial menu's entries, so the phone offers what the PC does
// from one configuration.
Topic {
	id: topic

	name: "radial"

	function describe(entries) {
		return entries.map(entry => ({
			id: String(entry.id),
			label: String(entry.label || ""),
			icon: String(entry.icon || ""),
			active: !!entry.active,
			enabled: entry.enabled !== false,
			children: Array.isArray(entry.children) ? topic.describe(entry.children) : null
		}));
	}

	data: topic.wanted ? ({ entries: topic.describe(Radial.tree) }) : null

	function call(action, args, done) {
		if (action !== "run") throw new Error("unknown-action");
		let level = Radial.tree;
		let entry = null;
		for (const id of args.path || []) {
			entry = (level || []).find(candidate => String(candidate.id) === String(id));
			if (!entry) throw new Error("That entry is gone");
			level = entry.children;
		}
		if (!entry || typeof entry.run !== "function" || entry.enabled === false) throw new Error("Nothing to run");
		entry.run();
		return {};
	}
}
