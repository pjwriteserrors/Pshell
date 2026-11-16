// pshell-core's HTTP API (docs/core.md › HTTP API) and its event socket.

export class ApiError extends Error {
	constructor(message, status, code, data) {
		super(message);
		this.status = status;
		this.code = code;
		this.data = data;
	}
}

let onUnauthorized = null;
export function setUnauthorizedHandler(fn) {
	onUnauthorized = fn;
}

export async function request(method, path, body, options = {}) {
	const headers = { ...(options.headers || {}) };
	let payload = body;
	// every cookie write carries the CSRF header (docs/core.md › Identity)
	if (method !== "GET" && method !== "HEAD") headers["X-Pshell"] = "1";
	if (body !== undefined && body !== null) {
		headers["Content-Type"] = "application/json";
		payload = JSON.stringify(body);
	}
	let response;
	try {
		response = await fetch(path, { method, headers, body: payload, credentials: "same-origin", signal: options.signal });
	} catch (error) {
		if (error.name === "AbortError") throw error;
		throw new ApiError("netcore does not answer", 0, "offline");
	}
	const type = response.headers.get("Content-Type") || "";
	let data = null;
	if (type.includes("json")) {
		try {
			data = await response.json();
		} catch (error) {
			data = null;
		}
	} else {
		data = await response.text();
	}
	if (!response.ok) {
		const message = (data && data.error) || (typeof data === "string" && data.length < 200 && data) || response.statusText || "Request failed";
		const error = new ApiError(message, response.status, data?.code || "http", data);
		if (response.status === 401 && !options.quiet && onUnauthorized) onUnauthorized(error);
		throw error;
	}
	return data;
}

export const get = (path, params, options) => request("GET", withQuery(path, params), undefined, options);
export const post = (path, body, options) => request("POST", path, body ?? {}, options);
export const put = (path, body, options) => request("PUT", path, body ?? {}, options);
export const patch = (path, body, options) => request("PATCH", path, body ?? {}, options);
export const del = (path, body, options) => request("DELETE", path, body, options);

export function withQuery(path, params) {
	if (!params) return path;
	const query = new URLSearchParams();
	for (const [key, value] of Object.entries(params)) {
		if (value === undefined || value === null || value === "") continue;
		if (Array.isArray(value)) value.forEach(v => query.append(key, v));
		else query.append(key, value === true ? "1" : value === false ? "0" : value);
	}
	const text = query.toString();
	return text ? `${path}${path.includes("?") ? "&" : "?"}${text}` : path;
}

// lists may come bare or wrapped ({devices: […]}, {entries: […]})
export function listOf(data, ...keys) {
	if (Array.isArray(data)) return data;
	for (const key of [...keys, "items", "entries", "list"]) if (Array.isArray(data?.[key])) return data[key];
	return [];
}

// ── events (WebSocket /api/events): {type, at, …} ───────────────────────────
const listeners = new Map();
let socket = null;
let retry = 0;
let wanted = false;
let timer = 0;
let state = "closed";
const stateListeners = new Set();

export function on(event, fn) {
	if (!listeners.has(event)) listeners.set(event, new Set());
	listeners.get(event).add(fn);
	return () => listeners.get(event)?.delete(fn);
}

export function onSocketState(fn) {
	stateListeners.add(fn);
	fn(state);
	return () => stateListeners.delete(fn);
}

function setState(next) {
	state = next;
	stateListeners.forEach(fn => fn(state));
}

function emit(event, data) {
	for (const fn of [...(listeners.get(event) ?? []), ...(listeners.get("*") ?? [])]) {
		try {
			fn(data);
		} catch (error) {
			console.error(error);
		}
	}
}

export function connectEvents() {
	wanted = true;
	clearTimeout(timer);
	if (socket && socket.readyState <= 1) return;
	const url = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/api/events`;
	try {
		socket = new WebSocket(url);
	} catch (error) {
		schedule();
		return;
	}
	setState("connecting");
	socket.onopen = () => {
		retry = 0;
		setState("open");
		emit("socket", { open: true });
	};
	socket.onmessage = message => {
		let data;
		try {
			data = JSON.parse(message.data);
		} catch (error) {
			return;
		}
		const type = data?.type ?? data?.event;
		if (type) emit(type, data);
	};
	socket.onclose = () => {
		setState("closed");
		emit("socket", { open: false });
		socket = null;
		if (wanted) schedule();
	};
	socket.onerror = () => {};
}

// backoff: 1.2 s, 2.4 s … up to ~38 s, with a little jitter
function schedule() {
	retry = Math.min(retry + 1, 6);
	clearTimeout(timer);
	timer = setTimeout(() => wanted && connectEvents(), 600 * 2 ** retry * (0.85 + Math.random() * 0.3));
}

export function disconnectEvents() {
	wanted = false;
	clearTimeout(timer);
	socket?.close();
}

// answers when the browser comes back from sleep or the network changes
addEventListener("online", () => wanted && connectEvents());
document.addEventListener("visibilitychange", () => {
	if (document.visibilityState === "visible" && wanted && !socket) {
		retry = 0;
		connectEvents();
	}
});
