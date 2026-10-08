pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The asteroids that pass the earth this week (plugin `asteroids`), with
// where each of them, the moon and the sun are, a day back and a week ahead.
// scripts/asteroids.py fetches them from NASA JPL every six hours and keeps
// them in ~/.cache/pshell/asteroids.json; in between nothing is asked.
//
// With `asteroid-alerts` it says when one stands in the night sky over the
// weather's city, bright enough to be seen, and again when that is over.
// How faint still counts is the host profile's `asteroids.magnitude`
// (default 10, a pair of binoculars; 6 is the naked eye).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("asteroids")
	readonly property bool alerts: root.enabled && Plugins.on("asteroid-alerts")
	readonly property real limit: Number(Host.profile.asteroids?.magnitude) || 10
	// [{ des, name, start, end (ms), mag, az, alt (degrees, when it starts), to (the azimuth when it ends) }]
	property var sightings: []
	property bool again: false
	// what was said already: { "des|start": "seen" | "over" }
	property var told: ({})

	// [{ des, name, at (ms of the closest approach), dist (LD), speed (km/s), size (m), measured, path }]
	// in the order they pass
	property var objects: []
	// one sample per step from `from` on: x, y, z (LD, ecliptic, the earth in
	// the middle) and how far it moves in a step
	property var moon: []
	// the direction to the sun, three numbers a day
	property var sun: []
	property real from: 0
	property real step: 7200000
	property int count: 0
	readonly property real until: root.from + root.step * Math.max(0, root.count - 1)

	// the minute it is
	property real clock: Date.now()
	readonly property bool ready: root.enabled && root.objects.length > 0 && root.clock < root.until
	// the one that passes next, or the last that did
	readonly property var next: {
		if (!root.ready) return null;
		return root.objects.find(object => object.at >= root.clock) ?? root.objects[root.objects.length - 1];
	}

	// where a path is at a time: x, y and z are written into `out`
	function locate(path, time, out) {
		const last = root.count - 1;
		const at = Math.max(0, Math.min(last, (time - root.from) / root.step));
		const i = Math.min(last - 1, Math.floor(at));
		const t = at - i;
		const a = i * 6;
		const first = 2 * t * t * t - 3 * t * t + 1;
		const lead = t * t * t - 2 * t * t + t;
		const second = 3 * t * t - 2 * t * t * t;
		const trail = t * t * t - t * t;
		out[0] = first * path[a] + lead * path[a + 3] + second * path[a + 6] + trail * path[a + 9];
		out[1] = first * path[a + 1] + lead * path[a + 4] + second * path[a + 7] + trail * path[a + 10];
		out[2] = first * path[a + 2] + lead * path[a + 5] + second * path[a + 8] + trail * path[a + 11];
		return out;
	}

	function sunAt(time, out) {
		const last = root.sun.length / 3 - 1;
		const at = Math.max(0, Math.min(last, (time - root.from) / 86400000));
		const i = Math.min(Math.max(0, last - 1), Math.floor(at));
		const t = at - i;
		const next = Math.min(last, i + 1);
		for (let axis = 0; axis < 3; axis += 1) out[axis] = root.sun[i * 3 + axis] * (1 - t) + root.sun[next * 3 + axis] * t;
		return out;
	}

	// lunar distances
	function distance(ld) {
		return `${ld < 10 ? ld.toFixed(2) : ld.toFixed(1)} LD`;
	}

	function size(object) {
		if (!object || !object.size) return "?";
		const text = object.size < 1000 ? `${Math.round(object.size)} m` : `${(object.size / 1000).toFixed(1)} km`;
		return object.measured ? text : `~${text}`;
	}

	// "in 3 h 20 min", "2 d 4 h ago"
	function when(at, now) {
		const minutes = Math.max(1, Math.round(Math.abs(at - now) / 60000));
		let text = `${minutes} min`;
		if (minutes >= 1440) text = `${Math.floor(minutes / 1440)} d ${Math.floor(minutes % 1440 / 60)} h`;
		else if (minutes >= 60) text = `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
		return at < now ? `${text} ago` : `in ${text}`;
	}

	function compass(az) {
		return ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][Math.round(az / 45) % 8];
	}

	// says what begins and what has ended
	function announce() {
		if (!root.alerts) return;
		const now = Date.now();
		const told = Object.assign({}, root.told);
		let changed = false;
		for (const sighting of root.sightings) {
			const key = `${sighting.des}|${sighting.start}`;
			if (now >= sighting.start && now < sighting.end && !told[key]) {
				told[key] = "seen";
				changed = true;
				// where to look, and where it wanders to
				const from = root.compass(sighting.az);
				const to = root.compass(sighting.to ?? sighting.az);
				const where = `Look ${from}, ${sighting.alt}° high${to !== from ? " · moves " + to : ""}`;
				const how = sighting.mag <= 6 ? "naked eye" : (sighting.mag <= 10 ? "binoculars" : "telescope");
				Notifs.pushInternal("running", `${sighting.name} is in the sky`, `${where} · ${how} (${sighting.mag.toFixed(1)} mag) · until ${Qt.formatTime(new Date(sighting.end), "HH:mm")}`, {
					icon: "meteor",
					duration: 30000
				});
			} else if (now >= sighting.end && told[key] === "seen") {
				told[key] = "over";
				changed = true;
				// not for a night the shell slept through
				if (now < sighting.end + 3600000) Notifs.pushInternal("done", `${sighting.name} is out of sight`, "", { icon: "meteor", duration: 15000 });
			}
		}
		for (const key in told) {
			if (Number(key.split("|")[1]) > now - 10 * 86400000) continue;
			delete told[key];
			changed = true;
		}
		if (!changed) return;
		root.told = told;
		store.setText(JSON.stringify({ told: told }));
	}

	function fetch() {
		if (!root.enabled) return;
		// asked again while it runs, for another place perhaps: once more after it
		root.again = fetcher.running;
		if (fetcher.running) return;
		const command = ["python3", `${Paths.scripts}/asteroids.py`, "--limit", String(root.limit)];
		if (isFinite(Weather.latitude) && isFinite(Weather.longitude)) command.push("--at", `${Weather.latitude},${Weather.longitude}`);
		fetcher.exec(command);
	}

	function receive(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!data || !Array.isArray(data.objects) || !(data.count > 1)) return;
		root.from = Number(data.from);
		root.step = Number(data.step);
		root.count = data.count;
		root.moon = data.moon || [];
		root.sun = data.sun || [];
		root.objects = data.objects.filter(object => object.path?.length === data.count * 6);
		root.sightings = Array.isArray(data.sightings) ? data.sightings : [];
		root.announce();
	}

	onAlertsChanged: root.announce()

	// the sky is the one over the weather's city, once that is known
	Connections {
		target: Weather
		function onLongitudeChanged() {
			root.fetch();
		}
	}

	FileView {
		id: store

		path: Paths.stateFile("asteroids.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.told = JSON.parse(String(text() || "{}")).told || {};
			} catch (error) {}
		}
	}

	Process {
		id: fetcher

		onExited: if (root.again) root.fetch()
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: 1800000
		triggeredOnStart: true
		onTriggered: root.fetch()
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: 60000
		onTriggered: {
			root.clock = Date.now();
			root.announce();
		}
	}
}
