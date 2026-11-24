pragma Singleton

import QtQuick
import Quickshell

// Meeting links of the calendar (docs/browser.md "Meetings"): a minute
// before an event with a Teams, Meet, Zoom, Jitsi, Webex or Whereby link a
// toast offers "Join", which opens the link in the browser. The link is the
// event's own (joinUrl) or the first one found in its place or its text.
//
// Work stays out of private time: an event of the Microsoft calendar is
// work, and work shows only in a working context – a qtrack timer runs or is
// paused, or time was tracked today (the workday has begun). Without qtrack
// there is no such line and everything shows. Baikal's events (and the
// birthdays) are private and always show. MsCalendar's own reminders and
// its timer offers follow the same rule (`shows`).
Singleton {
	id: root

	readonly property bool enabled: (MsCalendar.enabled && MsCalendar.signedIn) || NasCalendar.active

	// a qtrack timer runs, is paused, or ran today
	readonly property bool working: !Plugins.on("qtrack") || QtrackTimer.tracking || QtrackTimer.paused || QtrackTimer.todaySeconds > 0

	readonly property var linkPattern: /https?:\/\/(?:[\w-]+\.)*(?:teams\.microsoft\.com\/(?:l\/meetup-join|meet)|teams\.live\.com\/meet|zoom\.us\/(?:j|my|w|s)|meet\.google\.com|meet\.jit\.si|8x8\.vc|jitsi\.[\w.-]+|webex\.com\/(?:meet|join|[\w.-]+\/j\.php)|whereby\.com)\/[^\s<>"'\\)\]]+/i

	// `${id}@${start}` → true: offered once
	property var offered: ({})

	function isWork(event) {
		return !!event && !event.source;
	}

	function shows(event) {
		return !root.isWork(event) || root.working;
	}

	function linkOf(event) {
		if (!event) return "";
		for (const text of [event.joinUrl, event.location, event.body]) {
			const found = String(text || "").match(root.linkPattern);
			if (found) return found[0].replace(/[.,;:]+$/, "");
		}
		return "";
	}

	function kindOf(url) {
		const text = String(url);
		if (/teams\.(microsoft|live)\.com/i.test(text)) return "Teams";
		if (/meet\.google\.com/i.test(text)) return "Meet";
		if (/zoom\.us/i.test(text)) return "Zoom";
		if (/webex\.com/i.test(text)) return "Webex";
		if (/whereby\.com/i.test(text)) return "Whereby";
		return "Jitsi";
	}

	// in the browser: the linked one when it is there, else as pages open
	function join(event) {
		const url = root.linkOf(event);
		if (url === "") return;
		if (WebLink.connected) WebLink.open(url);
		else Browser.open(url);
	}

	function check() {
		if (!root.enabled) return;
		const now = Date.now();
		for (const event of MsCalendar.eventsOn(new Date(now))) {
			if (event.allDay || !MsCalendar.active(event)) continue;
			const key = `${event.id}@${event.start}`;
			const lead = Date.parse(event.start) - now;
			// a minute before, or late (the shell started after it began)
			if (lead > 60000 || lead < -5 * 60000 || root.offered[key]) continue;
			if (!root.shows(event)) continue;
			const url = root.linkOf(event);
			if (url === "") continue;
			const offered = Object.assign({}, root.offered);
			offered[key] = true;
			root.offered = offered;
			root.offer(event, url, lead);
		}
	}

	function offer(event, url, lead) {
		const time = Qt.formatTime(new Date(event.start), "HH:mm");
		const detail = `${root.kindOf(url)} · ${lead > 0 ? "starts" : "started"} ${time}`;
		const actions = [{ label: "Join", icon: "video", run: () => root.join(event) }];
		const source = event.source === "baikal" ? "calendar" : "ms-calendar";
		Reminders.fire(source, {
			key: `${event.id}@${event.start}`,
			title: String(event.subject || ""),
			body: detail,
			icon: "video",
			actions: actions,
			post: () => Notifs.pushInternal("running", String(event.subject || ""), detail, {
				icon: "video",
				actions: actions,
				duration: Math.max(60000, Date.parse(event.start) + 5 * 60000 - Date.now())
			})
		});
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: 15000
		triggeredOnStart: true
		onTriggered: root.check()
	}
}
