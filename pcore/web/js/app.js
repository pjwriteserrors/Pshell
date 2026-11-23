// The portal's frame: sidebar, top bar, the page in the middle, the bottom
// navigation on phones, and the router between the pages (real paths:
// /services/nas, /devices …; core serves index.html for every non-API path).
import { h, icon, clear, isMobile, mem } from "./util.js";
import * as api from "./api.js";
import { state, set, on as onStore, isAdmin, myName, refreshServices, refreshGuard, refreshHealth, refreshSettings, refreshMe, normServices, normSample, patchService, setting } from "./store.js";
import { viewTransition, animate, stagger, EASE, DUR } from "./motion.js";
import { showMenu, toast, closeAll, openDialog } from "./ui.js";
import * as theme from "./theme.js";

const VIEWS = {
	home: () => import("./views/home.js"),
	services: () => import("./views/services.js"),
	devices: () => import("./views/devices.js"),
	sessions: () => import("./views/sessions.js"),
	calendar: () => import("./views/calendar.js"),
	smarthome: () => import("./views/smarthome.js"),
	security: () => import("./views/security.js"),
	health: () => import("./views/health.js"),
	settings: () => import("./views/settings.js")
};

export const NAV = [
	{ name: "home", label: "Home", icon: "home_outline", href: "/" },
	{ name: "services", label: "Services", icon: "server_network", href: "/services" },
	{ name: "devices", label: "Devices", icon: "devices", href: "/devices" },
	{ name: "sessions", label: "Sessions", icon: "account_switch_outline", href: "/sessions" },
	{ name: "calendar", label: "Calendar", icon: "calendar_month", href: "/calendar" },
	{ name: "smarthome", label: "Smart home", icon: "power_plug", href: "/smarthome" },
	{ name: "security", label: "Security", icon: "shield_lock_outline", href: "/security" },
	{ name: "health", label: "Health", icon: "heart_pulse", href: "/health" },
	{ name: "settings", label: "Settings", icon: "tune_variant", href: "/settings", admin: true }
];

export const app = { route: null, view: null, go, routeOf, el: {} };
window.coreApp = app;

// "/services/nas?x=1" → { name: "services", parts: ["nas"], query }
export function routeOf(loc = location) {
	const parts = loc.pathname.split("/").filter(Boolean).map(p => {
		try {
			return decodeURIComponent(p);
		} catch (error) {
			return p;
		}
	});
	const name = parts[0] && VIEWS[parts[0]] ? parts[0] : "home";
	return { name, parts: parts.slice(1), query: Object.fromEntries(new URLSearchParams(loc.search)), href: loc.pathname + loc.search };
}

function go(href, { replace = false } = {}) {
	if (href === location.pathname + location.search) {
		app.view?.refresh?.();
		return;
	}
	if (replace) history.replaceState(null, "", href);
	else history.pushState(null, "", href);
	render();
}

let renderToken = 0;
async function render() {
	const route = routeOf();
	closeAll();
	closeDrawer();
	const token = ++renderToken;
	const previous = app.route;
	// the same page with another part (a service's detail): the view moves itself
	if (previous && app.view?.update && previous.name === route.name) {
		app.route = route;
		app.view.update(route, previous);
		markNav(route);
		app.el.top.setTitle(app.view);
		return;
	}
	let module;
	try {
		module = await VIEWS[route.name]();
	} catch (error) {
		toast("This page did not load", { tone: "bad", icon: "alert_circle_outline", body: error.message });
		return;
	}
	if (token !== renderToken) return;
	const order = Object.keys(VIEWS);
	const direction = previous && order.indexOf(route.name) < order.indexOf(previous.name) ? "back" : "forward";
	await viewTransition(() => {
		app.view?.unmount?.();
		const main = app.el.main;
		clear(main);
		app.route = route;
		const view = module.default(route, app);
		app.view = view;
		main.dataset.view = route.name;
		main.appendChild(view.el);
		markNav(route);
		app.el.top.setTitle(view);
		main.scrollTop = 0;
	}, direction);
	app.view?.mounted?.();
}

