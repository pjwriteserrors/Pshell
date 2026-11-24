pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Small helps in the browser's pages (docs/browser.md "What the shell does with it"),
// each its own plugin:
//
// - `browser-codes`: one-time codes from the phone's SMS and notifications,
//   the mailbox and the made-up identities' inboxes are kept in memory for
//   ten minutes; when a code field in the browser has the focus (or had it
//   in the last five minutes when a code comes), the page shows them in a
//   small card at the field. Only a click there puts one in.
// - `browser-timers`: times in a recipe's steps get a button in the page;
//   it starts a timer here, which ends as a reminder (source `timer`) and on
//   the Amazfit watch as a notification that vibrates.
// - `browser-brake`: after a while on the sites of a list (Reddit, Shorts,
//   Instagram, TikTok, …) the page shows how long it was today
//   (Screentime), quietly, again after as long. Nothing is blocked.
Singleton {
	id: root

	readonly property bool linked: WebLink.enabled && WebLink.connected
	readonly property bool codesOn: Plugins.on("browser-codes") && root.linked
	readonly property bool timersOn: Plugins.on("browser-timers") && root.linked
	readonly property bool brakeOn: Plugins.on("browser-brake") && Plugins.on("screentime") && root.linked

	// settings (browser-assist.json)
	property int brakeMinutes: 15
	property var brakeSites: root.defaultSites
	readonly property var defaultSites: ["reddit.com", "youtube.com/shorts", "instagram.com", "tiktok.com", "x.com", "facebook.com", "9gag.com"]

	// ── what the pages offer: told to every browser that comes ────────────
	readonly property string pageConfig: JSON.stringify({ codes: Plugins.on("browser-codes"), timers: Plugins.on("browser-timers") })
	property string toldLinks: ""

	onPageConfigChanged: tellSoon.restart()

	Connections {
		target: WebLink

		function onLinksChanged() {
			tellSoon.restart();
		}

		function onEventReceived(event) {
			root.received(event);
		}
	}

	Timer {
		id: tellSoon

		interval: 400
		onTriggered: {
			if (!WebLink.connected) return;
			const config = JSON.parse(root.pageConfig);
			for (const source of Object.keys(WebLink.links)) WebLink.command("attention", config, null, source);
		}
	}

	function received(event) {
		switch (event.name) {
		case "codeField":
			if (!root.codesOn) return;
			root.field = { source: event.source, tabId: event.tabId, frameId: event.frameId || 0, at: Date.now() };
			root.offer();
			return;
		case "codeUsed":
			root.field = null;
			return;
		case "timer":
			if (root.timersOn) root.startTimer(event);
			return;
		case "timerCancel":
			root.dropTimer(String(event.id || ""), false);
			return;
		}
	}

	// ── one-time codes ────────────────────────────────────────────────────
	// [{ code, from, at }] newest first, never written anywhere
	property var codes: []
	// the code field that had the focus last: { source, tabId, frameId, at }
	property var field: null

	// the code a message is about, if it is about one (as Identities.code)
	function codeIn(text) {
		const value = String(text || "");
		if (!/code|kode|pin\b|otp|tan\b|verif|bestätig|confirm|passw|sicherheit|security/i.test(value)) return "";
		const match = value.match(/(?:^|[^\w.,:\/-])(\d{3}[ -]\d{3}|\d{4,8})(?![\w\/-])/);
		return match ? match[1].replace(/[ -]/g, "") : "";
	}

	function addCode(code, from, at) {
		if (!root.codesOn || code === "") return;
		const when = at > 0 ? (at < 1e12 ? at * 1000 : at) : Date.now();
		const now = Date.now();
		if (now - when > 600000) return;
		if (root.codes.some(entry => entry.code === code)) return;
		root.codes = [{ code: code, from: String(from || ""), at: when }].concat(root.codes.filter(entry => now - entry.at < 600000)).slice(0, 6);
		if (root.field && now - root.field.at < 300000) root.offer();
	}

	function ago(at) {
		const minutes = Math.floor((Date.now() - at) / 60000);
		return minutes < 1 ? "now" : `${minutes} min`;
	}

	function offer() {
		const field = root.field;
		const now = Date.now();
		const fresh = root.codes.filter(entry => now - entry.at < 600000);
		if (!field || fresh.length === 0) return;
		WebLink.command("codes", {
			tabId: field.tabId,
			frameId: field.frameId,
			codes: fresh.slice(0, 3).map(entry => ({ code: entry.code, from: entry.from, ago: root.ago(entry.at) }))
		}, null, field.source);
	}

	Timer {
		interval: 60000
		repeat: true
		running: root.codes.length > 0
		onTriggered: {
			const now = Date.now();
			root.codes = root.codes.filter(entry => now - entry.at < 600000);
			if (root.field && now - root.field.at > 300000) root.field = null;
		}
	}

	// the phone's SMS and notifications
	Connections {
		target: root.codesOn && Plugins.on("phone") ? Phone : null

		function onEvent(topic, name, data, device) {
			if (topic !== "phone.notifications" || name !== "posted" || data?.update) return;
			root.addCode(root.codeIn(`${data.title || ""} ${data.text || ""}`), String(data.app || data.title || "Phone"), 0);
		}
	}

	// the mailbox
	Connections {
		target: root.codesOn && Plugins.on("messages") && Plugins.on("mail") ? Mail : null

		function onIncoming(mail) {
			root.addCode(root.codeIn(`${mail?.subject || ""} ${mail?.preview || ""}`), String(mail?.name || mail?.email || "Mail"), 0);
		}
	}

	// the made-up identities' inboxes
	Connections {
		target: root.codesOn && Plugins.on("identities") ? Identities : null

		function onIdentitiesChanged() {
			const now = Date.now();
			for (const identity of Identities.identities) {
				for (const message of identity.mail?.messages ?? []) {
					if (now - Number(message.at || 0) < 600000) root.addCode(root.codeIn(`${message.subject || ""} ${message.text || ""}`), message.from || message.address || "Mail", Number(message.at));
				}
				for (const message of identity.phone?.messages ?? []) {
					if (now - Number(message.at || 0) < 600000) root.addCode(root.codeIn(message.text), message.from || "SMS", Number(message.at));
				}
			}
		}
	}

	// ── timers from recipe pages ──────────────────────────────────────────
	// [{ id, label, title, seconds, end, source, tabId }]
	property var timers: []
	property real now: Date.now()

	function clock(seconds) {
		const s = Math.max(0, Math.round(seconds));
		const h = Math.floor(s / 3600);
		const m = Math.floor((s % 3600) / 60);
		const rest = String(s % 60).padStart(2, "0");
		return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${rest}` : `${m}:${rest}`;
	}

	function startTimer(event) {
		const seconds = Math.max(1, Math.round(Number(event.seconds) || 0));
		const timer = {
			id: String(event.id || `t${Date.now()}`),
			label: String(event.label || "").trim() || root.clock(seconds),
			title: String(event.title || ""),
			seconds: seconds,
			end: Date.now() + seconds * 1000,
			source: event.source,
			tabId: event.tabId
		};
		root.timers = root.timers.filter(each => each.id !== timer.id).concat([timer]);
		root.provide();
		Notifs.pushInternal("running", `Timer ${root.clock(seconds)}`, timer.label, {
			icon: "timer_outline",
			app: "Timer",
			actions: [{ label: "Cancel", icon: "close", run: () => root.dropTimer(timer.id, true) }]
		});
	}

	function dropTimer(id, tellPage) {
		const timer = root.timers.find(each => each.id === id);
		if (!timer) return;
		root.timers = root.timers.filter(each => each.id !== id);
		root.provide();
		if (tellPage) WebLink.command("timerGone", { tabId: timer.tabId, id: id }, null, timer.source);
	}

	function ring(timer) {
		root.dropTimer(timer.id, true);
		Reminders.fire("timer", {
			key: timer.id,
			title: "Time's up",
			body: timer.label,
			icon: "timer_outline",
			post: () => Notifs.pushInternal("done", "Time's up", timer.label, { icon: "timer_outline", app: "Timer", sound: "reminder", duration: 60000 })
		});
		// the watch: a notification, which vibrates
		Reminders.buzz("Time's up", timer.label);
	}

	function provide() {
		Reminders.provide("timer", root.timers.map(timer => ({ key: timer.id, title: timer.label, at: Math.floor(timer.end / 1000), icon: "timer_outline", detail: timer.title })));
	}

	Timer {
		interval: 1000
		repeat: true
		running: root.timers.length > 0
		onTriggered: {
			root.now = Date.now();
			for (const timer of root.timers.slice())
				if (timer.end <= root.now) root.ring(timer);
		}
	}

	// ── the scroll brake ──────────────────────────────────────────────────
	// { pattern, seconds, last, next } of the stretch on one of the sites
	property var stretch: null

	// the entry of the list a page belongs to ("reddit.com", "youtube.com/shorts")
	function siteOf(host, path) {
		const plain = String(host || "").replace(/^www\./, "").toLowerCase();
		const page = `${plain}${path || "/"}`.toLowerCase();
		for (const entry of root.brakeSites) {
			const pattern = String(entry).trim().replace(/^https?:\/\//, "").replace(/^www\./, "").replace(/\/+$/, "").toLowerCase();
			if (pattern === "") continue;
			if (pattern.includes("/")) {
				const site = pattern.split("/")[0];
				const rest = pattern.slice(site.length);
				if ((plain === site || plain.endsWith(`.${site}`)) && page.slice(page.indexOf("/")).startsWith(rest)) return pattern;
			} else if (plain === pattern || plain.endsWith(`.${pattern}`)) {
				return pattern;
			}
		}
		return "";
	}

	// seconds today on it
	function todayOn(pattern) {
		const day = Screentime.day(Screentime.today);
		let seconds = 0;
		if (pattern.includes("/")) {
			for (const page of Object.keys(day.pages || {}))
				if (root.siteOf(page.split("/")[0], page.slice(page.indexOf("/"))) === pattern) seconds += Number(day.pages[page][0]) || 0;
		} else {
			for (const host of Object.keys(day.links || {}))
				if (host === pattern || host.endsWith(`.${pattern}`)) seconds += Number(day.links[host]) || 0;
		}
		return seconds;
	}

	function siteName(pattern) {
		const parts = pattern.split("/").filter(part => part !== "");
		const word = parts.length > 1 ? parts[parts.length - 1] : parts[0].replace(/\.[a-z]+$/, "");
		return word.charAt(0).toUpperCase() + word.slice(1);
	}

	function brakeTick() {
		if (!root.brakeOn) return;
		const now = Date.now();
		const window = Niri.windows.find(each => each.is_focused);
		const tab = window && /floorp|firefox|librewolf|zen|waterfox/i.test(String(window.app_id || "")) ? Screentime.tabFor(String(window.title || "")) : null;
		const pattern = tab ? root.siteOf(tab.host, tab.path) : "";
		if (pattern === "") return;
		let stretch = root.stretch;
		// another site, or away for a few minutes: a new stretch
		if (!stretch || stretch.pattern !== pattern || now - stretch.last > 180000) stretch = { pattern: pattern, seconds: 0, last: now, next: root.brakeMinutes * 60 };
		stretch.seconds += Math.min(20, Math.max(0, (now - stretch.last) / 1000));
		stretch.last = now;
		if (stretch.seconds >= stretch.next) {
			stretch.next += root.brakeMinutes * 60;
			root.hint(pattern);
		}
		root.stretch = stretch;
	}

	function hint(pattern) {
		const text = `${root.siteName(pattern)} · ${Screentime.format(root.todayOn(pattern))} today`;
		const tab = WebLink.activeTab;
		const fallback = () => Notifs.pushInternal("running", text, "", { icon: "timer_sand", app: "Screen time", duration: 6000 });
		if (!tab) return fallback();
		WebLink.command("brake", { tabId: tab.id, text: text }, (ok, data) => {
			if (!ok || data !== true) fallback();
		}, tab.source);
	}

	Connections {
		target: root.brakeOn ? Screentime : null

		function onStampChanged() {
			root.brakeTick();
		}
	}

	// ── settings ──────────────────────────────────────────────────────────
	function setBrake(minutes, sites) {
		if (minutes !== undefined && minutes !== null) root.brakeMinutes = Math.max(5, Math.min(120, Math.round(minutes)));
		if (Array.isArray(sites)) root.brakeSites = sites.map(site => String(site).trim()).filter(site => site !== "");
		file.setText(JSON.stringify({ brake: { minutes: root.brakeMinutes, sites: root.brakeSites } }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("browser-assist.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				if (data.brake?.minutes) root.brakeMinutes = Math.max(5, Math.min(120, Number(data.brake.minutes)));
				if (Array.isArray(data.brake?.sites)) root.brakeSites = data.brake.sites.map(String);
			} catch (error) {}
		}
	}
}
