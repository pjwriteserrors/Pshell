pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Baikal calendar on netcore (plugin "nas-calendar", docs/nas.md): its
// events beside the Microsoft ones in the calendar (MsCalendar.eventsOn adds
// them). CalDAV is spoken with curl: PROPFIND finds the calendars of the
// user, a REPORT with <expand> asks for the six weeks of a month grid with
// repeating events already unrolled by the server. The password stays in
// the keyring (secret-tool, service "pshell-baikal") and reaches curl only
// through its stdin; the URL and the user are kept in nas.json
// (`calendar`: { url, user }).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("nas-calendar")
	readonly property var config: root.enabled ? (Nas.local.calendar ?? ({})) : ({})
	readonly property string url: String(root.config.url || "http://192.168.178.22:8082/dav.php").replace(/\/+$/, "")
	readonly property string user: String(root.config.user || "")
	readonly property bool active: root.enabled && root.user !== "" && root.hasPassword

	property bool hasPassword: false
	property string error: ""
	// [{ href, name, color }]
	property var calendars: []
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

	function eventsOn(key) {
		return root.byDay[key] ?? [];
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
			if (root.hasPassword) root.ensure(new Date());
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
		const body = `<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-data><c:expand ${range}/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range ${range}/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
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
		const body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/></d:prop></d:propfind>';
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
				out.push({ href: href, name: root.decode(root.first(response, "displayname")) || decodeURIComponent(href.split("/").filter(p => p).pop() ?? ""), color: root.first(response, "calendar-color").slice(0, 7) });
			}
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

	// every quarter of an hour what is shown is asked again
	Timer {
		running: root.active
		repeat: true
		interval: 15 * 60000
		onTriggered: root.refresh()
	}

	// ── CalDAV over curl; the password goes in on stdin ──────────────────
	function ask(url, method, depth, body, done) {
		root.busy += 1;
		const proc = asker.createObject(root, { done: (text, error) => {
			root.busy -= 1;
			done(text, error);
		} });
		proc.command = ["sh", "-c", [
			'p=$(secret-tool lookup service pshell-baikal user "$2") || exit 3',
			'[ -n "$p" ] || exit 3',
			'e=$(printf "%s" "$2:$p" | sed \'s/\\\\/\\\\\\\\/g; s/"/\\\\"/g\')',
			'printf \'user = "%s"\\n\' "$e" | curl -sS -f --max-time 25 -K - -X "$4" -H "Depth: $5" -H "Content-Type: application/xml; charset=utf-8" --data-binary "$3" "$1"'
		].join("\n"), "sh", url, root.user, body, method, depth];
		proc.running = true;
	}

	Component {
		id: asker

		Process {
			id: proc

			property var done: null
			property string out: ""
			property string err: ""
			stdout: StdioCollector {
				onStreamFinished: proc.out = text
			}
			stderr: StdioCollector {
				onStreamFinished: proc.err = text
			}
			onExited: code => {
				const error = code === 0 ? "" : (code === 3 ? "No password in the keyring" : (String(proc.err).trim().split("\n").pop() || `curl failed (${code})`));
				Qt.callLater(() => {
					if (proc.done) proc.done(proc.out, error);
					proc.destroy();
				});
			}
		}
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

	function parseEvents(text, calendar) {
		const out = [];
		for (const raw of root.elements(text, "calendar-data")) {
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