function markNav(route) {
	for (const item of document.querySelectorAll("[data-route]")) {
		const part = item.dataset.part;
		// a smart home device's own page lights its item under Smart home, not Smart home itself
		const on = item.dataset.route === route.name && (part ? part === route.parts[0] : !(route.name === "smarthome" && route.parts[0]));
		item.classList.toggle("active", on);
		if (on) item.setAttribute("aria-current", "page");
		else item.removeAttribute("aria-current");
	}
}

// ── the frame ──────────────────────────────────────────────────────────────
export function startShell() {
	const root = document.getElementById("app");
	clear(root);
	document.body.dataset.page = "app";
	let folded = false;
	try {
		folded = localStorage.getItem("core.sidebar") === "0";
	} catch (error) {}
	const sidebar = buildSidebar();
	const top = buildTopBar();
	const main = h("main.main", { id: "main", tabindex: "-1" });
	const frame = h("div.frame", { class: folded ? "no-sidebar" : "" },
		h("a.skip", { href: "#main", onclick: event => {
			event.preventDefault();
			main.focus();
		} }, "Skip to the page"),
		sidebar,
		h("div.stage", top, h("div.stage-body", main)),
		buildBottomNav());
	root.appendChild(frame);
	app.el = { root: frame, sidebar, top, main };
	animate(frame, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.xlong, fill: "none" });
	animate(sidebar, [{ opacity: 0, transform: "translateX(-24px)" }, { opacity: 1, transform: "none" }], { duration: 600, easing: EASE.spring, fill: "none" });
	animate(top, [{ opacity: 0, transform: "translateY(-12px)" }, { opacity: 1, transform: "none" }], { duration: 600, delay: 60, easing: EASE.spring, fill: "backwards" });

	addEventListener("popstate", render);
	// links inside the portal move without a reload
	document.addEventListener("click", event => {
		const a = event.target.closest?.("a[href]");
		if (!a || a.target || a.hasAttribute("download") || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
		const url = new URL(a.href, location.href);
		if (url.origin !== location.origin || url.pathname.startsWith("/api/") || url.pathname === "/login" || url.pathname === "/logout" || a.getAttribute("href").startsWith("#")) return;
		event.preventDefault();
		go(url.pathname + url.search);
	});
	installKeys();
	installEvents();

	refreshServices();
	refreshGuard();
	refreshHealth();
	refreshSettings().then(() => {
		if (state.me?.setup_totp || (setting("totp_required", false) && state.me?.user && !state.me.user.totp)) {
			toast("Two-step sign-in is required here – set it up now", { icon: "shield_key_outline", tone: "warn", timeout: 0, action: { label: "Set up", run: () => go("/security?totp=1") } });
		}
	});
	// a fallback while the socket is down
	setInterval(() => {
		if (document.visibilityState !== "visible" || document.body.classList.contains("socket-live")) return;
		refreshServices();
		refreshHealth();
		refreshGuard();
	}, 30000);
	render();
}

// ── live events → the store and toasts ─────────────────────────────────────
const STATE_WORD = { up: "is up", down: "is down", degraded: "is struggling", stopped: "was stopped", unknown: "is in an unknown state" };

