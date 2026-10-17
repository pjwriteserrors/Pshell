pragma Singleton

import QtQuick
import Quickshell
import qs.style.theme

// The watch (an Amazfit on the wrist, docs/watch.md) as the shell sees it:
// what its face handed over to the phone daemon now and then – the nights
// with their stages, the days with steps, heart, stress, blood oxygen – and
// whether it is on the link right now (the mouse app). The daemon keeps the
// history (scripts/phone/pshell_phone/health.py); this only reads the topic
// "watch" and puts it in shape for >watch.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("watch")
	readonly property var data: Phone.watch ?? ({})
	readonly property var link: root.data.link ?? ({})
	readonly property bool connected: !!root.link.connected
	readonly property bool mouse: !!root.link.mouse
	readonly property string name: root.link.name || "Watch"
	readonly property bool paired: (root.link.paired ?? []).length > 0
	readonly property int battery: root.data.battery ?? -1
	readonly property real synced: (root.data.synced ?? 0) * 1000
	// [{ date, bed, wake, total, score, deep, light, rem, awake, stages: [[kind, from, to]] (minutes from bed), naps }]
	readonly property var nights: root.data.nights ?? []
	readonly property var lastNight: root.nights.length > 0 ? root.nights[root.nights.length - 1] : null
	// [{ date, steps, stepsGoal, calories, resting, stress, pai }]
	readonly property var days: root.data.days ?? []
	// today in full: heart (144 × 10 min), stress (24 h), oxygen (24 h), temperature (48 × 30 min), goals
	readonly property var today: root.data.today ?? ({})
	readonly property bool known: root.nights.length > 0 || root.days.length > 0

	// a minute ticker, for "synced 4 min ago"
	property real now: Date.now()
	Timer {
		interval: 30000
		running: root.enabled
		repeat: true
		onTriggered: root.now = Date.now()
	}

	readonly property string syncedText: {
		if (root.synced <= 0) return "Not synced yet";
		const minutes = Math.max(0, Math.round((root.now - root.synced) / 60000));
		if (minutes < 1) return "Synced just now";
		if (minutes < 60) return `Synced ${minutes} min ago`;
		if (minutes < 24 * 60) return `Synced ${Math.round(minutes / 60)} h ago`;
		return `Synced ${Qt.formatDate(new Date(root.synced), "d MMM")}`;
	}

	// the stages, in the order the hypnogram stacks them, with their colours
	readonly property var stages: [
		{ id: "wake", label: "Awake" },
		{ id: "rem", label: "REM" },
		{ id: "light", label: "Light" },
		{ id: "deep", label: "Deep" }
	]

	// a stage's colour: deep the strongest, awake the warning
	function tone(kind) {
		switch (kind) {
		case "deep": return Theme.primary;
		case "light": return Theme.secondary;
		case "rem": return Theme.tertiary;
		default: return Theme.warning;
		}
	}

	// "7 h 12", "48 min"
	function span(minutes) {
		const m = Math.round(Math.max(0, minutes || 0));
		if (m < 60) return `${m} min`;
		return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`;
	}

	function clock(seconds) {
		return Qt.formatTime(new Date(seconds * 1000), "HH:mm");
	}

	function dateOf(key) {
		const parts = String(key).split("-").map(Number);
		return new Date(parts[0], (parts[1] || 1) - 1, parts[2] || 1);
	}

	function night(key) {
		return root.nights.find(each => each.date === key) ?? null;
	}

	// minutes of each stage in a night: { wake, rem, light, deep }
	function shares(night) {
		const out = { wake: 0, rem: 0, light: 0, deep: 0 };
		for (const stage of night?.stages ?? [])
			out[stage[0]] = (out[stage[0]] ?? 0) + Math.max(0, stage[2] - stage[1]);
		if (out.deep === 0 && night) out.deep = night.deep ?? 0;
		return out;
	}

	// the average of the nights before the given one (up to a week of them)
	function usual(key) {
		const before = root.nights.filter(each => each.date < key).slice(-7);
		if (before.length === 0) return 0;
		return before.reduce((sum, each) => sum + each.total, 0) / before.length;
	}

	// what the score says, in a word
	function verdict(score) {
		if (score >= 85) return "Excellent";
		if (score >= 70) return "Good";
		if (score >= 55) return "Fair";
		return score > 0 ? "Poor" : "";
	}
}
