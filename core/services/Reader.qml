pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The fast reader: a text one word at a time, every word on the same spot
// with the letter the eye rests on marked, so the eyes never move. Text
// dropped on "Read" of the drop commands is read in the reader panel.
// Speed, size and pauses are kept in reader.json.
Singleton {
	id: root

	readonly property var speeds: [
		{ wpm: 250, label: "Comfortable" },
		{ wpm: 300, label: "Focus" },
		{ wpm: 400, label: "Fast" },
		{ wpm: 500, label: "Skim" }
	]
	// the word's height in pixels
	readonly property var sizes: [
		{ value: "sm", label: "SM", pixels: 40 },
		{ value: "md", label: "MD", pixels: 56 },
		{ value: "lg", label: "LG", pixels: 72 },
		{ value: "xl", label: "XL", pixels: 92 }
	]

	property int wpm: 300
	property string size: "md"
	// a word that ends a clause or a sentence stays longer
	property bool punctuation: true
	// 3 … 2 … 1 before the words run
	property bool countdown: true
	readonly property int pixels: (root.sizes.find(entry => entry.value === root.size) ?? root.sizes[1]).pixels

	property var words: []
	property int index: 0
	property bool playing: false
	// what the countdown shows, 0 when it does not run
	property int counting: 0
	// the last word was shown for its time
	property bool finished: false

	readonly property string word: root.words[root.index] ?? ""
	readonly property string previous: root.index > 0 ? root.words[root.index - 1] : ""
	readonly property string next: root.words[root.index + 1] ?? ""
	readonly property real progress: root.words.length > 1 ? root.index / (root.words.length - 1) : (root.finished ? 1 : 0)

	function read(text, screen) {
		const words = [];
		for (const token of String(text || "").replace(/­/g, "").split(/\s+/)) {
			if (token === "") continue;
			// a dash on its own stays with the word before it
			if (words.length > 0 && !root.spoken(token)) words[words.length - 1] += ` ${token}`;
			else words.push(token);
		}
		if (words.length === 0) {
			Notifs.pushInternal("error", "No text to read", "", { icon: "book_open_page_variant" });
			return;
		}
		root.pause();
		root.words = words;
		root.index = 0;
		root.finished = false;
		if (screen) Popups.open("reader", screen);
		else Popups.withFocusedScreen(focused => Popups.open("reader", focused));
		// the countdown covers the panel coming up; without it the words wait
		if (root.countdown) root.play();
		else opening.restart();
	}

	// what was dropped on the command; `at` is where the ring was
	function readItems(items, at) {
		root.read(Shelf.textOf(items.filter(item => item.kind !== "file")), Popups.screenByName(at?.output));
	}

	function letter(character) {
		return character.toLowerCase() !== character.toUpperCase() || (character >= "0" && character <= "9");
	}

	function spoken(word) {
		for (const character of word)
			if (root.letter(character)) return true;
		return false;
	}

	// the letter the eye rests on: a little left of the middle. Quotes and
	// brackets around the word do not count.
	function pivot(word) {
		let start = 0;
		while (start < word.length && !root.letter(word[start])) start += 1;
		if (start >= word.length) return 0;
		let end = word.length;
		while (end > start && !root.letter(word[end - 1])) end -= 1;
		const length = end - start;
		return start + (length <= 1 ? 0 : length <= 5 ? 1 : length <= 9 ? 2 : length <= 13 ? 3 : 4);
	}

	function endsSentence(word) {
		return /[.!?…]["'“”„»«)\]]*$/.test(word);
	}

	// how long a word stays, in milliseconds
	function duration(word) {
		let factor = 1;
		if (root.punctuation) {
			if (root.endsSentence(word)) factor = 2.2;
			else if (/[,;:–—]["'“”„»«)\]]*$/.test(word)) factor = 1.5;
		}
		// a long word takes longer to take in
		if (word.length > 9) factor += Math.min(0.6, (word.length - 9) * 0.06);
		return Math.round(60000 / root.wpm * factor);
	}

	function schedule() {
		tick.interval = root.duration(root.word);
		tick.restart();
	}

	function play() {
		if (root.words.length === 0 || root.playing) return;
		if (root.finished || root.index >= root.words.length - 1) root.index = 0;
		root.finished = false;
		root.playing = true;
		if (root.countdown) {
			root.counting = 3;
			count.restart();
		} else {
			root.schedule();
		}
	}

	function pause() {
		opening.stop();
		tick.stop();
		count.stop();
		root.counting = 0;
		root.playing = false;
	}

	function toggle() {
		if (root.playing) root.pause();
		else root.play();
	}

	function seek(index) {
		if (root.words.length === 0) return;
		root.index = Math.max(0, Math.min(root.words.length - 1, Math.round(index)));
		root.finished = false;
		if (root.playing && root.counting === 0) root.schedule();
	}

	function restart() {
		root.seek(0);
	}

	// where the sentence around a word starts
	function sentenceStart(index) {
		let start = index;
		while (start > 0 && !root.endsSentence(root.words[start - 1])) start -= 1;
		return start;
	}

	// to the start of the sentence; from its first words to the one before
	function back() {
		const start = root.sentenceStart(root.index);
		root.seek(start > 0 && root.index - start <= 2 ? root.sentenceStart(start - 1) : start);
	}

	function forward() {
		let index = root.index + 1;
		while (index < root.words.length - 1 && !root.endsSentence(root.words[index - 1])) index += 1;
		root.seek(index);
	}

	function setSpeed(wpm) {
		root.wpm = Math.max(100, Math.min(1000, Math.round(wpm)));
		root.save();
	}

	function setSize(size) {
		root.size = size;
		root.save();
	}

	function setPunctuation(on) {
		root.punctuation = !!on;
		root.save();
	}

	function setCountdown(on) {
		root.countdown = !!on;
		root.save();
	}

	function save() {
		file.setText(JSON.stringify({ wpm: root.wpm, size: root.size, punctuation: root.punctuation, countdown: root.countdown }, null, "\t") + "\n");
	}

	// a panel that left stops the words
	Connections {
		target: Popups
		function onCurrentChanged() {
			if (Popups.current !== "reader") root.pause();
		}
	}

	// without a countdown a new text starts once the panel stands
	Timer {
		id: opening

		interval: 420
		onTriggered: if (Popups.current === "reader") root.play()
	}

	Timer {
		id: count

		interval: 650
		repeat: true
		onTriggered: {
			root.counting -= 1;
			if (root.counting > 0) return;
			count.stop();
			root.schedule();
		}
	}

	Timer {
		id: tick

		onTriggered: {
			if (root.index >= root.words.length - 1) {
				root.playing = false;
				root.finished = true;
				return;
			}
			root.index += 1;
			root.schedule();
		}
	}

	FileView {
		id: file

		path: Paths.stateFile("reader.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(String(text() || "{}"));
				if (Number(saved.wpm) >= 100 && Number(saved.wpm) <= 1000) root.wpm = Math.round(Number(saved.wpm));
				if (root.sizes.some(entry => entry.value === saved.size)) root.size = saved.size;
				if (typeof saved.punctuation === "boolean") root.punctuation = saved.punctuation;
				if (typeof saved.countdown === "boolean") root.countdown = saved.countdown;
			} catch (error) {}
		}
	}
}