function installEvents() {
	api.connectEvents();
	api.onSocketState(s => {
		document.body.classList.toggle("socket-live", s === "open");
		document.body.classList.toggle("socket-down", s === "closed");
	});
	api.on("hello", data => {
		if (data.services) set("services", normServices(data.services));
		if (data.guard) set("guard", data.guard);
		if (data.health) set("health", normSample(data.health));
	});
	api.on("health", data => set("health", normSample(data.sample ?? data)));
	api.on("service", data => {
		const known = state.services.find(s => s.name === data.name);
		patchService(data.name, { state: data.state });
		refreshServices();
		const title = known?.title || data.name;
		if (data.was && data.was !== data.state) {
			const bad = data.state === "down" || data.state === "degraded";
			toast(`${title} ${STATE_WORD[data.state] || data.state}`, {
				icon: bad ? "alert_circle_outline" : data.state === "up" ? "check_circle_outline" : "information_outline",
				tone: bad ? "bad" : data.state === "up" ? "good" : undefined,
				body: data.was ? `was ${data.was}` : undefined,
				timeout: bad ? 9000 : 4200,
				action: { label: "Open", run: () => go(`/services/${encodeURIComponent(data.name)}`) }
			});
		}
	});
	api.on("pressure", data => {
		refreshGuard();
		const level = data.level;
		toast(level === "ok" ? "Memory is calm again" : level === "critical" ? "Memory is critical" : "Memory is tight", {
			icon: level === "ok" ? "check_circle_outline" : "memory",
			tone: level === "ok" ? "good" : level === "critical" ? "bad" : "warn",
			body: [data.available_mb !== undefined && data.available_mb !== null ? `${Math.round(data.available_mb)} MB available` : null, data.stopped?.length ? `stopped ${data.stopped.join(", ")}` : null, data.was ? `was ${data.was}` : null].filter(Boolean).join(" · ") || undefined,
			timeout: level === "ok" ? 4200 : 10000,
			action: level === "ok" ? undefined : { label: "Health", run: () => go("/health") }
		});
	});
	api.on("login", data => {
		const me = data.who === myName();
		// your own sign-ins only when they come from a new address
		if (me && !data.new) return;
		toast(me ? "You signed in somewhere" : `${data.who} signed in`, {
			icon: "login",
			tone: data.new || data.address_new ? "warn" : undefined,
			body: [data.address, data.ip].filter(Boolean).join(" · "),
			timeout: 7000,
			action: { label: "Sessions", run: () => go("/sessions") }
		});
	});
	api.on("login_failed", data => toast(`Failed sign-in${data.name ? ` as ${data.name}` : ""}`, {
		icon: "shield_alert_outline", tone: "warn", body: data.ip, timeout: 7000,
		action: { label: "Log", run: () => go("/security?log=1") }
	}));
	api.on("locked", data => toast(`Sign-in locked${data.name ? ` for ${data.name}` : ""}`, {
		icon: "lock_outline", tone: "bad", body: `${data.ip || ""} – too many failures, 15 min`, timeout: 10000,
		action: { label: "Log", run: () => go("/security?log=1") }
	}));
	api.on("device", data => {
		const d = data.device || {};
		// the Devices page says it itself
		if ((data.action === "added" || data.action === "revoked") && app.route?.name !== "devices") {
			toast(`${d.name || "A device"} ${data.action === "added" ? "was added" : "was revoked"}`, { icon: data.action === "added" ? "devices" : "link_variant_off", tone: data.action === "revoked" ? "warn" : undefined, timeout: 4200 });
		}
	});
	api.on("socket", data => {
		if (data.open) {
			refreshServices();
			refreshGuard();
		}
	});
}

// ── sidebar (Sidebar.qml) ──────────────────────────────────────────────────
function sideItem({ label, iconName, route, part, href, badge, dot }) {
	const el = h("a.side-item", { href, dataset: { route } },
		h("span.side-mark"),
		dot || icon(iconName),
		h("span.side-label.ellipsis", label),
		badge || null);
	if (part) el.dataset.part = part;
	return el;
}

