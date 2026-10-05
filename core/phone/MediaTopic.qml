import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.core.services

// media: the player the shell picked, and the others to pick from. The
// position is sent as an anchor (position at a time), so a playing track
// costs no message per second; the phone counts on by itself.
Topic {
	id: topic

	name: "media"

	// { position, at } in seconds / ms since epoch
	property var anchor: ({ position: 0, at: Date.now() })

	// a stream has no length; the player then reports its position as one
	readonly property real length: (Media.player?.lengthSupported ?? false) ? Media.length : 0

	function mark() {
		topic.anchor = { position: Media.position, at: Date.now() };
	}

	data: topic.wanted ? ({
		has: Media.hasPlayer,
		playing: Media.playing,
		title: Media.title,
		artist: Media.artist,
		album: Media.player?.trackAlbum ?? "",
		art: { "$blob": Media.art },
		length: topic.length,
		position: topic.anchor.position,
		positionAt: topic.anchor.at,
		rate: Media.player?.rate ?? 1,
		canSeek: topic.length > 0 && (Media.player?.canSeek ?? false),
		canNext: Media.player?.canGoNext ?? false,
		canPrevious: Media.player?.canGoPrevious ?? false,
		canControl: Media.player?.canControl ?? false,
		canHandoff: /^https?:/.test(String(Media.player?.metadata?.["xesam:url"] ?? "")),
		player: Media.player?.identity ?? "",
		players: Media.players.map(player => ({
			name: player.identity || player.dbusName,
			playing: player.isPlaying,
			current: player === Media.player
		}))
	}) : null

	onWantedChanged: if (topic.wanted) topic.mark()
	onLengthChanged: topic.mark()

	Connections {
		target: Media
		enabled: topic.wanted

		function onPlayingChanged() {
			topic.mark();
		}
		function onTitleChanged() {
			topic.mark();
		}
		function onPlayerChanged() {
			topic.mark();
		}
		// a seek: the position is not where the anchor says it would be
		function onPositionChanged() {
			const expected = topic.anchor.position + (Media.playing ? (Date.now() - topic.anchor.at) / 1000 * (Media.player?.rate ?? 1) : 0);
			if (Math.abs(Media.position - expected) > 1.5) topic.mark();
		}
	}

	function call(action, args, done) {
		const player = Media.player;
		switch (action) {
		case "playPause":
			if (player?.canTogglePlaying) player.togglePlaying();
			return {};
		case "play":
			if (player?.canPlay) player.play();
			return {};
		case "pause":
			if (player?.canPause) player.pause();
			return {};
		case "next":
			if (player?.canGoNext) player.next();
			return {};
		case "previous":
			if (player?.canGoPrevious) player.previous();
			return {};
		case "seek":
			if (args.position !== undefined && Media.length > 0) Media.seek(Number(args.position) / Media.length);
			else if (args.ratio !== undefined) Media.seek(Number(args.ratio));
			topic.mark();
			return {};
		// what plays here continues on the phone: where it is, and it stops here
		case "handoff": {
			if (!topic.link.allowed("handoff")) throw new Error("Hand-off is off");
			const url = String(player?.metadata?.["xesam:url"] ?? "");
			if (!/^https?:/.test(url)) throw new Error("The player does not say what it plays");
			const position = Math.floor(Media.position);
			if (player.canPause) player.pause();
			return { url: url, position: position, title: Media.title, headset: topic.link.releaseHeadset() };
		}
		case "select": {
			const wanted = Media.players.find(p => (p.identity || p.dbusName) === String(args.player));
			if (!wanted) throw new Error("No such player");
			Media.select(wanted);
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
