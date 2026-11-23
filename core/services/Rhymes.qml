pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Writing lyrics (plugin "rhymes"): a window of its own (core/views/rhymes/)
// with rhymes for the words in front of the cursor, the syllables and the
// rhyme scheme beside each line, rhyming words in colour, a library of songs
// in ~/Music/Lyrics, a beat to write to with each line's start in it, takes
// recorded over it and the songs as a playlist of the music player.
// The helper (scripts/rhymes/rhymes.py) holds the dictionary in memory, so a
// rhyme is there a few milliseconds after a key; it ends ten minutes after
// the window closed.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("rhymes")
	readonly property string helperScript: `${Paths.scripts}/rhymes/rhymes.py`

	// ── the window ─────────────────────────────────────────────────────────
	property bool windowOpen: false
	property bool watching: false
	// the window has the keyboard
	property bool focused: false
	// someone else wants rhymes (the launcher's >rhyme)
	property int askers: 0
	readonly property bool quiet: root.focused && root.setting("quiet", true)
	onQuietChanged: Notifs.writingQuiet = root.quiet

	signal said(string text, string icon)
	signal jump(int row, int column)
	signal flash(int row)

	function open() {
		if (!root.enabled) return;
		root.windowOpen = true;
		root.wake();
		focusTimer.restart();
		if (!root.song) {
			const last = root.setting("last", "");
			if (last !== "") root.load(last);
		}
	}

	function close() {
		root.windowOpen = false;
		root.saveNow();
		if (root.beatPlaying) root.stop();
	}

	function toggle() {
		if (root.windowOpen) root.close();
		else root.open();
	}

	function niriWindow() {
		return Niri.windows.find(window => /( – Rhymes|^Rhymes)$/.test(String(window.title)) && /quickshell/i.test(String(window.app_id))) ?? null;
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = root.niriWindow();
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	function say(text, icon) {
		if (root.windowOpen && root.watching) root.said(text, icon || "information_outline");
		else Notifs.pushInternal("done", text, "", { app: "Rhymes", icon: icon || "music_note" });
	}

	// ── settings ───────────────────────────────────────────────────────────
	property var settings: ({ sidebar: true, panel: "rhymes", last: "", quiet: true, latency: 30, countIn: true, stress: true, colours: true, artist: "", window: 4, nas: false })

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n");
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("rhymes.json")
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
		}
	}

	// ── the helper ─────────────────────────────────────────────────────────
	property bool ready: false
	// the dictionary could not be fetched (no network the first time)
	property bool missing: false
	property string libraryRoot: ""
	property int counter: 0
	property var callbacks: ({})
	property var queued: []
	// the last request of a kind that only wants the newest answer
	property var newest: ({})

	function wake() {
		if (!root.enabled) return;
		idleTimer.restart();
		if (!helper.running) helper.running = true;
	}

	function request(op, args, done) {
		if (!root.enabled) return 0;
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const line = JSON.stringify(Object.assign({ req: id, op: op }, args || {})) + "\n";
		if (!helper.running) {
			root.queued.push(line);
			helper.running = true;
		} else helper.write(line);
		idleTimer.restart();
		return id;
	}

	// only the answer to the last one counts (rhymes, the analysis)
	function latest(op, args, done) {
		const id = root.request(op, args, data => {
			if (root.newest[op] === id) done(data);
		});
		root.newest[op] = id;
	}

	function receive(line) {
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.req !== undefined) {
			const done = root.callbacks[message.req];
			delete root.callbacks[message.req];
			if (message.stale) return;
			if (message.error) {
				if (!["around", "analyze", "synonyms"].includes(message.op)) root.say(message.error, "alert_circle_outline");
				return;
			}
			if (done) done(message.data);
			return;
		}
		switch (message.type) {
		case "ready":
			root.ready = message.ok === true;
			root.missing = message.missing === true;
			root.libraryRoot = message.root || "";
			if (root.ready) {
				root.analyze();
				root.askAround();
			}
			break;
		case "beat":
			root.takeBeat(message);
			break;
		case "job":
			root.takeJob(message);
			break;
		case "monitor":
			root.monitorOn = message.on === true;
			break;
		case "recording":
			root.recording = message.on === true;
			if (!message.on && message.take && root.song && message.id === root.song.id) {
				root.song = Object.assign({}, root.song, { takes: (root.song.takes || []).concat([message.take]) });
				if (message.studio) root.studio = message.studio;
				root.requestWave(message.take.file);
				root.withTakes = true;
				root.say(`${message.take.name} kept`, "microphone");
			}
			break;
		}
	}

	Process {
		id: helper

		stdinEnabled: true
		command: ["python3", "-u", root.helperScript]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(`rhymes: ${line}`)
		}
		onRunningChanged: {
			if (helper.running) {
				for (const line of root.queued) helper.write(line);
				root.queued = [];
				return;
			}
			root.ready = false;
			root.beatPlaying = false;
			root.recording = false;
			root.loadedBeat = "";
			root.callbacks = ({});
		}
	}

	// the dictionary again (it could not be fetched before)
	function retry() {
		if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		root.missing = false;
		retryTimer.restart();
	}

	Timer {
		id: retryTimer

		interval: 600
		onTriggered: {
			if (helper.running) return retryTimer.restart();
			root.wake();
		}
	}

	// the helper goes when nobody has needed it for ten minutes
	Timer {
		id: idleTimer

		interval: 600000
		onTriggered: {
			if (root.windowOpen || root.askers > 0 || root.recording) idleTimer.restart();
			else if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
	}

	// ── the library ────────────────────────────────────────────────────────
	property var songs: []
	property var ideas: []
	property var found: null
	property string query: ""

	function refresh() {
		root.request("songs", {}, data => {
			root.songs = data.songs || [];
			root.libraryRoot = data.root || root.libraryRoot;
		});
		root.request("ideas", {}, data => root.ideas = data.ideas || []);
	}

	function search(text) {
		root.query = text;
		if (text.trim() === "") {
			root.found = null;
			return;
		}
		root.latest("search", { query: text }, data => root.found = data);
	}

	function create(title) {
		root.saveNow();
		root.request("create", { title: title || "" }, data => {
			root.take(data);
			root.refresh();
			root.jump(0, 0);
		});
	}

	function load(id, row) {
		if (root.song && root.song.id === id) {
			if (row !== undefined && row >= 0) root.jump(row, 0);
			return;
		}
		root.saveNow();
		root.request("load", { id: id }, data => {
			root.take(data);
			if (row !== undefined && row >= 0) Qt.callLater(() => {
				root.jump(row, 0);
				root.flash(row);
			});
		});
	}

	function rename(title) {
		if (!root.song) return;
		root.song = Object.assign({}, root.song, { title: title });
		root.changed();
	}

	function setArtist(name) {
		if (!root.song) return;
		root.song = Object.assign({}, root.song, { artist: name });
		if (name !== "") root.setSetting("artist", name);
		root.changed();
	}

	function remove(id) {
		root.request("delete", { id: id }, () => {
			if (root.song && root.song.id === id) {
				root.song = null;
				lines.clear();
				root.setSetting("last", "");
			}
			root.refresh();
			root.say("Moved to the trash", "delete");
		});
	}

	function duplicate(id) {
		root.saveNow();
		root.request("duplicate", { id: id }, data => {
			root.take(data);
			root.refresh();
		});
	}

	function addIdea(text, source) {
		if (String(text).trim() === "") return;
		root.request("addIdea", { text: text, source: source || "pc" }, () => root.refresh());
	}

	function dropIdea(id) {
		root.ideas = root.ideas.filter(idea => idea.id !== id);
		root.request("dropIdea", { id: id });
	}

	// ── the song being written ─────────────────────────────────────────────
	property var song: null
	readonly property string windowTitle: root.song ? `${root.song.title || "Untitled"} – Rhymes` : "Rhymes"
	property bool dirty: false
	property int savedAt: 0
	// the lines, each with when it starts in the beat (-1 not yet) and a key of its own
	property ListModel lines: ListModel {}
	property int uid: 0
	// what the helper found in the words: { lines: [{ syl, stress, scheme, words: [{ s, e, n, g, m, r }] }], sections, groups }
	property var analysis: ({ lines: [], sections: [], groups: 0 })
	// where the cursor is: the row and the column
	property int row: 0
	property int column: 0

	function take(data) {
		lines.clear();
		const text = String(data.text || "").split("\n");
		const times = data.times || [];
		for (let i = 0; i < text.length; i += 1) {
			const t = times[i];
			// a heading that only repeats a hook: { ref: [a time for each of the hook's lines] }
			const refs = t && typeof t === "object" && Array.isArray(t.ref) ? t.ref.map(x => x === null || x === undefined ? "" : String(x)).join(",") : "";
			const first = Array.isArray(t) ? t[0] : (typeof t === "number" ? t : null);
			lines.append({ text: text[i], t: first === null || first === undefined ? -1 : Number(first), refs: refs, key: root.uid++ });
		}
		const meta = Object.assign({}, data);
		delete meta.text;
		delete meta.times;
		root.song = meta;
		root.dirty = false;
		root.undoStack = [];
		root.redoStack = [];
		root.lastText = root.textNow();
		root.setSetting("last", data.id);
		root.analysis = ({ lines: [], sections: [], groups: 0 });
		root.cue = Number(meta.cue || 0);
		root.loopA = meta.loop ? Number(meta.loop[0]) : -1;
		root.loopB = meta.loop ? Number(meta.loop[1]) : -1;
		root.wave = [];
		root.loadedBeat = "";
		root.beatPlaying = false;
		if (root.beatPath !== "") root.request("wave", { path: root.beatPath });
		// the key of beats from before the key finder
		if (root.beatPath !== "" && !meta.key) root.findKey();
		root.studio = { tracks: [], clips: [], duration: 0, kinds: root.studio.kinds || {}, available: root.studio.available || {} };
		root.loadStudio();
		root.analyze();
		root.versions = [];
		root.preview = null;
		if (root.setting("panel", "rhymes") === "versions") root.loadVersions();
	}

	function textNow() {
		const out = [];
		for (let i = 0; i < lines.count; i += 1) out.push(lines.get(i).text);
		return out.join("\n");
	}

	function timesNow() {
		const out = [];
		for (let i = 0; i < lines.count; i += 1) {
			const line = lines.get(i);
			const refs = root.refTimes(i);
			if (refs.some(x => x >= 0)) out.push({ ref: refs.map(x => x >= 0 ? x : null) });
			else out.push(line.t >= 0 ? line.t : null);
		}
		return out;
	}

	// ── a hook that comes back: its lines timed again under the heading that repeats it ──
	// the times there, one for each line of the hook (-1: none yet)
	function refTimes(rowIndex) {
		const refs = String(lines.get(rowIndex)?.refs || "");
		return refs === "" ? [] : refs.split(",").map(x => x === "" ? -1 : Number(x));
	}

	// the hook's lines a heading repeats (rows), [] when it repeats none
	function refLines(rowIndex) {
		const section = (root.analysis.sections || []).find(s => s.line === rowIndex);
		const from = section?.ref ?? -1;
		const out = [];
		if (from < 0) return out;
		for (let i = from + 1; i < lines.count; i += 1) {
			const text = lines.get(i).text;
			if (/^\s*\[[^\]]+\]\s*$/.test(text)) break;
			if (text.trim() !== "") out.push(i);
		}
		return out;
	}

	function stampRef(rowIndex, index, at) {
		if (rowIndex < 0 || rowIndex >= lines.count) return;
		root.remember();
		const refs = root.refTimes(rowIndex);
		while (refs.length <= index) refs.push(-1);
		refs[index] = at === null ? -1 : Math.round((at !== undefined ? at : root.positionNow()) * 100) / 100;
		lines.setProperty(rowIndex, "refs", refs.some(x => x >= 0) ? refs.map(x => x >= 0 ? String(x) : "").join(",") : "");
		root.changed();
	}

	function unstampRef(rowIndex, index) {
		root.stampRef(rowIndex, index, null);
	}

	// every start: [{ t, row, shows, ref }] by time; a repeated hook's line is played
	// under its heading (row) and shows the hook's line (shows)
	function marks() {
		const out = [];
		for (let i = 0; i < lines.count; i += 1) {
			const line = lines.get(i);
			if (line.t >= 0) out.push({ t: line.t, row: i, shows: i, ref: -1 });
			const refs = root.refTimes(i);
			if (refs.length === 0) continue;
			const hook = root.refLines(i);
			refs.forEach((t, n) => {
				if (t >= 0 && n < hook.length) out.push({ t: t, row: i, shows: hook[n], ref: n });
			});
		}
		return out.sort((a, b) => a.t - b.t);
	}

	// something about the song changed: saved a moment later, analysed sooner
	function changed() {
		if (!root.song) return;
		root.dirty = true;
		saveTimer.restart();
		analyzeTimer.restart();
	}

	function saveNow() {
		if (!root.song || !root.dirty) return;
		saveTimer.stop();
		root.dirty = false;
		const id = root.song.id;
		root.request("save", {
			id: id,
			text: root.textNow(),
			meta: { title: root.song.title || "Untitled", artist: root.song.artist || "", times: root.timesNow(), bpm: root.song.bpm || 0, offset: root.song.offset || 0, bar: root.song.bar || 4, cue: root.cue, loop: root.looping ? [root.loopA, root.loopB] : null, done: !!root.song.done }
		}, () => {
			root.savedAt = Date.now();
			const at = root.songs.findIndex(s => s.id === id);
			if (at >= 0) {
				const list = root.songs.slice();
				const first = root.textNow().split("\n").find(l => l.trim() !== "" && !/^\s*\[.*\]\s*$/.test(l)) || "";
				list[at] = Object.assign({}, list[at], { title: root.song?.id === id ? root.song.title : list[at].title, modified: Date.now() / 1000, first: first.trim(), lines: root.textNow().split("\n").filter(l => l.trim() !== "" && !/^\s*\[.*\]\s*$/.test(l)).length });
				list.sort((a, b) => b.modified - a.modified);
				root.songs = list;
			}
		});
	}

	Timer {
		id: saveTimer

		interval: 900
		onTriggered: root.saveNow()
	}

	function analyze() {
		if (!root.ready || !root.song) return;
		root.latest("analyze", { text: root.textNow(), window: root.setting("window", 4) }, data => root.analysis = data);
	}

	Timer {
		id: analyzeTimer

		interval: 70
		onTriggered: root.analyze()
	}

	// ── editing, kept undoable ─────────────────────────────────────────────
	property var undoStack: []
	property var redoStack: []
	property string lastText: ""

	function snapshot() {
		const rows = [];
		for (let i = 0; i < lines.count; i += 1) rows.push({ text: lines.get(i).text, t: lines.get(i).t, refs: lines.get(i).refs || "" });
		return { rows: rows, row: root.row, column: root.column };
	}

	// before a change that is not typing (a line split, joined, moved), and every pause in typing
	function remember() {
		const top = root.undoStack[root.undoStack.length - 1];
		if (top && root.same(top, root.snapshot())) return;
		const stack = root.undoStack.concat([root.snapshot()]);
		root.undoStack = stack.length > 300 ? stack.slice(stack.length - 300) : stack;
		root.redoStack = [];
	}

	function same(a, b) {
		return JSON.stringify(a.rows) === JSON.stringify(b.rows);
	}

	function restore(state) {
		lines.clear();
		for (const r of state.rows) lines.append({ text: r.text, t: r.t, refs: r.refs || "", key: root.uid++ });
		root.changed();
		root.jump(state.row, state.column);
	}

	function undo() {
		if (root.undoStack.length === 0) return;
		const now = root.snapshot();
		let state = root.undoStack[root.undoStack.length - 1];
		root.undoStack = root.undoStack.slice(0, -1);
		// the newest snapshot is what is there already: one further back
		if (root.same(state, now) && root.undoStack.length > 0) {
			state = root.undoStack[root.undoStack.length - 1];
			root.undoStack = root.undoStack.slice(0, -1);
		}
		root.redoStack = root.redoStack.concat([now]);
		root.restore(state);
	}

	function redo() {
		if (root.redoStack.length === 0) return;
		const state = root.redoStack[root.redoStack.length - 1];
		root.redoStack = root.redoStack.slice(0, -1);
		root.undoStack = root.undoStack.concat([root.snapshot()]);
		root.restore(state);
	}

	Timer {
		id: typingPause

		interval: 700
		onTriggered: root.remember()
	}

	function typed(rowIndex, text) {
		if (rowIndex < 0 || rowIndex >= lines.count || lines.get(rowIndex).text === text) return;
		if (!typingPause.running) root.remember();
		typingPause.restart();
		lines.setProperty(rowIndex, "text", text);
		root.changed();
	}

	// Enter: the line is cut at the cursor; the new line keeps no time
	function split(rowIndex, at) {
		root.remember();
		const text = lines.get(rowIndex).text;
		lines.setProperty(rowIndex, "text", text.slice(0, at));
		lines.insert(rowIndex + 1, { text: text.slice(at), t: at === 0 ? lines.get(rowIndex).t : -1, refs: at === 0 ? (lines.get(rowIndex).refs || "") : "", key: root.uid++ });
		if (at === 0) {
			lines.setProperty(rowIndex, "t", -1);
			lines.setProperty(rowIndex, "refs", "");
		}
		root.changed();
		root.jump(rowIndex + 1, 0);
	}

	// Backspace at the start: into the line above
	function joinUp(rowIndex) {
		if (rowIndex <= 0) return;
		root.remember();
		const above = lines.get(rowIndex - 1).text;
		const text = lines.get(rowIndex).text;
		lines.setProperty(rowIndex - 1, "text", above + text);
		if (lines.get(rowIndex - 1).t < 0) lines.setProperty(rowIndex - 1, "t", lines.get(rowIndex).t);
		lines.remove(rowIndex);
		root.changed();
		root.jump(rowIndex - 1, above.length);
	}

	function moveLine(rowIndex, by) {
		const to = rowIndex + by;
		if (to < 0 || to >= lines.count) return;
		root.remember();
		lines.move(rowIndex, to, 1);
		root.changed();
		root.jump(to, root.column);
	}

	function duplicateLine(rowIndex) {
		root.remember();
		const line = lines.get(rowIndex);
		lines.insert(rowIndex + 1, { text: line.text, t: -1, refs: "", key: root.uid++ });
		root.changed();
		root.jump(rowIndex + 1, root.column);
	}

	function removeLines(from, to) {
		root.remember();
		const a = Math.max(0, Math.min(from, to));
		const b = Math.min(lines.count - 1, Math.max(from, to));
		lines.remove(a, b - a + 1);
		if (lines.count === 0) lines.append({ text: "", t: -1, refs: "", key: root.uid++ });
		root.changed();
		root.jump(Math.min(a, lines.count - 1), 0);
	}

	// text with line breaks goes in as lines of its own
	function insertText(rowIndex, at, text) {
		const parts = String(text).replace(/\r/g, "").split("\n");
		root.remember();
		const current = lines.get(rowIndex).text;
		const before = current.slice(0, at);
		const after = current.slice(at);
		if (parts.length === 1) {
			lines.setProperty(rowIndex, "text", before + parts[0] + after);
			root.changed();
			root.jump(rowIndex, at + parts[0].length);
			return;
		}
		lines.setProperty(rowIndex, "text", before + parts[0]);
		for (let i = 1; i < parts.length; i += 1)
			lines.insert(rowIndex + i, { text: parts[i] + (i === parts.length - 1 ? after : ""), t: -1, refs: "", key: root.uid++ });
		root.changed();
		root.jump(rowIndex + parts.length - 1, parts[parts.length - 1].length);
	}

	function linesText(from, to) {
		const out = [];
		for (let i = Math.max(0, Math.min(from, to)); i <= Math.min(lines.count - 1, Math.max(from, to)); i += 1) out.push(lines.get(i).text);
		return out.join("\n");
	}

	// ── rhymes for what is in front of the cursor ──────────────────────────
	// { words, splits: [[{ from, to, text }]], spans: [{ from, to, syllables, groups: [{ kind, items }] }] }
	property var around: null
	property string aroundKey: ""

	function cursorAt(rowIndex, column) {
		if (rowIndex < 0) return;
		root.row = rowIndex;
		root.column = column;
		aroundTimer.restart();
	}

	function wordsBefore(rowIndex, column) {
		let words = [];
		const pattern = /[A-Za-z0-9]+(?:['’][A-Za-z]+)*['’]?/g;
		// the line up to the cursor; too few words there, the end of the line above helps out
		for (let r = rowIndex; r >= 0 && words.length < 3 && rowIndex - r < 2; r -= 1) {
			const text = r === rowIndex ? String(lines.get(r)?.text ?? "").slice(0, column) : String(lines.get(r)?.text ?? "");
			if (/^\s*\[.*\]\s*$/.test(text)) break;
			const found = text.match(pattern) || [];
			words = found.concat(words);
			if (r === rowIndex && found.length > 0) break;
		}
		return words.slice(-3);
	}

	function askAround() {
		if (!root.ready || !root.song || lines.count === 0) return;
		const words = root.wordsBefore(root.row, root.column);
		const key = words.join(" ").toLowerCase();
		if (key === root.aroundKey) return;
		root.aroundKey = key;
		if (words.length === 0) {
			root.around = null;
			return;
		}
		root.latest("around", { words: words }, data => root.around = data);
	}

	// rhymes for any words (the launcher)
	function rhymesFor(words, done) {
		root.askers += 1;
		root.wake();
		root.latest("around", { words: words }, data => {
			root.askers = Math.max(0, root.askers - 1);
			done(data);
		});
	}

	Timer {
		id: aroundTimer

		interval: 45
		onTriggered: root.askAround()
	}

	// words of the same meaning for the word at the cursor, those that rhyme with the line above first
	property var synonyms: null

	function askSynonyms(word, rhymeWith) {
		if (!word) return;
		root.latest("synonyms", { word: word, rhymeWith: rhymeWith || "" }, data => root.synonyms = data);
	}

	// ── versions ───────────────────────────────────────────────────────────
	property var versions: []
	property var preview: null

	function loadVersions() {
		if (!root.song) return;
		root.request("versions", { id: root.song.id }, data => root.versions = data.versions || []);
	}

	function keepVersion() {
		if (!root.song) return;
		root.saveNow();
		root.request("keepVersion", { id: root.song.id, text: root.textNow(), why: "kept" }, () => {
			root.loadVersions();
			root.say("Version kept", "history");
		});
	}

	function showVersion(name) {
		if (!root.song) return;
		root.request("version", { id: root.song.id, name: name, current: root.textNow() }, data => root.preview = data);
	}

	function restoreVersion(name) {
		if (!root.song || !root.preview || root.preview.name !== name) return;
		const text = root.preview.text;
		root.request("keepVersion", { id: root.song.id, text: root.textNow(), why: "before" }, () => root.loadVersions());
		root.remember();
		lines.clear();
		for (const line of String(text).split("\n")) lines.append({ text: line, t: -1, refs: "", key: root.uid++ });
		root.preview = null;
		root.changed();
		root.say("Version back", "restore");
	}

	function dropVersion(name) {
		if (!root.song) return;
		root.request("dropVersion", { id: root.song.id, name: name }, () => root.loadVersions());
		if (root.preview?.name === name) root.preview = null;
	}

	// ── the beat ───────────────────────────────────────────────────────────
	readonly property string beatPath: root.song?.beatPath ?? ""
	readonly property bool hasBeat: root.beatPath !== ""
	property string loadedBeat: ""
	property bool beatPlaying: false
	property real beatDuration: 0
	property real basePosition: 0
	property real baseAt: 0
	property real position: 0
	property real speed: 1
	// where Stop goes back to: the chosen spot
	property real cue: 0
	property real loopA: -1
	property real loopB: -1
	readonly property bool looping: root.loopA >= 0 && root.loopB > root.loopA
	property var wave: []
	// the line whose time has come, -1 before the first
	// (under a heading that repeats the hook, the heading is the one playing)
	readonly property int playingRow: root.playingMark?.row ?? -1
	readonly property var playingMark: {
		if (!root.hasBeat || root.position <= 0 && !root.beatPlaying) return null;
		let found = null;
		for (const m of root.marks())
			if (m.t <= root.position + 0.05) found = m;
			else break;
		return found;
	}
	// when the line playing ends: the next start after it
	readonly property real nextMark: {
		const at = root.playingMark?.t ?? -1;
		for (const m of root.marks())
			if (m.t > at + 0.01) return m.t;
		return root.beatDuration;
	}
	// what the beat plays with: the takes that are on
	property bool withTakes: false

	function positionNow() {
		if (!root.beatPlaying) return root.basePosition;
		let p = root.basePosition + (Date.now() - root.baseAt) / 1000 * root.speed;
		if (root.looping && p > root.loopB) p = root.loopA + (p - root.loopA) % (root.loopB - root.loopA);
		return Math.min(root.beatDuration || 1e9, p);
	}

	Timer {
		running: root.beatPlaying
		repeat: true
		interval: root.watching ? 33 : 500
		triggeredOnStart: true
		onTriggered: root.position = root.positionNow()
	}

	function takeBeat(message) {
		root.beatPlaying = message.playing === true;
		root.basePosition = Number(message.position) || 0;
		root.baseAt = Date.now();
		root.beatDuration = Number(message.duration) || root.beatDuration;
		root.speed = Number(message.speed) || 1;
		root.position = root.positionNow();
	}

	// the click on every beat, played along (never mixed down)
	readonly property bool metronome: root.setting("metronome", false) && (root.song?.bpm ?? 0) > 0

	function findKey() {
		if (root.song && root.hasBeat) root.request("key", { id: root.song.id });
	}

	function tempoNow() {
		return root.metronome ? { bpm: root.song.bpm, offset: root.song.offset || 0, bar: root.song.bar || 4 } : null;
	}

	function toggleMetronome() {
		if ((root.song?.bpm ?? 0) <= 0) return root.say("The song has no tempo yet", "metronome");
		root.setSetting("metronome", !root.setting("metronome", false));
		root.loadedBeat = "";
		if (root.beatPlaying) root.ensureBeat(() => {});
	}

	function ensureBeat(done) {
		if (!root.hasBeat) return;
		const want = `${root.beatPath}|${root.withTakes}|${root.metronome ? root.song.bpm + "/" + root.song.offset + "/" + root.song.bar : ""}`;
		if (root.loadedBeat === want) return done();
		root.request("beatLoad", { path: root.beatPath, id: root.song.id, withTakes: root.withTakes, metronome: root.tempoNow() }, () => {
			root.loadedBeat = want;
			if (root.looping) root.request("beatLoop", { a: root.loopA, b: root.loopB });
			done();
		});
	}

	// from a line's start, the chosen spot, or where it is
	function play(at) {
		if (!root.hasBeat) return;
		const from = at !== undefined && at >= 0 ? at : root.cue;
		root.cue = from;
		root.ensureBeat(() => root.request("beatPlay", { at: from }));
		root.beatPlaying = true;
		root.basePosition = from;
		root.baseAt = Date.now();
	}

	// stopped, back at the chosen spot
	function stop() {
		root.beatPlaying = false;
		root.basePosition = root.cue;
		root.position = root.cue;
		root.request("beatStop", { to: root.cue });
	}

	function playPause() {
		if (root.beatPlaying) root.stop();
		else root.play(root.cue);
	}

	function playFromRow(rowIndex) {
		const t = rowIndex >= 0 && rowIndex < lines.count ? lines.get(rowIndex).t : -1;
		if (t >= 0) root.play(Math.max(0, t - 0.15));
		else root.play(root.cue);
	}

	function seek(to) {
		root.cue = Math.max(0, to);
		root.basePosition = root.cue;
		root.baseAt = Date.now();
		root.position = root.cue;
		root.ensureBeat(() => root.request("beatSeek", { to: root.cue }));
		root.changed();
	}

	// the line starts now (or at a given time); the next line is next
	function stamp(rowIndex, at) {
		if (rowIndex < 0 || rowIndex >= lines.count) return;
		root.remember();
		lines.setProperty(rowIndex, "t", Math.round((at !== undefined ? at : root.positionNow()) * 100) / 100);
		root.changed();
	}

	function unstamp(rowIndex) {
		if (rowIndex < 0 || rowIndex >= lines.count) return;
		root.remember();
		lines.setProperty(rowIndex, "t", -1);
		root.changed();
	}

	function setLoop(a, b) {
		root.loopA = a;
		root.loopB = b;
		if (root.loadedBeat !== "") root.request("beatLoop", { a: root.looping ? a : null, b: root.looping ? b : null });
		root.changed();
	}

	// the section the cursor is in, from its first timed line to the next section's
	function loopSection(rowIndex) {
		if (root.looping) return root.setLoop(-1, -1);
		const sections = root.analysis.sections || [];
		let start = 0;
		let end = lines.count;
		for (const s of sections) {
			if (s.line <= rowIndex) start = s.line;
			else {
				end = s.line;
				break;
			}
		}
		let a = -1;
		let b = -1;
		for (let i = start; i < end; i += 1) {
			const t = lines.get(i).t;
			if (t >= 0 && (a < 0 || t < a)) a = t;
		}
		for (let i = end; i < lines.count; i += 1) {
			const t = lines.get(i).t;
			if (t >= 0) {
				b = t;
				break;
			}
		}
		if (a < 0) return root.say("No line of it has a time", "timer_outline");
		if (b < 0) b = root.beatDuration;
		root.setLoop(a, b);
		root.play(a);
	}

	function setSpeed(value) {
		root.speed = value;
		root.request("beatSpeed", { speed: value });
	}

	function pickBeat() {
		if (!root.song) return;
		Files.pick({ title: "A beat for the song", folder: Paths.home + "/Music", filters: ["*.mp3", "*.flac", "*.wav", "*.ogg", "*.opus", "*.m4a", "*.aac", "*.aiff", "*.webm"] }, paths => {
			if (paths.length > 0) root.setBeat(paths[0]);
		});
	}

	function setBeat(path) {
		if (!root.song) return;
		if (root.beatPlaying) root.stop();
		const id = root.song.id;
		root.request("setBeat", { id: id, path: String(path).replace(/^file:\/\//, "") }, data => {
			if (!root.song || root.song.id !== id) return;
			root.song = Object.assign({}, root.song, { beat: data.beat, beatPath: data.beatPath, beatName: data.beatName, bpm: 0, offset: 0 });
			root.loadedBeat = "";
			root.wave = [];
			root.cue = 0;
			root.request("wave", { path: data.beatPath });
			root.request("tempo", { id: id });
			root.findKey();
			root.loadStudio();
			root.refresh();
		});
	}

	function dropBeat() {
		if (!root.song) return;
		if (root.beatPlaying) root.stop();
		root.request("dropBeat", { id: root.song.id }, () => {
			root.song = Object.assign({}, root.song, { beat: "", beatPath: "", beatName: "", bpm: 0, offset: 0 });
			root.loadedBeat = "";
			root.wave = [];
		});
	}

	function setTempo(bpm, offset) {
		if (!root.song) return;
		root.song = Object.assign({}, root.song, { bpm: bpm, offset: offset !== undefined ? offset : root.song.offset });
		root.changed();
		if (root.metronome) root.remix();
	}

	// taps of a key: the tempo from the last few
	property var taps: []

	function tap() {
		const now = Date.now();
		let list = root.taps.filter(t => now - t < 2500).concat([now]);
		root.taps = list.slice(-8);
		if (root.taps.length >= 3) {
			const gaps = [];
			for (let i = 1; i < root.taps.length; i += 1) gaps.push(root.taps[i] - root.taps[i - 1]);
			const mean = gaps.reduce((a, b) => a + b, 0) / gaps.length;
			root.setTempo(Math.round(60000 / mean * 2) / 2);
		}
	}

	// ── jobs and takes ─────────────────────────────────────────────────────
	// kind → { state, progress, text }
	property var jobs: ({})
	property bool recording: false
	property var whisper: ({ installed: false, installing: false })

	function takeJob(message) {
		const next = Object.assign({}, root.jobs);
		next[message.kind] = { state: message.state, progress: message.progress ?? 0, text: message.text || message.error || "" };
		root.jobs = next;
		if (message.state === "failed") root.say(message.error || "It did not work", "alert_circle_outline");
		if (message.state !== "done") return;
		const result = message.result || {};
		switch (message.kind) {
		case "wave":
			if (result.path === root.beatPath) root.wave = result.wave || [];
			else {
				const next = Object.assign({}, root.waves);
				next[result.path] = result.wave || [];
				root.waves = next;
			}
			break;
		case "stems":
			root.say("Tracks exported", "check");
			Qt.openUrlExternally("file://" + result.folder);
			break;
		case "tempo":
			if (root.song && result.id === root.song.id) root.song = Object.assign({}, root.song, { bpm: result.bpm, offset: result.offset });
			break;
		case "key":
			if (root.song && result.id === root.song.id) root.song = Object.assign({}, root.song, { key: result });
			break;
		case "bounce":
			if (root.song && result.id === root.song.id) root.song = Object.assign({}, root.song, { bounce: String(result.path).split("/").pop() });
			root.say("Mixed down", "check");
			break;
		case "install":
			root.whisper = { installed: true, installing: false };
			root.say("Speech recognition is ready", "check");
			break;
		case "align":
			root.applyTimes(result.times || []);
			break;
		}
	}

	function jobRunning(kind) {
		return root.jobs[kind]?.state === "running";
	}

	// where a take starts: in the studio the spot chosen on the tracks, else the cursor's line (or that spot)
	readonly property real recordFrom: {
		if (root.setting("view", "write") === "studio") return root.cue;
		void root.row;
		const t = lines.get(root.row)?.t ?? -1;
		return t >= 0 ? t : root.cue;
	}

	function record() {
		if (!root.song || !root.hasBeat) return;
		if (root.recording) {
			root.request("recordStop", {});
			root.recording = false;
			root.beatPlaying = false;
			root.loadedBeat = "";
			return;
		}
		const at = root.recordFrom;
		const bar = root.song.bpm > 0 ? 60 / root.song.bpm * (root.song.bar || 4) : 2;
		root.loadedBeat = "";
		root.request("recordStart", { id: root.song.id, at: at, countIn: root.setting("countIn", true) ? bar : 0, line: root.row, latency: root.setting("latency", 30) / 1000, track: root.armed, withTakes: root.withTakes, metronome: root.tempoNow() });
		root.recording = true;
	}

	function editTake(clip, changes) {
		if (!root.song) return;
		root.clips = root.clips.map(c => c.clip === clip ? Object.assign({}, c, changes) : c);
		root.request("takeEdit", { id: root.song.id, clip: clip, changes: changes }, data => {
			root.song = Object.assign({}, root.song, { takes: data.takes });
			if (data.studio) root.studio = data.studio;
			root.remix();
		});
	}

	function dropTake(clip) {
		if (!root.song) return;
		root.request("takeDrop", { id: root.song.id, clip: clip }, data => {
			root.song = Object.assign({}, root.song, { takes: data.takes });
			if (data.studio) root.studio = data.studio;
			root.remix();
		});
	}

	// ── the studio: tracks, clips, the mix, effects ────────────────────────
	property var studio: ({ tracks: [], clips: [], duration: 0, kinds: {}, available: {} })
	// the clips as shown, ahead of the helper while something is dragged
	property var clips: []
	onStudioChanged: root.clips = root.studio.clips || []
	readonly property var tracks: root.studio.tracks || []
	// the track recordings go into
	property string armedTrack: ""
	readonly property string armed: root.tracks.some(t => t.id === root.armedTrack && t.kind === "audio") ? root.armedTrack : (root.tracks.find(t => t.kind === "audio")?.id ?? "")
	property var waves: ({})
	property var presets: []
	property bool monitorOn: false

	function loadStudio() {
		if (!root.song) return;
		const id = root.song.id;
		root.request("studio", { id: id }, data => {
			if (!root.song || root.song.id !== id) return;
			root.studio = data;
			root.monitorOn = data.monitor?.on === true;
			for (const clip of data.clips || []) root.requestWave(clip.file);
		});
		root.request("fxPresets", {}, data => root.presets = data.presets || []);
	}

	function takePath(file) {
		return root.song ? `${root.song.folder}/takes/${String(file).split("/").pop()}` : "";
	}

	function requestWave(file) {
		const path = root.takePath(file);
		if (path && root.waves[path] === undefined) {
			const next = Object.assign({}, root.waves);
			next[path] = [];
			root.waves = next;
			root.request("wave", { path: path });
		}
	}

	// after a change of the mix: what plays follows (the helper keeps where it was)
	function remix() {
		root.loadedBeat = "";
		remixTimer.restart();
	}

	Timer {
		id: remixTimer

		interval: 120
		onTriggered: if (root.beatPlaying) root.ensureBeat(() => {})
	}

	function studioCall(op, args) {
		if (!root.song) return;
		const id = root.song.id;
		root.request(op, Object.assign({ id: id }, args), data => {
			if (!root.song || root.song.id !== id || !data?.tracks) return;
			root.studio = data;
			root.remix();
		});
	}

	function addTrack(name) {
		root.studioCall("trackAdd", { name: name || "" });
	}

	function editTrack(track, changes) {
		root.studio = Object.assign({}, root.studio, { tracks: root.tracks.map(t => t.id === track ? Object.assign({}, t, changes) : t) });
		root.studioCall("trackEdit", { track: track, changes: changes });
	}

	function moveTrack(track, to) {
		root.studioCall("trackMove", { track: track, to: to });
	}

	function dropTrack(track) {
		root.studioCall("trackDrop", { track: track });
	}

	function splitClip(clip, at) {
		root.studioCall("clipSplit", { clip: clip, at: at });
	}

	// the clips under the playhead cut there
	function splitAtPlayhead() {
		const at = root.position;
		for (const c of root.clips)
			if (c.start < at && at < c.start + c.length && (c.track === root.armed || root.clips.filter(o => o.start < at && at < o.start + o.length).length === 1))
				root.splitClip(c.clip, at);
	}

	function setChain(track, chain) {
		root.editTrack(track, { fx: chain });
		if (root.monitorOn && track === root.armed) root.setMonitor(true);
	}

	function importChain(track) {
		Files.pick({ title: "An FL Studio mixer state", folder: Paths.home + "/Downloads", filters: ["*.fst"] }, paths => {
			if (paths.length === 0) return;
			root.request("fxImport", { path: String(paths[0]).replace(/^file:\/\//, "") }, data => {
				const t = root.tracks.find(t => t.id === track);
				root.setChain(track, (t?.fx || []).concat(data.chain || []));
				const missed = (data.found || []).filter(f => !f.becomes && f.plugin !== "Wave Candy").map(f => f.plugin);
				root.say(missed.length ? `${data.name}: without ${missed.join(", ")}` : data.name, "tune_vertical");
			});
		});
	}

	function savePreset(name, chain) {
		root.request("fxSavePreset", { name: name, chain: chain }, data => root.presets = data.presets || []);
	}

	function dropPreset(name) {
		root.request("fxDropPreset", { name: name }, data => root.presets = data.presets || []);
	}

	function setMonitor(on) {
		if (!root.song) return;
		root.request("monitor", { on: on, id: root.song.id, track: root.armed, fx: root.setting("monitorFx", true), level: root.setting("monitorLevel", 1) });
	}

	function exportTracks() {
		if (root.song) root.request("stemsExport", { id: root.song.id });
	}

	// one new effect in a track's chain, with its settings at their start
	function newEffect(kind) {
		const k = root.studio.kinds?.[kind];
		const params = {};
		for (const p of k?.params || []) params[p.key] = p.default;
		if (kind === "eq") params.bands = [{ type: "lowcut", freq: 80, gain: 0, q: 0.7 }, { type: "bell", freq: 300, gain: 0, q: 1 }, { type: "bell", freq: 3000, gain: 0, q: 1 }, { type: "highshelf", freq: 10000, gain: 0, q: 0.7 }];
		return { kind: kind, on: true, name: k?.name ?? kind, params: params };
	}

	function bounce() {
		if (root.song && root.hasBeat) {
			root.saveNow();
			root.request("bounce", { id: root.song.id });
		}
	}

	function checkWhisper() {
		root.request("whisperStatus", {}, data => root.whisper = data);
	}

	function installWhisper() {
		root.whisper = { installed: false, installing: true };
		root.request("whisperInstall", {});
	}

	// each line's start from what a take heard
	function alignTake(file) {
		if (!root.song) return;
		root.saveNow();
		root.request("align", { id: root.song.id, take: file, lines: root.textNow().split("\n") });
	}

	function applyTimes(times) {
		root.remember();
		let n = 0;
		for (let i = 0; i < Math.min(times.length, lines.count); i += 1) {
			if (times[i] !== null && times[i] !== undefined) {
				lines.setProperty(i, "t", Number(times[i]));
				n += 1;
			}
		}
		root.changed();
		root.say(n > 0 ? `${n} lines timed` : "No line was recognised", n > 0 ? "timer_outline" : "alert_circle_outline");
	}

	// ── the music player ───────────────────────────────────────────────────
	function playInMusic(songId) {
		root.saveNow();
		root.request("playlist", {}, data => {
			const list = data.songs || [];
			if (list.length === 0) return root.say("No song has music yet", "music_note");
			const names = Object.assign({}, Music.names);
			for (const s of list) names[s.path] = { title: s.title, artist: s.artist || "" };
			Music.names = names;
			const first = list.find(s => s.id === songId) ?? list[0];
			Music.open(first.path, { list: list.map(s => s.path) });
		});
	}

	// ── lines from elsewhere ───────────────────────────────────────────────
	// a note called "Lyric ideas" (written on the phone, the watch or in the
	// bar) is an inbox: its lines go into the ideas, the note is left empty
	readonly property var inbox: Notes.notes.find(note => /^\s*lyric ideas\s*$/i.test(note.title) && note.body.trim() !== "") ?? null
	onInboxChanged: if (root.inbox && root.enabled) inboxTimer.restart()

	Timer {
		id: inboxTimer

		interval: 1500
		onTriggered: {
			const note = root.inbox;
			if (!note) return;
			const lines = note.body.split("\n").map(l => l.replace(/^\s*([-*•]|\d+\.)\s+/, "").trim()).filter(l => l !== "");
			Notes.upsert(note.id, note.title, "");
			for (const line of lines) root.addIdea(line, "note");
			if (lines.length > 0) root.say(lines.length === 1 ? "An idea came in" : `${lines.length} ideas came in`, "lightbulb_outline");
		}
	}

	// ── the NAS ────────────────────────────────────────────────────────────
	// the library as a folder pair of the NAS (both ways, into /Lyrics)
	readonly property bool nasAvailable: Nas.enabled
	readonly property bool nasOn: (Array.isArray(Nas.local.sync) ? Nas.local.sync : []).some(pair => pair.id === "lyrics" && pair.enabled !== false)

	function setNas(on) {
		Nas.loadLocal(() => {
			const pairs = (Array.isArray(Nas.local.sync) ? Nas.local.sync : []).filter(pair => pair.id !== "lyrics");
			if (on) pairs.push({ id: "lyrics", local: String(root.libraryRoot || `${Paths.home}/Music/Lyrics`).replace(Paths.home, "~"), remote: "/Lyrics", mode: "twoway", mirror_deletes: false });
			Nas.setLocal("sync", pairs, (data, error) => {
				if (!error && on) Nas.syncNow("lyrics");
			});
		});
	}

	// ── what the shell asks for ────────────────────────────────────────────
	onEnabledChanged: if (!root.enabled && helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n")
	onWindowOpenChanged: {
		if (root.windowOpen) {
			root.wake();
			root.refresh();
			root.checkWhisper();
		}
	}
}
