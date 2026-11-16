// Boot: wear the palette, ask who we are, then the login or the app.
import * as theme from "./theme.js";
import * as api from "./api.js";
import { installRipples } from "./motion.js";
import { state, set } from "./store.js";

theme.applyCached();
installRipples();
theme.load();

// the palette follows the shell: a push from the PC fades in
api.on("theme", () => theme.load());
api.on("kv", data => {
	if (data?.ns === "theme") theme.load();
});

async function boot() {
	let hello = null;
	try {
		hello = await api.get("/api/hello", null, { quiet: true });
	} catch (error) {
		hello = { name: "NAS", auth: false, offline: true };
	}
	set("hello", hello);
	document.title = hello?.name ? `${hello.name} · NAS` : "NAS";
	if (hello?.auth) {
		try {
			set("me", await api.get("/api/me", null, { quiet: true }));
		} catch (error) {
			hello.auth = false;
		}
	}
	if (!hello?.auth) {
		const { showLogin } = await import("./views/login.js");
		showLogin(hello, startApp);
		return;
	}
	startApp();
}

async function startApp() {
	if (!state.me) {
		try {
			set("me", await api.get("/api/me"));
		} catch (error) {}
	}
	const { startShell } = await import("./app.js");
	startShell();
}

api.setUnauthorizedHandler(async () => {
	if (document.body.dataset.page === "login") return;
	api.disconnectEvents();
	if (state.hello?.core) {
		// is the portal there to sign in again, or only the NAS's own login?
		try {
			set("hello", await api.get("/api/hello", null, { quiet: true }));
		} catch (error) {}
	}
	const { showLogin } = await import("./views/login.js");
	showLogin(state.hello, () => location.reload(), { expired: true });
});

boot();
