// What the browser remembers of pages (docs/browser.md "Page memory"), each
// part only while the shell switches it on (config.memory, kept for the
// next start):
//
// - index: the text of pages looked at for a while, in this browser's
//   IndexedDB ("pshell-memory"), never of a private window or a page with a
//   password field, a payment form or a sign-in address (content/memory.js
//   decides). `search` (the launcher's >tab) also answers `pages` found by
//   their text, with a snippet. Each page is marked with the mode it was
//   seen in (work: a qtrack timer ran); without the timer work-only pages
//   are not found. Pages go after 120 days, the oldest beyond 4000.
//   The same visits make the day: `memoryToday` lists today's pages with how
//   long each was in front, how far it was read and how long something
//   played (the shell's day review).
// - reading: where a long page was left (storage "reading"); the page offers
//   to go on there, also from another device (the shell asks pshell-core).
// - highlights: text kept from a page as a note is marked on it again.
// - clips: text copied from a page goes to the shell with its address and a
//   text fragment (#:~:text=) that leads back to it.
//
// content/memory.js asks "memory:page" on every page and reports what
// happens; nothing of a private window is ever taken.

const MEMORY_DB = "pshell-memory";
const KEEP_PAGES = 4000;
const KEEP_DAYS_OF = 120;
const KEEP_REVIEW_DAYS = 14;
const MAX_TEXT = 40000;
const MAX_TERMS = 4000;
const TRACKING = /^(utm_.*|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|yclid|_hsenc|_hsmi|ref_src|ref_url|si)$/i;

let memoryKept = { index: false, reading: false, highlights: false, clips: false, work: false };
browser.storage.local.get("memory").then(kept => {
	if (kept.memory) memoryKept = Object.assign(memoryKept, kept.memory);
});

// what the shell switched on; the last one it sent while it is away
function memoryConfig() {
	const now = config.memory;
	if (now && JSON.stringify(now) !== JSON.stringify(memoryKept)) {
		memoryKept = Object.assign({}, now);
		browser.storage.local.set({ memory: memoryKept });
	}
	return memoryKept;
}

function modeNow() {
	return memoryConfig().work ? "work" : "private";
}

// the page an address stands for (pcore/server/pshell_core/browse.py key_of)
function pageKey(url) {
	let parts;
	try {
		parts = new URL(url);
	} catch (error) {
		return "";
	}
	if (!/^https?:$/.test(parts.protocol)) return "";
	let host = parts.hostname.toLowerCase().replace(/^www\./, "");
	if (parts.port) host += `:${parts.port}`;
	let path = parts.pathname || "/";
	if (path.length > 1) path = path.replace(/\/+$/, "") || "/";
	const query = new URLSearchParams();
	for (const [name, value] of parts.searchParams) if (!TRACKING.test(name)) query.append(name, value);
	const rest = query.toString();
	return `${host}${path}${rest ? `?${rest}` : ""}`;
}

