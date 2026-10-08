import QtQuick
import Quickshell
import qs.core.services
import qs.style.bar

// What this style draws around the surfaces: one bar per screen, and the
// rounded lower screen corners with their frame.
Scope {
	id: root

	readonly property var bars: Plugins.on("bar") ? Quickshell.screens : []

	// The compositor lays out what reserves space in the order it came, so
	// the frame's sides have to come after the bars, or they push them in.
	property bool settled: false
	onBarsChanged: {
		root.settled = false;
		settle.restart();
	}

	Timer {
		id: settle

		interval: 300
		running: true
		onTriggered: root.settled = true
	}

	Variants {
		model: root.bars

		Bar {}
	}

	Variants {
		model: Plugins.on("bottom-corners") ? Quickshell.screens : []

		BottomCorners {}
	}

	Variants {
		model: {
			if (!root.settled || !Plugins.on("bottom-corners") || !Corners.framed) return [];
			const edges = !Corners.all ? ["bottom"] : Plugins.on("bar") ? ["bottom", "left", "right"] : ["bottom", "left", "right", "top"];
			const spaces = [];
			for (const screen of Quickshell.screens)
				for (const edge of edges) spaces.push({ screen: screen, edge: edge });
			return spaces;
		}

		FrameSpace {}
	}
}
