import QtQuick
import Quickshell
import qs.core.services

// screentime: where the time at the screen went. The snapshot is today; an
// earlier day is asked for with a call, so the panel on the PC and another
// phone keep the day they look at.
Topic {
	id: topic

	name: "screentime"
	throttle: 1000

	// as many rows of each kind as a phone shows
	readonly property int top: 8

	// one day: its total, its week and what it went to
	function snapshot(key) {
		const day = Screentime.day(key);
		const versus = Screentime.versus(key);
		const rows = {};
		for (const kind of Screentime.kinds) {
			rows[kind.value] = Screentime.rows(key, kind.value).slice(0, topic.top).map(row => ({
				label: String(row.label),
				detail: String(row.detail),
				icon: String(row.icon),
				seconds: Math.round(row.seconds)
			}));
		}
		return {
			day: key,
			today: Screentime.today,
			label: Qt.formatDate(Screentime.dateOf(key), "dddd, d MMMM"),
			total: Math.round(day.total),
			longest: Math.round(day.longest),
			longestEnd: day.longest > 0 ? Qt.formatTime(new Date(day.longestEnd), "HH:mm") : "",
			versus: versus ? { seconds: Math.round(versus.seconds), ratio: Math.round(versus.ratio * 1000) / 1000 } : null,
			week: Screentime.week(key).map(each => ({
				key: each.key,
				label: Qt.formatDate(each.date, "ddd"),
				total: Math.round(each.total),
				ahead: each.ahead
			})),
			earlier: Object.keys(Screentime.days).some(each => each < key),
			browserLinked: Screentime.browserLinked,
			kinds: Screentime.kinds,
			rows: rows
		};
	}

	data: topic.wanted ? topic.snapshot(Screentime.today) : null

	function call(action, args, done) {
		if (action !== "day") throw new Error("unknown-action");
		const key = String(args.key || "");
		if (!/^\d{4}-\d{2}-\d{2}$/.test(key) || key > Screentime.today) throw new Error("No such day");
		return topic.snapshot(key);
	}
}
