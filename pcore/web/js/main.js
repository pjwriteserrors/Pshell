// Boot: wear the palette, then /logout, /login or the portal itself.
import * as theme from "./theme.js";
import * as api from "./api.js";
import { installRipples } from "./motion.js";
import { refreshMe, state } from "./store.js";

theme.applyCached();
installRipples();
theme.load();

// `next` is followed only when it is http(s) on this very host (the server
// checks the port against services.json; this is the second look)
export function safeNext(raw) {
	if (!raw) return null;
	try {
		const url = new URL(raw, location.origin);
		if (url.protocol !== "http:" && url.protocol !== "https:") return null;
		if (url.hostname !== location.hostname) return null;
		if (url.origin === location.origin && (url.pathname === "/login" || url.pathname === "/logout")) return null;
		return url.href;
	} catch (error) {
		return null;
	}
}

api.setUnauthorizedHandler(() => {
	if (document.body.dataset.page !== "app") return;
	api.disconnectEvents();
	location.href = `/login?expired=1&next=${encodeURIComponent(location.pathname + location.search)}`;
});

async function boot() {
	const params = new URLSearchParams(location.search);
	const next = safeNext(params.get("next"));
	const path = location.pathname.replace(/\/+$/, "") || "/";

	if (path === "/logout") {
		try {
			await api.post("/api/auth/logout", {}, { quiet: true });
		} catch (error) {}
		if (next && new URL(next).origin !== location.origin) {
			// back to the service; it sends the browser here to sign in again
			location.replace(next);
			return;
		}
		history.replaceState(null, "", next ? `/login?next=${encodeURIComponent(params.get("next"))}` : "/login");
		return showLogin(next, { signedOut: true });
	}

	let me = null;
	try {
		me = await refreshMe({ quiet: true });
	} catch (error) {
		if (error.status !== 401 && error.status !== 403) return showLogin(next, { offline: error.code === "offline" || error.status >= 500 });
	}
	if (!me?.user && !me?.device) {
		// a page of the portal asked for directly comes back after the sign-in
		const back = next || (path !== "/" && path !== "/login" ? location.pathname + location.search : null);
		if (back && !next) history.replaceState(null, "", `/login?next=${encodeURIComponent(back)}`);
		return showLogin(safeNext(back), { expired: params.get("expired") === "1" });
	}
	if (path === "/login") {
		if (next) {
			location.replace(next);
			return;
		}
		history.replaceState(null, "", "/");
	}
	startApp();
}

async function showLogin(next, flags = {}) {
	if (location.pathname !== "/login") history.replaceState(null, "", `/login${location.search}`);
	const { showLogin: show } = await import("./views/login.js");
	show({ ...flags, next }, async result => {
		// another service: only where the server agrees too (it checks the port)
		const target = next && new URL(next).origin !== location.origin && result && "next" in result ? safeNext(result.next) : next;
		if (target) {
			location.href = target;
			return;
		}
		history.replaceState(null, "", "/");
		if (!state.me) await refreshMe({ quiet: true }).catch(() => {});
		startApp();
	});
}

async function startApp() {
	const { startShell } = await import("./app.js");
	startShell();
}

boot();
