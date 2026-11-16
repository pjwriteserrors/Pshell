// What files look like: their thumbnail (or a tinted kind tile), cards and
// list rows, the drag ghost stack, and the thumbnail waiting list that the
// "thumb" event fills.
import { h, icon, kindIcon, kindTone, thumbable, size as fmtSize, when, nameOf, parentOf, KIND_LABEL, kindOf, plural } from "./util.js";
import * as api from "./api.js";

const bust = new Map(); // path → counter, after a "thumb" event
const waiting = new Map(); // path → Set(img)

api.on("thumb", data => {
	const path = data.path;
	if (!path) return;
	bust.set(path, (bust.get(path) || 0) + 1);
	const imgs = waiting.get(path);
	if (!imgs) return;
	waiting.delete(path);
	for (const img of imgs) {
		if (!img.isConnected) continue;
		const size = img.dataset.size || 256;
		img.classList.remove("failed");
		img.src = api.thumbUrl(path, size, bust.get(path));
	}
});

// a thumbnail that is not made yet: the server queued it, the "thumb" event brings it
// a 404 says why: "queued" (it is being made) or "none" (no picture to show –
// asking again would not help)
const noPicture = new Set();
export function waitForThumb(img, path) {
	if (noPicture.has(path)) return;
	if (!waiting.has(path)) waiting.set(path, new Set());
	waiting.get(path).add(img);
	fetch(img.src, { credentials: "same-origin" }).then(async r => {
		if (r.ok) {
			if (img.dataset.retried) return;
			img.dataset.retried = "1";
			img.src = `${img.src.split("&r=")[0]}&r=${Date.now()}`;
			return;
		}
		const data = await r.json().catch(() => ({}));
		if (data.code === "none") {
			noPicture.add(path);
			waiting.get(path)?.delete(img);
		}
	}).catch(() => {});
}

export function hasNoPicture(path) {
	return noPicture.has(path);
}

export function thumbSrc(entry, size = 256) {
	return api.thumbUrl(entry.path, size, bust.get(entry.path));
}

// a folder's look (FileThumb.qml): a folder with a few of its pictures
// peeking out – looked up only once the card is on screen
const previewCache = new Map();
const previewQueue = [];
let previewRunning = 0;
function folderPreviews(path) {
	if (previewCache.has(path)) return previewCache.get(path);
	const promise = new Promise(resolve => previewQueue.push({ path, resolve }));
	previewCache.set(path, promise);
	pumpPreviews();
	return promise;
}
function pumpPreviews() {
	while (previewRunning < 3 && previewQueue.length) {
		const { path, resolve } = previewQueue.shift();
		previewRunning += 1;
		api.get("/api/ls", { path }, { quiet: true }).then(data => {
			const pics = (data.entries || []).filter(e => !e.dir && e.thumb && ["image", "video", "pdf"].includes(e.kind)).slice(0, 3);
			resolve({ pics, count: (data.entries || []).length });
		}).catch(() => resolve({ pics: [], count: null })).finally(() => {
			previewRunning -= 1;
			pumpPreviews();
		});
	}
}
const folderSeen = typeof IntersectionObserver === "function" ? new IntersectionObserver(items => {
	for (const item of items) {
		if (!item.isIntersecting) continue;
		folderSeen.unobserve(item.target);
		item.target._load?.();
	}
}, { rootMargin: "200px" }) : null;

export function forgetFolderPreview(path) {
	previewCache.delete(path);
}

function folderArt(entry, tile) {
	const sheets = h("div.folder-sheets");
	const front = h("div.folder-front", entry.vault ? icon("lock_outline") : entry.favorite ? icon("star") : null);
	const art = h("div.folder-art", h("div.folder-back"), sheets, front);
	tile.appendChild(art);
	tile._load = () => folderPreviews(entry.path).then(({ pics, count }) => {
		if (count !== null) tile.dataset.count = count;
		tile.dispatchEvent(new CustomEvent("folder-count", { detail: count, bubbles: true }));
		pics.forEach((pic, i) => {
			const img = h("img.sheet", { alt: "", draggable: false, decoding: "async" });
			img.style.setProperty("--i", i);
			img.style.setProperty("--n", pics.length);
			img.addEventListener("load", () => img.classList.add("loaded"));
			img.src = thumbSrc(pic, 256);
			sheets.appendChild(img);
		});
		if (pics.length) art.classList.add("filled");
	});
	if (folderSeen) folderSeen.observe(tile);
	else tile._load();
}

// the picture of an entry: a thumbnail that fades in, a folder, or the
// kind tile (a tinted squircle with the glyph and the ending)
export function art(entry, { size = 256, folder = true } = {}) {
	const kind = kindOf(entry);
	const tile = h("div.art", { dataset: { kind } });
	tile.style.setProperty("--tone", kindTone(entry));
	if (entry.dir) {
		tile.classList.add("folder");
		if (folder) folderArt(entry, tile);
		else tile.appendChild(h("div.kind-tile", icon(kindIcon(entry))));
		return tile;
	}
	const ext = /\.([^./]{1,5})$/.exec(entry.name || "")?.[1];
	const glyph = h("div.kind-tile", icon(kindIcon(entry)), ext ? h("span.kind-ext", ext.toUpperCase()) : null);
	tile.appendChild(glyph);
	if (thumbable(entry) && !noPicture.has(entry.path)) {
		const img = h("img.thumb", { alt: "", loading: "lazy", decoding: "async", draggable: false });
		img.dataset.size = size;
		img.addEventListener("load", () => {
			img.classList.add("loaded");
			tile.classList.add("has-thumb");
		});
		img.addEventListener("error", () => {
			img.classList.add("failed");
			waitForThumb(img, entry.path);
		});
		img.src = thumbSrc(entry, size);
		tile.appendChild(img);
		if (entry.kind === "video") tile.appendChild(h("span.art-badge", icon("play")));
	}
	return tile;
}