function sideSection(title, items, id) {
	let collapsed = false;
	try {
		collapsed = localStorage.getItem(`core.side.${id}`) === "1";
	} catch (error) {}
	const list = h("div.side-list", items);
	const head = h("div.side-head", h("button.side-title", { type: "button", title: "Fold", "aria-expanded": String(!collapsed) }, h("span.section-label", title)));
	const section = h("section.side-section", { class: `${collapsed ? "collapsed" : ""} side-${id}` }, head, list);
	head.firstChild.addEventListener("click", () => {
		collapsed = !collapsed;
		section.classList.toggle("collapsed", collapsed);
		head.firstChild.setAttribute("aria-expanded", String(!collapsed));
		try {
			localStorage.setItem(`core.side.${id}`, collapsed ? "1" : "0");
		} catch (error) {}
	});
	section.list = list;
	return section;
}

export function stateTone(s) {
	return { up: "up", down: "down", degraded: "degraded", stopped: "stopped" }[s] || "unknown";
}

function buildSidebar() {
	const statusDot = h("span.live-dot");
	const brandState = h("span.brand-state", "Connecting…");
	const fold = h("button.icon-btn.small.hide-mobile", { type: "button", title: "Hide the sidebar (Ctrl+B)" }, icon("dock_left"));
	fold.addEventListener("click", () => toggleSidebar());
	const brand = h("div.brand",
		h("div.app-tile", icon("server")),
		h("div.brand-text", h("div.brand-name.ellipsis", "netcore"), h("div.brand-sub", statusDot, brandState)),
		fold);

	const guardBadge = h("span.side-badge.warn", { hidden: true }, "!");
	// devices with a page of their own (a robot vacuum, a washing machine) hang under Smart home
	const smartSub = h("div.side-sub");
	const showSmart = nodes => {
		const list = (nodes || []).filter(n => n.view?.ui);
		const sig = list.map(n => `${n.id}:${n.view.name}:${n.view.busy}`).join("|");
		if (smartSub.dataset.sig === sig) return;
		const first = !smartSub.childElementCount;
		smartSub.dataset.sig = sig;
		clear(smartSub);
		for (const n of list) {
			smartSub.appendChild(sideItem({ label: n.view.name, iconName: n.view.ui === "washer" ? "washing_machine" : "robot_vacuum", route: "smarthome", part: n.id,
				href: `/smarthome/${encodeURIComponent(n.id)}`, badge: n.view.busy ? h("span.side-busy") : null }));
		}
		if (first) stagger(smartSub.children, { step: 40, distance: 6 });
		if (app.route) markNav(app.route);
	};
	api.get("/api/smarthome", undefined, { quiet: true }).then(data => showSmart(data.nodes)).catch(() => {});
	api.on("smarthome", data => data.nodes && showSmart(data.nodes));
	const downBadge = h("span.side-badge.bad", { hidden: true });
	const top = h("div.side-list.top",
		sideItem({ label: "Home", iconName: "home_outline", route: "home", href: "/" }),
		sideItem({ label: "Services", iconName: "server_network", route: "services", href: "/services", badge: downBadge }),
		sideItem({ label: "Devices", iconName: "devices", route: "devices", href: "/devices" }),
		sideItem({ label: "Sessions", iconName: "account_switch_outline", route: "sessions", href: "/sessions" }),
		sideItem({ label: "Calendar", iconName: "calendar_month", route: "calendar", href: "/calendar" }),
		sideItem({ label: "Smart home", iconName: "power_plug", route: "smarthome", href: "/smarthome" }),
		smartSub);
	const system = sideSection("System", [
		sideItem({ label: "Health", iconName: "heart_pulse", route: "health", href: "/health", badge: guardBadge }),
		sideItem({ label: "Security", iconName: "shield_lock_outline", route: "security", href: "/security" }),
		isAdmin() ? sideItem({ label: "Settings", iconName: "tune_variant", route: "settings", href: "/settings" }) : null
	].filter(Boolean), "system");
	const services = sideSection("Services", [], "services");

	// the Pi at a glance, as the file manager shows its drives
	const memBar = h("div.drive-bar", h("i", { style: { width: "0%" } }));
	const memText = h("span.side-label.ellipsis", "Memory");
	const pi = h("a.side-item.drive", { href: "/health", dataset: { route: "health-pi" }, title: "The Pi's memory" },
		h("span.side-mark"), icon("memory"), h("span.drive-text", memText, memBar));
	const temp = h("span.side-label.ellipsis", "–");
	const tempItem = h("a.side-item", { href: "/health", dataset: { route: "health-temp" } }, h("span.side-mark"), icon("thermometer"), temp);
	const piSection = sideSection("Raspberry Pi", [pi, tempItem], "pi");

	const scroller = h("div.side-scroll", top, system, services, piSection);
	const aside = h("aside.sidebar", { "aria-label": "Pages" }, brand, scroller);

	const showServices = list => {
		clear(services.list);
		for (const s of list) {
			services.list.appendChild(sideItem({ label: s.title || s.name, route: "services", part: s.name, href: `/services/${encodeURIComponent(s.name)}`, dot: h(`span.state-dot.${stateTone(s.state)}`, { title: s.state || "unknown" }) }));
		}
		services.hidden = !list.length;
		const down = list.filter(s => s.state === "down" || s.state === "degraded").length;
		downBadge.hidden = !down;
		downBadge.textContent = down;
		if (app.route) markNav(app.route);
	};
	onStore("services", showServices);
	onStore("guard", g => {
		guardBadge.hidden = !g || g.level === "ok";
		guardBadge.className = `side-badge ${g?.level === "critical" ? "bad" : "warn"}`;
	});
	onStore("health", s => {
		if (!s) return;
		const used = s.mem_total ? 1 - s.mem_available / s.mem_total : 0;
		memBar.firstChild.style.width = `${Math.max(2, Math.round(used * 100))}%`;
		const tight = s.mem_available !== null && s.mem_available < (setting("tight_mb", 900) * 1048576);
		memBar.className = `drive-bar${s.mem_available < setting("critical_mb", 450) * 1048576 ? " bad" : tight ? " warn" : ""}`;
		memText.textContent = `${mem(s.mem_available, 1)} free`;
		temp.textContent = s.temp !== null ? `${s.temp.toFixed(1)} °C` : "–";
	});
	api.onSocketState(s => {
		statusDot.className = `live-dot ${s}`;
		brandState.textContent = s === "open" ? "pshell core · live" : s === "connecting" ? "Connecting…" : "Offline – retrying";
	});
	return aside;
}

