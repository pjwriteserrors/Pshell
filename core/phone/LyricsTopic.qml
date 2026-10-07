import QtQuick
import Quickshell
import qs.core.services

// lyrics: the words of the song that plays on the PC. Looking from the phone
// counts as looking (Lyrics.remote), so the lines are fetched although the
// media panel is closed. Which line is sung the phone works out from the
// media topic's position, so nothing is sent per line.
Topic {
	id: topic

	name: "lyrics"
	throttle: 200

	Binding {
		target: Lyrics
		property: "remote"
		value: 1
		when: topic.wanted
		restoreMode: Binding.RestoreValue
	}

	data: topic.wanted ? ({
		state: Lyrics.state,
		synced: Lyrics.synced,
		title: Lyrics.title,
		artist: Media.artist,
		key: Lyrics.key,
		lines: Lyrics.lines.map(line => ({ t: Number(line.t), text: String(line.text || "") }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		// shows them on the PC too
		case "show":
			Lyrics.show(args.on !== false);
			return {};
		}
		throw new Error("unknown-action");
	}
}
