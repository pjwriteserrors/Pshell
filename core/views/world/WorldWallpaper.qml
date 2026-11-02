import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.core.services

// The world behind the windows of one screen: not clickable, slowly travelling
// from town to town, and it stops while windows hide it. The shell's colours stay
// what they were: the real wallpaper, which they come from, is not touched.
PanelWindow {
	id: root

	required property var modelData

	readonly property var output: Niri.workspaces.find(space => space.output === root.modelData.name && space.is_active) ?? null
	readonly property bool covered: {
		const space = root.output;
		if (!space) return false;
		let area = 0;
		for (const window of Niri.windows) {
			const size = window.layout?.tile_size;
			if (window.workspace_id === space.id && !window.is_floating && size) area += size[0] * size[1];
		}
		return area >= root.modelData.width * root.modelData.height * 0.85;
	}
	property int stop: 0

	visible: World.wallpaperVisible
	screen: root.modelData
	color: "#0f4560"
	WlrLayershell.layer: WlrLayer.Bottom
	WlrLayershell.namespace: "shell-world-wallpaper"
	exclusionMode: ExclusionMode.Ignore
	mask: Region {}
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}

	function visit() {
		const cities = World.scene?.cities ?? [];
		if (cities.length === 0) {
			map.fit();
			return;
		}
		const city = cities[root.stop % cities.length];
		root.stop += 1;
		map.flyTo(city.centre[0], city.centre[1] + 40, 2.2);
		map.ease = 0.22;
	}

	WorldMap {
		id: map

		anchors.fill: parent
		world: World.scene
		folder: World.folder
		interactive: false
		rate: 80
		paused: root.covered || Niri.focusedFullscreen || (Plugins.on("games") && Games.running.length > 0)
	}

	Timer {
		interval: 45000
		repeat: true
		triggeredOnStart: true
		running: World.scene !== null && !map.paused
		onTriggered: root.visit()
	}
}
