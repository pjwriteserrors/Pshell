import QtQuick
import Quickshell
import qs.core.services

// apps: the programs of the PC, to start from the phone. The list is asked
// for (`list`), not published: it is long and rarely changes.
Topic {
	id: topic

	name: "apps"
	data: topic.wanted ? ({ count: DesktopEntries.applications.values.length }) : null

	function call(action, args, done) {
		switch (action) {
		case "list":
			return {
				apps: DesktopEntries.applications.values.filter(entry => !entry.noDisplay).map(entry => {
					const icon = AppIcons.app(entry.icon, [entry.id]);
					return {
						id: entry.id,
						name: entry.name,
						comment: entry.comment || entry.genericName || "",
						icon: String(icon).startsWith("/") ? { "$blob": icon } : null
					};
				}).sort((a, b) => a.name.localeCompare(b.name))
			};
		case "launch": {
			const entry = DesktopEntries.applications.values.find(candidate => candidate.id === String(args.id));
			if (!entry) throw new Error("No such program");
			entry.execute();
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
