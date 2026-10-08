pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Where the connections go, app by app (plugin `connections`; `Connections`
// is QML's own). scripts/outbound.py reads the sockets every second and
// looks their addresses up in a database on this machine; it runs only
// while a view is on the screen and leaves nothing behind.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("connections")
	// views that are on the screen
	property int watchers: 0
	readonly property bool active: root.enabled && root.watchers > 0

	// [{ id, conns, down, up, places: [key] }], the busiest first
	property var apps: []
	// [{ key, city, country, cc, lat, lon, conns, down, up, apps: [{ id, conns, down, up }] }]
	property var places: []
	readonly property var appTable: root.table(root.apps, "id")
	readonly property var placeTable: root.table(root.places, "key")
	// the first sample is in
	property bool ready: false
	// the location database: "ready" | "loading" | "failed"
	property string geo: "ready"
	property real progress: 0
	// where the time zone is at home
	property var zone: [50.1, 8.7]
	// [latitude, longitude] of this machine: the weather's city when there is one
	readonly property var origin: isFinite(Weather.latitude) && isFinite(Weather.longitude) ? [Weather.latitude, Weather.longitude] : root.zone

	function table(list, key) {
		const out = {};
		list.forEach(entry => out[entry[key]] = entry);
		return out;
	}

	function watch(on) {
		root.watchers = Math.max(0, root.watchers + (on ? 1 : -1));
	}

	function title(id) {
		const name = String(id || "");
		return name.charAt(0).toUpperCase() + name.slice(1);
	}

	// "" when the app has none
	function icon(id) {
		const name = String(id || "").toLowerCase();
		return AppIcons.papirus(name) || Quickshell.iconPath(name, true);
	}

	function receive(line) {
		let sample = null;
		try {
			sample = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!sample) return;
		root.geo = String(sample.geo || "ready");
		root.progress = Number(sample.progress) || 0;
		if (sample.origin) root.zone = sample.origin;
		root.apps = sample.apps || [];
		root.places = sample.places || [];
		root.ready = true;
	}

	onActiveChanged: {
		if (root.active) return;
		root.apps = [];
		root.places = [];
		root.ready = false;
	}

	Process {
		running: root.active
		command: ["python3", `${Paths.scripts}/outbound.py`, "watch"]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
	}
}
