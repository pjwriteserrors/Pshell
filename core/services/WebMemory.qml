pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// What the browser remembers of pages (docs/browser.md "Page memory"); the
// extension keeps the pages' text itself (background/memory.js), this side
// switches its parts on and keeps what the shell has of it:
//
// - `browser-memory`: the launcher's >tab also finds pages by their text
//   (WebLink.search answers `pages`).
// - `browser-reading`: where a long page was left goes to pshell-core
//   (/api/browse/reading), so another device can offer to go on there.
// - `browser-highlights`: text kept as a note from a page ("Keep as note",
//   WebMenu) is kept here and in pshell-core (/api/browse/highlights) and
//   marked on the page; deleting the note takes it away.
// - `browser-clipsource`: text copied from a page keeps its page in the
//   clipboard history (sourceOf), a click leads back to the spot.
// - `browser-review`: in the evening the Today panel shows the articles read
//   and the videos watched today: Put on shelf, or Later (a reminder for
//   tomorrow evening that opens the page).
//
// Everything is marked with the mode it happened in: `work` while a qtrack
// timer runs, else `private`; without a timer nothing of work shows.
// Kept in ~/.local/state/pshell/browser-memory.json: { highlights, clips,
// reviewed: { day, keys } }.
Singleton {
	id: root

	// WebLink reads browserConfig while it builds its config: read nothing
	// of WebLink before this singleton stands
	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	readonly property bool linked: Plugins.on("browser-link")
	readonly property bool indexOn: root.linked && Plugins.on("browser-memory")
	readonly property bool readingOn: root.linked && Plugins.on("browser-reading")
	readonly property bool highlightsOn: root.linked && Plugins.on("browser-highlights")
	readonly property bool clipsOn: root.linked && Plugins.on("browser-clipsource") && Plugins.on("clipboard")
	readonly property bool reviewOn: root.indexOn && Plugins.on("browser-review")
	readonly property bool work: root.built && Plugins.on("qtrack") && QtrackTimer.tracking
	readonly property string mode: root.work ? "work" : "private"

	// what the extension gets with the config (WebLink.config)
	readonly property var browserConfig: ({
			index: root.indexOn,
			reading: root.readingOn,
			highlights: root.highlightsOn,
			clips: root.clipsOn,
			work: root.work
		})

	// [{ id, url, title, text, note (Notes id), mode, at (ms), synced }]
	property var highlights: []
	// [{ preview (as the clipboard history shows it), url, title, fragment, mode, at (ms) }], newest first
	property var clips: []
	// { day, keys }: what the day review was done with today
	property var reviewed: ({ day: "", keys: [] })
	property bool loaded: false

	// today's pages worth a look back: [{ key, url, title, host, kind, dwell, media, progress }]
	property var today: []
	readonly property bool evening: clock.date.getHours() >= 17
	readonly property var review: {
		const day = Qt.formatDate(clock.date, "yyyy-MM-dd");
		const done = root.reviewed.day === day ? root.reviewed.keys : [];
		return root.today.filter(item => !done.includes(item.key)).slice(0, 8);
	}

	SystemClock {
		id: clock

		precision: SystemClock.Minutes
	}

	// ── pages ───────────────────────────────────────────────────────────────
	// the page an address stands for (background/memory.js pageKey)
	function keyOf(url) {
		const found = String(url || "").match(/^https?:\/\/(?:[^@\/?#]*@)?([^\/?#]+)([^?#]*)(\?[^#]*)?/i);
		if (!found) return "";
		const host = found[1].toLowerCase().replace(/^www\./, "");
		let path = found[2] || "/";
		if (path.length > 1) path = path.replace(/\/+$/, "") || "/";
		const query = String(found[3] || "").slice(1).split("&").filter(part => part !== "" && !/^(utm_[^=]*|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|yclid|_hsenc|_hsmi|ref_src|ref_url|si)(=|$)/i.test(part));
		return `${host}${path}${query.length ? "?" + query.join("&") : ""}`;
	}

	function shows(item) {
		return root.work || !item || item.mode !== "work";
	}

	// ── what the extension asks ─────────────────────────────────────────────
	// "memory:page" { url, key } → { reading: from pshell-core | null, highlights }
	function ask(what, args, reply) {
		if (what !== "memory:page") return reply(false, `nothing answers ${what}`);
		const url = String(args?.url || "");
		const key = root.keyOf(url);
		const answer = { reading: null, highlights: root.highlightsOn ? root.highlights.filter(item => root.keyOf(item.url) === key && root.shows(item)) : [] };
		const asks = [];
		if (root.readingOn) asks.push("reading");
		if (root.highlightsOn) asks.push("highlights");
		if (!Netcore.online || asks.length === 0 || key === "") return reply(true, answer);
		let left = asks.length;
		let answered = false;
		const finish = () => {
			if (answered) return;
			answered = true;
			reply(true, answer);
		};
		const one = () => {
			if (--left === 0) finish();
		};
		const query = `?url=${encodeURIComponent(url)}`;
		if (root.readingOn) Netcore.call("GET", `/api/browse/reading${query}`, null, data => {
			const place = data?.reading;
			if (place && root.shows(place)) answer.reading = place;
			one();
		});
		if (root.highlightsOn) Netcore.call("GET", `/api/browse/highlights${query}`, null, data => {
			const known = new Set(answer.highlights.map(item => item.id));
			for (const item of data?.highlights || [])
				if (!known.has(item.id) && root.shows(item)) answer.highlights.push({ id: item.id, text: item.text });
			one();
		});
		// pshell-core slow or away: what is here
		root.lateAnswers = root.lateAnswers.concat([finish]);
		answerLate.start();
	}

	property var lateAnswers: []

	Timer {
		id: answerLate

		interval: 2000
		onTriggered: {
			const waiting = root.lateAnswers;
			root.lateAnswers = [];
			for (const finish of waiting) finish();
		}
	}

	// ── what the extension tells ────────────────────────────────────────────
	Connections {
		target: root.built ? WebLink : null

		function onEventReceived(event) {
			if (event.name === "reading") root.noteReading(event);
			else if (event.name === "copied") root.noteCopy(event);
		}
	}

	// where a page was left: to pshell-core, at most every ten seconds a page
	property var readingDue: ({})

	function noteReading(event) {
		if (!root.readingOn || event.private) return;
		const key = String(event.key || root.keyOf(event.url));
		if (key === "" || (!(key in root.readingDue) && Object.keys(root.readingDue).length >= 200)) return;
		root.readingDue = Object.assign({}, root.readingDue, { [key]: {
				url: String(event.url || ""),
				title: String(event.title || ""),
				progress: Number(event.progress) || 0,
				anchor: String(event.anchor || ""),
				mode: event.mode === "work" ? "work" : "private"
			} });
		if (!readingFlush.running) readingFlush.start();
	}

	Timer {
		id: readingFlush

		interval: 10000
		onTriggered: {
			// pshell-core away: kept until it is back (the browser has its own copy)
			if (!Netcore.online) return;
			const due = root.readingDue;
			root.readingDue = {};
			for (const key of Object.keys(due)) Netcore.call("PUT", "/api/browse/reading", due[key], () => {});
		}
	}

	function normal(text) {
		return String(text || "").split(/\s+/).filter(part => part !== "").join(" ");
	}

	function bare(text) {
		return String(text || "").toLowerCase().replace(/[^0-9a-z\u00c0-\u024f\u0370-\u04ff]+/g, "");
	}

	function noteCopy(event) {
		if (!root.clipsOn || event.private || !/^https?:\/\//.test(String(event.url || ""))) return;
		const clip = {
			preview: root.normal(event.text).slice(0, 400),
			url: String(event.url),
			title: String(event.title || ""),
			fragment: String(event.fragment || ""),
			mode: event.mode === "work" ? "work" : "private",
			at: Date.now()
		};
		if (clip.preview === "") return;
		root.clips = [clip].concat(root.clips.filter(item => item.preview !== clip.preview)).slice(0, 300);
		root.save();
	}

	// the page a clipboard entry was copied from, or null
	function sourceOf(entry) {
		if (!root.clipsOn || !entry || entry.isImage || entry.kind !== "text") return null;
		const preview = String(entry.preview || "");
		let found = root.clips.find(clip => clip.preview === preview) ?? null;
		if (!found) {
			// the browser's clipboard text may differ a little from the selection
			const head = root.bare(preview).slice(0, 60);
			const time = Number(entry.time || 0) * 1000;
			if (head.length >= 8) found = root.clips.find(clip => Math.abs(clip.at - time) < 20000 && root.bare(clip.preview).includes(head)) ?? null;
		}
		return found && root.shows(found) ? found : null;
	}

	function hostOf(url) {
		const found = String(url || "").match(/^https?:\/\/(?:[^@\/?#]*@)?([^\/?#:]+)/i);
		return found ? found[1].replace(/^www\./, "") : "";
	}

	// back to the spot (the text fragment)
	function openSource(clip) {
		if (!clip) return;
		const url = clip.url + (clip.fragment || "");
		if (WebLink.connected) WebLink.open(url);
		else Browser.open(url);
	}

	// ── highlights ─────────────────────────────────────────────────────────
	function newId() {
		let id = "hl_";
		for (let i = 0; i < 12; i++) id += "0123456789abcdef"[Math.floor(Math.random() * 16)];
		return id;
	}

	// text kept as a note from a page (WebMenu "Keep as note")
	function highlight(url, title, text, noteId) {
		const plain = root.normal(text).slice(0, 2000);
		if (!root.highlightsOn || root.keyOf(url) === "" || plain.length < 3) return;
		root.highlights = root.highlights.concat([{
				id: root.newId(),
				url: String(url).split("#")[0],
				title: String(title || ""),
				text: plain,
				note: String(noteId || ""),
				mode: root.mode,
				at: Date.now(),
				synced: false
			}]).slice(-2000);
		root.save();
		root.sync();
	}

	function sync() {
		if (!Netcore.online) return;
		for (const item of root.highlights) {
			if (item.synced) continue;
			const id = item.id;
			Netcore.call("POST", "/api/browse/highlights", { id: id, url: item.url, title: item.title, text: item.text, note: item.note, mode: item.mode }, (data, error) => {
				if (error) return;
				root.highlights = root.highlights.map(each => each.id === id ? Object.assign({}, each, { synced: true }) : each);
				root.save();
			});
		}
	}

	// a deleted note takes its highlight with it
	Connections {
		target: root.built ? Notes : null

		function onNotesChanged() {
			if (!Notes.loaded || !root.loaded) return;
			const gone = root.highlights.filter(item => item.note !== "" && !Notes.find(item.note));
			if (gone.length === 0) return;
			root.highlights = root.highlights.filter(item => !gone.includes(item));
			root.save();
			for (const item of gone)
				if (item.synced && Netcore.online) Netcore.call("DELETE", `/api/browse/highlights/${item.id}`, null, () => {});
		}
	}

	Connections {
		target: root.built ? Netcore : null

		function onOnlineChanged() {
			if (!Netcore.online) return;
			root.sync();
			if (Object.keys(root.readingDue).length > 0) readingFlush.start();
		}
	}

	// ── the day review ─────────────────────────────────────────────────────
	function refreshToday() {
		if (!root.reviewOn || !WebLink.connected) {
			root.today = [];
			return;
		}
		WebLink.command("memoryToday", {}, (ok, data) => {
			if (!ok || !Array.isArray(data)) return;
			root.today = data.filter(item => {
				if (!root.work && item.modes && !item.modes.includes("private")) return false;
				if (item.kind === "video") return item.media >= 120 || item.dwell >= 180;
				return item.kind === "article" && (item.dwell >= 90 || (item.progress >= 0.5 && item.dwell >= 45));
			}).map(item => ({
					key: String(item.key),
					url: String(item.url),
					title: String(item.title || item.url),
					host: String(item.host || "").replace(/^www\./, ""),
					kind: item.kind === "video" ? "video" : "article",
					dwell: Number(item.dwell) || 0
				}));
		});
	}

	function reviewedNow(item) {
		const day = Qt.formatDate(new Date(), "yyyy-MM-dd");
		const keys = root.reviewed.day === day ? root.reviewed.keys : [];
		root.reviewed = { day: day, keys: keys.concat([item.key]) };
		root.save();
	}

	function shelve(item) {
		if (!Plugins.on("shelves")) return;
		Shelf.keep([{ kind: "link", url: item.url }]);
		root.reviewedNow(item);
	}

	// a reminder for tomorrow at 18:00 that opens the page
	function later(item) {
		const at = new Date();
		at.setDate(at.getDate() + 1);
		at.setHours(18, 0, 0, 0);
		Reminders.create({ title: item.title, note: item.url, at: Math.floor(at.getTime() / 1000) }, (data, error) => {
			if (!error) root.reviewedNow(item);
		});
	}

	function open(item) {
		if (WebLink.connected) WebLink.open(item.url);
		else Browser.open(item.url);
	}

	// everything the browser kept (Settings › Browser)
	function forget() {
		WebLink.command("memoryForget", {}, null);
		root.today = [];
	}

	// ── kept ───────────────────────────────────────────────────────────────
	function save() {
		if (!root.loaded) return;
		saveDue.restart();
	}

	Timer {
		id: saveDue

		interval: 400
		onTriggered: file.setText(JSON.stringify({ highlights: root.highlights, clips: root.clips, reviewed: root.reviewed }) + "\n")
	}

	FileView {
		id: file

		path: Paths.stateFile("browser-memory.json")
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(text());
				root.highlights = Array.isArray(saved.highlights) ? saved.highlights : [];
				root.clips = Array.isArray(saved.clips) ? saved.clips : [];
				root.reviewed = saved.reviewed && Array.isArray(saved.reviewed.keys) ? saved.reviewed : { day: "", keys: [] };
			} catch (error) {}
			root.loaded = true;
			root.sync();
		}
		onLoadFailed: root.loaded = true
	}
}
