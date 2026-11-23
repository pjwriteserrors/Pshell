pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The launcher's places (>wp): what is meant while typing, then all that is
// known about one. scripts/places.py asks open sources only (Photon,
// Nominatim, Wikipedia/Wikidata, the place's website, Panoramax, OSRM,
// Transitous, Open-Meteo, OSM tiles) near the weather's city and answers in
// lines, so the view brings each part in as it comes. Kept here: places
// saved to go to or been to, with own stars and a note, the ones looked at
// lately, and up to three to compare.
Singleton {
	id: root

	// where "near" is: the weather's city, or a "places.home" of the host profile
	readonly property real originLat: root.home ? root.home.lat : Weather.latitude
	readonly property real originLon: root.home ? root.home.lon : Weather.longitude
	readonly property var home: {
		const value = String(Host.profile.places?.home ?? "");
		const match = /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/.exec(value);
		return match ? { lat: Number(match[1]), lon: Number(match[2]) } : null;
	}
	readonly property string originName: Host.profile.places?.homeName ?? (root.home ? "Home" : (Weather.city || ""))

	// ── typing ──────────────────────────────────────────────────────────
	property string query: ""
	property var suggestions: []
	property var categoryItems: []
	property string categoryLabel: ""
	// idle · loading · found · none · error
	property string state: "idle"
	property string error: ""
	readonly property bool loading: root.state === "loading" || debounce.running

	// ── one place ───────────────────────────────────────────────────────
	property var place: null
	property var about: null
	property string avatar: ""
	property var photos: []
	property var routes: null
	property var nearby: null
	property var weather: null
	property var map: null
	// idle · loading · found · none · error
	property string placeState: "idle"
	property string placeError: ""
	readonly property bool placeLoading: root.placeState === "loading" || root._placeRunning !== null
	// the brief of the place being opened, shown until its details come
	property var opening: null

	// ── kept ────────────────────────────────────────────────────────────
	// id → { brief…, list: "want"|"been"|"", stars: 0–5, note, saved, visited }
	property var saved: ({})
	property var history: []
	property var compare: []
	readonly property var wantList: Object.values(root.saved).filter(entry => entry.list === "want").sort((a, b) => b.saved - a.saved)
	readonly property var beenList: Object.values(root.saved).filter(entry => entry.list === "been").sort((a, b) => (b.visited || b.saved) - (a.visited || a.saved))
	// ticks each minute: open/closed and countdowns follow it
	property date now: new Date()

	property string _query: ""
	property string _shown: ""
	property int _seq: 0
	property var _running: null
	property int _placeSeq: 0
	property var _placeRunning: null

	function originArgs() {
		if (isFinite(root.originLat) && isFinite(root.originLon))
			return ["--lat", root.originLat.toFixed(5), "--lon", root.originLon.toFixed(5)];
		return Weather.city ? ["--city", Weather.city] : [];
	}

	function request(text) {
		const value = String(text || "").trim();
		if (value === "") {
			debounce.stop();
			root.stopSearch();
			root._shown = "";
			root.query = "";
			root.suggestions = [];
			root.categoryItems = [];
			root.categoryLabel = "";
			root.state = "idle";
			return;
		}
		if (value === root._shown) return;
		root._query = value;
		debounce.restart();
	}

	function flush() {
		if (!debounce.running) return;
		debounce.stop();
		root.search();
	}

	function search() {
		root._shown = root._query;
		root.query = root._query;
		root.error = "";
		root.state = "loading";
		root.stopSearch();
		root._seq += 1;
		const proc = finder.createObject(root, { seq: root._seq, fresh: true });
		proc.command = ["python3", "-u", `${Paths.scripts}/places.py`, "suggest", root._query].concat(root.originArgs());
		proc.running = true;
		root._running = proc;
	}

	function stopSearch() {
		root._seq += 1;
		if (root._running) root._running.running = false;
		root._running = null;
	}

	function handleSearch(proc, line) {
		if (proc.seq !== root._seq) return;
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		// the first answer of a new search replaces what the last one showed
		if (proc.fresh && (message.type === "suggestions" || message.type === "category")) {
			proc.fresh = false;
			root.suggestions = [];
			root.categoryItems = [];
			root.categoryLabel = "";
		}
		switch (message.type) {
		case "suggestions":
			root.suggestions = message.items || [];
			root.state = root.suggestions.length > 0 || root.categoryItems.length > 0 ? "found" : "none";
			break;
		case "category":
			root.categoryItems = message.items || [];
			root.categoryLabel = message.label || "";
			if (root.categoryItems.length > 0) root.state = "found";
			break;
		case "error":
			if (root.state === "loading") {
				root.error = String(message.error || "No answer");
				root.state = "error";
			}
			break;
		case "done":
			if (root.state === "loading") root.state = "none";
			break;
		}
	}

	// ── a place ─────────────────────────────────────────────────────────

	function open(brief) {
		if (!brief?.id) return;
		root.stopPlace();
		root.opening = brief;
		root.place = null;
		root.about = null;
		root.avatar = root.saved[brief.id]?.avatar ?? "";
		root.photos = [];
		root.routes = null;
		root.nearby = null;
		root.weather = null;
		root.map = null;
		root.placeError = "";
		root.placeState = "loading";
		root._placeSeq += 1;
		const proc = reader.createObject(root, { seq: root._placeSeq });
		const args = ["python3", "-u", `${Paths.scripts}/places.py`, "details", brief.id].concat(root.originArgs());
		if (root.home) args.push("--from", `${root.home.lat},${root.home.lon}`);
		if (Theme.dark) args.push("--dark");
		proc.command = args;
		proc.running = true;
		root._placeRunning = proc;
	}

	function close() {
		root.stopPlace();
		root.opening = null;
		root.place = null;
		root.placeState = "idle";
	}

	function stopPlace() {
		root._placeSeq += 1;
		if (root._placeRunning) root._placeRunning.running = false;
		root._placeRunning = null;
	}

	function handlePlace(seq, line) {
		if (seq !== root._placeSeq) return;
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (message.type) {
		case "place":
			root.place = message;
			root.placeState = "found";
			root.remember(message);
			break;
		case "about":
			root.about = message;
			break;
		case "image":
			if (message.role === "avatar") {
				root.avatar = message.path;
				root.touch(root.place?.id, { avatar: message.path });
			} else {
				root.photos = root.photos.concat([message]).sort((a, b) => a.index - b.index);
			}
			break;
		case "routes":
			root.routes = message;
			break;
		case "nearby":
			root.nearby = message;
			break;
		case "weather":
			root.weather = message;
			break;
		case "map":
			root.map = message;
			break;
		case "none":
			root.placeState = "none";
			break;
		case "error":
			if (root.placeState === "loading") {
				root.placeError = String(message.error || "No answer");
				root.placeState = "error";
			}
			break;
		}
	}

	// ── what is kept ────────────────────────────────────────────────────

	// the little that is shown of a place in lists and when comparing
	function brief(place) {
		const keep = ["id", "name", "kind", "key", "kindLabel", "street", "postcode", "city", "lat", "lon", "cuisine", "hours", "distance", "phone", "website"];
		const out = {};
		for (const key of keep) if (place?.[key] !== undefined) out[key] = place[key];
		return out;
	}

	function remember(place) {
		const entry = Object.assign(root.brief(place), { avatar: root.avatar, seen: Date.now() });
		root.history = [entry].concat(root.history.filter(item => item.id !== entry.id)).slice(0, 12);
		if (root.saved[place.id]) root.touch(place.id, root.brief(place));
		root.write();
	}

	function forget(id) {
		root.history = root.history.filter(item => item.id !== id);
		root.write();
	}

	function entry(id) {
		return root.saved[id] ?? null;
	}

	function touch(id, change) {
		if (!id) return;
		const history = root.history.map(item => item.id === id ? Object.assign({}, item, change) : item);
		root.history = history;
		if (!root.saved[id]) {
			root.write();
			return;
		}
		const next = Object.assign({}, root.saved);
		next[id] = Object.assign({}, next[id], change);
		root.saved = next;
		root.write();
	}

	function keep(place, change) {
		if (!place?.id) return;
		const next = Object.assign({}, root.saved);
		const before = next[place.id] ?? Object.assign(root.brief(place), { list: "", stars: 0, note: "", saved: Date.now(), avatar: root.place?.id === place.id ? root.avatar : (place.avatar ?? "") });
		const after = Object.assign({}, before, change);
		// nothing left to keep: let it go
		if (after.list === "" && !after.stars && !after.note) delete next[place.id];
		else next[place.id] = after;
		root.saved = next;
		root.write();
	}

	function toggleList(place, list) {
		const current = root.saved[place.id]?.list ?? "";
		const change = { list: current === list ? "" : list };
		if (list === "been" && current !== "been") change.visited = Date.now();
		root.keep(place, change);
	}

	function rate(place, stars) {
		const current = root.saved[place.id]?.stars ?? 0;
		root.keep(place, { stars: current === stars ? 0 : stars });
	}

	function note(place, text) {
		if ((root.saved[place.id]?.note ?? "") === text) return;
		root.keep(place, { note: text });
	}

	function comparing(id) {
		return root.compare.some(item => item.id === id);
	}

	function toggleCompare(place) {
		if (root.comparing(place.id)) {
			root.compare = root.compare.filter(item => item.id !== place.id);
		} else {
			const item = Object.assign(root.brief(place), {
				avatar: root.place?.id === place.id ? root.avatar : (place.avatar ?? ""),
				routes: root.place?.id === place.id ? root.routes : null,
				features: place.features ?? [],
				facts: place.facts ?? []
			});
			root.compare = root.compare.concat([item]).slice(-3);
		}
		root.write();
	}

	function clearCompare() {
		root.compare = [];
		root.write();
	}

	function write() {
		store.setText(JSON.stringify({ saved: root.saved, history: root.history, compare: root.compare }, null, 2));
	}

	// ── opening hours ───────────────────────────────────────────────────

	readonly property var dayNames: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

	function dayIndex(date) {
		return (date.getDay() + 6) % 7;
	}

	function clock(minutes) {
		const m = ((minutes % 1440) + 1440) % 1440;
		return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
	}

	function span(minutes) {
		if (minutes < 60) return `${minutes} min`;
		const h = Math.floor(minutes / 60);
		const m = minutes % 60;
		return m === 0 || h >= 5 ? `${h} h` : `${h} h ${m} min`;
	}

	// { known, open, always, minutes (until it changes), until ("22:00", "Mon 11:00") }
	function openState(hours, at) {
		const week = hours?.week;
		if (!week || week.every(day => day.length === 0)) return { known: false };
		if (hours.always) return { known: true, open: true, always: true };
		const date = at ?? root.now;
		const today = root.dayIndex(date);
		const minute = date.getHours() * 60 + date.getMinutes();
		const current = week[today].find(range => range[0] <= minute && minute < range[1]);
		if (current) {
			// a range that runs to midnight and on into the next morning
			let end = current[1];
			let day = today;
			let guard = 0;
			while (end % 1440 === 0 && guard < 7) {
				const next = week[(day + 1) % 7].find(range => range[0] === 0);
				if (!next) break;
				end = (end - end % 1440) + next[1];
				day = (day + 1) % 7;
				guard += 1;
			}
			if (guard >= 7) return { known: true, open: true, always: true };
			return { known: true, open: true, minutes: end - minute, until: root.clock(end) };
		}
		for (let offset = 0; offset < 8; offset += 1) {
			const day = (today + offset) % 7;
			const start = week[day].map(range => range[0]).filter(start => offset > 0 || start > minute).sort((a, b) => a - b)[0];
			if (start === undefined) continue;
			const minutes = offset * 1440 + start - minute;
			return { known: true, open: false, minutes: minutes, until: offset === 0 ? root.clock(start) : (offset === 1 ? `tomorrow ${root.clock(start)}` : `${root.dayNames[day]} ${root.clock(start)}`) };
		}
		return { known: true, open: false };
	}

	// ── weather codes ───────────────────────────────────────────────────

	function weatherIcon(code, day) {
		const night = day === 0;
		if (code === 0) return night ? "weather_night" : "weather_sunny";
		if (code <= 2) return night ? "weather_night_partly_cloudy" : "weather_partly_cloudy";
		if (code === 3) return "weather_cloudy";
		if (code <= 48) return "weather_fog";
		if (code <= 57) return "weather_rainy";
		if (code <= 67) return "weather_pouring";
		if (code <= 77) return "weather_snowy";
		if (code <= 82) return "weather_pouring";
		if (code <= 86) return "weather_snowy_heavy";
		return "weather_lightning";
	}

	// ── links ───────────────────────────────────────────────────────────

	function placeQuery(place) {
		return [place?.name, place?.street, place?.postcode, place?.city].filter(part => part).join(", ");
	}

	function reviewsUrl(place) {
		return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(root.placeQuery(place))}`;
	}

	function routeUrl(place) {
		return `https://www.google.com/maps/dir/?api=1&destination=${place.lat},${place.lon}`;
	}

	function osmUrl(place) {
		return place?.osmUrl || `https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lon}#map=18/${place.lat}/${place.lon}`;
	}

	Timer {
		id: debounce

		interval: 320
		onTriggered: root.search()
	}

	Timer {
		interval: 30000
		repeat: true
		running: true
		onTriggered: root.now = new Date()
	}

	Component {
		id: finder

		Process {
			id: proc

			property int seq: 0
			property bool fresh: true

			stdout: SplitParser {
				onRead: line => root.handleSearch(proc, line)
			}
			onExited: code => {
				if (proc.seq === root._seq) {
					root._running = null;
					if (root.state === "loading") {
						root.state = code === 0 ? "none" : "error";
						if (code !== 0) root.error = "The search stopped";
					}
				}
				proc.destroy();
			}
		}
	}

	Component {
		id: reader

		Process {
			id: proc

			property int seq: 0

			stdout: SplitParser {
				onRead: line => root.handlePlace(proc.seq, line)
			}
			onExited: code => {
				if (proc.seq === root._placeSeq) {
					root._placeRunning = null;
					if (root.placeState === "loading") {
						root.placeState = "error";
						root.placeError = code === 0 ? "No answer" : "The lookup stopped";
					}
				}
				proc.destroy();
			}
		}
	}

	FileView {
		id: store

		path: Paths.stateFile("places.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}")) || {};
				root.saved = data.saved && typeof data.saved === "object" ? data.saved : {};
				root.history = Array.isArray(data.history) ? data.history : [];
				root.compare = Array.isArray(data.compare) ? data.compare : [];
			} catch (error) {}
		}
	}
}
