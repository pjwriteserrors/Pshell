pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Which program opens what – the desktop's default apps, as xdg-open, the
// portals and the programs themselves go by (mimeapps.list, read and written
// by scripts/default_apps.py through GIO). Pshell settings → Default apps.
//
// Two the shell asks itself: its terminal and the browser it opens pages
// in. Picked there, they are kept in default-apps.json and win over the
// host profile (Terminal.qml, Browser.qml).
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/default_apps.py`

	// [{ id, label, icon, types, current, currentReal, currentApp, others: [{ type, app, name }], unset, apps: [{ id, name, icon, executable, hidden, command, types, share }] }]
	property var kinds: []
	// [{ id, name, icon, executable }]
	property var terminals: []
	property bool loading: false
	property bool loaded: false
	property string file: ""
	property bool backedUp: false
	// the kind being changed right now, and to which program
	property string busy: ""
	property string pending: ""
	property string error: ""

	// the shell's own: executables, "" for the host profile's
	property string terminal: ""
	property string browser: ""

	readonly property var byId: {
		const out = {};
		for (const kind of root.kinds) out[kind.id] = kind;
		return out;
	}

	function load() {
		if (lister.running) return;
		root.loading = true;
		lister.running = true;
	}

	// the program for every type of a kind it opens
	function set(kind, appId) {
		if (root.busy !== "") return;
		root.busy = kind;
		root.pending = appId;
		root.error = "";
		const app = root.byId[kind]?.apps.find(entry => entry.id === appId);
		setter.command = ["python3", root.script, "set", kind, appId];
		setter.running = true;
		// the shell opens pages in the browser picked here
		if (kind === "browser" && app?.executable) root.keep("browser", app.executable);
	}

	// one type only (one that opened elsewhere)
	function setType(kind, mime, appId) {
		if (root.busy !== "") return;
		root.busy = kind;
		root.pending = appId;
		root.error = "";
		setter.command = ["python3", root.script, "set-type", mime, appId];
		setter.running = true;
	}

	// several types of a kind at once
	function setTypes(kind, mimes, appId) {
		if (root.busy !== "" || mimes.length === 0) return;
		root.busy = kind;
		root.pending = appId;
		root.error = "";
		setter.command = ["python3", root.script, "set-type", mimes.join(","), appId];
		setter.running = true;
	}

	function keep(name, value) {
		if (name === "terminal") root.terminal = String(value);
		else if (name === "browser") root.browser = String(value);
		state.setText(JSON.stringify({ terminal: root.terminal, browser: root.browser }) + "\n");
	}

	// a program's name as the list says it: a one-off "open with" command by what it runs
	function nameOf(app) {
		if (!app) return "Nothing";
		if (app.hidden && app.command && ["sh", "bash", "zsh", "env"].includes(app.name)) {
			const inner = /-c\s+'([^']+)'/.exec(app.command);
			return inner ? inner[1] : app.command;
		}
		return app.name;
	}

	function take(kind) {
		if (!kind) return;
		root.kinds = root.kinds.map(entry => entry.id === kind.id ? kind : entry);
	}

	Process {
		id: lister

		command: ["python3", root.script, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text));
					root.kinds = data.kinds || [];
					root.terminals = data.terminals || [];
					root.file = String(data.file || "");
					root.backedUp = data.backup === true;
					root.loaded = true;
				} catch (error) {
					root.error = "Could not read the default apps";
				}
				root.loading = false;
			}
		}
		onExited: code => {
			if (code !== 0) {
				root.loading = false;
				root.error = "Could not read the default apps";
			}
		}
	}

	Process {
		id: setter

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text));
					root.take(data.state);
					root.backedUp = true;
				} catch (error) {}
			}
		}
		stderr: StdioCollector {
			onStreamFinished: if (String(text).trim() !== "") root.error = String(text).trim().split("\n").pop()
		}
		onExited: code => {
			if (code !== 0 && root.error === "") root.error = "That did not work";
			root.busy = "";
			root.pending = "";
		}
	}

	FileView {
		id: state

		path: Paths.stateFile("default-apps.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.terminal = String(data.terminal || "");
				root.browser = String(data.browser || "");
			} catch (error) {}
		}
	}
}