function toggleSidebar() {
	if (isMobile()) {
		openDrawer();
		return;
	}
	const folded = !app.el.root.classList.contains("no-sidebar");
	app.el.root.classList.toggle("no-sidebar", folded);
	try {
		localStorage.setItem("core.sidebar", folded ? "0" : "1");
	} catch (error) {}
}

function openDrawer() {
	app.el.root.classList.add("drawer-open");
	setTimeout(() => app.el.sidebar.querySelector(".side-item")?.focus(), 60);
}
export function closeDrawer() {
	app.el.root?.classList.remove("drawer-open");
}

// ── top bar (TopBar.qml): the page as a tab, the live state, the account;
// below it the way back, the crumbs and the view's own tools
function buildTopBar() {
	const menuBtn = h("button.icon-btn.only-mobile", { title: "Pages", "aria-label": "Pages" }, icon("menu"));
	menuBtn.addEventListener("click", openDrawer);
	const unfold = h("button.icon-btn.unfold", { title: "Show the sidebar (Ctrl+B)" }, icon("dock_left"));
	unfold.addEventListener("click", () => toggleSidebar());
	const tab = h("div.tab", h("span.tab-icon", icon("home_outline")), h("span.tab-title.ellipsis", ""));

	const guard = h("a.guard-chip", { href: "/health", hidden: true }, h("span.guard-dot"), h("span.guard-text", ""));
	onStore("guard", g => {
		const level = g?.level || "ok";
		guard.hidden = level === "ok";
		guard.className = `guard-chip ${level}`;
		guard.querySelector(".guard-text").textContent = level === "critical" ? "Memory critical" : "Memory tight";
	});
	const live = h("span.live-chip.hide-mobile", h("span.live-dot"), h("span", "Live"));
	api.onSocketState(s => {
		live.firstChild.className = `live-dot ${s}`;
		live.lastChild.textContent = s === "open" ? "Live" : s === "connecting" ? "Connecting" : "Offline";
		live.classList.toggle("off", s !== "open");
	});

	const schemeBtn = h("button.icon-btn", { title: "Light or dark" }, icon(schemeIcon()));
	schemeBtn.addEventListener("click", () => {
		const r = schemeBtn.getBoundingClientRect();
		const current = theme.scheme();
		const pick = value => {
			theme.setScheme(value);
			schemeBtn.replaceChildren(icon(schemeIcon()));
		};
		showMenu([
			{ header: "Look" },
			{ label: "Like the system", icon: "brightness_auto", checked: current === "auto", run: () => pick("auto") },
			{ label: "Light", icon: "white_balance_sunny", checked: current === "light", run: () => pick("light") },
			{ label: "Dark", icon: "weather_night", checked: current === "dark", run: () => pick("dark") }
		], r.right - 200, r.bottom + 6);
	});

	const name = myName() || "?";
	const avatar = h("button.avatar", { title: `Account: ${name}`, "aria-label": `Account: ${name}` }, name.slice(0, 1).toUpperCase());
	avatar.addEventListener("click", () => {
		const rect = avatar.getBoundingClientRect();
		showMenu([
			{ header: `${name}${isAdmin() ? " · admin" : ""}` },
			{ label: "Password and two-step sign-in", icon: "shield_key_outline", run: () => go("/security") },
			{ label: "Sessions", icon: "account_switch_outline", run: () => go("/sessions") },
			{ label: "Keyboard", icon: "keyboard_outline", shortcut: "?", run: showShortcuts },
			{ separator: true },
			{ label: "Sign out", icon: "logout", danger: true, run: logout }
		], rect.right - 4, rect.bottom + 6, { keyboard: true });
	});

	const back = h("button.icon-btn.small", { title: "Back (Alt+←)", "aria-label": "Back" }, icon("arrow_left"));
	back.addEventListener("click", () => history.back());
	const forward = h("button.icon-btn.small.hide-mobile", { title: "Forward (Alt+→)", "aria-label": "Forward" }, icon("arrow_right"));
	forward.addEventListener("click", () => history.forward());
	const titleSlot = h("div.nav-crumbs");
	const toolsSlot = h("div.nav-tools");

	const row1 = h("div.top-row", menuBtn, unfold, tab, h("div.top-gap"), guard, live, schemeBtn, avatar);
	const row2 = h("div.nav-row", h("div.nav-buttons", back, forward), titleSlot, toolsSlot);
	const bar = h("header.topbar", row1, row2);
	bar.setTitle = view => {
		clear(titleSlot);
		clear(toolsSlot);
		const title = view.tabTitle?.() || view.title || "";
		document.title = title && title !== "Home" ? `${title} · netcore` : "netcore";
		tab.querySelector(".tab-title").textContent = title;
		tab.querySelector(".tab-icon").replaceChildren(icon(view.tabIcon?.() || view.icon || "server"));
		animate(tab, [{ opacity: 0.4, transform: "scale(0.96)" }, { opacity: 1, transform: "none" }], { duration: 320, easing: EASE.spring, fill: "none" });
		const crumbs = view.crumbs?.() || [{ label: view.title, icon: view.icon }];
		titleSlot.appendChild(h("nav.crumbs", { "aria-label": "Where you are" }, crumbs.map((c, i) => [
			i ? h("span.crumb-sep", icon("chevron_right")) : null,
			c.href && i < crumbs.length - 1
				? h("a.crumb", { href: c.href }, c.icon ? icon(c.icon) : null, h("span", c.label))
				: h("span.crumb.last", { "aria-current": "page" }, c.icon ? icon(c.icon) : null, h("span", c.label))
		])));
		if (view.toolsEl) toolsSlot.appendChild(view.toolsEl);
	};
	return bar;
}

