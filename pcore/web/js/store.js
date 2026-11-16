// What the whole portal shares: who is signed in, the services, the guard,
// the newest health sample and the settings. Views listen with on(key).
import * as api from "./api.js";

const listeners = new Map();

export const state = {
	me: null,
	services: [],
	guard: null,
	health: null,
	settings: null,
	settingsCritical: null,
	booted: false
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

// ── who ─────────────────────────────────────────────────────────────────────
export const user = () => state.me?.user ?? null;
export const myName = () => user()?.name ?? state.me?.device?.name ?? "";
export const isAdmin = () => user()?.role === "admin" || (state.me?.device?.scopes?.core || []).includes("admin");
export const hasTotp = () => !!(user()?.totp ?? user()?.totp_on);

export function sessionId() {
	const s = state.me?.session;
	return s && typeof s === "object" ? s.id : s ?? null;
}

// confirmed_until in seconds (or ms, or ISO) → ms since the epoch
export function confirmedUntil() {
	const v = state.me?.confirmed_until;
	if (!v) return 0;
	if (typeof v === "number") return v < 1e12 ? v * 1000 : v;
	const t = Date.parse(v);
	return Number.isNaN(t) ? 0 : t;
}

export async function refreshMe(options = { quiet: true }) {
	const me = await api.get("/api/auth/me", null, options);
	set("me", me);
	return me;
}

// ── services: always a list of {name, …} ────────────────────────────────────
export function normServices(data) {
	if (Array.isArray(data)) return data.map(s => ({ ...s, name: s.name ?? s.id }));
	const list = Array.isArray(data?.services) ? data.services : null;
	if (list) return normServices(list);
	return Object.entries(data?.services ?? data ?? {}).map(([name, s]) => ({ ...s, name }));
}

export async function refreshServices() {
	try {
		const list = normServices(await api.get("/api/services", null, { quiet: true }));
		state.booted = true;
		set("services", list);
	} catch (error) {}
	return state.services;
}

export function patchService(name, patch) {
	const list = state.services.map(s => (s.name === name ? { ...s, ...patch } : s));
	set("services", list);
}

export async function refreshGuard() {
	try {
		set("guard", await api.get("/api/guard", null, { quiet: true }));
	} catch (error) {}
	return state.guard;
}

export async function refreshHealth() {
	try {
		set("health", normSample(await api.get("/api/health/now", null, { quiet: true })));
	} catch (error) {}
	return state.health;
}

export async function refreshSettings() {
	try {
		setSettings(await api.get("/api/settings", null, { quiet: true }));
	} catch (error) {
		if (!state.settings) set("settings", {});
	}
	return state.settings;
}

// {settings, critical} (or the bare object): the values, and which keys need a confirmation
export function setSettings(data) {
	if (!data || typeof data !== "object") return;
	if (Array.isArray(data.critical)) state.settingsCritical = data.critical;
	set("settings", data.settings && typeof data.settings === "object" ? data.settings : data);
}

export const isCriticalSetting = key => (state.settingsCritical || ["totp_required", "guard_stop"]).includes(key);

// "alerts.failed" may come flat or nested
export function setting(key, fallback) {
	const s = state.settings || {};
	if (key in s) return s[key];
	if (key.includes(".")) {
		const [a, b] = key.split(".");
		if (s[a] && typeof s[a] === "object" && b in s[a]) return s[a][b];
	}
	return fallback;
}

// ── a health sample with the units the views use (bytes, %, °C, s) ─────────
// docs/core.md names the fields; memory is taken as bytes, but kB (/proc)
// and MB numbers are recognised by their size (a Pi has 1–8 GB).
export function bytes(v) {
	if (v === null || v === undefined || Number.isNaN(Number(v))) return null;
	v = Number(v);
	if (v === 0) return 0;
	if (v < 1e5) return v * 1048576;
	if (v < 1e8) return v * 1024;
	return v;
}

export function normSample(s) {
	if (!s || typeof s !== "object") return null;
	s = s.sample ?? s;
	const temp = s.temp === null || s.temp === undefined ? null : Number(s.temp) > 1000 ? Number(s.temp) / 1000 : Number(s.temp);
	const load = Array.isArray(s.load) ? s.load : [s.load1, s.load5, s.load15];
	const containers = {};
	const raw = s.containers || {};
	if (Array.isArray(raw)) raw.forEach(c => (containers[c.name] = bytes(c.mem)));
	else for (const [k, v] of Object.entries(raw)) containers[k] = bytes(typeof v === "object" ? v?.mem : v);
	const disk = s.disk || {};
	return {
		at: s.at ?? s.t ?? s.time ?? null,
		mem_total: bytes(s.mem_total),
		mem_available: bytes(s.mem_available),
		swap_used: bytes(s.swap_used),
		psi_some10: s.psi_some10 ?? null,
		psi_full10: s.psi_full10 ?? null,
		load1: load[0] ?? null,
		load5: load[1] ?? null,
		load15: load[2] ?? null,
		cpu: s.cpu ?? null,
		temp,
		throttled: s.throttled ?? null,
		disk: { used: disk.used ?? null, total: disk.total ?? null },
		uptime: s.uptime ?? null,
		containers
	};
}