function dayOf(time) {
	const date = new Date(time);
	return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

// ── the store ────────────────────────────────────────────────────────────────
let memoryDb = null;
function openMemory() {
	if (memoryDb) return memoryDb;
	memoryDb = new Promise((resolve, reject) => {
		const request = indexedDB.open(MEMORY_DB, 1);
		request.onupgradeneeded = () => {
			const db = request.result;
			const pages = db.createObjectStore("pages", { keyPath: "key" });
			pages.createIndex("terms", "terms", { multiEntry: true });
			pages.createIndex("last", "last");
			const days = db.createObjectStore("days", { keyPath: "id" });
			days.createIndex("day", "day");
		};
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => {
			memoryDb = null;
			reject(request.error);
		};
	});
	return memoryDb;
}

function done(request) {
	return new Promise((resolve, reject) => {
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

async function store(name, mode) {
	return (await openMemory()).transaction(name, mode || "readonly").objectStore(name);
}

// words without accents, lower case
function fold(text) {
	return String(text || "").normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

function termsOf(title, text) {
	const seen = new Set();
	for (const part of [title, text]) {
		for (const word of fold(part).split(/[^\p{L}\p{N}]+/u)) {
			if (word.length < 2 || word.length > 30) continue;
			seen.add(word);
			if (seen.size >= MAX_TERMS) return [...seen];
		}
	}
	return [...seen];
}

// a visit of a page (content/memory.js): kept with its text the first time,
// then how long it was in front, how far read, how long something played
async function noteVisit(message, tab) {
	const settings = memoryConfig();
	if (!settings.index || !tab || tab.incognito) return;
	const key = pageKey(message.url);
	if (!key) return;
	const now = Date.now();
	const mode = modeNow();
	const title = String(message.title || "").slice(0, 300);
	const pages = await store("pages", "readwrite");
	const old = await done(pages.get(key));
	const page = old || { key, first: now, visits: 0, modes: [] };
	page.url = String(message.url).split("#")[0];
	page.host = hostOf(page.url);
	page.title = title || page.title || "";
	page.last = now;
	if (message.first) page.visits = (page.visits || 0) + 1;
	if (!page.modes.includes(mode)) page.modes = page.modes.concat([mode]);
	if (typeof message.text === "string" && message.text.trim()) {
		page.text = message.text.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim().slice(0, MAX_TEXT);
		page.terms = termsOf(page.title, page.text);
	} else if (!page.terms) {
		page.text = page.text || "";
		page.terms = termsOf(page.title, "");
	}
	if (message.kind) page.kind = message.kind;
	pages.put(page);

	const days = await store("days", "readwrite");
	const id = `${dayOf(now)}|${key}`;
	const day = (await done(days.get(id))) || { id, day: dayOf(now), key, first: now, dwell: 0, media: 0, progress: 0, modes: [] };
	Object.assign(day, { url: page.url, host: page.host, title: page.title, last: now, kind: message.kind || day.kind || "page" });
	day.dwell = Math.max(day.dwell, Number(message.dwell) || 0);
	day.media = Math.max(day.media, Number(message.media) || 0);
	day.progress = Math.max(day.progress, Number(message.progress) || 0);
	if (!day.modes.includes(mode)) day.modes = day.modes.concat([mode]);
	days.put(day);
}

// what the mode now may see: without a timer nothing only seen at work
function visible(item) {
	return modeNow() === "work" || !item.modes || item.modes.includes("private");
}

function snippetOf(text, tokens) {
	const plain = String(text || "").replace(/\s+/g, " ");
	const folded = fold(plain);
	let at = -1;
	for (const token of tokens) {
		at = folded.indexOf(token);
		if (at >= 0) break;
	}
	if (at < 0) return plain.slice(0, 140);
	const start = Math.max(0, at - 50);
	const cut = plain.slice(start, start + 160);
	return `${start > 0 ? "…" : ""}${cut.slice(cut.indexOf(" ") > 0 && start > 0 ? cut.indexOf(" ") + 1 : 0)}${start + 160 < plain.length ? "…" : ""}`;
}

// pages whose title or text holds every word typed (the last one as its beginning)
async function searchPages(query, limit) {
	if (!memoryConfig().index) return [];
	const tokens = fold(query).split(/[^\p{L}\p{N}]+/u).filter(word => word.length >= 2);
	if (tokens.length === 0 || !tokens.some(word => word.length >= 3)) return [];
	const pages = await store("pages");
	const terms = pages.index("terms");
	let keys = null;
	for (const [index, token] of tokens.entries()) {
		const prefix = index === tokens.length - 1 || token.length >= 4;
		const range = prefix && token.length >= 3 ? IDBKeyRange.bound(token, `${token}￿`) : IDBKeyRange.only(token);
		const found = new Set(await done(terms.getAllKeys(range, 3000)));
		keys = keys === null ? found : new Set([...keys].filter(key => found.has(key)));
		if (keys.size === 0) return [];
	}
	const now = Date.now();
	const found = [];
	for (const key of [...keys].slice(0, 400)) {
		const page = await done(pages.get(key));
		if (!page || !visible(page)) continue;
		const title = fold(page.title);
		let score = Math.log((page.visits || 1) + 1);
		for (const token of tokens) if (title.includes(token)) score += 3;
		if (now - page.last < 7 * 86400 * 1000) score += 1;
		found.push({ page, score });
	}
	found.sort((a, b) => b.score - a.score || b.page.last - a.page.last);
	return found.slice(0, limit).map(({ page }) => ({
		title: page.title,
		url: page.url,
		host: page.host,
		last: page.last,
		snippet: snippetOf(page.text, tokens)
	}));
}

async function pruneMemory() {
	try {
		const now = Date.now();
		const pages = await store("pages", "readwrite");
		const old = await done(pages.index("last").getAllKeys(IDBKeyRange.upperBound(now - KEEP_DAYS_OF * 86400 * 1000)));
		for (const key of old) pages.delete(key);
		const count = await done(pages.count());
		if (count > KEEP_PAGES) {
			const oldest = await done(pages.index("last").getAllKeys(null, count - KEEP_PAGES));
			for (const key of oldest) pages.delete(key);
		}
		const days = await store("days", "readwrite");
		const gone = await done(days.index("day").getAllKeys(IDBKeyRange.upperBound(dayOf(now - KEEP_REVIEW_DAYS * 86400 * 1000), true)));
		for (const id of gone) days.delete(id);
	} catch (error) {
		console.error("[pshell] memory:", error);
	}
}
setTimeout(pruneMemory, 30 * 1000);
setInterval(pruneMemory, 6 * 3600 * 1000);

// everything kept, gone (Settings › Browser)
async function forgetMemory() {
	(await store("pages", "readwrite")).clear();
	(await store("days", "readwrite")).clear();
	await browser.storage.local.remove("reading");
}

// ── where a page was left ────────────────────────────────────────────────────
async function readingOf(key) {
	const kept = (await browser.storage.local.get("reading")).reading || {};
	return kept[key] || null;
}

let readingDue = Promise.resolve();
function keepReading(key, place) {
	readingDue = readingDue.then(async () => {
		const kept = (await browser.storage.local.get("reading")).reading || {};
		kept[key] = place;
		const keys = Object.keys(kept);
		if (keys.length > 600) {
			keys.sort((a, b) => kept[a].at - kept[b].at);
			for (const old of keys.slice(0, keys.length - 600)) delete kept[old];
		}
		await browser.storage.local.set({ reading: kept });
	}).catch(() => {});
	return readingDue;
}

async function noteReading(message, tab) {
	if (!memoryConfig().reading || !tab || tab.incognito) return;
	const key = pageKey(message.url);
	if (!key) return;
	const place = {
		url: String(message.url).split("#")[0],
		title: String(message.title || "").slice(0, 300),
		progress: Math.max(0, Math.min(1, Number(message.progress) || 0)),
		anchor: String(message.anchor || "").replace(/\s+/g, " ").trim().slice(0, 200),
		mode: modeNow(),
		at: Date.now()
	};
	await keepReading(key, place);
	toShell({ type: "event", name: "reading", key, ...place });
}

// the shell's answer for a page (pshell-core: where another device left
// it, highlights), or nothing after a moment
async function fromShellFor(url, key) {
	if (!bridge.connected) return null;
	const wanted = memoryConfig();
	if (!wanted.reading && !wanted.highlights) return null;
	return await Promise.race([
		ask("memory:page", { url, key }).catch(() => null),
		new Promise(resolve => setTimeout(() => resolve(null), 2500))
	]);
}

async function pageAnswer(message, tab) {
	const wanted = memoryConfig();
	const answer = { features: { index: !!wanted.index, reading: !!wanted.reading, highlights: !!wanted.highlights, clips: !!wanted.clips }, reading: null, highlights: [] };
	if (!tab || tab.incognito) return Object.assign(answer, { features: {} });
	const key = pageKey(message.url);
	if (!key) return answer;
	const local = wanted.reading ? await readingOf(key) : null;
	const remote = await fromShellFor(message.url, key);
	let place = local;
	const other = remote && remote.reading;
	if (wanted.reading && other && typeof other.progress === "number") {
		const newer = !local || other.at * 1000 > local.at + 60 * 1000;
		if (newer && (!local || Math.abs(other.progress - local.progress) > 0.01)) place = { progress: other.progress, anchor: other.anchor || "", device: other.device || "", at: other.at * 1000, done: !!other.done };
	}
	if (place && !place.done && place.progress >= 0.05 && place.progress < 0.95) answer.reading = { progress: place.progress, anchor: place.anchor || "", device: place.device || "" };
	if (wanted.highlights && remote && Array.isArray(remote.highlights)) answer.highlights = remote.highlights.map(item => ({ id: item.id, text: String(item.text || "") })).filter(item => item.text);
	return answer;
}

// the mark of kept text, in the shell's primary colour (styles.js keeps the theme)
async function highlightCss(tab) {
	const primary = (typeof themeColors !== "undefined" && themeColors.icons_attention) || "#d9a35b";
	const code = `::highlight(pshell-kept) { background-color: color-mix(in srgb, ${primary} 38%, transparent); color: inherit; text-decoration: underline 2px color-mix(in srgb, ${primary} 80%, transparent); }`;
	await browser.tabs.insertCSS(tab.id, { code, cssOrigin: "user" }).catch(() => {});
	return true;
}

// ── copied text ──────────────────────────────────────────────────────────────
function noteCopy(message, tab) {
	if (!memoryConfig().clips || !tab || tab.incognito) return;
	const text = String(message.text || "");
	if (!text.trim()) return;
	toShell({
		type: "event",
		name: "copied",
		text: text.slice(0, 4000),
		url: String(message.url || "").split("#")[0],
		title: String(message.title || "").slice(0, 300),
		fragment: String(message.fragment || "").slice(0, 600),
		mode: modeNow()
	});
}

browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || typeof message.pshell !== "string" || !message.pshell.startsWith("memory:")) return;
	const tab = sender.tab;
	switch (message.pshell) {
		case "memory:page":
			return pageAnswer(message, tab);
		case "memory:visit":
			return noteVisit(message, tab).then(() => true, error => {
				console.error("[pshell] memory:", error);
				return false;
			});
		case "memory:reading":
			return noteReading(message, tab).then(() => true);
		case "memory:css":
			return tab && !tab.incognito ? highlightCss(tab) : Promise.resolve(false);
		case "memory:copied":
			noteCopy(message, tab);
			return Promise.resolve(true);
	}
});

// ── for the shell ────────────────────────────────────────────────────────────
// the launcher's search also finds pages by their text
const searchWithoutText = COMMANDS.search;
COMMANDS.search = async message => {
	const found = await searchWithoutText(message);
	const query = String(message.query || "").trim();
	if (!query) return found;
	try {
		found.pages = await searchPages(query, Math.max(1, Math.min(20, message.limit || 8)));
	} catch (error) {
		found.pages = [];
	}
	return found;
};

// today's pages for the day review: [{ key, url, title, host, kind, dwell
// (s in front), media (s played), progress, modes, first, last }]
COMMANDS.memoryToday = async message => {
	if (!memoryConfig().index) return [];
	const days = await store("days");
	const today = await done(days.index("day").getAll(IDBKeyRange.only(dayOf(Date.now()))));
	return today.filter(visible).sort((a, b) => b.last - a.last);
};

COMMANDS.memoryForget = async () => {
	await forgetMemory();
	return true;
};

// a page and where it was read, for a test or the shell
COMMANDS.memoryPage = async message => {
	const key = pageKey(message.url);
	const page = key ? await done((await store("pages")).get(key)) : null;
	return { key, page: page ? Object.assign({}, page, { terms: page.terms.length }) : null, reading: key ? await readingOf(key) : null };
};
