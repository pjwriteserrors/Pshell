pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The game library (`games` plugin, >games, scripts/games.py): Steam's
// installed games, its non-Steam shortcuts and games added here by their
// program. Steam's run through Steam; the others with Proton, Wine, as
// Linux programs, or through Steam once they were added to it.
//
// The library is read when the surface opens; pictures that are missing are
// fetched after (Steam's store, SteamGridDB with a key) and come in one game
// at a time. What runs is asked every few seconds while someone looks or a
// game runs.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/games.py`

	property var games: []
	property bool loaded: false
	property bool loading: false
	property string error: ""
	property bool steam: false
	property bool steamRunning: false
	// [{ id, name, kind: proton | wine }]
	property var runners: []
	// a SteamGridDB key is kept
	property bool gridKey: false
	// ids of the games that run
	property var running: []
	// the windows games_guard.py takes for games: [{id, app, title}]
	property var windows: []
	// the surface is up
	property bool watched: false
	// scripts/games_guard.py keeps games fullscreen
	readonly property bool guarding: guard.running

	// ── a launch ───────────────────────────────────────────────────────────
	property string launching: ""
	property string launchVia: ""
	property string launchError: ""
	// a game whose launch went through, until it is seen running or a while passed
	property string started: ""

	// ── adding to Steam ────────────────────────────────────────────────────
	property string steamAdding: ""
	property string steamProgress: ""

	// ── cover search ───────────────────────────────────────────────────────
	property string searchQuery: ""
	property var searchResults: []
	property bool searching: false

	// gamepads plugged in, read while the library is up (scripts/games_pad.py)
	property int pads: 0
	// a pad was pressed last, not a key: the hints show its buttons
	property bool padUsed: false
	signal pad(string button)

	// the game the library opens on (from the bar's panel), and whether with its menu
	property string focusId: ""
	property bool focusMenu: false

	// a program to add, asked for from elsewhere (the file manager, IPC)
	signal addRequested(string path)
	signal launched(string id)
	signal failed(string id, string message)

	readonly property var shown: root.games.filter(game => !game.hidden)

	function game(id) {
		return root.games.find(each => each.id === id) ?? null;
	}

	function isRunning(id) {
		return root.running.indexOf(id) >= 0;
	}

	function answerOf(text) {
		const lines = String(text || "").trim().split("\n");
		for (let i = lines.length - 1; i >= 0; i--) {
			try {
				return JSON.parse(lines[i]);
			} catch (error) {}
		}
		return {};
	}

	// a call of games.py; `done(answer)` gets the last line, `line(data)` each one
	function call(args, done, line) {
		const process = callComponent.createObject(root, { done: done ?? null, each: line ?? null });
		process.command = ["python3", "-u", root.script].concat(args);
		process.running = true;
		return process;
	}

	function refresh() {
		if (lister.running) return;
		root.loading = true;
		lister.running = true;
	}

	function fetchArt(ids) {
		if (artFetcher.running) return;
		artFetcher.command = ["python3", "-u", root.script, "art"].concat(ids ?? []);
		artFetcher.running = true;
	}

	// one game changed: its object is replaced, the rest keep theirs
	function patch(id, change) {
		const index = root.games.findIndex(each => each.id === id);
		if (index < 0) return;
		const next = root.games.slice();
		next[index] = Object.assign({}, next[index], change);
		root.games = next;
	}

	function replaceGame(game) {
		if (!game) return;
		const index = root.games.findIndex(each => each.id === game.id);
		const next = root.games.slice();
		if (index < 0) next.push(game);
		else next[index] = game;
		root.games = next;
	}

	// ── playing ────────────────────────────────────────────────────────────
	function launch(id, runner) {
		const game = root.game(id);
		if (!game || root.launching !== "") return;
		root.launching = id;
		root.launchVia = "";
		root.launchError = "";
		root.patch(id, { lastPlayed: Math.floor(Date.now() / 1000) });
		root.call(["launch", id, runner ?? ""], answer => {
			if (answer.error) {
				root.launchError = answer.error;
				root.launching = "";
				Sounds.play("error");
				root.failed(id, answer.error);
				return;
			}
			root.launchVia = answer.via || "";
			// the game finds a controller switched on later as well; it only has to be on
			if (answer.pads === 0)
				Notifs.post({ app: "Games", icon: "input-gaming", summary: "No controller is on", body: `Switch it on – ${game.name} picks it up once it is.` });
			root.started = id;
			startedTimeout.restart();
			root.launching = "";
			Sounds.play("taskDone");
			root.launched(id);
			root.pollRunning();
		});
	}

	// ── a game's landing page ─────────────────────────────────────────────
	// by id: what games.py stats said (play time, days, time to beat, achievements)
	property var stats: ({})
	property string statsLoading: ""

	function loadStats(id) {
		if (!id) return;
		root.statsLoading = id;
		root.call(["stats", id], answer => {
			if (root.statsLoading === id) root.statsLoading = "";
			if (answer.error || !answer.id) return;
			const next = Object.assign({}, root.stats);
			next[id] = answer;
			root.stats = next;
		});
	}

	// what beaten means: main | plus | full | done | "" (main)
	function setGoal(id, goal) {
		const known = root.stats[id];
		if (known) {
			const next = Object.assign({}, root.stats);
			next[id] = Object.assign({}, known, { goal });
			root.stats = next;
		}
		root.call(["goal", id, goal]);
	}

	// sessions of play: from when a game was first seen running to when it
	// was gone (games.py merges one its own watcher kept as well)
	property var sessionStarts: ({})

	function followSessions(now) {
		const at = Math.floor(Date.now() / 1000);
		const starts = Object.assign({}, root.sessionStarts);
		for (const id of now)
			if (starts[id] === undefined) starts[id] = at;
		for (const id of Object.keys(starts)) {
			if (now.indexOf(id) >= 0) continue;
			root.call(["session", id, String(starts[id]), String(at)]);
			delete starts[id];
		}
		root.sessionStarts = starts;
	}

	onWindowsChanged: root.pollRunning()

	function pollRunning() {
		if (!runningPoll.running) runningPoll.running = true;
	}

	// ── what the user keeps ────────────────────────────────────────────────
	function update(id, change, done) {
		root.patch(id, change);
		const request = Object.assign({ id: id }, change);
		root.call(["update", JSON.stringify(request)], answer => {
			if (answer.game) root.replaceGame(answer.game);
			if (done) done(answer);
		});
	}

	function toggleFavorite(id) {
		const game = root.game(id);
		if (!game) return;
		Sounds.play(game.favorite ? "toggleOff" : "toggleOn");
		root.update(id, { favorite: !game.favorite });
	}

	function setHidden(id, hidden) {
		root.update(id, { hidden: !!hidden });
	}

	function rename(id, name) {
		const text = String(name || "").trim();
		if (text === "") return;
		root.update(id, { name: text });
	}

	function setRunner(id, runner) {
		root.update(id, { runner: runner });
	}

	// art: "steam:<appid>", "sgdb:<id>" or "none"
	function setArt(id, art, done) {
		root.update(id, { art: art }, done);
	}

	function remove(id) {
		root.games = root.games.filter(each => each.id !== id);
		root.call(["remove", id]);
	}

	// request: { exe, name, runner, art }; done(game | null, error)
	function add(request, done) {
		root.call(["add", JSON.stringify(request)], answer => {
			if (answer.game) {
				root.replaceGame(answer.game);
				Sounds.play("taskDone");
			} else {
				Sounds.play("error");
			}
			if (done) done(answer.game ?? null, answer.error ?? "");
		});
	}

	function addToSteam(id, tool) {
		if (root.steamAdding !== "") return;
		root.steamAdding = id;
		root.steamProgress = "Adding to Steam";
		root.call(["steam-add", id, tool ?? ""], answer => {
			root.steamAdding = "";
			root.steamProgress = "";
			const game = root.game(id);
			if (answer.error) {
				Notifs.pushInternal("error", "Not added to Steam", answer.error, { icon: "steam" });
				return;
			}
			Notifs.pushInternal("done", `${game?.name ?? "The game"} is in Steam`, answer.restarted ? "Steam was restarted to take it in" : "It shows up in the library", { icon: "steam", sound: "taskDone" });
			root.refresh();
		}, data => {
			if (data.progress) root.steamProgress = data.progress;
		});
	}

	// ── finding pictures and programs ──────────────────────────────────────
	function search(term) {
		root.searchQuery = String(term || "").trim();
		searchDelay.restart();
	}

	function clearSearch() {
		searchDelay.stop();
		root.searchQuery = "";
		root.searchResults = [];
		root.searching = false;
	}

	function guess(path, done) {
		root.call(["guess", path], done);
	}

	// a program picked in a file dialog; done(path) – "" when nothing was
	property var pickDone: null
	property bool picking: false

	function pickProgram(done) {
		if (root.picking) return;
		root.pickDone = done;
		root.picking = true;
		// where the other games are: the folder all of them share
		const dirs = root.games.filter(each => each.kind !== "steam" && each.dir).map(each => String(each.dir).replace(/\/+$/, "").split("/"));
		let common = dirs.length > 0 ? dirs[0].slice(0, -1) : [];
		for (const parts of dirs) {
			let i = 0;
			while (i < common.length && i < parts.length && common[i] === parts[i]) i++;
			common = common.slice(0, i);
		}
		const start = common.length > 1 ? common.join("/") : Paths.home;
		Files.pick({ title: "Add a game", folder: start, filters: ["*.exe", "*.msi", "*.bat", "*.sh", "*.x86_64", "*.AppImage"] }, paths => {
			root.picking = false;
			const done = root.pickDone;
			root.pickDone = null;
			if (done) done(paths[0] ?? "");
		});
	}

	function setKey(key, done) {
		root.call(["key", key], answer => {
			if (!answer.error) root.gridKey = !!answer.key;
			if (done) done(answer);
		});
	}

	// ── processes ──────────────────────────────────────────────────────────
	Process {
		id: lister

		command: ["python3", root.script, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				root.loading = false;
				const data = root.answerOf(text);
				if (!data.games) {
					root.error = data.error || "The library could not be read";
					root.loaded = true;
					return;
				}
				root.error = "";
				root.steam = !!data.steam;
				root.steamRunning = !!data.steamRunning;
				root.runners = data.runners || [];
				root.gridKey = !!data.gridKey;
				if (JSON.stringify(data.games) !== JSON.stringify(root.games)) root.games = data.games;
				root.loaded = true;
				if (data.games.some(game => game.needsArt || !game.art?.hero)) root.fetchArt();
			}
		}
	}

	Process {
		id: artFetcher

		stdout: SplitParser {
			onRead: line => {
				let data = {};
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (data.id) root.patch(data.id, { art: data.art, artChoice: data.artChoice, needsArt: !data.art?.cover });
			}
		}
	}

	Timer {
		id: searchDelay

		interval: 380
		onTriggered: {
			if (root.searchQuery === "") {
				root.searchResults = [];
				root.searching = false;
				return;
			}
			root.searching = true;
			const query = root.searchQuery;
			root.call(["search", query], answer => {
				// an older answer that arrives late is not this search's
				if (query !== root.searchQuery) return;
				root.searchResults = answer.results || [];
				root.searching = false;
			});
		}
	}


	// what runs: often while someone looks or a game was just started
	Timer {
		interval: root.started !== "" ? 1500 : 4000
		repeat: true
		running: Plugins.on("games") && (root.watched || root.running.length > 0 || root.windows.length > 0 || root.started !== "")
		triggeredOnStart: true
		onTriggered: root.pollRunning()
	}

	Timer {
		id: startedTimeout

		interval: 90000
		onTriggered: root.started = ""
	}

	Process {
		id: runningPoll

		command: ["python3", root.script, "running"]
		stdout: StdioCollector {
			onStreamFinished: {
				const data = root.answerOf(text);
				if (!data.running) return;
				const ended = root.running.filter(id => data.running.indexOf(id) < 0);
				if (JSON.stringify(data.running) !== JSON.stringify(root.running)) root.running = data.running;
				root.followSessions(data.running);
				if (root.started !== "" && root.running.indexOf(root.started) >= 0) root.started = "";
				// a game that ended has a new play time
				if (ended.length > 0 && root.watched) root.refresh();
			}
		}
	}

	Process {
		id: padReader

		running: Plugins.on("games") && root.watched
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/games_pad.py`]
		stdout: SplitParser {
			onRead: line => {
				let data = {};
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (data.pads !== undefined) root.pads = data.pads;
				if (data.pad) {
					root.padUsed = true;
					root.pad(data.pad);
				}
			}
		}
		onExited: root.pads = 0
	}

	// every game's window fullscreen, also one started in Steam itself
	Process {
		id: guard

		running: Plugins.on("games")
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/games_guard.py`]
		environment: ({ PSHELL_NIRI_EVENTS: "stdin" })
		stdout: SplitParser {
			onRead: line => {
				let data = null;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (Array.isArray(data.gaming)) root.windows = data.gaming;
			}
		}
		onExited: root.windows = []
		// niri's events from the shell's own stream, the whole state first
		onRunningChanged: if (guard.running && Niri.ready) for (const line of Niri.replay()) guard.write(line + "\n")
	}

	Connections {
		target: Niri
		enabled: guard.running

		function onLine(text, event) {
			if (/^\{"(Window|Workspace)/.test(text)) guard.write(text + "\n");
		}
	}

	Component {
		id: callComponent

		Process {
			id: job

			property var done: null
			property var each: null
			property string last: ""

			stdout: SplitParser {
				onRead: line => {
					job.last = line;
					if (!job.each) return;
					try {
						job.each(JSON.parse(line));
					} catch (error) {}
				}
			}
			onExited: code => {
				const answer = root.answerOf(job.last);
				if (code !== 0 && !answer.error) answer.error = "Something went wrong";
				if (job.done) job.done(answer);
				job.destroy();
			}
		}
	}
}
