.pragma library

// How the launcher finds apps. A name answers before anything else does:
// the whole name, its start, the start of one of its words, its initials
// ("vsc"), the name as it is run ("nautilus" for Files), then the words of
// what it is (generic name, keywords) and last, from three letters on, the
// words of its description. Letters scattered over a name only count when
// they keep close together, so "fire" finds Firefox and not dconf Editor.
// Use moves a found app up, never brings in one that does not answer.

function fold(text) {
	let value = String(text || "").toLowerCase();
	try {
		value = value.normalize("NFD").replace(/[̀-ͯ]/g, "");
	} catch (error) {}
	return value;
}

// where the words of a name start: after a space or a separator, and at a
// capital following a small letter ("LibreOffice", "qBittorrent")
function wordStarts(text) {
	const raw = String(text || "");
	const starts = [];
	for (let i = 0; i < raw.length; i++) {
		const char = raw[i];
		if (/[\s\-_.:/()+]/.test(char)) continue;
		const before = i > 0 ? raw[i - 1] : "";
		if (i === 0 || /[\s\-_.:/()+]/.test(before) || (/[A-Z]/.test(char) && /[a-z]/.test(before)) || (/[0-9]/.test(char) && !/[0-9]/.test(before)))
			starts.push(i);
	}
	return starts;
}

function range(from, length) {
	const list = [];
	for (let i = 0; i < length; i++) list.push(from + i);
	return list;
}

// letters of the query in order, each as early after the last as possible,
// preferring the start of a word; null when they are not all there or lie
// too far apart to be meant
function scattered(query, text, starts) {
	const indexes = [];
	let at = 0;
	let gaps = 0;
	let onStarts = 0;
	for (let q = 0; q < query.length; q++) {
		const char = query[q];
		let found = -1;
		// a word start within reach wins over the next plain letter
		const next = text.indexOf(char, at);
		if (next < 0) return null;
		const start = starts.find(s => s >= at && text[s] === char && s - next < 6);
		found = start !== undefined ? start : next;
		// the first letter starts a word: "obs" is not in "Tor Browser"
		if (indexes.length === 0 && !starts.includes(found)) return null;
		if (indexes.length > 0) gaps += found - indexes[indexes.length - 1] - 1;
		if (starts.includes(found)) onStarts++;
		indexes.push(found);
		at = found + 1;
	}
	if (gaps > query.length) return null;
	const quality = (onStarts / query.length) * 0.5 + (1 - gaps / (query.length + 1)) * 0.5;
	return { indexes: indexes, quality: quality };
}

// how well a name answers; { score, indexes } with the letters that answer
function scoreName(query, name) {
	const text = fold(name);
	if (query === "" || text === "") return { score: 0, indexes: [] };
	if (text === query) return { score: 1000, indexes: range(0, query.length) };
	if (text.startsWith(query)) return { score: 900 + Math.round(query.length / text.length * 50), indexes: range(0, query.length) };
	const starts = wordStarts(name);
	for (const start of starts) {
		if (text.startsWith(query, start)) return { score: 800 + Math.round(query.length / text.length * 40), indexes: range(start, query.length) };
	}
	// "lib wri": every typed word starts a word of the name, in order
	const parts = query.split(/\s+/).filter(part => part !== "");
	if (parts.length > 1) {
		const indexes = [];
		let from = 0;
		let ok = true;
		for (const part of parts) {
			const start = starts.find(s => s >= from && text.startsWith(part, s));
			if (start === undefined) {
				ok = false;
				break;
			}
			indexes.push(...range(start, part.length));
			from = start + part.length;
		}
		if (ok) return { score: 760, indexes: indexes };
	}
	if (query.length >= 2 && starts.length >= query.length) {
		const initials = starts.map(s => text[s]).join("");
		if (initials.startsWith(query)) return { score: 700, indexes: starts.slice(0, query.length) };
	}
	if (query.length >= 2) {
		const at = text.indexOf(query);
		if (at >= 0) return { score: 500, indexes: range(at, query.length) };
	}
	if (query.length >= 2 && !/\s/.test(query)) {
		const loose = scattered(query, text, starts);
		if (loose) return { score: 200 + Math.round(loose.quality * 150), indexes: loose.indexes };
	}
	return { score: 0, indexes: [] };
}

function wordsStartWith(text, query) {
	const value = fold(text);
	if (value === "") return false;
	if (value.startsWith(query)) return true;
	return wordStarts(text).some(start => value.startsWith(query, start));
}

