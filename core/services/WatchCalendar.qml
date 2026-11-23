pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The events of the next seven days (Microsoft and Baikal, MsCalendar.eventsOn)
// on the Amazfit watch, with a reminder at the event's own alarm or 10 minutes
// before. Amazfit option `calendarSync`. Only the events put there from here
// are taken away again (watch-calendar.json: eid → what was sent); the ones
// added by hand on the watch's page stay.
Singleton {
	id: root

	readonly property bool on: Amazfit.enabled && Amazfit.zeppReady && Amazfit.zepp?.caps?.calendar !== undefined && Amazfit.option("calendarSync", false) === true
	// eid → signature of what the watch has
	property var sent: ({})
	property bool loaded: false

	FileView {
		id: store

		path: Paths.stateFile("watch-calendar.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.sent = JSON.parse(store.text() || "{}");
			} catch (e) {
				root.sent = {};
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// a stable id in 0x40000000…0x7fffffff, apart from the hand-made ones (seconds since 1970)
	function eid(event) {
		const text = `${event.id}@${event.start}`;
		let h = 2166136261;
		for (let i = 0; i < text.length; i += 1) h = Math.imul(h ^ text.charCodeAt(i), 16777619) >>> 0;
		return 0x40000000 + (h % 0x3fffffff);
	}

	function wanted() {
		const out = {};
		const today = new Date();
		for (let i = 0; i < 7; i += 1) {
			const day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + i);
			for (const event of MsCalendar.eventsOn(day)) {
				if (event.cancelled || event.response === "declined" || Date.parse(event.end) < Date.now()) continue;
				const start = Math.floor(Date.parse(event.start) / 1000);
				const end = Math.floor(Date.parse(event.end) / 1000);
				const before = event.allDay ? 0 : (event.reminder >= 0 ? event.reminder : 10) * 60;
				const args = { eid: root.eid(event), title: String(event.subject).slice(0, 60), description: String(event.calendar ?? "").slice(0, 200), start: start, end: end, reminder: start - before, all_day: event.allDay, location: String(event.location ?? "").slice(0, 100) };
				out[args.eid] = args;
			}
		}
		return out;
	}

	function sync() {
		if (!root.on || !root.loaded) return;
		const want = root.wanted();
		const sent = Object.assign({}, root.sent);
		for (const eid of Object.keys(sent)) {
			if (want[eid] && JSON.stringify(want[eid]) === sent[eid]) continue;
			Amazfit.call("delete_event", { eid: Number(eid) });
			delete sent[eid];
		}
		for (const eid of Object.keys(want)) {
			if (sent[eid]) continue;
			Amazfit.call("add_event", want[eid]);
			sent[eid] = JSON.stringify(want[eid]);
		}
		root.sent = sent;
		store.setText(JSON.stringify(sent));
	}

	Timer {
		id: soon
		interval: 5000
		onTriggered: root.sync()
	}

	Connections {
		target: NasCalendar

		function onFetchedAtChanged() {
			soon.restart();
		}
	}

	Connections {
		target: MsCalendar

		function onByDayChanged() {
			soon.restart();
		}
	}

	onOnChanged: if (root.on) soon.restart()

	Timer {
		running: root.on
		repeat: true
		interval: 30 * 60000
		onTriggered: root.sync()
	}
}