export function metaLine(entry) {
	if (entry.note) return entry.note;
	if (entry.dir) return when(entry.mtime);
	return [fmtSize(entry.size), when(entry.mtime)].filter(Boolean).join(" · ");
}

export function card(entry, { showFolder = false } = {}) {
	const meta = h("div.card-meta.ellipsis", showFolder ? parentOf(entry.path) : metaLine(entry));
	const el = h("div.file-card", { dataset: { path: entry.path }, draggable: "true", role: "option", tabindex: "-1" },
		h("div.card-plate"),
		h("div.card-art", art(entry, { size: 256 })),
		h("div.card-name", { title: entry.name }, entry.favorite && !entry.dir ? icon("star", "fav") : null, h("span.name-text", entry.name)),
		meta,
		(entry.tags || []).length ? h("div.card-tags", entry.tags.slice(0, 3).map(t => h("span.tag-dot", { title: t }))) : null,
		h("span.card-check", icon("check_bold")));
	if (entry.dir && !showFolder && !entry.note) el.addEventListener("folder-count", event => {
		if (event.detail !== null) meta.textContent = plural(event.detail, "item");
	});
	if (entry.score) el.appendChild(h("span.card-score", { title: "How close in meaning" }, icon("creation"), `${Math.round(entry.score * 100)}`));
	return el;
}

export function row(entry, { showFolder = false } = {}) {
	const ext = entry.dir ? "Folder" : (/\.([^./]{1,6})$/.exec(entry.name || "")?.[1] || KIND_LABEL[entry.kind] || "File").toUpperCase();
	return h("div.file-row", { dataset: { path: entry.path }, draggable: "true", role: "option", tabindex: "-1" },
		h("span.card-check", icon("check_bold")),
		h("div.row-art", art(entry, { size: 256, folder: false })),
		h("div.row-name", h("span.name-text.ellipsis", { title: entry.name }, entry.name), entry.favorite ? icon("star", "fav") : null, (entry.tags || []).slice(0, 3).map(t => h("span.chip.small.tag-chip", t))),
		h("div.row-where.ellipsis", showFolder ? parentOf(entry.path) : entry.note || ""),
		h("div.row-date.tabular", when(entry.mtime)),
		h("div.row-size.tabular", entry.dir ? "" : fmtSize(entry.size)),
		h("div.row-kind", ext));
}

export function listHeader(view, onSort) {
	const col = (key, label, cls) => {
		const on = view.sort === key;
		const b = h(`button.lh-col${cls ? "." + cls : ""}`, { type: "button", class: on ? "on" : "" }, label, on ? icon(view.desc ? "chevron_down" : "chevron_up") : null);
		b.addEventListener("click", () => onSort(key));
		return b;
	};
	return h("div.list-head", h("span"), h("span"), col("name", "Name", "lh-name"), h("span"), col("mtime", "Modified", "num"), col("size", "Size", "num"), col("kind", "Kind"));
}

// the stack that follows the pointer while dragging, with a count badge
export function dragGhost(entries) {
	const ghost = h("div.drag-ghost");
	entries.slice(0, 3).reverse().forEach((entry, i, list) => {
		const layer = h("div.ghost-card", art(entry, { size: 256 }));
		const depth = list.length - 1 - i;
		layer.style.transform = `translate(${depth * 6}px, ${depth * -6}px) rotate(${depth * 4}deg)`;
		ghost.appendChild(layer);
	});
	if (entries.length > 1) ghost.appendChild(h("span.ghost-count", String(entries.length)));
	document.body.appendChild(ghost);
	setTimeout(() => ghost.remove(), 0);
	return ghost;
}

export function sortEntries(entries, { sort = "name", desc = false, foldersFirst = true } = {}) {
	const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
	const key = {
		name: (a, b) => collator.compare(a.name, b.name),
		mtime: (a, b) => (a.mtime || 0) - (b.mtime || 0),
		size: (a, b) => (a.size || 0) - (b.size || 0),
		kind: (a, b) => collator.compare(a.kind || "", b.kind || "") || collator.compare(a.name, b.name)
	}[sort] || ((a, b) => collator.compare(a.name, b.name));
	return entries.slice().sort((a, b) => {
		if (foldersFirst && a.dir !== b.dir) return a.dir ? -1 : 1;
		const r = key(a, b);
		return desc ? -r : r;
	});
}

export function groupOf(entry, mode) {
	if (mode === "kind") return entry.dir ? "Folders" : `${KIND_LABEL[entry.kind] || "File"}s`.replace("Audios", "Audio").replace("Codes", "Code");
	if (mode === "date") {
		const d = new Date((entry.mtime || 0) * 1000);
		const now = new Date();
		const days = (now - d) / 86400000;
		if (days < 1 && d.getDate() === now.getDate()) return "Today";
		if (days < 7) return "This week";
		if (days < 31) return "This month";
		if (d.getFullYear() === now.getFullYear()) return "This year";
		return String(d.getFullYear());
	}
	return "";
}

export { nameOf };

// what came lately: the newest files of the index
export async function recentEntries(limit = 80) {
	const data = await api.get("/api/recent", { limit }, { quiet: true });
	return Array.isArray(data) ? data : data.entries || [];
}
