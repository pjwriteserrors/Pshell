// What the whole interface shares: who is logged in, the server's status,
// settings, task types, the clipboard, favourites and tags, view options.
import * as api from "./api.js";

const listeners = new Map();

export const state = {
	hello: null,
	me: null,
	status: null,
	settings: null,
	types: [],
	clipboard: { paths: [], cut: false },
	favorites: [],
	tags: [],
	jobs: new Map(),
	tasks: new Map(),
	view: loadView()
};

export function on(key, fn) {
	if (!listeners.has(key)) listeners.set(key, new Set());
	listeners.get(key).add(fn);
	return () => listeners.get(key)?.delete(fn);
}

export function emit(key, value) {
	for (const fn of listeners.get(key) ?? []) {
		try {
			fn(value);
		} catch (error) {
			console.error(error);
		}
	}
}

export function set(key, value) {
	state[key] = value;
	emit(key, value);
}

export const isAdmin = () => state.me?.role === "admin" || (state.me?.caps || []).includes("admin");

// ── view options (per browser) ─────────────────────────────────────────────
function loadView() {
	const fallback = { mode: "grid", card: 156, sort: "name", desc: false, foldersFirst: true, hidden: false, details: false, sidebar: true, group: "none" };
	try {
		return { ...fallback, ...JSON.parse(localStorage.getItem("nas.view") || "{}") };
	} catch (error) {
		return fallback;
	}
}

export function setView(patch) {
	state.view = { ...state.view, ...patch };
	try {
		localStorage.setItem("nas.view", JSON.stringify(state.view));
	} catch (error) {}
	emit("view", state.view);
}

// ── the server's state ─────────────────────────────────────────────────────
export async function refreshStatus() {
	try {
		set("status", await api.get("/api/status", null, { quiet: true }));
	} catch (error) {}
	return state.status;
}

export async function refreshSettings() {
	try {
		set("settings", await api.get("/api/settings", null, { quiet: true }));
	} catch (error) {
		// not an admin: settings stay unknown, the defaults of docs/nas.md count
		if (!state.settings) set("settings", {});
	}
	return state.settings;
}

export async function refreshTypes() {
	try {
		const types = await api.get("/api/tasks/types", null, { quiet: true });
		set("types", Array.isArray(types) ? types : types?.types ?? []);
	} catch (error) {}
	return state.types;
}

export function setting(key, fallback) {
	const s = state.settings || {};
	if (key in s) return s[key];
	// "policy.thumb" may come nested
	if (key.includes(".")) {
		const [a, b] = key.split(".");
		if (s[a] && typeof s[a] === "object" && b in s[a]) return s[a][b];
	}
	return fallback;
}

// ── favourites and tags: the server's meta, shared with the shell and phone
export async function loadLibrary() {
	try {
		const fav = await api.get("/api/meta/favorites", null, { quiet: true });
		set("favorites", (fav?.entries || []).map(e => e.path));
	} catch (error) {
		set("favorites", []);
	}
	await loadTags();
}

export async function loadTags() {
	try {
		const tags = await api.get("/api/meta/tags", null, { quiet: true });
		set("tags", (tags || []).map(t => t.tag ?? t).filter(Boolean));
	} catch (error) {
		set("tags", []);
	}
}

export async function setFavorite(path, on) {
	await api.put("/api/meta", { path, favorite: on });
	const list = state.favorites.filter(p => p !== path);
	if (on) list.push(path);
	set("favorites", list.sort((a, b) => a.localeCompare(b)));
}

// a new tag shows in the sidebar at once; the server's list follows
export async function rememberTags(names) {
	const merged = [...new Set([...state.tags, ...names.filter(Boolean)])];
	if (merged.length !== state.tags.length) set("tags", merged);
	loadTags();
}

export function setClipboard(paths, cut) {
	set("clipboard", { paths, cut });
}