// the name an app is run by: "org.gnome.Nautilus" → "nautilus"
function runName(id) {
	const value = fold(id).replace(/\.desktop$/, "");
	const parts = value.split(".");
	return parts[parts.length - 1];
}

// entry: { name, genericName, comment, keywords: [], id }
// → { score, indexes (in the name), field: "name" | "id" | "kind" | "keywords" | "about" }
function score(query, entry) {
	const typed = fold(query).trim();
	if (typed === "") return { score: 0, indexes: [], field: "" };
	const byName = scoreName(typed, entry.name);
	if (byName.score >= 500) return { score: byName.score, indexes: byName.indexes, field: "name" };
	const run = runName(entry.id);
	if (typed.length >= 2 && run.startsWith(typed)) return { score: 600, indexes: [], field: "id" };
	if (byName.score > 0) return { score: byName.score, indexes: byName.indexes, field: "name" };
	if (typed.length >= 2 && (entry.keywords || []).some(word => wordsStartWith(word, typed))) return { score: 450, indexes: [], field: "keywords" };
	if (typed.length >= 2 && wordsStartWith(entry.genericName, typed)) return { score: 420, indexes: [], field: "kind" };
	if (typed.length >= 3 && fold(entry.genericName).includes(typed)) return { score: 300, indexes: [], field: "kind" };
	if (typed.length >= 3 && wordsStartWith(entry.comment, typed)) return { score: 150, indexes: [], field: "about" };
	return { score: 0, indexes: [], field: "" };
}

// what use adds: a little for the first launches, less for every further one
function usageBoost(uses) {
	return Math.min(120, Math.round(Math.log2(1 + Math.max(0, Number(uses) || 0)) * 25));
}

// entries: [{ key, name, genericName, comment, keywords, id }]
// usage: key → launches. → [{ key, score, indexes, field }], best first
function rank(entries, query, usage) {
	let found = [];
	for (const entry of entries) {
		const result = score(query, entry);
		if (result.score <= 0) continue;
		found.push({ key: entry.key, name: String(entry.name || ""), base: result.score, score: result.score + usageBoost((usage || {})[entry.key]), indexes: result.indexes, field: result.field });
	}
	// once a name answers well, what only its description or a loose
	// spelling answers is noise
	const best = found.reduce((most, each) => Math.max(most, each.base), 0);
	if (best >= 700) found = found.filter(each => each.base >= 300);
	found.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
	return found;
}

function escape(text) {
	return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// the name with the letters that answer in `color`, as styled text
function highlight(name, indexes, color) {
	const text = String(name || "");
	if (!indexes || indexes.length === 0) return escape(text);
	const marked = {};
	for (const index of indexes) marked[index] = true;
	let out = "";
	let open = false;
	for (let i = 0; i < text.length; i++) {
		if (marked[i] && !open) {
			out += `<font color="${color}"><b>`;
			open = true;
		} else if (!marked[i] && open) {
			out += "</b></font>";
			open = false;
		}
		out += escape(text[i]);
	}
	if (open) out += "</b></font>";
	return out;
}

// the shelves of the app grid, in the order they are shown; an app sits
// on the first whose freedesktop categories it has
const shelves = [
	{ id: "all", label: "All", glyph: "view_grid", categories: [] },
	{ id: "internet", label: "Internet", glyph: "web", categories: ["Network", "WebBrowser", "Email", "Chat", "InstantMessaging"] },
	{ id: "dev", label: "Develop", glyph: "code_braces", categories: ["Development", "IDE", "TextEditor"] },
	{ id: "games", label: "Games", glyph: "gamepad_variant", categories: ["Game"] },
	{ id: "graphics", label: "Graphics", glyph: "palette", categories: ["Graphics", "Photography"] },
	{ id: "media", label: "Media", glyph: "play_circle", categories: ["AudioVideo", "Audio", "Video", "Music", "Player"] },
	{ id: "office", label: "Office", glyph: "file_document", categories: ["Office", "Education", "Science"] },
	{ id: "system", label: "System", glyph: "cog", categories: ["System", "Settings", "Monitor", "PackageManager"] },
	{ id: "tools", label: "Tools", glyph: "wrench", categories: [] }
];

// the order a category decides by: games before development before the rest
const decidingOrder = ["games", "dev", "graphics", "media", "internet", "office", "system"];

function shelfOf(categories) {
	const list = (categories || []).map(String);
	for (const id of decidingOrder) {
		const shelf = shelves.find(each => each.id === id);
		if (shelf.categories.some(category => list.includes(category))) return id;
	}
	return "tools";
}