function schemeIcon() {
	const s = theme.scheme();
	return s === "light" ? "white_balance_sunny" : s === "dark" ? "weather_night" : "brightness_auto";
}

export async function logout() {
	try {
		await api.post("/api/auth/logout", {}, { quiet: true });
	} catch (error) {}
	api.disconnectEvents();
	location.href = "/login";
}

// ── bottom navigation (phones) ─────────────────────────────────────────────
function buildBottomNav() {
	const item = (label, iconName, route, href) => h("a.nav-item", { href, dataset: { route } }, h("span.nav-pill", icon(iconName)), h("span.nav-label", label));
	const more = h("button.nav-item", { type: "button" }, h("span.nav-pill", icon("menu")), h("span.nav-label", "More"));
	more.addEventListener("click", openDrawer);
	const nav = h("nav.bottom-nav.panel-glass", { "aria-label": "Pages" },
		item("Home", "home_outline", "home", "/"),
		item("Services", "server_network", "services", "/services"),
		item("Devices", "devices", "devices", "/devices"),
		item("Health", "heart_pulse", "health", "/health"),
		more);
	const scrim = h("div.drawer-scrim");
	scrim.addEventListener("click", closeDrawer);
	return h("div.mobile-chrome", nav, scrim);
}

// ── keys ───────────────────────────────────────────────────────────────────
const JUMPS = { h: "/", s: "/services", d: "/devices", e: "/sessions", c: "/calendar", m: "/smarthome", y: "/security", l: "/health", t: "/settings" };

