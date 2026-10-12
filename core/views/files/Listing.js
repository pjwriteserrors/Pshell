.pragma library
.import "FileKinds.js" as Kinds

// What a pane shows of what the daemon read: filtered, sorted, grouped,
// and brought into a ListModel by changes only, so a file that appears or
// goes is animated instead of the whole view starting over.

const ROLES = ["path", "name", "dir", "link", "broken", "size", "mtime", "mime", "hidden", "exec", "thumb", "canThumb", "text", "sniff", "kind", "group", "uri", "orig", "deleted", "folder", "key", "clipId", "clipKind", "order", "snippet"];

function row(entry, group, home) {
	const path = String(entry.path || "");
	const slash = path.lastIndexOf("/");
	const folder = slash > 0 ? path.slice(0, slash) : "/";
	return {
		path: path,
		name: String(entry.name || ""),
		dir: !!entry.dir,
		link: !!entry.link,
		broken: !!entry.broken,
		size: Number(entry.size) || 0,
		mtime: Number(entry.used || entry.mtime) || 0,
		mime: String(entry.mime || ""),
		hidden: !!entry.hidden,
		exec: !!entry.exec,
		thumb: String(entry.thumb || ""),
		canThumb: !!entry.canThumb,
		// what may be text is looked into like text; binary ones show their glyph after all
		text: !!entry.text || !!entry.sniff,
		sniff: !!entry.sniff,
		kind: Kinds.kindOf(entry),
		group: group || "",
		uri: String(entry.uri || ""),
		orig: String(entry.orig || ""),
		deleted: Number(entry.deleted) || 0,
		// a place of its own (the phone) says where in it a file is
		folder: entry.folder !== undefined ? String(entry.folder) : (home && folder.startsWith(home) ? "~" + folder.slice(home.length) : folder),
		key: String(entry.key || String(entry.name || "").toLowerCase()),
		// an entry of the clipboard history (its cliphist id), and what it held
		clipId: String(entry.clip || ""),
		clipKind: String(entry.clipKind || ""),
		// the place's own order (best matches first) and why it is there
		order: Number(entry.order) || 0,
		snippet: String(entry.snippet || "")
	};
}

function dateGroup(seconds) {
	const time = Number(seconds) * 1000;
	if (!time) return "Unknown";
	const today = new Date();
	today.setHours(0, 0, 0, 0);
	const start = today.getTime();
	if (time >= start) return "Today";
	if (time >= start - 86400000) return "Yesterday";
	if (time >= start - 6 * 86400000) return "This week";
	const date = new Date(time);
	const now = new Date();
	if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()) return "This month";
	if (date.getFullYear() === now.getFullYear()) return "This year";
	return String(date.getFullYear());
}

function dateRank(label) {
	const order = ["Today", "Yesterday", "This week", "This month", "This year"];
	const index = order.indexOf(label);
	if (index >= 0) return index;
	const year = Number(label);
	return year ? 10 + (3000 - year) : 99999;
}

function sizeGroup(entry) {
	if (entry.dir) return "Folders";
	const size = Number(entry.size) || 0;
	if (size >= 1e9) return "Huge";
	if (size >= 1e8) return "Large";
	if (size >= 1e6) return "Medium";
	if (size >= 1e4) return "Small";
	return "Tiny";
}

const SIZE_ORDER = ["Folders", "Huge", "Large", "Medium", "Small", "Tiny"];

