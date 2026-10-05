import QtQuick
import Quickshell
import qs.core.services

// updates: what the updates panel knows, and its buttons.
Topic {
	id: topic

	name: "updates"
	throttle: 300

	data: topic.wanted ? ({
		count: Updates.count,
		repo: Updates.repoCount,
		aur: Updates.aurCount,
		packages: Updates.packages.slice(0, 300),
		checking: Updates.checking,
		running: Updates.running,
		runningNames: Updates.runningNames,
		progress: Updates.progress,
		progressLabel: Updates.progressLabel,
		result: Updates.result,
		error: Updates.error,
		lastCheck: Updates.lastCheck,
		rebootNeeded: Updates.rebootNeeded,
		news: Updates.unreadNews.map(item => ({ title: item.title, link: item.link, date: item.date }))
	}) : null

	function call(action, args, done) {
		switch (action) {
		case "check":
			Updates.check(true);
			return {};
		case "updateAll":
			Updates.updateAll();
			return {};
		case "update":
			Updates.updateOne(String(args.name));
			return {};
		case "readNews":
			Updates.markAllRead();
			return {};
		}
		throw new Error("unknown-action");
	}
}
