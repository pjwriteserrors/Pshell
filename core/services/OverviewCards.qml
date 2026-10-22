pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// How round the cards of the overview panel are (the workspaces, and the
// windows on them follow). Unset they are as round as the windows
// themselves (niri's geometry-corner-radius). Kept in overview.json.
Singleton {
	id: root

	readonly property int max: 40
	// -1: like the windows
	property int corner: -1

	readonly property bool followsWindows: root.corner < 0
	readonly property real radius: root.followsWindows ? Math.min(root.max, Theme.windowRadius) : root.corner

	function setCorner(corner) {
		root.corner = corner < 0 ? -1 : Math.max(0, Math.min(root.max, Math.round(corner)));
		file.setText(JSON.stringify({ corner: root.corner }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("overview.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(String(text() || "{}"));
				const corner = Number(saved.corner);
				if (Number.isFinite(corner)) root.corner = corner < 0 ? -1 : Math.min(root.max, Math.round(corner));
			} catch (error) {}
		}
	}
}
