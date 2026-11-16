// Pieces several pages share: a service's tone and words, a state chip,
// a memory bar against the container's limit, log kinds, device kinds.
import { h, icon, mem } from "../util.js";

export const STATE_LABEL = { up: "Up", down: "Down", degraded: "Degraded", stopped: "Stopped", unknown: "Unknown" };

export function stateChip(state) {
	const s = STATE_LABEL[state] ? state : "unknown";
	return h(`span.state-chip.${s}`, h(`span.state-dot.${s}`), STATE_LABEL[s]);
}

export function serviceIcon(s) {
	return s?.icon || "server";
}

export function memBar(c) {
	const used = c?.mem ?? null;
	const limit = c?.mem_limit || null;
	if (used === null || used === undefined) return h("div.mem-line.none", h("span.subtle", "No container numbers"));
	const share = limit ? used / limit : null;
	const tone = share === null ? "" : share > 0.9 ? ".bad" : share > 0.75 ? ".warn" : "";
	return h("div.mem-line",
		h(`div.bar${tone}`, h("i", { style: { width: `${share === null ? 0 : Math.max(2, Math.min(100, share * 100)).toFixed(1)}%` } })),
		h("div.mem-text", h("span", mem(used, 1)), h("span.subtle", limit ? `of ${mem(limit, limit < 1073741824 ? 0 : 1)}` : "no limit")));
}

export const KIND_ICON = { pc: "monitor", laptop: "laptop", phone: "cellphone", other: "devices" };
export const KIND_LABEL = { pc: "PC", laptop: "Laptop", phone: "Phone", other: "Other" };

// the security log's kinds: icon, tone, words
export const LOG_KINDS = {
	login: ["login", "good", "Signed in"],
	login_failed: ["shield_alert_outline", "warn", "Failed sign-in"],
	locked: ["lock_outline", "bad", "Locked out"],
	logout: ["logout", "", "Signed out"],
	device_added: ["devices", "accent", "Device added"],
	device_revoked: ["link_variant_off", "warn", "Device revoked"],
	token_rotated: ["key_variant", "accent", "Token rotated"],
	password_changed: ["key_outline", "accent", "Password changed"],
	totp_on: ["shield_check_outline", "good", "Two-step on"],
	totp_off: ["shield_outline", "warn", "Two-step off"],
	user_added: ["account_plus", "accent", "User added"],
	user_removed: ["account_outline", "warn", "User removed"],
	confirm: ["shield_lock_outline", "", "Confirmed"],
	container_action: ["docker", "accent", "Container action"],
	pressure: ["memory", "warn", "Memory pressure"],
	service_down: ["alert_circle_outline", "bad", "Service down"],
	service_up: ["check_circle_outline", "good", "Service up"],
	service_changed: ["pencil_outline", "accent", "Service edited"],
	device_changed: ["pencil_outline", "", "Device changed"],
	user_changed: ["account_edit_outline", "", "User changed"],
	settings_changed: ["tune_variant", "accent", "Settings changed"]
};

export function logKind(kind) {
	const [i, tone, label] = LOG_KINDS[kind] || ["information_outline", "", kind];
	return { icon: i, tone, label };
}

// a log entry's detail (an object, or the JSON of one) in words
const DETAIL_WORDS = { new_ip: v => (v ? "new address" : ""), address: v => `on ${v}`, agent: v => agentOf(v).browser + (agentOf(v).os ? ` on ${agentOf(v).os}` : ""), others: v => `${v} other sessions`, ended_by: v => `ended by ${v}`, via: v => `via ${v}` };

export function detailText(detail) {
	if (detail === null || detail === undefined || detail === "") return "";
	if (typeof detail === "string") {
		if (!/^\s*[{[]/.test(detail)) return detail;
		try {
			detail = JSON.parse(detail);
		} catch (error) {
			return detail;
		}
	}
	if (typeof detail !== "object") return String(detail);
	return Object.entries(detail)
		.filter(([, v]) => v !== null && v !== undefined && v !== "" && v !== false)
		.map(([k, v]) => (DETAIL_WORDS[k] ? DETAIL_WORDS[k](v) : `${k.replace(/_/g, " ")} ${typeof v === "object" ? JSON.stringify(v) : v === true ? "" : v}`.trim()))
		.filter(Boolean)
		.join(" · ");
}

// "Mozilla/5.0 (X11; Linux x86_64) … Firefox/131.0" → {browser, os, icon}
export function agentOf(ua) {
	ua = String(ua || "");
	if (!ua) return { browser: "Unknown", os: "", icon: "help_circle_outline" };
	const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrom(e|ium)\//.test(ua) ? "Chromium" : /Safari\//.test(ua) ? "Safari"
		: /okhttp|Dalvik/i.test(ua) ? "Android app" : /python|aiohttp|curl|wget/i.test(ua) ? ua.split(/[\s/]/)[0] : ua.split(/[\s/]/)[0];
	const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS X/.test(ua) ? "macOS" : /Linux|X11/.test(ua) ? "Linux" : "";
	const iconName = /Android|iPhone|Mobile/.test(ua) ? "cellphone" : /Windows|Mac OS X|Linux|X11/.test(ua) ? "monitor" : "console_line";
	return { browser, os, icon: iconName };
}

// get_throttled: 0 (or "0x0") is fine; anything else as hex
export function throttledText(v) {
	if (v === null || v === undefined || v === 0 || v === "0x0" || v === "0") return "";
	return typeof v === "number" ? `0x${v.toString(16)}` : String(v);
}

// guard actions newest first, whatever order they came in
export function guardActions(g) {
	const toMs = v => (typeof v === "number" ? (v < 1e12 ? v * 1000 : v) : Date.parse(v) || 0);
	return [...(g?.actions || [])].sort((a, b) => toMs(b.at) - toMs(a.at));
}

export function sectionHead(title, sub, extra) {
	return h("div.section-head", h("div", h("h2", title), sub ? h("div.subtle", sub) : null), extra || null);
}

export function emptyRow(iconName, text) {
	return h("div.row-empty", icon(iconName), h("span", text));
}
