pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The screen frame of the bottom-corners plugin: how thick it is in pixels
// (0 leaves only the rounded lower corners) and whether it runs along the
// lower edge or all around the screen. Kept in corners.json.
Singleton {
	id: root

	readonly property int max: 80
	property int frame: 0
	// "bottom" | "all"
	property string edges: "bottom"

	readonly property bool framed: root.frame > 0
	readonly property bool all: Plugins.on("bottom-corners") && root.edges === "all"

	function setFrame(frame) {
		root.frame = Math.max(0, Math.min(root.max, Math.round(frame)));
		root.save();
	}

	function setEdges(edges) {
		root.edges = edges === "all" ? "all" : "bottom";
		root.save();
	}

	function save() {
		file.setText(JSON.stringify({ frame: root.frame, edges: root.edges }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("corners.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(String(text() || "{}"));
				if (Number(saved.frame) >= 0 && Number(saved.frame) <= root.max) root.frame = Math.round(Number(saved.frame));
				if (saved.edges === "all") root.edges = "all";
			} catch (error) {}
		}
	}
}
