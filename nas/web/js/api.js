// The NAS's HTTP API (docs/nas.md) and its event socket.

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
	if (method !== "GET" && method !== "HEAD") headers["X-Pshell"] = "1";
	if (body !== undefined && body !== null && !(body instanceof Blob) && !(body instanceof ArrayBuffer) && !(body instanceof FormData)) {
		headers["Content-Type"] = "application/json";
		payload = JSON.stringify(body);
	}
	let response;
	try {
		response = await fetch(path, { method, headers, body: payload, credentials: "same-origin", signal: options.signal });
	} catch (error) {
		if (error.name === "AbortError") throw error;
		throw new ApiError("The NAS does not answer", 0, "offline");
	}
	const type = response.headers.get("Content-Type") || "";
	let data = null;
	if (options.raw) {
		if (!response.ok) throw new ApiError(response.statusText || "Request failed", response.status, "http");
		return response;
	}
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

// urls the browser loads itself (img, video, downloads)
export const fileUrl = (path, download) => withQuery("/api/file", { path, dl: download ? 1 : undefined });
export const thumbUrl = (path, size = 256, bust) => withQuery("/api/thumb", { path, size, v: bust });
export const zipUrl = paths => withQuery("/api/zip", { path: paths });
export const previewUrl = path => withQuery("/api/preview", { path });

// ── events (WebSocket /api/events) ─────────────────────────────────────────
const listeners = new Map();
let socket = null;
let retry = 0;
let wanted = false;
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
	for (const fn of listeners.get(event) ?? []) {
		try {
			fn(data);
		} catch (error) {
			console.error(error);
		}
	}
	for (const fn of listeners.get("*") ?? []) {
		try {
			fn(data);
		} catch (error) {
			console.error(error);
		}
	}
}

export function connectEvents() {
	wanted = true;
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
		if (data?.event) emit(data.event, data);
	};
	socket.onclose = () => {
		setState("closed");
		emit("socket", { open: false });
		socket = null;
		if (wanted) schedule();
	};
	socket.onerror = () => {};
}

function schedule() {
	retry = Math.min(retry + 1, 6);
	setTimeout(() => wanted && connectEvents(), 600 * 2 ** retry);
}

export function disconnectEvents() {
	wanted = false;
	socket?.close();
}

// answers when the browser comes back from sleep or the network changes
addEventListener("online", () => wanted && connectEvents());
document.addEventListener("visibilitychange", () => {
	if (document.visibilityState === "visible" && wanted && !socket) connectEvents();
});
