// Small helpers every view uses: building elements, icons, formatting.
import { GLYPHS } from "./icons.js";

// h("div.card.big", {onclick, style: {...}, dataset: {...}}, children…)
export function h(tag, props, ...children) {
	if (props instanceof Node || typeof props === "string" || Array.isArray(props)) {
		children.unshift(props);
		props = null;
	}
	const [name, ...classes] = tag.split(".");
	let el;
	let id = "";
	const base = name.includes("#") ? name.split("#") : [name];
	if (base.length > 1) id = base[1];
	const tagName = base[0] || "div";
	el = tagName === "svg" || tagName === "path" || tagName === "circle" || tagName === "g" || tagName === "rect" || tagName === "line" || tagName === "text"
		? document.createElementNS("http://www.w3.org/2000/svg", tagName)
		: document.createElement(tagName);
	if (id) el.id = id;
	if (classes.length) el.setAttribute("class", classes.join(" "));
	if (props) {
		for (const [key, value] of Object.entries(props)) {
			if (value === undefined || value === null || value === false) continue;
			if (key === "style" && typeof value === "object") Object.assign(el.style, value);
			else if (key === "dataset") Object.assign(el.dataset, value);
			else if (key === "class") el.setAttribute("class", [el.getAttribute("class"), value].filter(Boolean).join(" "));
			else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
			else if (key === "html") el.innerHTML = value;
			else if (key === "text") el.textContent = value;
			else if (key in el && !(el instanceof SVGElement) && key !== "list" && key !== "form") el[key] = value;
			else el.setAttribute(key, value === true ? "" : value);
		}
	}
	append(el, children);
	return el;
}

function append(el, children) {
	for (const child of children) {
		if (child === null || child === undefined || child === false) continue;
		if (Array.isArray(child)) append(el, child);
		else if (child instanceof Node) el.appendChild(child);
		else el.appendChild(document.createTextNode(String(child)));
	}
}

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

export function glyph(name) {
	const code = GLYPHS[name] ?? GLYPHS[String(name).replace(/_outline$/, "")] ?? GLYPHS[`${name}_outline`];
	return code ? String.fromCodePoint(code) : "";
}

export function icon(name, extra = "") {
	const el = document.createElement("span");
	el.className = `i ${extra}`.trim();
	el.textContent = glyph(name);
	el.setAttribute("aria-hidden", "true");
	return el;
}

export function clear(el) {
	while (el.firstChild) el.removeChild(el.firstChild);
	return el;
}

export function debounce(fn, ms) {
	let timer = 0;
	const out = (...args) => {
		clearTimeout(timer);
		timer = setTimeout(() => fn(...args), ms);
	};
	out.cancel = () => clearTimeout(timer);
	return out;
}

export function throttleFrame(fn) {
	let queued = false;
	let last = null;
	return (...args) => {
		last = args;
		if (queued) return;
		queued = true;
		requestAnimationFrame(() => {
			queued = false;
			fn(...last);
		});
	};
}

// ── formatting ─────────────────────────────────────────────────────────────
export function size(bytes) {
	if (bytes === null || bytes === undefined || Number.isNaN(bytes)) return "";
	const units = ["B", "KB", "MB", "GB", "TB"];
	let n = Number(bytes);
	let u = 0;
	while (n >= 1000 && u < units.length - 1) {
		n /= 1000;
		u += 1;
	}
	return `${u === 0 ? n : n < 10 ? n.toFixed(1) : Math.round(n)} ${units[u]}`;
}

// seconds or milliseconds or an ISO string → Date
export function toDate(value) {
	if (value === null || value === undefined || value === "") return null;
	if (value instanceof Date) return value;
	if (typeof value === "number") return new Date(value < 1e12 ? value * 1000 : value);
	const n = Number(value);
	if (!Number.isNaN(n)) return toDate(n);
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d;
}

const dayFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" });
const dayYearFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" });
const timeFmt = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit" });
const longDay = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });

export function when(value) {
	const d = toDate(value);
	if (!d) return "";
	const now = new Date();
	const diff = (now - d) / 1000;
	if (diff >= -60 && diff < 45) return "just now";
	if (diff >= 0 && diff < 3600) return `${Math.round(diff / 60)} min ago`;
	const sameDay = d.toDateString() === now.toDateString();
	if (sameDay) return `today ${timeFmt.format(d)}`;
	const yesterday = new Date(now);
	yesterday.setDate(now.getDate() - 1);
	if (d.toDateString() === yesterday.toDateString()) return `yesterday ${timeFmt.format(d)}`;
	if (d.getFullYear() === now.getFullYear()) return dayFmt.format(d);
	return dayYearFmt.format(d);
}

