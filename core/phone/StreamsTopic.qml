import QtQuick
import Quickshell
import qs.core.services

// streams: what could go on and who is live. A tap plays it on the PC, or hands
// the phone the address and the place to start from.
Topic {
	id: topic

	name: "streams"

	property var known: ({ series: [], live: [] })

	function refresh() {
		if (!topic.wanted || !Plugins.on("streams")) return;
		Streams.call("continueList", {}, data => {
			if (data) topic.known = data;
		});
	}

	data: topic.wanted ? ({
		on: Plugins.on("streams"),
		series: topic.known.series.map(item => ({ series: item.series, name: item.name, video: item.video, title: item.title, n: item.n, total: item.total, left: item.left, position: item.position, duration: item.duration, url: item.url })),
		live: topic.known.live.map(item => ({ source: item.source, name: item.name, title: item.title, url: item.url, viewers: item.viewers })),
		playing: Streams.playing?.video ?? Streams.playing?.id ?? ""
	}) : null

	onWantedChanged: topic.refresh()

	Connections {
		target: Streams
		enabled: topic.wanted

		function onFeedStampChanged() {
			topic.refresh();
		}
		function onLiveStreamsChanged() {
			topic.refresh();
		}
	}

	function call(action, args, done) {
		switch (action) {
		case "play":
			Streams.play(String(args.video));
			return {};
		case "live":
			Streams.playLive(String(args.source));
			return {};
		}
		throw new Error("unknown-action");
	}
}
