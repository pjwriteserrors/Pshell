pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// A local model that helps to write a mail (scripts/messages/assist.py,
// Ollama; plugin mail-ai). It is told what was done and how the mail should
// read and writes the whole answer; or it puts the greeting, a sentence of
// thanks and a last sentence around what was written. Which model writes a
// mail is picked between fast and good (mail-ai.json); the frame is always
// the fastest one's. It only ever proposes:
// what it writes goes into the field when it is taken, and is edited there.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("mail-ai") && Mail.enabled

	// the models that can write, from the fastest to the best: [{ name, size }]
	property var models: []
	// the one that was picked; "" or one that is gone means the fastest
	property string picked: ""
	readonly property int level: Math.max(0, root.models.findIndex(model => model.name === root.picked))
	readonly property string model: root.models[root.level]?.name ?? ""

	onEnabledChanged: if (root.enabled) root.look()

	// what is installed, asked again whenever the panel comes up
	function look() {
		if (!lister.running) lister.running = true;
	}

	function pick(level) {
		const name = root.models[Math.max(0, Math.min(root.models.length - 1, level))]?.name ?? "";
		if (name === root.picked) return;
		root.picked = name;
		settings.setText(JSON.stringify({ model: name }, null, "\t") + "\n");
	}

	// what was said to it and what it wrote, by chat: { id: [{ role: "user" | "assistant", text }] }
	property var chats: ({})
	// the chat it is writing for, or ""
	property string writing: ""
	property string error: ""

	// the chat a frame is made for, and the one that is there: { key, greeting, thanks, closing }
	property string framing: ""
	property var framed: null
	property string frameError: ""

	function said(key) {
		return root.chats[key] ?? [];
	}

	function put(key, entries) {
		const next = Object.assign({}, root.chats);
		if (entries.length > 0) next[key] = entries;
		else delete next[key];
		root.chats = next;
	}

	// context: { me, to, thread, draft } as assist.py reads it
	function ask(key, context, text) {
		if (root.writing !== "" || String(text).trim() === "") return;
		const entries = root.said(key).concat([{ role: "user", text: String(text).trim() }]);
		root.put(key, entries);
		root.error = "";
		root.writing = key;
		writer.command = ["python3", `${Paths.scripts}/messages/assist.py`, "write", JSON.stringify(Object.assign({}, context, { chat: entries, model: root.model }))];
		writer.running = true;
	}

	function frame(key, context) {
		if (root.framing !== "") return;
		root.frameError = "";
		root.framed = null;
		root.framing = key;
		framer.command = ["python3", `${Paths.scripts}/messages/assist.py`, "frame", JSON.stringify(Object.assign({}, context, { model: root.models[0]?.name ?? "" }))];
		framer.running = true;
	}

	function stop() {
		writer.running = false;
		framer.running = false;
	}

	function forget(key) {
		if (root.writing === key) writer.running = false;
		root.put(key, []);
		root.error = "";
	}

	function parsed(line) {
		try {
			return JSON.parse(line);
		} catch (error) {
			return {};
		}
	}

	Process {
		id: lister

		running: root.enabled
		command: ["python3", `${Paths.scripts}/messages/assist.py`, "models"]
		stdout: SplitParser {
			onRead: line => {
				const data = root.parsed(line);
				if (data.models) root.models = data.models;
			}
		}
	}

	FileView {
		id: settings

		path: Paths.stateFile("mail-ai.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.picked = String(JSON.parse(String(text() || "{}")).model ?? "");
			} catch (error) {}
		}
	}

	Process {
		id: writer

		stdout: SplitParser {
			onRead: line => {
				const data = root.parsed(line);
				if (data.error) root.error = data.error;
				else if (data.done && root.writing !== "") root.put(root.writing, root.said(root.writing).concat([{ role: "assistant", text: data.text }]));
			}
		}
		onExited: root.writing = ""
	}

	Process {
		id: framer

		stdout: SplitParser {
			onRead: line => {
				const data = root.parsed(line);
				if (data.error) root.frameError = data.error;
				else if (data.greeting !== undefined) root.framed = { key: root.framing, greeting: data.greeting, thanks: data.thanks, closing: data.closing };
			}
		}
		onExited: root.framing = ""
	}
}
