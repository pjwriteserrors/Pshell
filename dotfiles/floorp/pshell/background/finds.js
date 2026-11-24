// What a page holds that the shell can keep (docs/browser.md "Places and
// events from pages"): places (schema.org Place/LocalBusiness with an
// address or a position, PostalAddress, links to a map) and events
// (schema.org Event). Read from the page only when its Pshell menu opens
// or the shell asks (`finds`); nothing is kept but the last answer per tab.
//
// Menu entries of the shell with `needs: "place" | "event"` show only where
// there is one: a page or tab that holds it, a link to a map (place), or a
// selection that looks like an address (place) or a date (event).
//
// Also the command `syncedTabs`: the tabs of the browser's other devices
// (Firefox Sync, experiments/parts/synced.js), for "Continue from the phone".

// tabId → { url, finds }
const findsCache = new Map();

browser.tabs.onUpdated.addListener((id, change) => {
	if (change.url || change.status === "loading") findsCache.delete(id);
});
browser.tabs.onRemoved.addListener(id => findsCache.delete(id));

// runs in the page: everything schema.org says, plus links to maps
function readPage() {
	const nodes = [];
	const walk = (value, depth) => {
		if (!value || typeof value !== "object" || depth > 12) return;
		if (Array.isArray(value)) return value.forEach(item => walk(item, depth + 1));
		if (value["@type"]) nodes.push(value);
		for (const key of Object.keys(value)) if (key !== "@context") walk(value[key], depth + 1);
	};
	for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
		try {
			walk(JSON.parse(script.textContent), 0);
		} catch (error) {}
	}
	// microdata, as JSON-LD would say it
	const micro = scope => {
		const out = { "@type": String(scope.getAttribute("itemtype") || "").split(/\s+/)[0] };
		const props = [...scope.querySelectorAll("[itemprop]")].filter(el => el.parentElement.closest("[itemscope]") === scope);
		for (const el of props) {
			const value = el.hasAttribute("itemscope") ? micro(el)
				: el.getAttribute("content") ?? el.getAttribute("datetime") ?? (el.tagName === "A" || el.tagName === "LINK" ? el.href : el.tagName === "META" ? "" : el.textContent.trim());
			for (const name of el.getAttribute("itemprop").split(/\s+/)) if (out[name] === undefined) out[name] = value;
		}
		return out;
	};
	for (const scope of document.querySelectorAll("[itemscope][itemtype]")) {
		if (!scope.parentElement?.closest("[itemscope]")) walk(micro(scope), 0);
	}
	const links = [];
	for (const a of document.querySelectorAll('a[href*="maps"], a[href*="openstreetmap.org"], a[href^="geo:"], iframe[src*="maps"]')) {
		const url = a.href || a.src || "";
		if (url && !links.some(link => link.url === url)) links.push({ url, text: (a.textContent || a.title || "").trim().slice(0, 200) });
		if (links.length >= 20) break;
	}
	return {
		nodes: JSON.parse(JSON.stringify(nodes.slice(0, 200))),
		links,
		selection: String(window.getSelection() || "").trim().slice(0, 2000),
		title: document.title
	};
}