function installKeys() {
	let pendingG = 0;
	document.addEventListener("keydown", event => {
		if (event.key === "Escape" && app.el.root?.classList.contains("drawer-open")) {
			closeDrawer();
			return;
		}
		const typing = event.target.closest?.("input, textarea, select, [contenteditable]");
		if (document.querySelector(".dialog-wrap, .menu-layer")) return;
		const mod = event.ctrlKey || event.metaKey;
		if (mod && event.key.toLowerCase() === "b") {
			event.preventDefault();
			toggleSidebar();
			return;
		}
		if (event.altKey && event.key === "ArrowLeft") {
			event.preventDefault();
			history.back();
			return;
		}
		if (event.altKey && event.key === "ArrowRight") {
			event.preventDefault();
			history.forward();
			return;
		}
		if (typing || mod || event.altKey) return;
		if (event.key === "?") {
			showShortcuts();
			return;
		}
		if (event.key === "g") {
			pendingG = Date.now();
			return;
		}
		if (pendingG && Date.now() - pendingG < 1200 && JUMPS[event.key]) {
			pendingG = 0;
			event.preventDefault();
			go(JUMPS[event.key]);
			return;
		}
		pendingG = 0;
		app.view?.onKey?.(event);
	});
}

function showShortcuts() {
	const rows = [
		["g h", "Home"],
		["g s", "Services"],
		["g d", "Devices"],
		["g e", "Sessions"],
		["g y", "Security"],
		["g l", "Health"],
		["g t", "Settings"],
		["Alt ← / →", "Back, forward"],
		["Ctrl B", "Sidebar"],
		["Esc", "Close a sheet or menu"],
		["Tab / Enter", "Move and press"]
	];
	openDialog({
		title: "Keyboard",
		icon: "keyboard_outline",
		body: h("div.shortcuts", rows.map(([k, v]) => h("div.shortcut-row", h("span", v), h("span.kbd", k))))
	});
}

export { refreshMe };
