import QtQuick
import Quickshell
import qs.core.services

// reader: the fast reader on the PC, one word at a time. The phone sends a
// text to read there and can play, pause and step while it runs.
Topic {
	id: topic

	name: "reader"
	throttle: 120

	readonly property bool shown: Popups.current === "reader"

	data: topic.wanted ? ({
		shown: topic.shown,
		playing: Reader.playing,
		counting: Reader.counting,
		finished: Reader.finished,
		index: Reader.index,
		count: Reader.words.length,
		progress: Reader.progress,
		word: Reader.word,
		wpm: Reader.wpm,
		size: Reader.size,
		punctuation: Reader.punctuation,
		countdown: Reader.countdown,
		speeds: Reader.speeds.map(speed => ({ wpm: Number(speed.wpm), label: String(speed.label) })),
		sizes: Reader.sizes.map(size => ({ value: String(size.value), label: String(size.label) }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "read": {
			const text = String(args.text || "").trim();
			if (text === "") throw new Error("Nothing to read");
			Reader.read(text);
			return {};
		}
		case "toggle":
			if (!topic.shown) throw new Error("The reader is not open");
			Reader.toggle();
			return {};
		case "play":
			Reader.play();
			return {};
		case "pause":
			Reader.pause();
			return {};
		case "back":
			Reader.back();
			return {};
		case "forward":
			Reader.forward();
			return {};
		case "restart":
			Reader.restart();
			return {};
		case "seek":
			Reader.seek(Number(args.index) || 0);
			return {};
		case "close":
			if (topic.shown) Popups.close();
			return {};
		case "speed":
			Reader.setSpeed(Number(args.wpm) || Reader.wpm);
			return {};
		case "size":
			Reader.setSize(String(args.size || Reader.size));
			return {};
		case "punctuation":
			Reader.setPunctuation(args.on !== false);
			return {};
		case "countdown":
			Reader.setCountdown(args.on !== false);
			return {};
		}
		throw new Error("unknown-action");
	}
}
