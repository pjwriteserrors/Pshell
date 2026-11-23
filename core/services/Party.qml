pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Split-screen co-op with PartyDeck (`games` plugin, scripts/party.py,
// core/views/games/PartyLobby.qml): the controllers, live while the lobby is
// open; what a party of a game needs (PartyDeck's handler, its program); the
// party that runs. Offered for games Steam's store calls online or LAN co-op.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/party.py`

	// PartyDeck is there
	property bool installed: false
	// the lobby is up: controllers are read
	property bool watching: false
	property var pads: []
	signal press(string pad, string button)

	// what party.py info said for the game of the lobby
	property var info: null
	property string infoFor: ""
	property bool loading: false

	property bool starting: false
	property string error: ""
	// the party that runs: {id, name, started, players}
	property var current: null

	function offered(game) {
		return root.installed && !!game && Array.isArray(game.coop) && (game.coop.includes("online") || game.coop.includes("lan"));
	}

	function runs(id) {
		return !!root.current && root.current.id === id;
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

	function call(args, done) {
		const process = callComponent.createObject(root, { done: done ?? null });
		process.command = ["python3", "-u", root.script].concat(args);
		process.running = true;
	}

	function load(game) {
		root.info = null;
		root.error = "";
		root.infoFor = game.id;
		root.loading = true;
		root.call(["info", JSON.stringify(root.gameOf(game))], answer => {
			if (root.infoFor !== game.id) return;
			root.loading = false;
			if (answer.error) root.error = answer.error;
			else root.info = answer;
		});
	}

	function gameOf(game) {
		return { id: game.id, name: game.name, kind: game.kind, appid: game.appid ?? "", dir: game.dir ?? "", exe: game.exe ?? "", tool: game.tool ?? "" };
	}

	function rumble(padId) {
		if (watcher.running) watcher.write(`rumble ${padId}\n`);
	}

	// plan: {game, exec, goldberg, layouts, players: [{pad, padId, profile, output, rect}]}
	function launch(plan, done) {
		if (root.starting) return;
		root.starting = true;
		root.error = "";
		root.call(["launch", JSON.stringify(plan)], answer => {
			root.starting = false;
			if (answer.error) {
				root.error = answer.error;
				Sounds.play("error");
			} else {
				Sounds.play("gameStart");
				root.poll();
				Games.pollRunning();
			}
			if (done) done(answer);
		});
	}

	function stop() {
		root.call(["stop"], () => {
			root.poll();
			Games.pollRunning();
		});
	}

	function poll() {
		root.call(["status"], answer => root.current = answer.party ?? null);
	}

	Component.onCompleted: {
		if (Plugins.on("games")) {
			finder.running = true;
			root.poll();
		}
	}

	Process {
		id: finder

		command: ["sh", "-c", "command -v partydeck"]
		onExited: code => root.installed = code === 0
	}

	// a party's end is seen a while after
	Timer {
		interval: 5000
		repeat: true
		running: root.current !== null
		onTriggered: root.poll()
	}

	Process {
		id: watcher

		running: root.watching && Plugins.on("games")
		stdinEnabled: true
		command: ["python3", "-u", root.script, "watch"]
		stdout: SplitParser {
			onRead: line => {
				let data = {};
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (Array.isArray(data.pads)) root.pads = data.pads;
				if (data.press) root.press(data.press, data.button);
			}
		}
		onRunningChanged: if (!running) root.pads = []
	}

	Component {
		id: callComponent

		Process {
			id: job

			property var done: null
			property string last: ""

			stdout: SplitParser {
				onRead: line => job.last = line
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
