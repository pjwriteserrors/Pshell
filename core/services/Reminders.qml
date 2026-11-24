pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// One reminder system (docs/reminders.md). Own reminders live in pshell-core
// (/api/reminders, through Netcore.call), their due moments come as
// `core:reminder` events and are shown by their level: quiet (list only),
// normal (toast), important (toast that stays), fullscreen (overlay on every
// screen, plugin `reminder-alert`). The shell's other reminders (Breaks,
// Updates, the calendars, expenses, the watch) go through `fire(source, …)`
// and take the level chosen for their source; `normal` is what they did
// before (their own `post`). `provide(source, items)` lists what is ahead.
//
// The list is kept in reminders.json, so a due own reminder still fires
// while core is away (once per id and occurrence); acks done meanwhile are
// sent when it is back. Unlocking or coming back after five idle minutes,
// the qtrack timer stopping and a game ending fire the reminders armed for
// that (POST /fire).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("reminders")
	readonly property bool alerting: root.enabled && Plugins.on("reminder-alert")
	readonly property bool online: root.enabled && root.built && Netcore.online

	readonly property var levelIds: ["quiet", "normal", "important", "fullscreen"]
	readonly property var sourceIds: ["own", "calendar", "ms-calendar", "expenses", "washer", "breaks", "updates", "invoice", "watch", "server", "pages", "prices", "parcels", "gifts"]

	// own reminders as core has them: { id, title, note, at, all_day, repeat,
	// level, escalate_min, trigger, state, snoozed_until, next, pending, … }
	property var reminders: []
	// source → level; a missing one is normal
	property var levels: ({})
	// what core itself knows for the next days: { source, key, title, at, level, url? }
	property var coreSources: []
	// source → [{ key, title, at, detail?, icon? }] from the shell's services
	property var provided: ({})
	// what fired and was not done yet: { uid, id, source, key, title, body,
	// icon, level, occurrence, escalated, actions, done, toast }
	property var alerts: []
	// `${id}@${occurrence}` → when it showed (ms): nothing shows twice
	property var shown: ({})
	// acks done while core was away: [{ id, occurrence }]
	property var pendingAcks: []
	property bool levelsDirty: false
	property bool loaded: false
	property string error: ""
	property real now: Date.now()
	property bool built: false

	// ── derived ────────────────────────────────────────────────────────────
	readonly property var screenAlerts: root.alerts.filter(alert => alert.level === "fullscreen")
	readonly property int pendingCount: root.alerts.length
	// own and source items in one list, by time: { kind, uid, id?, source, key,
	// title, detail, at (s), level, trigger, repeat, pending, reminder? }
	readonly property var items: {
		const out = [];
		const seen = {};
		for (const rem of root.reminders) {
			if (rem.state === "done") continue;
			out.push({
				kind: "own",
				uid: `rm:${rem.id}`,
				id: rem.id,
				source: "own",
				key: rem.id,
				title: String(rem.title ?? ""),
				detail: String(rem.note ?? ""),
				at: rem.next ?? null,
				level: String(rem.level || root.levelOf("own")),
				trigger: String(rem.trigger || "time"),
				repeat: rem.repeat ?? null,
				pending: (rem.pending ?? []).length > 0 || root.alerts.some(alert => alert.id === rem.id),
				reminder: rem
			});
		}
		let sources = root.coreSources;
		for (const source of Object.keys(root.provided))
			sources = sources.concat(root.provided[source].map(item => Object.assign({ source: source }, item)));
		for (const item of sources) {
			const at = Number(item.at) || null;
			const twin = `${item.source === "ms-calendar" ? "calendar" : item.source}|${item.title}|${at ? Math.round(at / 60) : ""}`;
			if (seen[twin]) continue;
			seen[twin] = true;
			out.push({
				kind: "source",
				uid: `${item.source}:${item.key ?? item.title}`,
				source: String(item.source),
				key: String(item.key ?? ""),
				title: String(item.title ?? ""),
				detail: String(item.detail ?? item.body ?? ""),
				icon: item.icon ?? "",
				url: item.url ?? "",
				at: at,
				level: root.levelOf(item.source),
				trigger: "time",
				repeat: null,
				pending: root.alerts.some(alert => alert.uid === `${item.source}:${item.key ?? item.title}`)
			});
		}
		return out.sort((a, b) => (b.pending - a.pending) || ((a.at ?? Infinity) - (b.at ?? Infinity)));
	}
	// the next own or source reminder still ahead
	readonly property var next: root.items.find(item => item.at && item.at * 1000 > root.now) ?? null

	// ── names and glyphs ───────────────────────────────────────────────────
	function levelOf(source) {
		const level = String(root.levels[String(source)] ?? "normal");
		return root.levelIds.includes(level) ? level : "normal";
	}

	function levelName(level) {
		return ({ quiet: "Quiet", normal: "Normal", important: "Important", fullscreen: "Fullscreen" })[level] ?? "Normal";
	}

	function levelGlyph(level) {
		return ({ quiet: "bell_off_outline", normal: "bell_outline", important: "bell_ring_outline", fullscreen: "fullscreen" })[level] ?? "bell_outline";
	}

	function sourceName(source) {
		return ({ own: "Own", calendar: "Calendar", "ms-calendar": "Outlook", expenses: "Expenses", washer: "Washer", breaks: "Breaks", updates: "Updates", invoice: "Invoices", watch: "Watch", server: "Server", pages: "Watched pages", prices: "Wish prices", parcels: "Parcels", gifts: "Gift ideas" })[source] ?? String(source);
	}

	function sourceGlyph(source) {
		return ({ own: "bell_outline", calendar: "calendar_clock", "ms-calendar": "calendar_clock", expenses: "currency_eur", washer: "washing_machine", breaks: "human_handsup", updates: "package_up", invoice: "file_document_outline", watch: "watch", server: "server", pages: "eye_outline", prices: "tag_outline", parcels: "package_variant_closed", gifts: "gift_outline" })[source] ?? "bell_outline";
	}

	function triggerName(trigger) {
		return ({ unlock: "When back", leave_home: "Leaving home", arrive_home: "Coming home", washer_done: "Washer done", qtrack_stop: "Timer stops", game_end: "Game ends" })[trigger] ?? "";
	}

	function triggerGlyph(trigger) {
		return ({ unlock: "lock_open_outline", leave_home: "exit_to_app", arrive_home: "home_outline", washer_done: "washing_machine", qtrack_stop: "timer_outline", game_end: "gamepad_variant" })[trigger] ?? "bell_outline";
	}

	function repeatText(repeat) {
		if (!repeat || !repeat.every) return "";
		const n = Number(repeat.n) || 1;
		const unit = ({ day: ["daily", "days"], week: ["weekly", "weeks"], month: ["monthly", "months"], year: ["yearly", "years"] })[repeat.every] ?? ["", ""];
		if (repeat.every === "week" && Array.isArray(repeat.days) && repeat.days.length > 0) {
			const names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
			return `${n === 1 ? "every" : `every ${n} weeks`} ${repeat.days.map(day => names[day] ?? "").join(", ")}`;
		}
		return n === 1 ? unit[0] : `every ${n} ${unit[1]}`;
	}

	// "14:30", "Tomorrow 9:00", "Fri 18:00", "24. Dec 18:00"
	function whenText(at, allDay) {
		if (!at) return "";
		const date = new Date(Number(at) * 1000);
		const today = new Date(root.now);
		today.setHours(0, 0, 0, 0);
		const day = Math.floor((new Date(date.getFullYear(), date.getMonth(), date.getDate()) - today) / 86400000);
		const time = allDay ? "" : Qt.formatTime(date, "HH:mm");
		const name = day === 0 ? (allDay ? "Today" : "") : day === 1 ? "Tomorrow" : day === -1 ? "Yesterday" : day > 1 && day < 7 ? Qt.formatDate(date, "ddd") : Qt.formatDate(date, date.getFullYear() === today.getFullYear() ? "d. MMM" : "d. MMM yyyy");
		return [name, time].filter(s => s).join(" ");
	}

	function itemText(item) {
		const parts = [];
		if (item.trigger && item.trigger !== "time") parts.push(root.triggerName(item.trigger));
		else if (item.at) parts.push(root.whenText(item.at, item.reminder?.all_day === true));
		const repeat = root.repeatText(item.repeat);
		if (repeat) parts.push(repeat);
		if (item.kind === "source") parts.push(root.sourceName(item.source));
		if (item.detail) parts.push(item.detail);
		return parts.join(" · ");
	}

	// ── the shell's own reminders ──────────────────────────────────────────
	// opts: { key, title, body, icon, actions: [{ label, icon, run }], post,
	// done }. `post` is what the source did before, run at level normal.
	function fire(source, opts) {
		const o = opts || {};
		const level = root.enabled ? root.levelOf(source) : "normal";
		if (level === "normal") {
			if (typeof o.post === "function") o.post();
			else Notifs.pushInternal("running", String(o.title ?? ""), String(o.body ?? ""), { icon: o.icon || root.sourceGlyph(source), sound: "reminder", duration: 20000, actions: o.actions ?? [], app: "Reminders" });
			return level;
		}
		root.raise({
			uid: `${source}:${o.key ?? o.title}`,
			id: "",
			source: String(source),
			key: String(o.key ?? ""),
			title: String(o.title ?? ""),
			body: String(o.body ?? ""),
			icon: o.icon || root.sourceGlyph(source),
			level: level,
			occurrence: Math.floor(Date.now() / 1000),
			escalated: false,
			actions: Array.isArray(o.actions) ? o.actions : [],
			done: typeof o.done === "function" ? o.done : null,
			again: o
		});
		return level;
	}

	// what is ahead for the list
	function provide(source, items) {
		const next = Object.assign({}, root.provided);
		if (Array.isArray(items) && items.length > 0) next[String(source)] = items;
		else delete next[String(source)];
		if (JSON.stringify(next[String(source)] ?? null) === JSON.stringify(root.provided[String(source)] ?? null)) return;
		root.provided = next;
	}

	// ── showing ────────────────────────────────────────────────────────────
	function raise(alert) {
		const old = root.alerts.find(each => each.uid === alert.uid);
		if (old?.toast) Notifs.removeToast(old.toast);
		let level = alert.level;
		if (level === "fullscreen" && !root.alerting) level = "important";
		const entry = Object.assign({}, alert, { level: level, toast: 0 });
		if (level === "normal" || level === "important") {
			const own = [{ label: "Done", icon: "check", run: () => root.done(entry.uid) }, { label: "5 min", icon: "timer_outline", run: () => root.snooze(entry.uid, 5) }];
			if (level === "important") own.push({ label: "1 h", icon: "timer_outline", run: () => root.snooze(entry.uid, 60) });
			entry.toast = Notifs.pushInternal("running", entry.title, entry.body, {
				icon: entry.icon,
				sound: "reminder",
				app: "Reminders",
				sticky: level === "important",
				duration: 30000,
				actions: entry.actions.map(action => ({ label: action.label, icon: action.icon, run: () => {
					action.run();
					root.drop(entry.uid);
				} })).concat(own)
			});
		}
		root.alerts = root.alerts.filter(each => each.uid !== alert.uid).concat([entry]);
		if (entry.escalated) root.buzz(entry.title, entry.body);
	}

	function drop(uid) {
		const alert = root.alerts.find(each => each.uid === uid);
		if (!alert) return;
		if (alert.toast) Notifs.removeToast(alert.toast);
		root.alerts = root.alerts.filter(each => each.uid !== uid);
	}

	// Done, from a toast, the overlay, the list or IPC: an own one is acked
	function done(uid) {
		const alert = root.alerts.find(each => each.uid === uid);
		const id = alert?.id || (String(uid).startsWith("rm:") ? String(uid).slice(3) : "");
		root.drop(uid);
		if (alert?.done) alert.done();
		if (id) root.ack(id, alert?.occurrence ?? null);
	}

	// minutes, or "back" (the next unlock or return)
	function snooze(uid, how) {
		const alert = root.alerts.find(each => each.uid === uid);
		const id = alert?.id || (String(uid).startsWith("rm:") ? String(uid).slice(3) : "");
		root.drop(uid);
		if (id) {
			root.forget(id);
			root.call("POST", `/api/reminders/${encodeURIComponent(id)}/snooze`, how === "back" ? { pc: true } : { minutes: Number(how) || 5 }, (data, error) => {
				if (error && alert) root.later(alert, how);
				else root.load();
			});
		} else if (alert) {
			root.later(alert, how);
		}
	}

	// snoozed while core cannot take it, or one of the shell's own
	property var waiting: []

	function later(alert, how) {
		root.waiting = root.waiting.concat([{ at: how === "back" ? 0 : Date.now() + (Number(how) || 5) * 60000, back: how === "back", alert: alert }]);
	}

	function wake(back) {
		const now = Date.now();
		const due = root.waiting.filter(entry => back ? entry.back : (!entry.back && entry.at <= now));
		if (due.length === 0) return;
		root.waiting = root.waiting.filter(entry => !due.includes(entry));
		for (const entry of due)
			root.raise(Object.assign({}, entry.alert, { occurrence: Math.floor(now / 1000) }));
	}

	// the watch buzzes for an escalated one
	property int buzzes: 0

	function buzz(title, body) {
		if (!Plugins.on("amazfit") || !Amazfit.zeppReady) return;
		root.buzzes += 1;
		Amazfit.send({ op: "notify", id: 2000000000 + root.buzzes % 100000, title: String(title), body: String(body), app: "dev.pshell", source: "Reminders", reply: false });
	}

	// ── the overlay: in the first pause of typing, like the eye rest ──────
	property bool overlayOpen: false
	property real overlayWaitSince: 0

	onScreenAlertsChanged: {
		if (root.screenAlerts.length === 0) {
			root.overlayOpen = false;
			root.overlayWaitSince = 0;
		} else if (!root.overlayOpen) {
			if (root.overlayWaitSince === 0) root.overlayWaitSince = Date.now();
			root.tryOverlay();
		}
	}

	function tryOverlay() {
		if (root.overlayOpen || root.screenAlerts.length === 0 || Session.locked) return;
		if (typingPause.isIdle || Date.now() - root.overlayWaitSince > 90000) {
			root.overlayOpen = true;
			root.overlayWaitSince = 0;
			Sounds.play("reminder");
		}
	}

	IdleMonitor {
		id: typingPause

		enabled: root.screenAlerts.length > 0 && !root.overlayOpen
		timeout: 2
		respectInhibitors: false
		onIsIdleChanged: if (isIdle) root.tryOverlay()
	}

	Timer {
		running: root.screenAlerts.length > 0 && !root.overlayOpen
		repeat: true
		interval: 3000
		onTriggered: root.tryOverlay()
	}

	// ── core ───────────────────────────────────────────────────────────────
	function call(method, path, body, done) {
		if (!root.online) {
			if (done) done(null, "Core not reachable", 0);
			return;
		}
		Netcore.call(method, path, body, done);
	}

	function load() {
		root.call("GET", "/api/reminders", null, (data, error) => {
			if (!data) {
				root.error = error;
				return;
			}
			root.error = "";
			root.reminders = Array.isArray(data.reminders) ? data.reminders : [];
			if (!root.levelsDirty && data.levels && typeof data.levels === "object") root.levels = data.levels;
			root.coreSources = Array.isArray(data.sources) ? data.sources : [];
			root.loaded = true;
			// what was acked elsewhere goes away here
			for (const alert of root.alerts) {
				if (!alert.id) continue;
				const rem = root.reminders.find(each => each.id === alert.id);
				if (!rem || rem.state === "done" || !(rem.pending ?? []).includes(alert.occurrence)) root.drop(alert.uid);
			}
			saveDelay.restart();
		});
	}

	// what fired while the shell or core was away
	function loadActive() {
		root.call("GET", "/api/reminders/active", null, data => {
			for (const entry of (data?.active ?? []))
				root.due(entry.reminder, Number(entry.occurrence), entry.escalated === true);
		});
	}

	// back in touch: what was done meanwhile goes up, then everything is fetched
	function reconnected() {
		if (!root.online) return;
		const acks = root.pendingAcks;
		root.pendingAcks = [];
		for (const ack of acks)
			Netcore.call("POST", `/api/reminders/${encodeURIComponent(ack.id)}/ack`, ack.occurrence ? { occurrence: ack.occurrence } : {}, () => {});
		if (root.levelsDirty) root.putLevels();
		root.load();
		root.loadActive();
	}

	function due(rem, occurrence, escalated) {
		if (!root.enabled || !rem?.id) return;
		const key = `${rem.id}@${occurrence}${escalated ? "!" : ""}`;
		if (root.shown[key]) return;
		const shown = Object.assign({}, root.shown);
		shown[key] = Date.now();
		root.shown = shown;
		saveDelay.restart();
		const trigger = String(rem.trigger || "time");
		// a reminder of a page (the browser, Watches): its address is a button, not text
		const url = /^https?:\/\//.test(String(rem.url || "")) ? String(rem.url) : "";
		const note = url ? String(rem.note || "").split("\n").filter(line => line.trim() !== url).join("\n") : String(rem.note || "");
		const source = String(rem.source || "own");
		root.raise({
			uid: `rm:${rem.id}`,
			id: rem.id,
			source: source,
			key: rem.id,
			title: String(rem.title ?? ""),
			body: String(note || (trigger !== "time" ? root.triggerName(trigger) : "")),
			icon: trigger !== "time" ? root.triggerGlyph(trigger) : (source !== "own" ? root.sourceGlyph(source) : "bell_ring_outline"),
			level: escalated ? "fullscreen" : String(rem.level || "normal"),
			occurrence: occurrence,
			escalated: escalated,
			actions: url ? [{ label: "Open", icon: "open_in_new", run: () => {
				if (WebLink.enabled && WebLink.connected) WebLink.open(url);
				else Browser.open(url);
				root.done(`rm:${rem.id}`);
			} }] : root.linkActions(rem.note),
			done: null
		});
	}

	// a reminder whose note is an address (the day review's "Later") opens it
	function linkActions(note) {
		const url = String(note || "").trim();
		if (!/^https?:\/\/\S+$/.test(url)) return [];
		return [{ label: "Open", icon: "open_in_new", run: () => Browser.openLink(url, "Reminders") }];
	}

	// done elsewhere (or here): it goes from the screen
	function cleared(id, occurrence) {
		for (const alert of root.alerts)
			if (alert.id === id && (occurrence === null || occurrence === undefined || Number(alert.occurrence) === Number(occurrence))) root.drop(alert.uid);
	}

	// snoozed: when it comes again it shows again
	function forget(id) {
		const shown = {};
		for (const key of Object.keys(root.shown))
			if (!key.startsWith(`${id}@`)) shown[key] = root.shown[key];
		root.shown = shown;
	}

	function ack(id, occurrence) {
		root.cleared(id, occurrence ?? null);
		const body = occurrence ? { occurrence: occurrence } : {};
		if (!root.online) {
			root.pendingAcks = root.pendingAcks.concat([{ id: id, occurrence: occurrence ?? null }]);
			saveDelay.restart();
			return;
		}
		Netcore.call("POST", `/api/reminders/${encodeURIComponent(id)}/ack`, body, (data, error) => {
			if (error) root.pendingAcks = root.pendingAcks.concat([{ id: id, occurrence: occurrence ?? null }]);
			root.load();
		});
	}

	// done(text) → { title, at, all_day, repeat, level, trigger } or null
	function parse(text, done) {
		root.call("POST", "/api/reminders/parse", { text: String(text) }, (data, error) => done(data && data.title !== undefined ? data : null, error));
	}

	function create(body, done) {
		root.call("POST", "/api/reminders", body, (data, error) => {
			if (error) Notifs.pushInternal("error", "Reminder not saved", error, { icon: "bell_outline", app: "Reminders" });
			else root.load();
			if (done) done(data, error);
		});
	}

	// typed text: parsed by core, then saved
	function add(text, done) {
		root.parse(text, (found, error) => {
			if (!found) {
				if (done) done(null, error || "Not understood");
				else Notifs.pushInternal("error", "Reminder not saved", error || String(text), { icon: "bell_outline", app: "Reminders" });
				return;
			}
			root.create(found, done);
		});
	}

	function update(id, patch, done) {
		root.call("PATCH", `/api/reminders/${encodeURIComponent(id)}`, patch, (data, error) => {
			root.load();
			if (done) done(data, error);
		});
	}

	function remove(id, done) {
		root.cleared(id, null);
		root.call("DELETE", `/api/reminders/${encodeURIComponent(id)}`, null, (data, error) => {
			root.load();
			if (done) done(data, error);
		});
	}

	function setLevel(source, level) {
		if (!root.levelIds.includes(level)) return;
		const next = Object.assign({}, root.levels);
		next[String(source)] = level;
		root.levels = next;
		root.levelsDirty = true;
		saveDelay.restart();
		root.putLevels();
	}

	function putLevels() {
		if (!root.online) return;
		Netcore.call("PUT", "/api/reminders/levels", root.levels, (data, error) => {
			if (error) return;
			root.levelsDirty = false;
			if (data && typeof data === "object" && !Array.isArray(data)) {
				const levels = data.levels && typeof data.levels === "object" ? data.levels : data;
				if (Object.keys(levels).length > 0) root.levels = levels;
			}
			saveDelay.restart();
		});
	}

	Connections {
		target: Nas
		enabled: root.enabled && root.built

		function onCoreEvent(message) {
			root.event(message);
		}
	}

	function event(message) {
		const type = String(message.type ?? String(message.event).slice(5));
		switch (type) {
		case "hello":
			reconnect.restart();
			break;
		case "link":
			if (message.linked) reconnect.restart();
			break;
		case "reminder":
			root.due(message.reminder, Number(message.occurrence), message.escalated === true);
			reload.restart();
			break;
		case "reminder_ack":
			root.cleared(message.id, message.occurrence ?? null);
			reload.restart();
			break;
		case "reminder_snooze":
			root.cleared(message.id, null);
			root.forget(message.id);
			reload.restart();
			break;
		case "reminders":
			reload.restart();
			break;
		}
	}

	onOnlineChanged: if (root.online) reconnect.restart()

	Timer {
		id: reconnect

		interval: 800
		onTriggered: root.reconnected()
	}

	Timer {
		id: reload

		interval: 400
		onTriggered: root.load()
	}

	// ── without core: due own reminders from the kept list ────────────────
	function checkOffline() {
		root.now = Date.now();
		root.wake(false);
		if (!root.enabled || root.online) return;
		const now = Date.now() / 1000;
		for (const rem of root.reminders) {
			if (rem.state === "done" || String(rem.trigger || "time") !== "time") continue;
			const at = Number(rem.next) || 0;
			if (at <= 0 || at > now || (Number(rem.snoozed_until) || 0) > now) continue;
			// only what came due recently: an old one core will tell about
			if (now - at > 86400) continue;
			root.due(rem, at, false);
		}
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: 15000
		triggeredOnStart: true
		onTriggered: root.checkOffline()
	}

	// ── triggers ───────────────────────────────────────────────────────────
	property real lastBack: 0

	function trigger(kind) {
		if (!root.enabled) return;
		if (kind === "unlock") {
			if (Date.now() - root.lastBack < 60000) return;
			root.lastBack = Date.now();
			root.wake(true);
			root.tryOverlay();
		}
		const armed = root.reminders.filter(rem => rem.state !== "done" && rem.trigger === kind);
		const local = () => {
			for (const rem of armed)
				root.due(rem, Math.floor(Date.now() / 1000), false);
		};
		// core fires every armed one of this trigger (its events show them)
		if (root.online) Netcore.call("POST", "/api/reminders/trigger", { trigger: kind }, (data, error) => {
			if (error) local();
		});
		else local();
	}

	Connections {
		target: Session
		enabled: root.enabled && root.built

		function onLockedChanged() {
			if (!Session.locked) root.trigger("unlock");
		}
	}

	IdleMonitor {
		id: away

		enabled: root.enabled
		timeout: 300
		respectInhibitors: false
		onIsIdleChanged: if (!isIdle) root.trigger("unlock")
	}

	property bool wasTracking: false
	property bool wasPlaying: false

	Connections {
		target: QtrackTimer
		enabled: root.enabled && root.built && Plugins.on("qtrack")

		function onTrackingChanged() {
			if (root.wasTracking && !QtrackTimer.tracking) root.trigger("qtrack_stop");
			root.wasTracking = QtrackTimer.tracking;
		}
	}

	Connections {
		target: GameMode
		enabled: root.enabled && root.built && Plugins.on("games")

		function onPlayingChanged() {
			if (root.wasPlaying && !GameMode.playing) root.trigger("game_end");
			root.wasPlaying = GameMode.playing;
		}
	}

	// ── what the shell's services have ahead ──────────────────────────────
	function collect() {
		if (!root.enabled) return;
		const now = Date.now();
		const nowS = Math.floor(now / 1000);
		const days = [new Date(now), new Date(now + 86400000)];
		if (Plugins.on("calendar") && MsCalendar.signedIn) {
			const out = [];
			for (const day of days)
				for (const event of MsCalendar.byDay[MsCalendar.dayKey(day)] ?? []) {
					const at = Math.floor(Date.parse(event.start) / 1000) - 300;
					if (!event.allDay && MsCalendar.active(event) && at > nowS) out.push({ key: `${event.id}@${event.start}`, title: String(event.subject ?? ""), at: at });
				}
			root.provide("ms-calendar", out);
		} else root.provide("ms-calendar", []);
		if (NasCalendar.active) {
			const out = [];
			for (const day of days)
				for (const event of NasCalendar.eventsOn(NasCalendar.dayKey(day))) {
					if (event.allDay || event.cancelled) continue;
					const at = Math.floor(Date.parse(event.start) / 1000) - (event.reminder >= 0 ? event.reminder : 5) * 60;
					if (at > nowS) out.push({ key: `${event.id}@${event.start}`, title: String(event.subject ?? ""), at: at });
				}
			root.provide("calendar", out);
		} else root.provide("calendar", []);
		if (Plugins.on("breaks") && Breaks.enabled) {
			const out = [];
			if (Plugins.on("stretch")) out.push({ key: "move", title: "Stretch", at: nowS + Math.max(0, Breaks.moveSeconds - Breaks.sinceMove), icon: "human_handsup" });
			if (Plugins.on("water")) out.push({ key: "water", title: "Drink something", at: nowS + Math.max(0, Breaks.waterSeconds - Breaks.sinceWater), icon: "cup_water" });
			if (Plugins.on("eye-rest")) out.push({ key: "eyes", title: "Rest your eyes", at: nowS + Math.max(0, Breaks.eyesSeconds - Breaks.sinceEyes), icon: "eye_outline" });
			root.provide("breaks", out);
		} else root.provide("breaks", []);
		if (Plugins.on("amazfit") && Amazfit.zeppReady) {
			const out = [];
			for (const alarm of Amazfit.zepp.alarms ?? []) {
				if (!alarm.enabled) continue;
				const at = root.nextAlarm(alarm.hour, alarm.minute, Number(alarm.repeat) & 0x7f, now);
				if (at > 0) out.push({ key: `alarm-${alarm.position}`, title: `Alarm ${String(alarm.hour).padStart(2, "0")}:${String(alarm.minute).padStart(2, "0")}`, at: at, icon: "alarm" });
			}
			for (const reminder of Amazfit.zepp.reminders ?? [])
				if (Number(reminder.time) > nowS) out.push({ key: `reminder-${reminder.position}`, title: String(reminder.text ?? ""), at: Number(reminder.time), icon: "watch" });
			root.provide("watch", out);
		} else root.provide("watch", []);
	}

	// the next time of a watch alarm: days a bit field from Monday (0: once)
	function nextAlarm(hour, minute, days, now) {
		for (let i = 0; i < 8; i += 1) {
			const date = new Date(now);
			date.setDate(date.getDate() + i);
			date.setHours(hour, minute, 0, 0);
			if (date.getTime() <= now) continue;
			if (days === 0 || (days & (1 << ((date.getDay() + 6) % 7)))) return Math.floor(date.getTime() / 1000);
		}
		return 0;
	}

	Timer {
		running: root.enabled && root.built
		repeat: true
		interval: 60000
		triggeredOnStart: true
		onTriggered: root.collect()
	}

	// ── kept between starts ────────────────────────────────────────────────
	function save() {
		const cut = Date.now() - 14 * 86400000;
		const shown = {};
		for (const key of Object.keys(root.shown))
			if (root.shown[key] >= cut) shown[key] = root.shown[key];
		store.setText(JSON.stringify({ reminders: root.reminders, levels: root.levels, levelsDirty: root.levelsDirty, sources: root.coreSources, shown: shown, pendingAcks: root.pendingAcks }, null, 1) + "\n");
	}

	Timer {
		id: saveDelay

		interval: 2000
		onTriggered: root.save()
	}

	FileView {
		id: store

		path: Paths.stateFile("reminders.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}")) || {};
				root.reminders = Array.isArray(data.reminders) ? data.reminders : [];
				root.levels = data.levels && typeof data.levels === "object" ? data.levels : {};
				root.levelsDirty = data.levelsDirty === true;
				root.coreSources = Array.isArray(data.sources) ? data.sources : [];
				root.shown = data.shown && typeof data.shown === "object" ? data.shown : {};
				root.pendingAcks = Array.isArray(data.pendingAcks) ? data.pendingAcks : [];
			} catch (error) {}
		}
	}

	// the other singletons are read only once this one stands (qml-singleton-cycles)
	Component.onCompleted: Qt.callLater(() => {
		root.built = true;
		root.wasTracking = Plugins.on("qtrack") && QtrackTimer.tracking;
		root.wasPlaying = Plugins.on("games") && GameMode.playing;
	})
}
