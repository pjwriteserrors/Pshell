import QtQuick
import Quickshell
import qs.core.services

// song: what the PC heard playing, with cover and links; listening on request.
Topic {
	id: topic

	name: "song"

	data: topic.wanted ? ({
		state: SongDetect.state,
		listening: SongDetect.listening,
		startedAt: SongDetect.startedAt,
		seconds: SongDetect.listenSeconds,
		message: SongDetect.message,
		song: SongDetect.song ? {
			title: SongDetect.song.title,
			artist: SongDetect.song.artist,
			album: SongDetect.song.album,
			cover: { "$blob": SongDetect.song.cover },
			links: (SongDetect.song.links || []).map(link => ({ label: String(link.label || link.name || link.service || "Open"), url: String(link.url || link) }))
		} : null
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "detect":
			SongDetect.detect();
			return {};
		case "cancel":
			SongDetect.cancel();
			return {};
		case "dismiss":
			SongDetect.dismiss();
			return {};
		case "open":
			SongDetect.open(String(args.url));
			return {};
		}
		throw new Error("unknown-action");
	}
}
