pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// How often each app and command was launched from the launcher, for its
// order (launcher-usage.json in the state folder).
Singleton {
	id: root

	// key → launches
	property var usageMap: ({})

	function usageKey(entry) {
		return String(entry?.id || entry?.name || "");
	}

	function appUsage(entry) {
		const key = root.usageKey(entry);
		return key !== "" ? Number(root.usageMap[key] || 0) : 0;
	}

	// the most used first, then by name
	function compareApps(left, right) {
		const usageDelta = root.appUsage(right) - root.appUsage(left);
		if (usageDelta !== 0) return usageDelta;
		return String(left.name || left.id || "").localeCompare(String(right.name || right.id || ""));
	}

	function recordLaunch(entry) {
		const key = root.usageKey(entry);
		if (key === "") return;
		const next = Object.assign({}, root.usageMap);
		next[key] = Number(next[key] || 0) + 1;
		root.usageMap = next;
		usageFile.setText(JSON.stringify(root.usageMap));
	}

	FileView {
		id: usageFile

		path: Paths.stateFile("launcher-usage.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const parsed = JSON.parse(usageFile.text());
				root.usageMap = parsed && typeof parsed === "object" ? parsed : ({});
			} catch (error) {
				root.usageMap = ({});
			}
		}
	}
}
