import QtQuick
import Quickshell
import qs.core.services

// sound: output and microphone volume, the output devices, a volume per app.
Topic {
	id: topic

	name: "sound"

	data: topic.wanted ? ({
		volume: Audio.volume,
		muted: Audio.muted,
		mic: Audio.micVolume,
		micMuted: Audio.micMuted,
		sink: Audio.sinkName,
		sinks: Audio.sinks.map(sink => ({ name: sink.name, title: Audio.shortSinkName(sink.description), active: sink.active, headphones: sink.headphones })),
		streams: Audio.streams.map(node => ({
			id: node.id,
			name: Audio.streamName(node),
			title: Audio.streamTitle(node),
			volume: node.audio?.volume ?? 0,
			muted: !!node.audio?.muted
		}))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "set":
			Audio.setVolume(Number(args.volume));
			return {};
		case "adjust":
			Audio.setVolume(Audio.volume + Number(args.delta || 0));
			return { volume: Audio.volume };
		case "mute":
			if (Audio.sink?.audio) Audio.sink.audio.muted = args.on === undefined ? !Audio.muted : !!args.on;
			return {};
		case "setMic":
			Audio.setMicVolume(Number(args.volume));
			return {};
		case "muteMic":
			if (Audio.source?.audio) Audio.source.audio.muted = args.on === undefined ? !Audio.micMuted : !!args.on;
			return {};
		case "sink":
			Audio.setDefaultSink(String(args.name));
			return {};
		case "stream": {
			const node = Audio.streams.find(n => n.id === Number(args.id));
			if (!node?.audio) throw new Error("No such stream");
			if (args.volume !== undefined) node.audio.volume = Math.max(0, Math.min(1, Number(args.volume)));
			if (args.muted !== undefined) node.audio.muted = !!args.muted;
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
