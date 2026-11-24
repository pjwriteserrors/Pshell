pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Places and events from web pages (docs/browser.md "Places and events from
// pages"), entries of the Pshell menu that WebMenu lists. The extension
// shows them only where the page has something (background/finds.js:
// schema.org Place/LocalBusiness/PostalAddress, links to maps, schema.org
// Event, or a selection that looks like an address or a date); after a
// click the shell asks it for what it found (`finds`).
//
// Save to Places: the place is looked up on the map (places.py suggest,
// near its own point when the page gives one) and kept in Places' "want"
// list. Route on phone: a route to it opens on the phone. Add to calendar:
// the event goes into the calendar's editor (Baikal) to be looked at and
// saved there; with only the Microsoft calendar a toast shows it with "Add".
// Several on one page: a toast to pick from. Nothing is kept of a private
// window (the entries are not shown there).
Singleton {
	id: root

	readonly property bool calendarOn: NasCalendar.active || (MsCalendar.enabled && MsCalendar.signedIn)

	// for WebMenu.entries
	function entries(phoneOn) {
		const out = [];
		const spots = ["page", "tab", "selection", "link"];
		if (Plugins.on("places")) out.push({ id: "place-save", title: "Save to Places", contexts: spots, group: "finds", needs: "place" });
		if (phoneOn) out.push({ id: "place-route", title: "Route on phone", contexts: spots, group: "finds", needs: "place" });
		if (root.calendarOn) out.push({ id: "event-add", title: "Add to calendar", contexts: ["page", "tab", "selection"], group: "finds", needs: "event" });
		return out;
	}

	function run(action, info) {
		if (!["place-save", "place-route", "event-add"].includes(action) || info.private) return;
		const selection = info.kind === "selection" ? String(info.text || "").trim() : "";
		WebLink.command("finds", { tabId: info.tabId ?? -1, link: info.kind === "link" ? String(info.link || "") : "", linkText: String(info.linkText || "") }, (ok, data) => {
			const finds = ok && data ? data : { places: [], events: [] };
			if (action === "event-add") return root.addEvent(finds, selection);
			const places = finds.link ? [finds.link] : selection !== "" ? [{ name: "", address: { text: selection.replace(/\s*\n\s*/g, ", ") }, lat: null, lon: null }] : (finds.places || []);
			if (places.length === 0) return root.say("No place on this page", "map_marker_off");
			root.choose(places, place => root.labelOf(place), place => action === "place-save" ? root.save(place) : root.route(place));
		}, info.source);
	}

	// one of several: a toast with the first few
	function choose(items, label, then) {
		if (items.length === 1) return then(items[0]);
		Notifs.pushInternal("", `${items.length} on this page`, "", {
			icon: "format_list_bulleted",
			duration: 20000,
			actions: items.slice(0, 3).map(item => ({ label: label(item).slice(0, 40), run: () => then(item) }))
		});
	}

	function labelOf(place) {
		return place.name || place.address?.text || `${Number(place.lat).toFixed(4)}, ${Number(place.lon).toFixed(4)}`;
	}

	function say(title, icon, detail) {
		Notifs.pushInternal("info", title, detail || "", { icon: icon });
	}

	// ── places ─────────────────────────────────────────────────────────
	function hasPoint(place) {
		return place.lat !== null && place.lat !== undefined && place.lon !== null && place.lon !== undefined && isFinite(place.lat) && isFinite(place.lon);
	}

	function route(place) {
		const destination = root.hasPoint(place) ? `${place.lat},${place.lon}` : [place.name, place.address?.text].filter(Boolean).join(", ");
		Phone.sendUrl(`https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(destination)}`, 0, root.labelOf(place));
	}

	// by its name near its point (or with its city), then by its address
	function save(place) {
		const queries = [];
		const address = String(place.address?.text || "");
		const city = String(place.address?.city || "");
		if (place.name) queries.push({ text: root.hasPoint(place) ? place.name : [place.name, city || address].filter(Boolean).join(", "), byName: true });
		if (address) queries.push({ text: address, byName: false });
		const job = matcher.createObject(root, { place: place, queries: queries });
		job.next();
	}

	function words(text) {
		return String(text || "").toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").split(/[^a-z0-9]+/).filter(word => word.length > 1);
	}

	function distance(a, b) {
		const rad = Math.PI / 180;
		const x = (b.lon - a.lon) * rad * Math.cos((a.lat + b.lat) * rad / 2);
		const y = (b.lat - a.lat) * rad;
		return Math.sqrt(x * x + y * y) * 6371000;
	}

	// the suggestion that is this place: 60 % of its words (the city's left
	// out), within 1.5 km of its point
	function best(place, items, byName) {
		const city = root.words(place.address?.city || "");
		const all = root.words(byName ? place.name : place.address?.street || place.address?.text);
		const own = all.filter(word => !city.includes(word));
		const wanted = own.length > 0 ? own : all;
		let pick = null;
		let top = 0;
		for (const item of items) {
			const have = root.words(`${item.name} ${item.street}`);
			const matched = wanted.filter(word => have.includes(word)).length;
			if (wanted.length === 0 || matched < Math.ceil(wanted.length * 0.6)) continue;
			let score = matched / wanted.length;
			if (root.hasPoint(place)) {
				const meters = root.distance(place, item);
				if (meters > 1500) continue;
				if (meters < 150) score += 0.2;
			}
			if (score > top) {
				top = score;
				pick = item;
			}
		}
		return pick;
	}

	// found by its address: kept there under the page's name
	function kept(place, found, byName) {
		const brief = byName || !place.name ? found : Object.assign({}, found, { name: place.name, street: found.street || found.name });
		Places.keep(brief, { list: "want" });
		Sounds.play("taskDone");
		Notifs.pushInternal("done", "Saved to Places", [brief.name, [brief.street, brief.city].filter(Boolean).join(", ")].filter(Boolean).join(" · "), {
			icon: "map_marker_check",
			actions: [{ label: "Show", icon: "map_marker", run: () => root.show(brief) }]
		});
	}

	function show(brief) {
		Popups.withFocusedScreen(screen => {
			if (Popups.current === "launcher") Popups.close();
			Popups.open("launcher", screen, "", ">wp ");
			Qt.callLater(() => Places.open(brief));
		});
	}

	Component {
		id: matcher

		Process {
			id: job

			property var place
			property var queries: []
			property int step: -1

			function next() {
				job.step += 1;
				if (job.step >= job.queries.length) {
					Notifs.pushInternal("error", "Not found on the map", root.labelOf(job.place), {
						icon: "map_marker_off",
						actions: [{ label: "Search", icon: "magnify", run: () => Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", `>wp ${root.labelOf(job.place)}`)) }]
					});
					job.destroy();
					return;
				}
				const near = root.hasPoint(job.place) ? ["--lat", Number(job.place.lat).toFixed(5), "--lon", Number(job.place.lon).toFixed(5)] : Places.originArgs();
				job.command = ["python3", "-u", `${Paths.scripts}/places.py`, "suggest", job.queries[job.step].text].concat(near);
				job.running = true;
			}

			stdout: SplitParser {
				onRead: line => {
					let message = null;
					try {
						message = JSON.parse(line);
					} catch (error) {
						return;
					}
					if (message.type !== "suggestions" || job.place === null) return;
					const byName = job.queries[job.step].byName;
					const found = root.best(job.place, message.items || [], byName);
					if (!found) return;
					const place = job.place;
					job.place = null;
					root.kept(place, found, byName);
				}
			}
			onExited: Qt.callLater(() => {
				if (job.place !== null) job.next();
				else job.destroy();
			})
		}
	}

	// ── events ─────────────────────────────────────────────────────────
	// "2026-12-12T20:00:00+01:00" (its own zone), "2026-12-12T20:00" (here), "2026-12-12"
	function dateOf(text) {
		const m = String(text || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?/);
		if (!m) return null;
		if (m[7]) return new Date(Date.parse(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6] || "00"}${m[7].length === 5 ? m[7].slice(0, 3) + ":" + m[7].slice(3) : m[7]}`));
		return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] || 0), Number(m[5] || 0));
	}

	function addEvent(finds, selection) {
		if (selection !== "") {
			if (NasCalendar.active) return NasCalendar.draftFrom(selection, "");
			const found = NasCalendar.parseText(selection, new Date());
			if (!found.when) return root.say("No date in the selection", "calendar_outline");
			return root.offerEvent({ title: found.title || String(finds.title || ""), start: found.start, end: found.end, allDay: found.allDay, where: found.location, notes: String(finds.url || "") });
		}
		const events = (finds.events || []).map(event => root.eventFrom(event, finds)).filter(event => event !== null);
		if (events.length === 0) return root.say("No event on this page", "calendar_outline");
		root.choose(events, event => `${Qt.formatDate(event.start, "d MMM")} ${event.title}`, event => root.offerEvent(event));
	}

	function eventFrom(event, finds) {
		const start = root.dateOf(event.start);
		if (!start) return null;
		const allDay = !!event.allDay;
		let end = root.dateOf(event.end);
		if (allDay) end = end ? new Date(end.getFullYear(), end.getMonth(), end.getDate() + 1) : new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1);
		else if (!end || end <= start) end = new Date(start.getTime() + 2 * 3600000);
		const link = String(event.url || finds.url || "");
		return {
			title: String(event.title || finds.title || ""),
			start: start,
			end: end,
			allDay: allDay,
			where: String(event.where || ""),
			notes: [link, String(event.description || "")].filter(Boolean).join("\n\n")
		};
	}

	// into the editor of the Today panel (Baikal), or a toast with "Add" (Microsoft)
	function offerEvent(event) {
		if (NasCalendar.active) {
			NasCalendar.draft = {
				calendar: NasCalendar.defaultCalendar(),
				title: event.title,
				location: event.where,
				notes: event.notes,
				allDay: event.allDay,
				start: event.allDay ? NasCalendar.dayKey(event.start) : NasCalendar.wallTime(event.start),
				end: event.allDay ? NasCalendar.dayKey(event.end) : NasCalendar.wallTime(event.end),
				repeat: "",
				reminder: -1
			};
			MsCalendar.selected = null;
			Popups.withFocusedScreen(screen => Popups.open("today", screen));
			return;
		}
		const when = event.allDay ? Qt.formatDate(event.start, "ddd d MMM") : `${Qt.formatDate(event.start, "ddd d MMM")}, ${Qt.formatTime(event.start, "HH:mm")}`;
		Notifs.pushInternal("", event.title, [when, event.where].filter(Boolean).join(" · "), {
			icon: "calendar_plus",
			duration: 20000,
			actions: [{ label: "Add to calendar", icon: "calendar_plus", run: () => root.importMs(event) }]
		});
	}

	function icsText(text) {
		return String(text || "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
	}

	function icsTime(date, allDay) {
		const pad = n => String(n).padStart(2, "0");
		if (allDay) return `;VALUE=DATE:${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`;
		return `:${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}T${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}00Z`;
	}

	property int icsCount: 0

	function importMs(event) {
		root.icsCount += 1;
		const path = `${Paths.runtime}/browser/event-${root.icsCount}.ics`;
		const ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//pshell//browser//EN", "BEGIN:VEVENT",
			`UID:pshell-web-${Date.now()}-${root.icsCount}`,
			`SUMMARY:${root.icsText(event.title)}`,
			`DTSTART${root.icsTime(event.start, event.allDay)}`,
			`DTEND${root.icsTime(event.end, event.allDay)}`,
			`LOCATION:${root.icsText(event.where)}`,
			`DESCRIPTION:${root.icsText(event.notes)}`,
			"END:VEVENT", "END:VCALENDAR"].join("\r\n") + "\r\n";
		const job = importer.createObject(root);
		job.command = ["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1" && python3 "$3" import "$1"; status=$?; rm -f "$1"; exit $status', "_", path, ics, `${Paths.scripts}/ms_calendar.py`];
		job.running = true;
	}

	Component {
		id: importer

		Process {
			id: job

			stdout: StdioCollector {
				id: out
			}
			onExited: Qt.callLater(() => {
				let answer = {};
				try {
					answer = JSON.parse(String(out.text || "").trim().split("\n").pop() || "{}");
				} catch (error) {
					answer = { error: "The calendar did not answer" };
				}
				if (answer.error || !answer.imported) Notifs.pushInternal("error", String(answer.error || "Not added"), "", { icon: "calendar_outline" });
				else {
					Sounds.play("taskDone");
					Notifs.pushInternal("done", "The event is in the calendar", "", { icon: "calendar_check" });
					MsCalendar.refresh();
				}
				job.destroy();
			})
		}
	}

	// the clicks of the Pshell menu (WebMenu lists the entries)
	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	Connections {
		target: root.built ? WebLink : null

		function onMenuClicked(action, info) {
			if (WebMenu.enabled) root.run(action, info || {});
		}
	}
}
