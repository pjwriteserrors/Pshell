import QtQuick
import Quickshell
import qs.core.services

// downloads: what the browser on the PC downloads, with progress; a finished
// file can be opened there or fetched to the phone.
Topic {
	id: topic

	name: "downloads"
	throttle: 400

	data: topic.wanted ? ({
		connected: Downloads.connected,
		phase: Downloads.phase,
		speed: Downloads.speed,
		items: Downloads.order.map(key => Downloads.table[key]).filter(item => !!item).map(item => ({
			key: String(item.key),
			name: String(item.name || ""),
			path: String(item.path || ""),
			url: String(item.url || ""),
			mime: String(item.mime || ""),
			state: String(item.state || ""),
			received: Number(item.received) || 0,
			total: Number(item.total) || 0,
			speed: Number(item.speed) || 0,
			eta: Number.isFinite(Number(item.eta)) ? Number(item.eta) : -1,
			error: String(item.error || ""),
			canResume: !!item.canResume,
			started: Number(item.started) || 0,
			finished: Number(item.finished) || 0
		}))
	}) : null

	onWantedChanged: if (topic.wanted) Downloads.seen()

	function call(action, args, done) {
		const key = String(args.key || "");
		switch (action) {
		case "pause":
			Downloads.pause(key);
			return {};
		case "resume":
			Downloads.resume(key);
			return {};
		case "cancel":
			Downloads.cancel(key);
			return {};
		case "dismiss":
			Downloads.dismiss(key);
			return {};
		case "open":
			Downloads.open(key);
			return {};
		case "reveal":
			Downloads.reveal(key);
			return {};
		// the finished file comes to the phone
		case "send": {
			const item = Downloads.table[key];
			if (!item || item.state !== "done" || !item.path) throw new Error("The download is not finished");
			topic.link.sendFiles([String(item.path)]);
			return {};
		}
		}
		throw new Error("unknown-action");
	}
}
