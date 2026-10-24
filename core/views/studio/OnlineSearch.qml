pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core.services

// What the theme picker's Online tab finds on Wallhaven and MoeWalls
// (scripts/wallpaper_search.py): the query, every filter either source
// knows, the pages found so far, and the result in front made ready to be
// looked at (staged: the full picture or the large still, with its tags) a
// moment after it came to the front. Nothing of it is written anywhere: the
// query, the filters and the tags live in here, the pictures in memory
// (forget() drops them when the picker closes), and what is worn is
// forgotten by the theme scripts once something else is put on.
Item {
	id: root

	readonly property string script: `${Quickshell.shellDir}/scripts/wallpaper_search.py`

	readonly property var sources: [
		{ value: "wallhaven", label: "Wallhaven" },
		{ value: "moewalls", label: "MoeWalls" }
	]
	readonly property var wallhavenCategories: [
		{ value: "general", label: "General" },
		{ value: "anime", label: "Anime" },
		{ value: "people", label: "People" }
	]
	readonly property var wallhavenTopics: ["Landscape", "Nature", "Space", "Minimalism", "City", "Abstract", "Mountains", "Forest", "Ocean", "Sunset", "Architecture", "Cars", "Fantasy", "Digital art", "Cyberpunk", "Dark"]
	readonly property var wallhavenSortings: [
		{ value: "date_added", label: "Latest" },
		{ value: "relevance", label: "Relevance" },
		{ value: "hot", label: "Hot" },
		{ value: "toplist", label: "Toplist" },
		{ value: "views", label: "Views" },
		{ value: "favorites", label: "Favorites" },
		{ value: "random", label: "Random" }
	]
	readonly property var topRanges: [
		{ value: "1d", label: "Day" },
		{ value: "3d", label: "3 days" },
		{ value: "1w", label: "Week" },
		{ value: "1M", label: "Month" },
		{ value: "3M", label: "3 months" },
		{ value: "6M", label: "6 months" },
		{ value: "1y", label: "Year" }
	]
	readonly property var purities: [
		{ value: "sfw", label: "SFW" },
		{ value: "sketchy", label: "Sketchy" },
		{ value: "nsfw", label: "NSFW" }
	]
	readonly property var fileTypes: [
		{ value: "", label: "Any" },
		{ value: "jpg", label: "JPG" },
		{ value: "png", label: "PNG" }
	]
	readonly property var wallhavenResolutions: ["1920x1080", "2560x1080", "2560x1440", "3440x1440", "3840x1600", "3840x2160", "5120x1440", "5120x2880"]
	readonly property var ratios: [
		{ value: "landscape", label: "Landscape" },
		{ value: "portrait", label: "Portrait" },
		{ value: "16x9", label: "16:9" },
		{ value: "16x10", label: "16:10" },
		{ value: "21x9", label: "21:9" },
		{ value: "32x9", label: "32:9" },
		{ value: "48x9", label: "48:9" },
		{ value: "4x3", label: "4:3" },
		{ value: "3x2", label: "3:2" },
		{ value: "9x16", label: "9:16" }
	]
	// the colours Wallhaven searches by
	readonly property var colors: ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399", "333399", "0066cc", "0099cc", "66cccc", "77cc33", "669900", "336600", "666600", "999900", "cccc33", "ffff00", "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300", "000000", "999999", "cccccc", "ffffff", "424153"]
	readonly property var moewallsCategories: [
		{ value: "", label: "All" },
		{ value: "landscape", label: "Landscape" },
		{ value: "fantasy", label: "Fantasy" },
		{ value: "sci-fi", label: "Sci-fi" },
		{ value: "abstract", label: "Abstract" },
		{ value: "pixel-art", label: "Pixel Art" },
		{ value: "vehicle", label: "Vehicle" },
		{ value: "animal", label: "Animal" },
		{ value: "lifestyle", label: "Lifestyle" },
		{ value: "games", label: "Games" },
		{ value: "anime", label: "Anime" },
		{ value: "movies", label: "Movies" },
		{ value: "others", label: "Others" }
	]
	readonly property var moewallsSortings: [
		{ value: "latest", label: "Latest" },
		{ value: "popular", label: "Popular" }
	]
	readonly property var moewallsRanges: [
		{ value: "day", label: "Day" },
		{ value: "week", label: "Week" },
		{ value: "month", label: "Month" },
		{ value: "all", label: "All time" }
	]
	readonly property var moewallsResolutions: ["1920x1080", "2560x1440", "3840x2160", "2560x1080", "3440x1440", "5120x1440", "7680x2160"]

	readonly property var wallhavenDefaults: ({
		categories: ["general", "anime", "people"],
		purity: ["sfw"],
		sorting: "toplist",
		order: "desc",
		topRange: "1M",
		resolutionMode: "atleast",
		atleast: "",
		resolutions: [],
		ratios: [],
		color: "",
		fileType: ""
	})
	readonly property var moewallsDefaults: ({
		category: "",
		sorting: "latest",
		range: "week",
		resolution: ""
	})

	property string source: "wallhaven"
	property string query: ""
	property var wallhaven: root.wallhavenDefaults
	property var moewalls: root.moewallsDefaults
	readonly property var filters: root.source === "wallhaven" ? root.wallhaven : root.moewalls
	// MoeWalls counts views only of the whole site or a category
	readonly property bool popularOnly: root.query.trim() === "" && root.moewalls.resolution === ""
	readonly property string moewallsSorting: root.popularOnly ? root.moewalls.sorting : "latest"
	// what differs from the defaults in the sheet (the chips above it count not)
	readonly property int activeFilters: {
		if (root.source === "moewalls")
			return ["sorting", "resolution"].filter(key => root.moewalls[key] !== root.moewallsDefaults[key]).length + (root.moewalls.sorting === "popular" && root.moewalls.range !== root.moewallsDefaults.range ? 1 : 0);
		return ["sorting", "order", "purity", "atleast", "resolutions", "ratios", "color", "fileType"].filter(key => JSON.stringify(root.wallhaven[key]) !== JSON.stringify(root.wallhavenDefaults[key])).length;
	}

	property var items: []
	property int page: 0
	property int lastPage: 0
	property int total: 0
	property string seed: ""
	property bool loading: false
	property bool loadingMore: false
	property string error: ""
	property bool searched: false
	// the query the results are for
	property string askedQuery: ""
	property int index: 0
	readonly property var current: root.items[root.index] ?? null
	readonly property bool more: root.page < root.lastPage

	// key → what stage answered; key → why it failed
	property var staged: ({})
	property var stageErrors: ({})
	readonly property var currentStage: root.current ? (root.staged[root.keyOf(root.current)] ?? null) : null
	readonly property string currentStageError: root.current ? (root.stageErrors[root.keyOf(root.current)] ?? "") : ""
	// the download of the result in front, while it is staged: how far (0 to
	// 1), how many bytes of how many, and since when (for the time left)
	readonly property bool currentStaging: root.current !== null && root.staging(root.current)
	property real stageProgress: 0
	property real stageBytes: 0
	property real stageTotal: 0
	property real stageStarted: 0

	property bool keySet: false
	property bool keyBusy: false
	property string keyError: ""

	// the download of what is put on, and what follows it
	property bool saving: false
	property real saveProgress: 0
	property real saveBytes: 0
	property real saveTotal: 0
	property real saveStarted: 0
	property var afterSave: null

	function keyOf(item) {
		return `${item.source}:${item.id}`;
	}

	function set(name, value) {
		const changes = {};
		changes[name] = value;
		root.assign(changes);
	}

	function assign(changes) {
		const next = Object.assign({}, root.filters, changes);
		if (root.source === "wallhaven") root.wallhaven = next;
		else root.moewalls = next;
		root.search();
	}

	// MoeWalls' views are counted without a query or a resolution
	function choosePopular() {
		root.query = "";
		root.assign({ sorting: "popular", resolution: "" });
	}

	// a value of a list that is chosen or not; an empty list is not left
	// where it means nothing (categories, purity)
	function toggle(name, value, keepOne) {
		const list = (root.filters[name] ?? []).slice();
		const at = list.indexOf(value);
		if (at >= 0) {
			if (keepOne && list.length === 1) return;
			list.splice(at, 1);
		} else {
			list.push(value);
		}
		root.set(name, list);
	}

	function setSource(value) {
		if (value === root.source) return;
		root.source = value;
		root.search();
	}

	function resetFilters() {
		if (root.source === "wallhaven") {
			const next = Object.assign({}, root.wallhavenDefaults);
			next.categories = root.wallhaven.categories;
			root.wallhaven = next;
		} else {
			const next = Object.assign({}, root.moewallsDefaults);
			next.category = root.moewalls.category;
			root.moewalls = next;
		}
		root.search();
	}

	function params(page) {
		const params = Object.assign({ source: root.source, q: root.query.trim(), page: page }, root.filters);
		if (root.source === "moewalls") params.sorting = root.moewallsSorting;
		if (page > 1 && root.seed !== "") params.seed = root.seed;
		return params;
	}

	// the first page of what the query and the filters find
	function search() {
		searchDelay.stop();
		root.searched = true;
		root.askedQuery = root.query.trim();
		root.loading = true;
		root.loadingMore = false;
		root.error = "";
		root.seed = "";
		searcher.page = 1;
		searcher.running = false;
		searcher.command = ["python3", root.script, "search", JSON.stringify(root.params(1))];
		searcher.running = true;
	}

	// typing: asked once the typing pauses
	function searchSoon() {
		searchDelay.restart();
	}

	function loadMore() {
		if (!root.more || root.loading || root.loadingMore) return;
		root.loadingMore = true;
		searcher.page = root.page + 1;
		searcher.running = false;
		searcher.command = ["python3", root.script, "search", JSON.stringify(root.params(searcher.page))];
		searcher.running = true;
	}

	function received(text, page) {
		let data = {};
		try {
			data = JSON.parse(String(text || "").trim() || "{}");
		} catch (error) {
			data = { error: "No answer" };
		}
		root.loading = false;
		root.loadingMore = false;
		if (data.error) {
			if (page === 1) {
				root.items = [];
				root.error = data.error;
			}
			return;
		}
		const items = Array.isArray(data.items) ? data.items : [];
		if (page === 1) {
			root.index = 0;
			root.items = items;
		} else {
			const known = new Set(root.items.map(item => item.id));
			root.items = root.items.concat(items.filter(item => !known.has(item.id)));
		}
		root.page = Number(data.page || page);
		root.lastPage = Number(data.lastPage || root.page);
		root.total = Number(data.total || 0);
		if (data.seed) root.seed = String(data.seed);
		root.stageSoon();
	}

	// Wallhaven's own query words: pictures like one, an uploader's
	function searchFor(query) {
		root.query = query;
		root.search();
	}

	function move(delta) {
		if (root.items.length === 0) return;
		root.select(Math.max(0, Math.min(root.items.length - 1, root.index + delta)));
	}

	function select(index) {
		root.index = index;
		if (root.items.length - index <= 6) root.loadMore();
		root.stageSoon();
	}

	// stepping quickly through the strip asks only for where it stops
	function stageSoon() {
		stageDelay.restart();
	}

	function stage() {
		const item = root.current;
		if (!item) return;
		const key = root.keyOf(item);
		if (root.staged[key] || (stager.running && stager.key === key)) return;
		stager.running = false;
		stager.key = key;
		stager.last = "";
		root.stageProgress = 0;
		root.stageBytes = 0;
		root.stageTotal = 0;
		root.stageStarted = Date.now();
		stager.command = ["python3", root.script, "stage", JSON.stringify(item)];
		stager.running = true;
	}

	function staging(item) {
		return !!item && stager.running && stager.key === root.keyOf(item);
	}

	function stageArrived(key, text) {
		let data = {};
		try {
			data = JSON.parse(String(text || "").trim() || "{}");
		} catch (error) {
			data = { error: "No answer" };
		}
		if (data.error || !data.themePath) {
			const errors = Object.assign({}, root.stageErrors);
			errors[key] = data.error || "Could not load";
			root.stageErrors = errors;
			return;
		}
		// as many as the script keeps (its STAGE_KEEP), the oldest go first
		const staged = Object.assign({}, root.staged);
		staged[key] = data;
		const keys = Object.keys(staged);
		for (const old of keys.slice(0, Math.max(0, keys.length - 40))) delete staged[old];
		root.staged = staged;
	}

	// the staged result as a folder to put on; `then` gets it
	function wear(item, then) {
		const stage = item ? root.staged[root.keyOf(item)] : null;
		if (!stage || root.saving) return;
		root.afterSave = then ?? null;
		root.saveProgress = 0;
		root.saveBytes = 0;
		root.saveTotal = 0;
		root.saveStarted = Date.now();
		root.saving = true;
		saver.command = ["python3", root.script, "wear", JSON.stringify({ item: item, stage: stage })];
		saver.running = true;
	}

	// the staged pictures, with their previews and colours
	function forget() {
		stager.running = false;
		root.staged = ({});
		root.stageErrors = ({});
		Quickshell.execDetached(["python3", root.script, "forget"]);
	}

	function cancelSave() {
		root.afterSave = null;
		root.saving = false;
		saver.running = false;
	}

	function saveFinished(line) {
		let data = {};
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!root.saving) return;
		root.saving = false;
		if (data.error || !data.themePath) {
			root.afterSave = null;
			Notifs.pushInternal("error", "Could not download the wallpaper", data.error || "", { icon: "download" });
			return;
		}
		const then = root.afterSave;
		root.afterSave = null;
		if (then) then(data.themePath);
	}

	// `progress <0..1> <bytes> <total>` of the script, or null
	function progressOf(line) {
		const match = String(line).match(/^progress ([0-9.]+)(?: ([0-9]+) ([0-9]+))?$/);
		if (!match) return null;
		return {
			fraction: Math.max(0, Math.min(1, Number(match[1]))),
			bytes: Number(match[2] ?? 0),
			total: Number(match[3] ?? 0)
		};
	}

	function setKey(key) {
		root.keyBusy = true;
		root.keyError = "";
		keySetter.pending = String(key || "").trim();
		keySetter.running = true;
	}

	Timer {
		id: searchDelay

		interval: 550
		onTriggered: root.search()
	}

	Timer {
		id: stageDelay

		interval: 280
		onTriggered: root.stage()
	}

	Process {
		id: searcher

		property int page: 1

		command: ["true"]
		// a search that was overtaken by the next one says nothing
		onExited: (exitCode, exitStatus) => {
			if (exitStatus === 0) root.received(results.text, searcher.page);
		}
		stdout: StdioCollector {
			id: results
		}
	}

	Process {
		id: stager

		property string key: ""
		// its answer, the line after the progress
		property string last: ""

		command: ["true"]
		// its last line is read before this is looked at
		onExited: (exitCode, exitStatus) => {
			if (exitStatus !== 0) return;
			const key = stager.key;
			Qt.callLater(() => {
				if (stager.key === key) root.stageArrived(key, stager.last);
			});
		}
		stdout: SplitParser {
			onRead: line => {
				const progress = root.progressOf(line);
				if (!progress) {
					stager.last = String(line);
					return;
				}
				root.stageProgress = progress.fraction;
				root.stageBytes = progress.bytes;
				root.stageTotal = progress.total;
			}
		}
	}

	Process {
		id: saver

		command: ["true"]
		stdout: SplitParser {
			onRead: line => {
				const progress = root.progressOf(line);
				if (!progress) {
					root.saveFinished(line);
					return;
				}
				root.saveProgress = progress.fraction;
				if (progress.total > 0) {
					root.saveBytes = progress.bytes;
					root.saveTotal = progress.total;
				}
			}
		}
		// its last line is read before this is looked at
		onExited: Qt.callLater(() => {
			if (!root.saving) return;
			root.cancelSave();
			Notifs.pushInternal("error", "Could not download the wallpaper", "", { icon: "download" });
		})
	}

	Process {
		id: keyReader

		running: Plugins.on("studio-wallpaper-online")
		command: ["python3", root.script, "key"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.keySet = !!JSON.parse(text).set;
				} catch (error) {}
			}
		}
	}

	Process {
		id: keySetter

		property string pending: ""

		command: ["python3", root.script, "key-set"]
		stdinEnabled: true
		onRunningChanged: if (keySetter.running) keySetter.write(keySetter.pending + "\n")
		stdout: StdioCollector {
			onStreamFinished: {
				root.keyBusy = false;
				try {
					const data = JSON.parse(text);
					root.keySet = !!data.set;
					root.keyError = String(data.error || "");
				} catch (error) {
					root.keyError = "No answer";
				}
				if (!root.keyError) root.search();
			}
		}
	}
}
