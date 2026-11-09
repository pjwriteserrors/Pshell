pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The launcher's dictionary (>d): what a word means, said and looks like.
// scripts/dictionary.py asks Wiktionary, Wikipedia, Commons and Openverse
// and answers in lines – the entry first, then the pictures one by one as
// they arrive, so the view can bring them in as they come. Typing is
// debounced; a newer word stops the lookup of the older one.
Singleton {
	id: root

	// what is asked for
	property string query: ""
	property string lang: "auto"
	// what came back
	property var entry: null
	property var images: []
	// idle · loading · found · none · error
	property string state: "idle"
	property string error: ""
	readonly property bool loading: root.state === "loading" || debounce.running
	// words looked up lately, newest first
	property var recent: []
	readonly property bool speaking: speaker.running

	property string _query: ""
	property string _lang: "auto"
	property string _shown: ""
	property int _seq: 0
	property var _running: null
	readonly property bool picturesComing: root._running !== null && root.entry !== null

	function request(text, lang) {
		const value = String(text || "").trim();
		const language = String(lang || "auto");
		if (value === "") {
			debounce.stop();
			root.stopLookup();
			root._shown = "";
			root.entry = null;
			root.images = [];
			root.state = "idle";
			return;
		}
		if (`${language}\n${value}` === root._shown) return;
		root._query = value;
		root._lang = language;
		debounce.restart();
	}

	// right now, without waiting for the typing to stop
	function flush() {
		if (!debounce.running) return;
		debounce.stop();
		root.start();
	}

	function start() {
		root._shown = `${root._lang}\n${root._query}`;
		root.query = root._query;
		root.lang = root._lang;
		root.error = "";
		root.state = "loading";
		root.stopLookup();
		root._seq += 1;
		const proc = lookup.createObject(root, { seq: root._seq });
		proc.command = ["python3", "-u", `${Paths.scripts}/dictionary.py`, root._query, "--lang", root._lang];
		proc.running = true;
		root._running = proc;
	}

	function stopLookup() {
		root._seq += 1;
		if (root._running) root._running.running = false;
		root._running = null;
	}

	function handle(seq, line) {
		if (seq !== root._seq) return;
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (message.type) {
		case "entry":
			root.entry = message;
			root.images = [];
			root.state = "found";
			root.remember(message.word);
			break;
		case "image":
			root.images = root.images.concat([message]).sort((a, b) => a.index - b.index);
			break;
		case "none":
			root.entry = null;
			root.images = [];
			root.state = "none";
			break;
		case "error":
			root.error = String(message.error || "Lookup failed");
			root.state = "error";
			break;
		}
	}

	function remember(word) {
		const value = String(word || "");
		if (value === "") return;
		root.recent = [value].concat(root.recent.filter(item => item.toLowerCase() !== value.toLowerCase())).slice(0, 8);
		store.setText(JSON.stringify({ recent: root.recent }, null, 2));
	}

	function forget(word) {
		root.recent = root.recent.filter(item => item !== word);
		store.setText(JSON.stringify({ recent: root.recent }, null, 2));
	}

	function speak() {
		const url = String(root.entry?.audio || "");
		if (url === "") return;
		speaker.running = false;
		speaker.command = ["mpv", "--no-video", "--really-quiet", "--no-terminal", url];
		speaker.running = true;
	}

	// "word – the first meaning"
	function plainText() {
		if (!root.entry) return "";
		const senses = (root.entry.senses || []).filter(sense => !sense.sub).slice(0, 3);
		const lines = senses.map(sense => senses.length > 1 ? `${sense.n}. ${sense.text}` : sense.text);
		return `${root.entry.word}\n${lines.join("\n")}`;
	}

	Timer {
		id: debounce

		interval: 550
		onTriggered: root.start()
	}

	Component {
		id: lookup

		Process {
			id: proc

			property int seq: 0

			stdout: SplitParser {
				onRead: line => root.handle(proc.seq, line)
			}
			onExited: code => {
				if (proc.seq === root._seq) {
					root._running = null;
					if (root.state === "loading") {
						root.state = "error";
						root.error = code === 0 ? "No answer" : "The lookup stopped";
					}
				}
				proc.destroy();
			}
		}
	}

	Process {
		id: speaker
	}

	FileView {
		id: store

		path: Paths.stateFile("dictionary.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const recent = (JSON.parse(String(text() || "{}")) || {}).recent;
				root.recent = Array.isArray(recent) ? recent.map(String) : [];
			} catch (error) {}
		}
	}
}