export function fullDate(value) {
	const d = toDate(value);
	return d ? `${longDay.format(d)}, ${timeFmt.format(d)}` : "";
}

export function dayLabel(value) {
	const d = toDate(value);
	if (!d) return "";
	const now = new Date();
	if (d.toDateString() === now.toDateString()) return "Today";
	const y = new Date(now);
	y.setDate(now.getDate() - 1);
	if (d.toDateString() === y.toDateString()) return "Yesterday";
	return longDay.format(d);
}

export function duration(seconds) {
	if (!seconds && seconds !== 0) return "";
	seconds = Math.round(seconds);
	const hh = Math.floor(seconds / 3600);
	const mm = Math.floor((seconds % 3600) / 60);
	const ss = seconds % 60;
	return hh > 0 ? `${hh}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}` : `${mm}:${String(ss).padStart(2, "0")}`;
}

export function uptime(seconds) {
	if (!seconds) return "";
	const d = Math.floor(seconds / 86400);
	const hh = Math.floor((seconds % 86400) / 3600);
	const mm = Math.floor((seconds % 3600) / 60);
	return d > 0 ? `${d} d ${hh} h` : hh > 0 ? `${hh} h ${mm} min` : `${mm} min`;
}

export function plural(n, one, many) {
	return `${n} ${n === 1 ? one : many ?? `${one}s`}`;
}

// ── paths ──────────────────────────────────────────────────────────────────
export function nameOf(path) {
	const clean = String(path || "/").replace(/\/+$/, "");
	return clean.split("/").pop() || "NAS";
}

export function parentOf(path) {
	const clean = String(path || "/").replace(/\/+$/, "");
	const i = clean.lastIndexOf("/");
	return i <= 0 ? "/" : clean.slice(0, i);
}

export function join(folder, name) {
	return `${String(folder || "/").replace(/\/+$/, "")}/${name}`;
}

export function extOf(name) {
	const m = /\.([^./]+)$/.exec(String(name || ""));
	return m ? m[1].toLowerCase() : "";
}

// ── kinds: icon and colour per kind (FileKinds.js in the shell) ────────────
const KIND_ICON = {
	dir: "folder",
	image: "image_outline",
	video: "movie_outline",
	audio: "music_note",
	pdf: "file_pdf_box",
	text: "text_box_outline",
	archive: "zip_box_outline",
	code: "code_braces",
	office: "file_document_outline",
	other: "file_outline"
};

const KIND_TONE = {
	dir: "var(--primary)",
	image: "var(--secondary)",
	video: "var(--tertiary)",
	audio: "var(--warning)",
	pdf: "var(--danger)",
	text: "var(--text-muted)",
	archive: "var(--warning)",
	code: "var(--success)",
	office: "var(--primary)",
	other: "var(--text-subtle)"
};

export const KIND_LABEL = {
	dir: "Folder",
	image: "Picture",
	video: "Video",
	audio: "Audio",
	pdf: "PDF",
	text: "Text",
	archive: "Archive",
	code: "Code",
	office: "Document",
	other: "File"
};

export function kindOf(entry) {
	if (!entry) return "other";
	if (entry.dir) return "dir";
	return entry.kind || "other";
}

export function kindIcon(entry) {
	if (entry?.dir && entry.vault) return "folder_lock_outline";
	if (entry?.dir && entry.favorite) return "folder_star_outline";
	return KIND_ICON[kindOf(entry)] ?? "file_outline";
}

export function kindTone(entry) {
	return KIND_TONE[kindOf(entry)] ?? KIND_TONE.other;
}

export function thumbable(entry) {
	return !!entry && !entry.dir && ["image", "video", "pdf", "audio"].includes(entry.kind);
}

export function uid() {
	return Math.random().toString(36).slice(2, 10);
}

export function copyText(text) {
	if (navigator.clipboard?.writeText && window.isSecureContext) return navigator.clipboard.writeText(text);
	// plain http (the NAS on the LAN): the old way
	const area = h("textarea", { style: { position: "fixed", opacity: "0", top: "0" } });
	area.value = text;
	document.body.appendChild(area);
	area.select();
	try {
		document.execCommand("copy");
	} finally {
		area.remove();
	}
	return Promise.resolve();
}

export function isMobile() {
	return matchMedia("(max-width: 760px)").matches;
}

export function isTouch() {
	return matchMedia("(pointer: coarse)").matches;
}
