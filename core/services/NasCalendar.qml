pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Baikal calendar on netcore (plugin "nas-calendar", docs/nas.md): its
// events beside the Microsoft ones in the calendar (MsCalendar.eventsOn adds
// them). PROPFIND finds the calendars of the
// user, a REPORT with <expand> asks for the six weeks of a month grid with
// repeating events already unrolled by the server. Every request goes
// through scripts/nas/baikal.py (Baikal wants Digest), which also edits an
// event in place so what the phone (DAVx5) put in stays; `draft` is the
// event open in the editor of the calendar panel. The password stays in the
// keyring (secret-tool, service "pshell-baikal"), baikal.py looks it up;
// the URL and the user are kept in nas.json (`calendar`: { url, user }).
// With pshell-core (Netcore) the account comes from there: core makes one
// for every member and hands its password to the member's devices
// (docs/core.md "Calendar"); calendars are shared with other members by
// CalDAV sharing, sharees addressed by the e-mail core gives them. Events
// remind like the Microsoft ones (MsCalendar.remind): at their own alarm,
// else 5 minutes before.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("nas-calendar")
	readonly property var config: root.enabled ? (Nas.local.calendar ?? ({})) : ({})
	readonly property string url: String(root.config.url || "http://192.168.178.22:8082/dav.php").replace(/\/+$/, "")
	readonly property string user: String(root.config.user || "")
	readonly property bool active: root.enabled && root.user !== "" && root.hasPassword

	property bool hasPassword: false
	property bool looked: false
	property string error: ""
	// [{ href, name, color, access: "" | owner | read | write }]; owner: shared by me, read/write: shared with me
	property var calendars: []
	readonly property var writable: root.calendars.filter(c => c.access !== "read")
	// core has an account for this member it has no password for: give it once
	property bool coreNeedsPassword: false
	// the members of core to share with: [{ name, email, display }]
	property var members: []
	// calendar href → { sharees: [{ email, write }], owner }
	property var shares: ({})
	property var reminded: ({})
	// the event in the editor: { href?, etag?, calendar, title, location,
	// notes, allDay, start, end, repeat, reminder } (baikal.py's fields)
	property var draft: null
	property bool saving: false
	// "YYYY-MM-DD" → [event]; loaded grid windows by their first day
	property var byDay: ({})
	property var loaded: ({})
	property var queue: []
	readonly property bool loading: root.busy > 0
	property int busy: 0
	property real fetchedAt: 0

	function dayKey(date) {
		return Qt.formatDate(date, "yyyy-MM-dd");
	}

	// with the birthdays of the address book (Contacts)
	function eventsOn(key) {
		const own = root.byDay[key] ?? [];
		const birthdays = Contacts.list.length > 0 ? Contacts.birthdaysOn(key) : [];
		return birthdays.length > 0 ? birthdays.concat(own) : own;
	}

	// ── the account ──────────────────────────────────────────────────────
	function setAccount(url, user) {
		Nas.setLocal("calendar", Object.assign({}, root.config, { url: String(url).trim(), user: String(user).trim() }));
		root.reset();
		Qt.callLater(root.lookForPassword);
	}

	function setPassword(password, done) {
		if (root.user === "") return done ? done("Set the user first") : undefined;
		const proc = storer.createObject(root, { done: done, input: String(password) });
		proc.command = ["secret-tool", "store", "--label=Baikal calendar (pshell)", "service", "pshell-baikal", "user", root.user];
		proc.running = true;
	}

	Component {
		id: storer

		Process {
			id: proc

			property var done: null
			property string input: ""
			stdinEnabled: true
			onStarted: {
				proc.write(proc.input);
				proc.stdinEnabled = false;
			}
			onExited: code => {
				if (code === 0) {
					// the same password for core too, so the phone gets the calendar from there
					if (root.coreNeedsPassword && proc.input !== "") root.giveCorePassword(proc.input);
					root.hasPassword = true;
					root.reset();
					root.ensure(new Date());
				}
				if (proc.done) proc.done(code === 0 ? "" : "The keyring did not take it");
				proc.destroy();
			}
		}
	}

	function lookForPassword() {
		if (!root.enabled || root.user === "") {
			root.hasPassword = false;
			return;
		}
		lookup.command = ["sh", "-c", 'secret-tool lookup service pshell-baikal user "$1" >/dev/null', "sh", root.user];
		lookup.running = true;
	}

	Process {
		id: lookup

		onExited: code => {
			root.hasPassword = code === 0;
			root.looked = true;
			if (root.hasPassword) root.ensure(new Date());
			else root.fromCore();
		}
	}

	// ── the account from pshell-core ─────────────────────────────────────
	function fromCore() {
		if (!root.enabled || !Netcore.active || root.hasPassword) return;
		Netcore.call("GET", "/api/calendar/account", null, (data, error) => {
			if (error || !data) return;
			root.coreNeedsPassword = data.need === "password";
			const url = root.config.url || data.url;
			if (data.user !== root.user || url !== root.config.url) {
				Nas.setLocal("calendar", Object.assign({}, root.config, { url: String(url).replace(/\/+$/, ""), user: data.user }));
				root.reset();
			}
			if (data.password) Qt.callLater(() => root.setPassword(data.password));
		});
	}

	// the password of an account core did not make, given once: core checks and keeps it
	function giveCorePassword(password, done) {
		Netcore.call("POST", "/api/calendar/account", { password: password }, (data, error) => {
			if (error) return done ? done(error) : undefined;
			root.coreNeedsPassword = false;
			root.setPassword(password, done);
		});
	}

	Connections {
		target: Netcore

		function onActiveChanged() {
			if (Netcore.active && root.looked && !root.hasPassword) root.fromCore();
		}
	}

	onEnabledChanged: if (root.enabled) Qt.callLater(root.lookForPassword)
	onUserChanged: Qt.callLater(root.lookForPassword)
	Component.onCompleted: if (root.enabled) Qt.callLater(root.lookForPassword)

	function reset() {
		root.calendars = [];
		root.byDay = {};
		root.loaded = {};
		root.queue = [];
		root.error = "";
	}

	function refresh() {
		if (!root.active) return;
		const keys = Object.keys(root.loaded);
		root.calendars = [];
		root.loaded = {};
		root.queue = keys;
		root.ensure(new Date());
	}

	// ── loading, a month grid at a time ──────────────────────────────────
	function gridStart(month) {
		const first = new Date(month.getFullYear(), month.getMonth(), 1);
		return new Date(first.getFullYear(), first.getMonth(), 1 - (first.getDay() + 6) % 7);
	}

	function ensure(month) {
		if (!root.active) return;
		const key = root.dayKey(root.gridStart(month));
		if (root.loaded[key] || root.queue.includes(key)) return root.next();
		root.queue = root.queue.concat([key]);
		root.next();
	}

	function next() {
		if (root.busy > 0 || root.queue.length === 0 || !root.active) return;
		if (root.calendars.length === 0) return root.discover();
		const key = root.queue[0];
		root.queue = root.queue.slice(1);
		const start = new Date(`${key}T00:00:00`);
		const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 42);
		const range = `start="${root.utc(start)}" end="${root.utc(end)}"`;
		const body = `<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data><c:expand ${range}/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range ${range}/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
		const found = [];
		let left = root.calendars.length;
		for (const calendar of root.calendars) {
			root.ask(root.absolute(calendar.href), "REPORT", "1", body, (text, error) => {
				if (!error) for (const event of root.parseEvents(text, calendar)) found.push(event);
				else root.error = error;
				left -= 1;
				if (left === 0) {
					root.apply(key, start, end, found);
					root.next();
				}
			});
		}
	}

	// the calendars of the user
	function discover() {
		const body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><d:share-access/></d:prop></d:propfind>';
		root.ask(`${root.url}/calendars/${encodeURIComponent(root.user)}/`, "PROPFIND", "1", body, (text, error) => {
			if (error) {
				root.error = error;
				root.queue = [];
				return;
			}
			const out = [];
			for (const response of root.elements(text, "response")) {
				if (!/<(?:[\w-]+:)?calendar\s*\/>/.test(response)) continue;
				const href = root.first(response, "href");
				if (href === "") continue;
				const access = root.first(response, "share-access");
				out.push({
					href: href,
					name: root.decode(root.first(response, "displayname")) || decodeURIComponent(href.split("/").filter(p => p).pop() ?? ""),
					color: root.first(response, "calendar-color").slice(0, 7),
					access: /read-write/.test(access) ? "write" : (/<(?:[\w-]+:)?read\s*\/>/.test(access) ? "read" : (/shared-owner/.test(access) ? "owner" : ""))
				});
			}
			out.sort((a, b) => a.name.localeCompare(b.name));
			if (out.length === 0) {
				root.error = "No calendar found for this user";
				root.queue = [];
				return;
			}
			root.error = "";
			root.calendars = out;
			root.next();
		});
	}

	function apply(key, start, end, events) {
		const days = Object.assign({}, root.byDay);
		for (let d = new Date(start); d < end; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) delete days[root.dayKey(d)];
		const from = root.dayKey(start);
		const to = root.dayKey(end);
		for (const event of events) {
			for (const day of event.days) {
				if (day < from || day >= to) continue;
				days[day] = (days[day] ?? []).filter(other => other.id !== event.id).concat([event]);
			}
		}
		for (const day of Object.keys(days)) days[day].sort((a, b) => (b.allDay - a.allDay) || (Date.parse(a.start) - Date.parse(b.start)));
		root.byDay = days;
		const loaded = Object.assign({}, root.loaded);
		loaded[key] = true;
		root.loaded = loaded;
		root.fetchedAt = Date.now();
	}

	// ── writing, through baikal.py ───────────────────────────────────────
	function write(op, request, done) {
		const proc = writer.createObject(root, { done: done ?? null, input: JSON.stringify(request) });
		proc.command = ["python3", `${Quickshell.shellDir}/scripts/nas/baikal.py`, op, root.url, root.user];
		proc.running = true;
	}

	Component {
		id: writer

		Process {
			id: proc

			property var done: null
			property string input: ""
			stdinEnabled: true
			stdout: StdioCollector {
				id: out
			}
			onStarted: {
				proc.write(proc.input);
				proc.stdinEnabled = false;
			}
			onExited: code => {
				let reply = {};
				try {
					reply = JSON.parse(out.text);
				} catch (e) {
					reply = { error: `baikal.py failed (${code})` };
				}
				Qt.callLater(() => {
					if (proc.done) proc.done(reply);
					proc.destroy();
				});
			}
		}
	}

	function failed(reply) {
		if (!reply.error) return false;
		Notifs.pushInternal("error", "Baikal", reply.error, { icon: "calendar_month" });
		return true;
	}

	function createCalendar(name, color, done) {
		root.write("mkcal", { name: name, color: color }, reply => {
			if (!root.failed(reply)) root.refresh();
			if (done) done(reply);
		});
	}

	function changeCalendar(href, change) {
		root.write("setcal", Object.assign({ href: href }, change), reply => {
			if (!root.failed(reply)) root.refresh();
		});
	}

	function deleteCalendar(href) {
		root.write("delcal", { href: href }, reply => {
			if (!root.failed(reply)) root.refresh();
		});
	}

	function pad(n) {
		return String(n).padStart(2, "0");
	}

	function wallTime(date) {
		return `${root.dayKey(date)}T${root.pad(date.getHours())}:${root.pad(date.getMinutes())}`;
	}

	// a new event on a day: the next full hour of today, or 9:00
	function newEvent(day) {
		const now = new Date();
		const today = root.dayKey(day) === root.dayKey(now);
		const start = new Date(day.getFullYear(), day.getMonth(), day.getDate(), today ? Math.min(23, now.getHours() + 1) : 9, 0);
		root.draft = {
			calendar: root.defaultCalendar(),
			title: "",
			location: "",
			notes: "",
			allDay: false,
			start: root.wallTime(start),
			end: root.wallTime(new Date(start.getTime() + 3600000)),
			repeat: "",
			reminder: -1
		};
	}

	// an event of the panel into the editor: its series as the server has it
	function editEvent(event) {
		root.saving = true;
		root.write("get", { href: event.href }, reply => {
			root.saving = false;
			if (root.failed(reply)) return;
			root.draft = Object.assign({}, reply.event, { href: event.href, etag: reply.etag, calendar: event.calendarHref, subject: event.subject });
		});
	}

	function saveDraft(fields) {
		const request = Object.assign({}, root.draft, fields);
		root.saving = true;
		root.write("save", request, reply => {
			root.saving = false;
			if (root.failed(reply)) return;
			if (!request.href) Nas.setLocal("calendar", Object.assign({}, root.config, { lastCalendar: request.calendar }));
			root.draft = null;
			MsCalendar.selected = null;
			root.refresh();
		});
	}

	function deleteEvent(event) {
		root.saving = true;
		root.write("delete", { href: event.href, etag: event.etag ?? "" }, reply => {
			root.saving = false;
			if (root.failed(reply)) return;
			root.draft = null;
			if (MsCalendar.selected?.href === event.href) MsCalendar.selected = null;
			root.refresh();
		});
	}

	// ── sharing with the members of core ─────────────────────────────────
	function loadMembers() {
		if (!Netcore.active) return;
		Netcore.call("GET", "/api/calendar/members", null, (data, error) => {
			if (!error && data) root.members = (data.members ?? []).filter(m => m.name !== root.user);
		});
	}

	function loadShares(href) {
		root.write("sharees", { href: href }, reply => {
			if (reply.error) return;
			const shares = Object.assign({}, root.shares);
			shares[href] = { sharees: reply.sharees ?? [], owner: reply.owner ?? "" };
			root.shares = shares;
		});
	}

	// mode: "" (not shared), "read" or "write"
	function share(href, member, mode) {
		const request = { href: href, set: [], remove: [] };
		if (mode === "") request.remove.push(member.email);
		else request.set.push({ email: member.email, name: member.display || member.name, write: mode === "write" });
		root.write("share", request, reply => {
			if (root.failed(reply)) return;
			root.loadShares(href);
			root.refresh();
		});
	}

	// ── copies: core keeps one every night, the PC takes the newest ───────
	// { kept, folder, count } of the last pull, or { error }
	property var copy: ({})

	function pullCopy() {
		if (!Netcore.active) return;
		Nas.call("corebaikal", {}, (data, error) => {
			root.copy = error ? { error: error } : (data?.error ? { error: data.error } : (data ?? {}));
		});
	}

	Timer {
		running: root.active && Netcore.active
		repeat: true
		interval: 6 * 3600000
		triggeredOnStart: true
		onTriggered: root.pullCopy()
	}

	// ── reminders: at the event's alarm, else 5 minutes before ────────────
	function remindDue() {
		if (!root.active) return;
		const now = Date.now();
		for (const event of root.eventsOn(root.dayKey(new Date(now)))) {
			if (event.allDay || event.cancelled) continue;
			const key = `${event.id}@${event.start}`;
			const lead = Date.parse(event.start) - now;
			const before = (event.reminder >= 0 ? event.reminder : 5) * 60000;
			if (lead > 0 && lead <= Math.max(before, 60000) && !root.reminded[key]) {
				const reminded = Object.assign({}, root.reminded);
				reminded[key] = true;
				root.reminded = reminded;
				MsCalendar.remind(event, lead, "calendar");
			}
		}
	}

	Timer {
		running: root.active
		repeat: true
		interval: 20000
		triggeredOnStart: true
		onTriggered: root.remindDue()
	}

	// ── .ics files and text into the calendar ────────────────────────────
	// done(reply): { ok, count } or { error }
	function importIcs(path, calendar, done) {
		root.write("import", { path: String(path).replace(/^file:\/\//, ""), calendar: calendar || root.defaultCalendar() }, reply => {
			if (!root.failed(reply)) root.refresh();
			if (done) done(reply);
		});
	}

	// an .ics attached to a mail: the mail daemon puts it on disk, then it is imported
	property var pendingAttachments: ({})

	function importMailAttachment(chat, message, attachment) {
		const request = Math.floor(Math.random() * 1000000000);
		const pending = Object.assign({}, root.pendingAttachments);
		pending[request] = true;
		root.pendingAttachments = pending;
		Mail.attachmentPath(chat, message, attachment, request);
	}

	Connections {
		target: Mail

		function onFileReady(request, path) {
			if (!root.pendingAttachments[request]) return;
			const pending = Object.assign({}, root.pendingAttachments);
			delete pending[request];
			root.pendingAttachments = pending;
			root.importIcs(path, "", reply => {
				if (!reply.error) Notifs.pushInternal("done", reply.count > 0 ? `${reply.count} added to the calendar` : "Already in the calendar", String(path).split("/").pop(), { icon: "calendar_check", app: "Calendar" });
			});
		}
	}

	function defaultCalendar() {
		const last = root.config.lastCalendar;
		return (root.writable.find(c => c.href === last) ?? root.writable[0])?.href ?? "";
	}

	// the editor below the Today panel, filled from a text (a PDF selection, a mail)
	function draftFrom(text, title) {
		// a long text (a PDF page, a mail) gives the date; its first line the title
		if (!title && String(text).length > 90) title = String(text).trim().split(/\n|\. /)[0].slice(0, 70);
		const found = root.parseText(text, new Date());
		root.draft = {
			calendar: root.defaultCalendar(),
			title: title || found.title,
			location: found.location,
			notes: title ? String(text).slice(0, 2000) : "",
			allDay: found.allDay,
			start: found.allDay ? root.dayKey(found.start) : root.wallTime(found.start),
			end: found.allDay ? root.dayKey(new Date(found.end.getFullYear(), found.end.getMonth(), found.end.getDate())) : root.wallTime(found.end),
			repeat: found.repeat,
			reminder: -1
		};
		MsCalendar.selected = null;
		Popups.withFocusedScreen(screen => Popups.open("today", screen));
	}

	// a parsed text straight into the calendar (the launcher's >cal)
	function addParsed(found, done) {
		if (!found.title) return done ? done({ error: "No title" }) : undefined;
		const end = found.allDay ? new Date(found.end.getFullYear(), found.end.getMonth(), found.end.getDate()) : found.end;
		const calendar = root.defaultCalendar();
		root.write("save", {
			calendar: calendar,
			title: found.title,
			location: found.location,
			notes: "",
			allDay: found.allDay,
			start: found.allDay ? root.dayKey(found.start) : root.wallTime(found.start),
			end: found.allDay ? root.dayKey(end) : root.wallTime(end),
			repeat: found.repeat,
			reminder: found.allDay ? -1 : 10
		}, reply => {
			if (!root.failed(reply)) {
				Nas.setLocal("calendar", Object.assign({}, root.config, { lastCalendar: calendar }));
				root.refresh();
			}
			if (done) done(reply);
		});
	}

	// "morgen 15 Uhr Zahnarzt @Praxis", "Fr 18:30-20 Kino", "24.12. ganztägig Weihnachten",
	// "jeden Montag 9 Standup 15min", "in 2 Stunden Pizza", "tomorrow 3pm dentist" →
	// { title, start, end, allDay, location, repeat, when (anything found) }
	function parseText(input, now) {
		let t = ` ${String(input).replace(/\s+/g, " ").trim()} `;
		// a match is cut out of the text; fn returning false puts it back
		const take = (re, fn) => {
			const m = t.match(re);
			if (!m) return false;
			const before = t;
			t = t.slice(0, m.index) + " " + t.slice(m.index + m[0].length);
			if (fn && fn(m) === false) {
				t = before;
				return false;
			}
			return true;
		};
		const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
		let day = null;
		let hour = -1;
		let minute = 0;
		let endHour = -1;
		let endMinute = 0;
		let length = 60;
		let allDay = false;
		let location = "";
		let repeat = "";
		let exact = null;
		const days = ["so|sonntag|sun|sunday", "mo|montag|mon|monday", "di|dienstag|tue|tuesday", "mi|mittwoch|wed|wednesday", "do|donnerstag|thu|thursday", "fr|freitag|fri|friday", "sa|samstag|sat|saturday"];
		const weekday = word => days.findIndex(d => d.split("|").includes(word.toLowerCase().replace(/\.$/, "")));
		const nextDay = (wd, strict) => {
			const add = (wd - today.getDay() + 7) % 7;
			return new Date(today.getFullYear(), today.getMonth(), today.getDate() + (add === 0 && strict ? 7 : add));
		};
		// QML's engine loses array destructuring into these variables: plain fields
		const clock = (h, m, half) => {
			h = Number(h);
			m = Number(m || 0);
			if (half && /pm/i.test(half) && h < 12) h += 12;
			if (half && /am/i.test(half) && h === 12) h = 0;
			return { h: h, m: m };
		};

		take(/\s@\s*(.+?)\s*$/, m => location = m[1]);
		take(/\s(ganzt(?:ä|ae)gig|ganztags|all[- ]day)(?=\s)/i, () => allDay = true);
		take(/\s(?:jede[nrs]?|every)\s+(?:tag|day)(?=\s)/i, () => repeat = "daily");
		take(/\s(t(?:ä|ae)glich|daily)(?=\s)/i, () => repeat = "daily");
		take(/\s(w(?:ö|oe)chentlich|weekly)(?=\s)/i, () => repeat = "weekly");
		take(/\s(?:jede[nrs]?|every)\s+(?:monat|month)(?=\s)|\s(monatlich|monthly)(?=\s)/i, () => repeat = "monthly");
		take(/\s(?:jede[nrs]?|every)\s+(?:jahr|year)(?=\s)|\s(j(?:ä|ae)hrlich|yearly)(?=\s)/i, () => repeat = "yearly");
		take(/\s(?:jede[nrs]?|every)\s+([a-zä]+)(?=\s)/i, m => {
			const wd = weekday(m[1]);
			if (wd >= 0) {
				repeat = "weekly";
				day = nextDay(wd, false);
			} else return false;
		});
		take(/\sin\s+(\d+)\s*(min(?:uten)?|minutes?|std\.?|stunden?|h|hours?)(?=\s)/i, m => {
			const n = Number(m[1]) * (/^m/i.test(m[2]) ? 60000 : 3600000);
			exact = new Date(now.getTime() + n);
		});
		take(/\sin\s+(\d+)\s*(tag(?:en)?|days?|wochen?|weeks?)(?=\s)/i, m => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + Number(m[1]) * (/^w/i.test(m[2]) ? 7 : 1)));
		take(/\s(?:am\s+|on\s+)?(\d{4})-(\d{2})-(\d{2})(?=\s)/, m => day = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
		take(/\s(?:am\s+|on\s+)?(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4})?)?(?=\s)/, m => {
			// "10.30" is no date
			if (Number(m[2]) > 12 || Number(m[2]) < 1 || Number(m[1]) > 31 || Number(m[1]) < 1) return false;
			let year = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : today.getFullYear();
			let d = new Date(year, Number(m[2]) - 1, Number(m[1]));
			if (!m[3] && d < today) d = new Date(year + 1, Number(m[2]) - 1, Number(m[1]));
			day = d;
		});
		take(/\s((?:ü|ue)bermorgen|day after tomorrow)(?=\s)/i, () => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 2));
		take(/\s(morgen|tomorrow)(?=\s)/i, () => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1));
		take(/\s(heute|today|tonight|heute abend)(?=\s)/i, () => day = today);
		if (!day) take(/\s(?:(n(?:ä|ae)chste[nrs]?|next)\s+|am\s+|on\s+)?(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\.?(?=\s)/i, m => day = nextDay(weekday(m[2]), !!m[1]));
		if (!day) take(/^\s(?:am\s+)?(mo|di|mi|do|fr|sa|so)\.?(?=\s)/i, m => day = nextDay(weekday(m[1]), false));
		take(/\s(?:um\s+|at\s+|von\s+|from\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?\s*(?:-|–|bis|to|until)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?(?=\s)/i, m => {
			if (Number(m[1]) > 23 || Number(m[4]) > 24) return false;
			const from = clock(m[1], m[2], m[3] || m[6]);
			const to = clock(m[4], m[5], m[6]);
			hour = from.h;
			minute = from.m;
			endHour = to.h;
			endMinute = to.m;
		});
		if (hour < 0) take(/\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)(?=\s)|\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})[:](\d{2})(?=\s)|\s(?:um|at|ab)\s+(\d{1,2})(?=\s)/i, m => {
			const at = m[1] !== undefined ? clock(m[1], m[2], m[3]) : (m[4] !== undefined ? clock(m[4], m[5]) : clock(m[6], 0));
			hour = at.h;
			minute = at.m;
		});
		// "10.30" is a time only once the day is known (else it could be a date)
		if (hour < 0 && day) take(/\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})\.(\d{2})(?=\s)/, m => {
			if (Number(m[1]) <= 23 && Number(m[2]) <= 59) {
				hour = Number(m[1]);
				minute = Number(m[2]);
			} else return false;
		});
		take(/\s(?:f(?:ü|ue)r\s+|for\s+)?(\d+(?:[.,]\d+)?)\s*(min(?:uten)?\.?|minutes?|std\.?|stunden?|h|hours?)(?=\s)/i, m => {
			length = Number(m[1].replace(",", ".")) * (/^m/i.test(m[2]) ? 1 : 60);
		});
		if (hour < 0 && day) take(/^\s+(\d{1,2})(?=\s)/, m => {
			if (Number(m[1]) <= 23) hour = Number(m[1]);
			else return false;
		});
		const title = t.replace(/\s(am|um|at|on|von|from|ab|bis)(?=\s)/gi, " ").replace(/\s+/g, " ").trim().replace(/^[-–:,]\s*/, "");
		let start;
		let end;
		const when = !!(day || exact || hour >= 0);
		if (exact) {
			start = exact;
			end = new Date(start.getTime() + length * 60000);
		} else if (hour >= 0 && hour <= 23 && !allDay) {
			let base = day ?? today;
			start = new Date(base.getFullYear(), base.getMonth(), base.getDate(), hour, Math.min(59, minute));
			if (!day && start < now) start = new Date(start.getTime() + 86400000);
			end = endHour >= 0 ? new Date(start.getFullYear(), start.getMonth(), start.getDate(), endHour, endMinute) : new Date(start.getTime() + length * 60000);
			if (end <= start) end = new Date(end.getTime() + 86400000);
		} else {
			allDay = true;
			start = day ?? today;
			end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1);
		}
		return { title: title, start: start, end: end, allDay: allDay && !exact, location: location, repeat: repeat, when: when };
	}

	// every quarter of an hour what is shown is asked again
	Timer {
		running: root.active
		repeat: true
		interval: 15 * 60000
		onTriggered: root.refresh()
	}

	// ── CalDAV, through baikal.py too ────────────────────────────────────
	function ask(url, method, depth, body, done) {
		root.busy += 1;
		root.write("dav", { url: url, method: method, depth: depth, body: body }, reply => {
			root.busy -= 1;
			done(reply.text ?? "", reply.error ?? "");
		});
	}

	function absolute(href) {
		if (/^https?:/.test(href)) return href;
		const origin = (root.url.match(/^https?:\/\/[^\/]+/) ?? [""])[0];
		return origin + href;
	}

	function utc(date) {
		const pad = n => String(n).padStart(2, "0");
		return `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}T${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
	}

	// ── a little XML and iCalendar ───────────────────────────────────────
	function elements(text, name) {
		const out = [];
		const pattern = new RegExp(`<((?:[\\w-]+:)?${name})\\b[^>]*>([\\s\\S]*?)</\\1>`, "g");
		let match;
		while ((match = pattern.exec(String(text))) !== null) out.push(match[2]);
		return out;
	}

	function first(text, name) {
		return (root.elements(text, name)[0] ?? "").trim();
	}

	function decode(text) {
		return String(text).replace(/&#x([0-9a-f]+);/gi, (m, hex) => String.fromCharCode(parseInt(hex, 16))).replace(/&#(\d+);/g, (m, dec) => String.fromCharCode(Number(dec)))
			.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&amp;/g, "&");
	}

	function icsText(value) {
		return String(value).replace(/\\n/gi, "\n").replace(/\\([,;\\])/g, "$1");
	}

	// "20261115T100000Z", "20261115T100000" (local or TZID), "20261115" (a day)
	function icsDate(value, params) {
		const m = String(value).match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/);
		if (!m) return null;
		if (m[4] === undefined) return { date: new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])), allDay: true };
		if (m[7] === "Z") return { date: new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]))), allDay: false };
		return { date: new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])), allDay: false };
	}

	function icsDuration(value) {
		const m = String(value).match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
		if (!m) return 0;
		const seconds = (Number(m[2] || 0) * 7 + Number(m[3] || 0)) * 86400 + Number(m[4] || 0) * 3600 + Number(m[5] || 0) * 60 + Number(m[6] || 0);
		return (m[1] === "-" ? -1 : 1) * seconds * 1000;
	}

	// minutes before the start of the first alarm relative to the start, or -1
	function alarmOf(block) {
		const m = String(block).match(/BEGIN:VALARM[\s\S]*?TRIGGER(;[^:\r\n]*)?:([+-]?P[^\r\n]+)/);
		if (!m || /RELATED=END|VALUE=DATE-TIME/i.test(m[1] ?? "")) return -1;
		const ms = -root.icsDuration(m[2].trim());
		return ms >= 0 ? Math.round(ms / 60000) : -1;
	}

	function parseEvents(text, calendar) {
		const out = [];
		for (const response of root.elements(text, "response")) {
			const href = root.first(response, "href");
			const etag = root.decode(root.first(response, "getetag"));
			const raw = root.first(response, "calendar-data");
			if (raw === "") continue;
			const ics = root.decode(raw).replace(/\r?\n[ \t]/g, "");
			const blocks = ics.split(/BEGIN:VEVENT\r?\n/).slice(1).map(block => block.split(/END:VEVENT/)[0]);
			for (const block of blocks) {
				const fields = {};
				for (const line of block.split(/\r?\n/)) {
					const at = line.indexOf(":");
					if (at <= 0) continue;
					const head = line.slice(0, at).split(";");
					const name = head[0].toUpperCase();
					if (fields[name] === undefined) fields[name] = { value: line.slice(at + 1), params: head.slice(1).join(";") };
				}
				const start = fields.DTSTART ? root.icsDate(fields.DTSTART.value, fields.DTSTART.params) : null;
				if (!start) continue;
				let end = fields.DTEND ? root.icsDate(fields.DTEND.value, fields.DTEND.params)?.date : null;
				if (!end && fields.DURATION) end = new Date(start.date.getTime() + root.icsDuration(fields.DURATION.value));
				if (!end) end = start.allDay ? new Date(start.date.getFullYear(), start.date.getMonth(), start.date.getDate() + 1) : start.date;
				const days = [];
				const stop = end > start.date ? new Date(end.getTime() - 1) : end;
				for (let d = new Date(start.date.getFullYear(), start.date.getMonth(), start.date.getDate()); d <= stop; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) days.push(root.dayKey(d));
				const location = fields.LOCATION ? root.icsText(fields.LOCATION.value) : "";
				const join = (`${location}\n${fields.DESCRIPTION?.value ?? ""}`.match(/https:\/\/[^\s\\]*(teams\.microsoft|zoom\.us|meet\.google|meet\.jit)[^\s\\]*/) ?? [""])[0];
				out.push({
					id: `baikal:${fields.UID?.value ?? ""}:${fields["RECURRENCE-ID"]?.value ?? start.date.getTime()}`,
					source: "baikal",
					href: href,
					etag: etag,
					calendarHref: calendar.href,
					readOnly: calendar.access === "read",
					reminder: root.alarmOf(block),
					calendar: calendar.name,
					color: calendar.color,
					subject: fields.SUMMARY ? root.icsText(fields.SUMMARY.value) : "(No title)",
					start: start.date.toISOString(),
					end: end.toISOString(),
					allDay: start.allDay,
					days: days,
					location: location,
					joinUrl: join,
					online: join !== "",
					webLink: "",
					body: fields.DESCRIPTION ? root.icsText(fields.DESCRIPTION.value).slice(0, 4000) : "",
					showAs: String(fields.TRANSP?.value ?? "") === "TRANSPARENT" ? "free" : "busy",
					cancelled: String(fields.STATUS?.value ?? "") === "CANCELLED",
					response: "",
					recurring: !!fields["RECURRENCE-ID"],
					private: String(fields.CLASS?.value ?? "") === "PRIVATE",
					isOrganizer: true,
					organizer: { name: calendar.name, email: "" },
					attendees: []
				});
			}
		}
		return out;
	}
}