const one = value => Array.isArray(value) ? value[0] : value;
const text = value => {
	value = one(value);
	if (value && typeof value === "object") value = value.name ?? value["@value"] ?? value.text ?? "";
	return String(value ?? "").replace(/\s+/g, " ").trim();
};
const typesOf = node => [].concat(node["@type"] || []).map(type => String(type).replace(/^.*[/#]/, ""));
const isEvent = node => typesOf(node).some(type => /Event$|^Festival$/.test(type));

function addressOf(value) {
	value = one(value);
	if (!value) return null;
	if (typeof value === "string") return { text: value.replace(/\s+/g, " ").trim() };
	const country = value.addressCountry;
	const out = {
		street: text(value.streetAddress),
		postcode: text(value.postalCode),
		city: text(value.addressLocality),
		region: text(value.addressRegion),
		country: text(country)
	};
	out.text = [out.street, [out.postcode, out.city].filter(Boolean).join(" "), out.country].filter(Boolean).join(", ");
	return out.text ? out : null;
}

function placeOf(node) {
	if (!node || typeof node !== "object") return null;
	const types = typesOf(node);
	if (types.some(type => /^(Person|WebSite|WebPage|Offer|Product|BreadcrumbList|ImageObject|SearchAction|GeoCoordinates|GeoShape)$/.test(type)) || isEvent(node)) return null;
	const geo = one(node.geo) || {};
	const lat = Number(geo.latitude ?? node.latitude);
	const lon = Number(geo.longitude ?? node.longitude);
	const address = types.includes("PostalAddress") ? addressOf(node) : addressOf(node.address);
	const hasGeo = Number.isFinite(lat) && Number.isFinite(lon) && (lat !== 0 || lon !== 0);
	if (!address && !hasGeo) return null;
	return {
		name: types.includes("PostalAddress") ? "" : text(node.name),
		kind: types[0] || "",
		address: address || { text: "" },
		lat: hasGeo ? lat : null,
		lon: hasGeo ? lon : null,
		phone: text(node.telephone),
		website: text(node.url),
		from: "page"
	};
}

// a link to a map: its point, or what it searches for
function mapPlace(url, label) {
	let u;
	try {
		u = new URL(url);
	} catch (error) {
		return null;
	}
	const place = (lat, lon, query) => {
		lat = Number(lat);
		lon = Number(lon);
		const hasGeo = Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && (lat !== 0 || lon !== 0);
		query = String(query || "").replace(/\+/g, " ").trim();
		if (!hasGeo && !query) return null;
		const name = String(label || "").replace(/\s+/g, " ").trim();
		return { name: /^(map|karte|route|directions|anfahrt|google maps|in google maps öffnen|open in maps)$/i.test(name) ? "" : name.slice(0, 120), kind: "", address: { text: query }, lat: hasGeo ? lat : null, lon: hasGeo ? lon : null, phone: "", website: "", from: "link" };
	};
	if (u.protocol === "geo:") {
		const [coords, rest] = u.pathname.split("?");
		const [lat, lon] = coords.split(";")[0].split(",");
		const q = new URLSearchParams(rest || u.search.slice(1)).get("q") || "";
		const at = q.match(/^(-?\d+\.\d+),(-?\d+\.\d+)(?:\((.*)\))?/);
		return at ? place(at[1], at[2], at[3] || "") : place(lat, lon, q);
	}
	const host = u.hostname.replace(/^www\./, "");
	const q = u.searchParams;
	if (/(^|\.)google\.[a-z.]+$/.test(host) && /^\/maps/.test(u.pathname) || /^maps\.google\./.test(host)) {
		const at = u.pathname.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/) || u.pathname.match(/!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/);
		const named = u.pathname.match(/\/place\/([^/]+)/);
		const query = q.get("q") || q.get("query") || q.get("destination") || q.get("daddr") || (named ? decodeURIComponent(named[1]) : "");
		const ll = (q.get("ll") || "").split(",");
		const coords = /^-?\d+\.\d+,-?\d+\.\d+$/.test(query) ? query.split(",") : null;
		if (coords) return place(coords[0], coords[1], "");
		return at ? place(at[1], at[2], query) : place(ll[0], ll[1], query);
	}
	if (/openstreetmap\.org$/.test(host)) {
		const hash = u.hash.match(/map=\d+\/(-?\d+\.\d+)\/(-?\d+\.\d+)/);
		return place(q.get("mlat") ?? (hash && hash[1]), q.get("mlon") ?? (hash && hash[2]), q.get("query") || "");
	}
	if (host === "maps.apple.com") {
		const ll = (q.get("ll") || q.get("sll") || "").split(",");
		return place(ll[0], ll[1], q.get("address") || q.get("q") || q.get("daddr") || "");
	}
	if (/bing\.com$/.test(host) && /^\/maps/.test(u.pathname)) {
		const cp = (q.get("cp") || "").split("~");
		return place(cp[0], cp[1], q.get("where1") || q.get("q") || "");
	}
	return null;
}

function eventOf(node) {
	if (!isEvent(node)) return null;
	const start = text(node.startDate);
	if (!/^\d{4}-\d{2}-\d{2}/.test(start)) return null;
	const location = one(node.location);
	const place = location && typeof location === "object" ? placeOf(Object.assign({ "@type": "Place" }, location)) : null;
	const where = place ? [place.name, place.address.text].filter(Boolean).join(", ") : text(location);
	return {
		title: text(node.name),
		start,
		end: text(node.endDate),
		allDay: !/T\d/.test(start),
		where,
		place,
		url: text(node.url),
		description: text(node.description).slice(0, 600),
		cancelled: /Cancelled/i.test(text(node.eventStatus))
	};
}

// "Hauptstr. 5, 12345 Berlin", "10 Downing Street, London SW1A 2AA"
const ADDRESS = /(\b\d{4,5}\s+\p{L}{3,}|\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b|\b\p{L}[\p{L}.-]*(stra(ß|ss)e|str\.|weg|platz|allee|gasse|ring|damm|ufer)\s*\d+|\b\d+\s+\p{L}+\s+(street|st\.|road|rd\.|avenue|ave\.|lane|boulevard|blvd\.?|drive|way|place)\b)/iu;
// "12.03.", "12. März", "March 12", "2026-03-12", "Fr 20:00"
const DATE = /(\b\d{1,2}\.\s?\d{1,2}\.|\b\d{1,2}\.\s?(jan|feb|mär|mar|apr|mai|may|jun|jul|aug|sep|okt|oct|nov|dez|dec)\p{L}*|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\p{L}*\s+\d{1,2}\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}(:\d{2})?\s?(uhr|am|pm)\b|\b\d{1,2}:\d{2}\b)/iu;

function findsOf(raw) {
	const places = [];
	const events = [];
	const seen = new Set();
	const keep = place => {
		if (!place) return;
		const key = `${place.name}|${place.address.text}|${place.lat}|${place.lon}`.toLowerCase();
		if (seen.has(key)) return;
		seen.add(key);
		places.push(place);
	};
	for (const node of raw.nodes || []) {
		const event = eventOf(node);
		if (event) {
			events.push(event);
			continue;
		}
		keep(placeOf(node));
	}
	// an address alone, when a place with a name already has it
	const named = places.filter(place => place.name);
	const kept = places.filter(place => place.name || !named.some(other => other.address.text === place.address.text || (place.lat !== null && other.lat === place.lat && other.lon === place.lon)));
	// links to maps only when the page says nothing itself
	if (kept.length === 0) for (const link of raw.links || []) keep(mapPlace(link.url, link.text));
	const all = kept.length ? kept : places;
	for (const event of events) if (event.place && !all.some(place => place.name === event.place.name && place.address.text === event.place.address.text)) all.push(Object.assign({}, event.place, { from: "event" }));
	return {
		places: all.slice(0, 12),
		events: events.filter(event => !event.cancelled).slice(0, 12),
		selection: raw.selection || "",
		title: raw.title || ""
	};
}

async function pageFinds(tabId, fresh) {
	const tab = tabId >= 0 ? await browser.tabs.get(tabId) : await activeTab();
	if (!scriptable(tab)) return { places: [], events: [], selection: "", title: "", url: "" };
	const cached = findsCache.get(tab.id);
	if (!fresh && cached && cached.url === tab.url) return cached.finds;
	const raw = await inTab(tab.id, readPage);
	const finds = Object.assign(findsOf(raw || {}), { url: tab.url, tabId: tab.id });
	findsCache.set(tab.id, { url: tab.url, finds });
	return finds;
}

// the shell asks after a click: { tabId, link? } → { places, events, selection, title, url, link }
COMMANDS.finds = async message => {
	const finds = Object.assign({}, await pageFinds(message.tabId ?? -1, true));
	finds.link = message.link ? mapPlace(message.link, message.linkText || "") : null;
	return finds;
};

COMMANDS.syncedTabs = async () => {
	if (!browser.pshellChrome) return [];
	return await browser.pshellChrome.command("syncedTabs", {});
};

// ── showing the entries only where they have something ───────────────────
function entriesWithNeeds() {
	return (config.menu || []).filter(entry => entry && entry.needs);
}

function wanted(entry, info, finds) {
	const selection = String(info.selectionText || "");
	if (info.contexts.includes("selection") && selection) {
		return entry.needs === "place" ? ADDRESS.test(selection) : DATE.test(selection);
	}
	if (info.contexts.includes("link") && info.linkUrl) {
		return entry.needs === "place" && mapPlace(info.linkUrl, "") !== null;
	}
	if (!finds) return false;
	return entry.needs === "place" ? finds.places.length > 0 : finds.events.length > 0;
}

let shownTick = 0;
browser.menus.onShown.addListener(async (info, tab) => {
	const entries = entriesWithNeeds();
	if (entries.length === 0) return;
	const tick = ++shownTick;
	const plain = info.contexts.includes("page") || info.contexts.includes("tab") || info.contexts.includes("frame");
	let finds = null;
	if (tab && !tab.incognito && plain && !info.linkUrl && !info.selectionText) {
		const cached = findsCache.get(tab.id);
		finds = cached && cached.url === tab.url ? cached.finds : null;
		if (!finds) {
			// hidden until the page was read, then shown if it holds something
			for (const entry of entries) browser.menus.update(`pshell:${entry.id}`, { visible: false }).catch(() => {});
			browser.menus.refresh();
			try {
				finds = await pageFinds(tab.id, false);
			} catch (error) {
				finds = null;
			}
			if (tick !== shownTick) return;
		}
	}
	for (const entry of entries) {
		const visible = !!tab && !tab.incognito && wanted(entry, info, finds);
		await browser.menus.update(`pshell:${entry.id}`, { visible }).catch(() => {});
	}
	browser.menus.refresh();
});