// opts: { sort: name|modified|size|kind, desc, foldersFirst, hidden, filter, group: none|kind|date|size, home }
function arrange(entries, opts) {
	const filter = String(opts.filter || "").trim().toLowerCase();
	const words = filter === "" ? [] : filter.split(/\s+/);
	const rows = [];
	// groups the place gives itself (copies found): their own order
	const givenRank = {};
	for (const entry of entries) {
		if (!opts.hidden && entry.hidden) continue;
		if (words.length > 0) {
			const name = String(entry.name || "").toLowerCase();
			if (!words.every(word => name.includes(word))) continue;
		}
		let group = "";
		if (opts.group === "kind") group = Kinds.kindLabel(Kinds.kindOf(entry));
		else if (opts.group === "date") group = dateGroup(entry.used || entry.mtime);
		else if (opts.group === "size") group = sizeGroup(entry);
		else if (opts.group === "given") {
			group = String(entry.group || "");
			givenRank[group] = Number(entry.groupRank) || 0;
		}
		rows.push(row(entry, group, opts.home));
	}
	const sign = opts.desc ? -1 : 1;
	const byName = (a, b) => a.key < b.key ? -1 : (a.key > b.key ? 1 : (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)));
	let compare;
	switch (opts.sort) {
	case "given":
		compare = (a, b) => a.order - b.order;
		break;
	case "modified":
		compare = (a, b) => (a.mtime - b.mtime) * sign || byName(a, b);
		break;
	case "size":
		compare = (a, b) => (a.size - b.size) * sign || byName(a, b);
		break;
	case "kind":
		compare = (a, b) => (Kinds.kindRank(a.kind) - Kinds.kindRank(b.kind)) * sign || byName(a, b);
		break;
	default:
		compare = (a, b) => byName(a, b) * sign;
	}
	const grouped = opts.group && opts.group !== "none";
	const groupRank = r => {
		if (opts.group === "kind") return Kinds.kindRank(r.kind);
		if (opts.group === "date") return dateRank(r.group);
		if (opts.group === "size") return SIZE_ORDER.indexOf(r.group);
		if (opts.group === "given") return givenRank[r.group] ?? 0;
		return 0;
	};
	rows.sort((a, b) => {
		if (grouped) {
			const g = groupRank(a) - groupRank(b);
			if (g !== 0) return g;
		}
		if (opts.foldersFirst !== false && a.dir !== b.dir) return a.dir ? -1 : 1;
		return compare(a, b);
	});
	return rows;
}

function same(a, b) {
	return a.mtime === b.mtime && a.size === b.size && a.thumb === b.thumb && a.name === b.name && a.group === b.group
		&& a.hidden === b.hidden && a.canThumb === b.canThumb && a.folder === b.folder;
}

// Brings `model` to `next` with as few changes as possible. A big change
// (another folder, a new order of many) starts over instead; returns true
// when it did.
function sync(model, next, limit) {
	const count = model.count;
	if (count === 0 || next.length === 0 || Math.abs(next.length - count) > (limit || 400)) {
		model.clear();
		if (next.length > 0) model.append(next);
		return true;
	}
	const wanted = {};
	for (let i = 0; i < next.length; i += 1) wanted[next[i].path] = i;
	// gone
	for (let i = model.count - 1; i >= 0; i -= 1)
		if (wanted[model.get(i).path] === undefined) model.remove(i, 1);
	// moved or new, in the new order
	let moves = 0;
	for (let i = 0; i < next.length; i += 1) {
		const item = next[i];
		if (i < model.count && model.get(i).path === item.path) {
			if (!same(model.get(i), item)) model.set(i, item);
			continue;
		}
		let found = -1;
		for (let j = i + 1; j < model.count; j += 1) {
			if (model.get(j).path === item.path) {
				found = j;
				break;
			}
		}
		if (found >= 0) {
			moves += 1;
			if (moves > (limit || 400)) {
				model.clear();
				model.append(next);
				return true;
			}
			model.move(found, i, 1);
			if (!same(model.get(i), item)) model.set(i, item);
		} else {
			model.insert(i, item);
		}
	}
	while (model.count > next.length) model.remove(model.count - 1, 1);
	return false;
}

// the rows of a grouped grid: a header, then cards `columns` to a row
function rowsOf(items, columns) {
	const rows = [];
	let group = null;
	let current = null;
	for (let i = 0; i < items.length; i += 1) {
		const item = items[i];
		if (item.group !== group) {
			group = item.group;
			let size = 0;
			for (let j = i; j < items.length && items[j].group === group; j += 1) size += 1;
			rows.push({ header: true, title: group, count: size, indexes: [] });
			current = null;
		}
		if (!current || current.indexes.length >= columns) {
			current = { header: false, title: "", count: 0, indexes: [] };
			rows.push(current);
		}
		current.indexes.push(i);
	}
	return rows;
}
