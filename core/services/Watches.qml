pragma Singleton

import QtQuick
import Quickshell

// What pshell-core watches on the web for the user (docs/core.md "Watches",
// docs/browser.md): parts of pages, wishes with their price history,
// parcels until delivered. Core checks them, also while the PC is off, and
// tells as reminders (Reminders.qml shows them, the phone rings). The
// browser adds them: the Pshell menu's "Watch part of page" (a picker in the
// page), "Add to wish list" (the page's schema.org price, else the picker),
// "Track parcel"; order pages offer the tracking numbers they show
// (`parcel-scan`, a toast, nothing is added without the click).
// "Remind tonight / tomorrow / at the weekend" make an own reminder with the
// page's address; closing the tab is offered.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("watches")
	readonly property bool online: root.enabled && root.built && Netcore.online
	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	// [{ id, kind: element|product|parcel, title, url, status, … }] (core's view)
	property var list: []
	property var keys: ({ track17: false })
	property bool loaded: false
	property string error: ""

	readonly property var parcels: root.list.filter(w => w.kind === "parcel")
	readonly property var openParcels: root.parcels.filter(w => !w.done)
	readonly property var pages: root.list.filter(w => w.kind === "element")
	readonly property var wishes: root.list.filter(w => w.kind === "product")
	readonly property var outForDelivery: root.openParcels.filter(w => w.state === "out" || w.state === "pickup")

	readonly property var stateNames: ({ unknown: "No news yet", info: "Announced", transit: "On its way", pickup: "Ready for pickup", out: "Out for delivery", delivered: "Delivered", problem: "Problem", manual: "Carrier page only" })
	readonly property var stateGlyphs: ({ unknown: "package_variant_closed", info: "package_variant_closed", transit: "truck_outline", pickup: "store_outline", out: "truck_fast_outline", delivered: "truck_check_outline", problem: "alert_circle_outline", manual: "open_in_new" })
	readonly property var statusNames: ({ new: "Not checked yet", ok: "", missing: "Not in the page's HTML", blocked: "The site refuses checks", error: "Check failed", manual: "" })

	// ── core ───────────────────────────────────────────────────────────────
	function call(method, path, body, done) {
		if (!root.online) {
			if (done) done(null, "Core not reachable");
			return;
		}
		Netcore.call(method, path, body, done);
	}

	function load() {
		root.call("GET", "/api/watches", null, (data, error) => {
			if (!data) {
				root.error = error;
				return;
			}
			root.error = "";
			root.list = Array.isArray(data.watches) ? data.watches : [];
			root.keys = data.keys ?? { track17: false };
			root.loaded = true;
		});
	}

	function add(body, done) {
		root.call("POST", "/api/watches", body, (data, error) => {
			if (error) Notifs.pushInternal("error", "Not added", error, { icon: "eye_outline", app: "Watches" });
			else root.load();
			if (done) done(data, error);
		});
	}

	function update(id, patch, done) {
		root.call("PATCH", `/api/watches/${encodeURIComponent(id)}`, patch, (data, error) => {
			if (error) Notifs.pushInternal("error", "Not changed", error, { icon: "eye_outline", app: "Watches" });
			root.load();
			if (done) done(data, error);
		});
	}

	function remove(id) {
		root.list = root.list.filter(w => w.id !== id);
		root.call("DELETE", `/api/watches/${encodeURIComponent(id)}`, null, () => root.load());
	}

	function check(id) {
		root.call("POST", `/api/watches/${encodeURIComponent(id)}/check`, null, () => root.load());
	}

	function setTrack17(key) {
		root.call("PUT", "/api/watches/keys", { track17: String(key || "") }, (data, error) => {
			if (error) Notifs.pushInternal("error", "Key not saved", error, { icon: "key_outline", app: "Watches" });
			root.load();
		});
	}

	function open(w) {
		const url = String(w?.url || "");
		if (url === "") return;
		if (WebLink.enabled && WebLink.connected) WebLink.open(url);
		else Browser.open(url);
	}

	// ── what each says, in a line ─────────────────────────────────────────
	function money(amount, currency) {
		if (amount === null || amount === undefined) return "";
		const sign = ({ EUR: "€", USD: "$", GBP: "£" })[currency] ?? (currency || "");
		return `${Number(amount).toLocaleString(Qt.locale("de_DE"), "f", 2)} ${sign}`.trim();
	}

	function glyph(w) {
		if (w.kind === "parcel") return root.stateGlyphs[w.state] ?? "package_variant_closed";
		if (w.kind === "product") return w.for ? "gift_outline" : "tag_outline";
		return "eye_outline";
	}

	function title(w) {
		if (w.kind === "parcel") return `${w.carrier_name} · ${w.label || w.title || w.number}`;
		return w.title || String(w.url).replace(/^https?:\/\/(www\.)?/, "").slice(0, 60);
	}

	function line(w) {
		const problem = w.status && w.status !== "ok" && w.status !== "manual" ? (root.statusNames[w.status] ?? w.status) : "";
		if (w.kind === "parcel") {
			const parts = [root.stateNames[w.state] ?? w.state];
			if (w.text && w.state !== "manual") parts.push(w.text);
			if (w.expected) parts.push(w.expected.slice(0, 10));
			if (w.status === "error" || w.status === "blocked") parts.push(w.error || problem);
			return parts.filter(s => s).join(" · ");
		}
		if (w.kind === "product") {
			const parts = [];
			if (w.price !== null && w.price !== undefined) parts.push(root.money(w.price, w.currency));
			if (w.low !== null && w.low !== undefined && w.low < w.price) parts.push(`low ${root.money(w.low, w.currency)}`);
			if (w.target) parts.push(`below ${root.money(w.target, w.currency)}`);
			if (w.for) parts.push(`for ${w.for.name}`);
			if (problem) parts.push(problem);
			return parts.join(" · ");
		}
		return [w.value ?? w.seen ?? "", problem].filter(s => s).join(" · ");
	}

	// a carrier's time ("2026-11-23T18:00:00+01:00", "23.11.2026 18:00") as the shell says it
	function parsed(text) {
		const t = String(text || "").trim();
		if (t === "") return null;
		const de = t.match(/^(\d{1,2})\.(\d{1,2})\.(\d{4})(?:[ ,]+(\d{1,2}):(\d{2}))?/);
		const d = de ? new Date(Number(de[3]), Number(de[2]) - 1, Number(de[1]), Number(de[4] || 0), Number(de[5] || 0)) : new Date(t);
		return isNaN(d.getTime()) ? null : d;
	}

	function whenOf(text) {
		const d = root.parsed(text);
		if (!d) return "";
		return Reminders.whenText(Math.floor(d.getTime() / 1000), /^\d{4}-\d{2}-\d{2}$/.test(String(text)));
	}

	// the expected day: Today, Tomorrow, Fri, 3. Dec
	function dayOf(text) {
		const d = root.parsed(text);
		if (!d) return "";
		return Reminders.whenText(Math.floor(d.getTime() / 1000), true);
	}

	// how far the price moved since the wish was added, in %
	function dropOf(w) {
		const first = Number((w.prices ?? [])[0]?.price ?? w.seen);
		const now = Number(w.price);
		if (!isFinite(first) || !isFinite(now) || first <= 0) return 0;
		return (now - first) / first * 100;
	}

	function sinceText(w) {
		const at = Number((w.prices ?? [])[0]?.at ?? w.created);
		return at ? Qt.formatDate(new Date(at * 1000), "d. MMM") : "";
	}

	// days until the next birthday ("1990-12-01" or "12-01"), -1 unknown
	function birthdayIn(birthday) {
		const m = String(birthday || "").match(/(\d{2})-(\d{2})$/);
		if (!m) return -1;
		const today = new Date();
		today.setHours(0, 0, 0, 0);
		let next = new Date(today.getFullYear(), Number(m[1]) - 1, Number(m[2]));
		if (next < today) next = new Date(today.getFullYear() + 1, Number(m[1]) - 1, Number(m[2]));
		return Math.round((next - today) / 86400000);
	}

	function birthdayText(birthday) {
		const days = root.birthdayIn(birthday);
		return days < 0 ? "" : days === 0 ? "birthday today" : days === 1 ? "birthday tomorrow" : `birthday in ${days} days`;
	}

	// wishes by whom they are for: own ones first, then people by their next birthday
	readonly property var wishGroups: {
		const groups = {};
		for (const w of root.wishes) {
			const name = w.for?.name ?? "";
			if (!groups[name]) groups[name] = { name: name, birthday: "", wishes: [] };
			if (w.for?.birthday) groups[name].birthday = w.for.birthday;
			groups[name].wishes.push(w);
		}
		return Object.values(groups).sort((a, b) => {
			if (a.name === "" || b.name === "") return a.name === "" ? -1 : 1;
			const da = root.birthdayIn(a.birthday), db = root.birthdayIn(b.birthday);
			return (da < 0 ? 999 : da) - (db < 0 ? 999 : db) || a.name.localeCompare(b.name);
		});
	}

	function prices(w) {
		return (w.prices ?? []).map(p => Number(p.price));
	}

	// ── from the browser ──────────────────────────────────────────────────
	function refusePrivate(info) {
		if (!info?.private) return false;
		Notifs.pushInternal("info", "Not from a private window", "", { icon: "incognito", app: "Watches" });
		return true;
	}

	// "Watch part of page": the picker in the page; its answer comes as the event `watchPicked`
	function pickPart(info) {
		if (root.refusePrivate(info)) return;
		WebLink.command("watchPick", { tabId: info.tabId ?? -1, mode: "element" }, (ok, data) => {
			if (!ok) Notifs.pushInternal("error", "No picker in this page", String(data || ""), { icon: "eye_outline", app: "Watches" });
		}, info.source);
	}

	// "Add to wish list": a link is taken as it is; a page tells its own price, else the picker
	function wish(info) {
		if (root.refusePrivate(info)) return;
		if (info.kind === "link" && info.link) {
			root.addWish({ url: String(info.link), title: String(info.linkText || "").trim() });
			return;
		}
		WebLink.command("product", { tabId: info.tabId ?? -1 }, (ok, data) => {
			if (ok && data && data.price !== null && data.price !== undefined) {
				root.addWish({ url: String(data.url || info.page), title: String(data.title || info.title || ""), seen: Number(data.price), currency: String(data.currency || ""), image: String(data.image || "") });
			} else {
				WebLink.command("watchPick", { tabId: info.tabId ?? -1, mode: "price" }, (ok2, data2) => {
					if (!ok2) root.addWish({ url: String(info.page), title: String(info.title || "") });
				}, info.source);
			}
		}, info.source);
	}

	function addWish(body) {
		root.add(Object.assign({ kind: "product" }, body), (data, error) => {
			if (!data) return;
			const price = data.price ?? data.seen;
			Notifs.pushInternal("done", "On the wish list", [root.title(data), price !== null && price !== undefined ? root.money(price, data.currency) : (root.statusNames[data.status] ?? "")].filter(s => s).join(" · "), {
				icon: "gift_outline",
				app: "Watches",
				actions: Contacts.list.length > 0 ? [{ label: "For someone", icon: "account_outline", run: () => root.openPanel(data.id) }] : []
			});
		});
	}

	// what the picker found: { mode, url, title, selector, attr, value, price, currency, private }
	function picked(event) {
		if (!root.enabled || event.private) return;
		const url = String(event.url || "");
		if (!/^https?:/.test(url) || !event.selector) return;
		if (event.mode === "price") {
			root.addWish({ url: url, title: String(event.title || ""), selector: String(event.selector), seen: event.price ?? null, currency: String(event.currency || "") });
			return;
		}
		root.add({ kind: "element", url: url, title: String(event.title || "").slice(0, 120), selector: String(event.selector), attr: String(event.attr || ""), seen: String(event.value || "") }, (data, error) => {
			if (!data) return;
			const missing = data.status === "missing" || data.status === "blocked";
			Notifs.pushInternal(missing ? "info" : "done", missing ? "Watching, but core cannot see it" : "Watching", missing ? (root.statusNames[data.status] ?? "") : String(data.value ?? event.value ?? "").slice(0, 120), {
				icon: "eye_outline",
				app: "Watches",
				actions: missing ? [{ label: "Remove", icon: "delete_outline", run: () => root.remove(data.id) }] : []
			});
		});
	}

	// "Track parcel" on a selection: every number in it
	function trackText(info) {
		if (root.refusePrivate(info)) return;
		const numbers = root.numbersIn(String(info.text || ""));
		if (numbers.length === 0) {
			Notifs.pushInternal("info", "No tracking number", "", { icon: "package_variant_closed", app: "Watches" });
			return;
		}
		for (const number of numbers)
			root.track({ number: number, hint: `${info.text} ${info.page}`, page: String(info.page || ""), label: root.shopOf(info.page, info.title) });
	}

	// "Track parcel" on a page: what the page shows (the same scan as for order pages)
	function trackPage(info) {
		if (root.refusePrivate(info)) return;
		WebLink.command("parcels", { tabId: info.tabId ?? -1 }, (ok, data) => {
			const found = ok ? (data?.numbers ?? []) : [];
			if (found.length === 0) Notifs.pushInternal("info", "No tracking number on this page", "", { icon: "package_variant_closed", app: "Watches" });
			for (const item of found)
				root.track({ number: item.number, carrier: item.carrier || undefined, hint: item.hint || "", page: String(info.page || ""), label: root.shopOf(info.page, info.title) });
		}, info.source);
	}

	function track(body) {
		root.add(Object.assign({ kind: "parcel" }, body), (data, error) => {
			if (data) Notifs.pushInternal("done", `${data.carrier_name} parcel tracked`, [data.number, root.stateNames[data.state] ?? ""].filter(s => s).join(" · "), { icon: "package_variant_closed", app: "Watches" });
		});
	}

	// tracking numbers in text: UPS, DHL, Hermes, DPD, GLS (parcels.py has the same)
	function numbersIn(text) {
		const out = [];
		const re = /\b(1Z[0-9A-Z]{16}|(?:JJD|JVGL)\d{10,22}|H\d{19}|[A-Z]{2}\d{9}DE|\d{11,20})\b/g;
		for (const m of String(text).replace(/(\d)[ ](?=\d)/g, "$1").matchAll(re))
			if (!out.includes(m[1])) out.push(m[1]);
		return out.slice(0, 5);
	}

	function shopOf(page, title) {
		if (title === undefined) return String(page || "").replace(/^https?:\/\/(www\.)?/, "").split(/[\/:?#]/)[0];
		const host = String(page || "").replace(/^https?:\/\/(www\.)?/, "").split(/[\/:]/)[0];
		return host || String(title || "").slice(0, 60);
	}

	// order pages: numbers the extension found ({ numbers: [{ number, carrier, hint }], page, title })
	property var offered: []

	function offerParcels(event) {
		if (!root.enabled || !Plugins.on("parcel-scan") || event.private) return;
		const known = root.parcels.map(w => w.number);
		const fresh = (event.numbers ?? []).filter(item => item && item.number && !known.includes(item.number) && !root.offered.includes(item.number)).slice(0, 3);
		if (fresh.length === 0) return;
		root.offered = root.offered.concat(fresh.map(item => item.number)).slice(-200);
		const shop = root.shopOf(event.page, event.title);
		Notifs.pushInternal("info", fresh.length === 1 ? "Track this parcel?" : "Track these parcels?", fresh.map(item => `${item.name || item.carrier} ${item.number}`).join("\n"), {
			icon: "package_variant_closed",
			app: "Watches",
			duration: 30000,
			actions: [{ label: "Track", icon: "package_variant_closed", run: () => {
				for (const item of fresh)
					root.track({ number: item.number, carrier: item.carrier || undefined, hint: item.hint || "", page: String(event.page || ""), label: shop });
			} }]
		});
	}

	// ── remind me of this page ────────────────────────────────────────────
	// tonight: 19:00 (later in the evening: in an hour); tomorrow: 9:00;
	// weekend: Saturday 10:00 (on Saturday after that: Sunday; on Sunday: next Saturday)
	function remindAt(when, now) {
		const d = new Date(now ?? Date.now());
		const at = new Date(d);
		at.setSeconds(0, 0);
		if (when === "tonight") {
			at.setHours(19, 0);
			if (at.getTime() - d.getTime() < 30 * 60000) {
				at.setTime(d.getTime() + 60 * 60000);
				at.setMinutes(Math.ceil(at.getMinutes() / 15) * 15, 0, 0);
			}
		} else if (when === "tomorrow") {
			at.setDate(d.getDate() + 1);
			at.setHours(9, 0);
		} else {
			const day = d.getDay();
			let ahead = (6 - day + 7) % 7;
			at.setDate(d.getDate() + ahead);
			at.setHours(10, 0);
			if (at.getTime() <= d.getTime()) {
				at.setDate(at.getDate() + (day === 6 ? 1 : 6));
			}
		}
		return Math.floor(at.getTime() / 1000);
	}

	function remindPage(info, when) {
		if (root.refusePrivate(info)) return;
		const url = String(info.kind === "link" ? info.link : info.page || "");
		if (!/^https?:/.test(url)) return;
		const title = String((info.kind === "link" ? info.linkText : info.title) || url).trim().slice(0, 200);
		const at = root.remindAt(when);
		Reminders.create({ title: title, note: url, at: at, url: url, source: "own" }, (data, error) => {
			if (!data) return;
			const tab = info.kind !== "link" && (info.tabId ?? -1) >= 0;
			Notifs.pushInternal("done", "Reminder set", `${Reminders.whenText(at)} · ${title}`, {
				icon: "bell_outline",
				app: "Reminders",
				actions: tab ? [{ label: "Close tab", icon: "tab_remove", run: () => WebLink.command("close", { tabId: info.tabId }, null, info.source) }] : []
			});
		});
	}

	// ── the panel ─────────────────────────────────────────────────────────
	property string focusId: ""

	function openPanel(id) {
		root.focusId = String(id || "");
		Popups.withFocusedScreen(screen => Popups.open("watches", screen));
	}

	// people for a gift: the address book's names and birthdays
	function people() {
		return Contacts.list.filter(c => c.name).map(c => ({ name: String(c.name), birthday: String(c.birthday || "") })).sort((a, b) => a.name.localeCompare(b.name));
	}

	// ── events ─────────────────────────────────────────────────────────────
	Connections {
		target: root.built && root.enabled ? Nas : null

		function onCoreEvent(message) {
			const type = String(message.type ?? String(message.event).slice(5));
			if (type === "watches") reload.restart();
			else if (type === "hello") reload.restart();
		}
	}

	Connections {
		target: root.built && root.enabled ? WebLink : null

		function onEventReceived(event) {
			if (event.name === "watchPicked") root.picked(event);
			else if (event.name === "parcels") root.offerParcels(event);
		}
	}

	onOnlineChanged: if (root.online) reload.restart()

	Timer {
		id: reload

		interval: 500
		onTriggered: root.load()
	}

	// parcels move while nobody looks: a fresh list now and then
	Timer {
		running: root.online
		repeat: true
		interval: 10 * 60000
		onTriggered: root.load()
	}
}
