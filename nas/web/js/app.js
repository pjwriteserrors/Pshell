// The app's frame: sidebar, top bar, the page in the middle, the bottom
// navigation on phones, the jobs tray, and the router between the pages.
import { h, icon, clear, nameOf, debounce, isMobile, plural, size as fmtSize } from "./util.js";
import * as api from "./api.js";
import { state, on as onStore, refreshStatus, refreshSettings, refreshTypes, loadLibrary, setView, isAdmin } from "./store.js";
import { viewTransition, ring, rollText, animate, EASE, DUR } from "./motion.js";
import { showMenu, toast, popover, closeAll } from "./ui.js";
import { closeQuickLook } from "./quicklook.js";
import * as uploads from "./uploads.js";
import * as jobs from "./jobs.js";

const VIEWS = {
	home: () => import("./views/home.js"),
	files: () => import("./views/browse.js"),
	search: () => import("./views/browse.js"),
	tag: () => import("./views/browse.js"),
	photos: () => import("./views/photos.js"),
	storage: () => import("./views/storage.js"),
	dupes: () => import("./views/dupes.js"),
	trash: () => import("./views/trash.js"),
	activity: () => import("./views/activity.js"),
	shares: () => import("./views/shares.js"),
	tasks: () => import("./views/tasks.js"),
	health: () => import("./views/health.js"),
	devices: () => import("./views/devices.js"),
	settings: () => import("./views/settings.js")
};

export const app = {
	route: null,
	view: null,
	go,
	routeOf,
	openFolder: path => go(`#/files${encodePath(path)}`),
	el: {}
};
window.nasApp = app;

export function encodePath(path) {
	return String(path || "/").split("/").map(encodeURIComponent).join("/").replace(/^\/?/, "/");
}

// "#/files/Photos/2024?x=1" → { name: "files", path: "/Photos/2024", query }
export function routeOf(hash = location.hash) {
	const raw = hash.replace(/^#/, "") || "/home";
	const [pathPart, queryPart] = raw.split("?");
	const parts = pathPart.split("/").filter(Boolean);
	const name = parts[0] && VIEWS[parts[0]] ? parts[0] : "home";
	const rest = parts.slice(1).map(p => {
		try {
			return decodeURIComponent(p);
		} catch (error) {
			return p;
		}
	});
	return { name, path: `/${rest.join("/")}`, parts: rest, query: Object.fromEntries(new URLSearchParams(queryPart || "")), hash: `#${raw}` };
}

function go(hash, { replace = false } = {}) {
	if (hash === location.hash) {
		app.view?.refresh?.();
		return;
	}
	if (replace) history.replaceState(null, "", hash);
	else history.pushState(null, "", hash);
	render();
}

let renderToken = 0;
async function render() {
	const route = routeOf();
	// a page change takes menus, dialogs and quick look with it
	closeAll();
	closeQuickLook();
	const token = ++renderToken;
	const previous = app.route;
	// the same page with another folder or query: the view moves itself
	if (previous && app.view?.update && previous.name === route.name && app.view.accepts?.(route) !== false) {
		app.route = route;
		app.view.update(route, previous);
		markNav(route);
		app.el.top.refreshTab(app.view);
		return;
	}
	const module = await VIEWS[route.name]();
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
		const target = item.dataset.route;
		let on = target === route.name;
		if (route.name === "files" && item.dataset.path) on = route.path === item.dataset.path || (item.dataset.path !== "/" && route.path.startsWith(`${item.dataset.path}/`));
		else if (item.dataset.path && route.name !== "files") on = false;
		if (route.name === "files" && target === "files" && !item.dataset.path) on = true;
		if (target === "search") on = route.name === "search" && !!route.query.recent;
		if (target === "tag") on = route.name === "tag" && item.dataset.path === `tag:${route.parts[0]}`;
		item.classList.toggle("active", on);
		const scroll = on && item.closest(".side-scroll");
		if (scroll && (item.offsetTop < scroll.scrollTop + 8 || item.offsetTop + item.offsetHeight > scroll.scrollTop + scroll.clientHeight - 40)) {
			scroll.scrollTo({ top: item.offsetTop - scroll.clientHeight / 2, behavior: "smooth" });
		}
	}
	app.el.top?.setRoute(route);
}

// ── the frame ──────────────────────────────────────────────────────────────
export function startShell() {
	const root = document.getElementById("app");
	clear(root);
	document.body.dataset.page = "app";
	const sidebar = buildSidebar();
	const top = buildTopBar();
	const main = h("main.main", { id: "main", tabindex: "-1" });
	const right = h("div.right-slot");
	const frame = h("div.frame", { class: state.view.sidebar ? "" : "no-sidebar" },
		sidebar,
		h("div.stage", top, h("div.stage-body", main)),
		right,
		buildBottomNav());
	root.appendChild(frame);
	app.el = { root: frame, sidebar, top, main, right };
	animate(frame, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.xlong, fill: "none" });
	animate(sidebar, [{ opacity: 0, transform: "translateX(-24px)" }, { opacity: 1, transform: "none" }], { duration: 600, easing: EASE.spring, fill: "none" });
	animate(top, [{ opacity: 0, transform: "translateY(-12px)" }, { opacity: 1, transform: "none" }], { duration: 600, delay: 60, easing: EASE.spring, fill: "backwards" });

	addEventListener("popstate", render);
	addEventListener("hashchange", () => {
		if (routeOf().hash !== app.route?.hash) render();
	});
	installKeys();
	uploads.init(app);
	jobs.init(app);

	api.connectEvents();
	api.on("notify", data => toast(data.title || "Note", {
		body: data.body,
		tone: data.level === "error" ? "bad" : data.level === "warn" ? "warn" : undefined,
		icon: data.level === "error" ? "alert_circle_outline" : data.level === "warn" ? "alert_outline" : "bell_outline",
		timeout: data.level === "error" ? 9000 : 5000
	}));
	api.on("worker", () => refreshStatus());
	api.on("health", () => refreshStatus());
	api.on("settings", () => refreshSettings());
	// favourites and tags may change on another device
	const libraryLater = debounce(() => loadLibrary(), 1500);
	api.on("changed", libraryLater);
	api.on("socket", data => data.open && refreshStatus());
	api.onSocketState(s => document.body.classList.toggle("socket-down", s === "closed"));

	refreshStatus();
	refreshSettings();
	refreshTypes();
	loadLibrary();
	setInterval(() => document.visibilityState === "visible" && refreshStatus(), 30000);

	render();

	if (sessionStorage.getItem("nas.totpSetup")) {
		sessionStorage.removeItem("nas.totpSetup");
		toast("Two-step login is required – set it up now", { icon: "shield_key_outline", tone: "warn", timeout: 0, action: { label: "Set up", run: () => go("#/settings?section=account") } });
	}
}

// ── sidebar (Sidebar.qml) ──────────────────────────────────────────────────
function sideItem({ label, iconName, route, path, href, onClick, badge, dot, hint }) {
	const el = h("a.side-item", { href: href || "#", dataset: { route: route || "", path: path || "" }, title: hint || "" },
		h("span.side-mark"),
		dot ? h("span.side-dot", { style: { background: dot } }) : icon(iconName),
		h("span.side-label.ellipsis", label),
		badge || null);
	if (path === undefined) delete el.dataset.path;
	el.addEventListener("click", event => {
		if (onClick) {
			event.preventDefault();
			onClick(event);
			return;
		}
		if (isMobile()) closeDrawer();
	});
	return el;
}

function sideSection(title, items, { id, empty, action } = {}) {
	let collapsed = false;
	try {
		collapsed = localStorage.getItem(`nas.side.${id || title}`) === "1";
	} catch (error) {}
	const list = h("div.side-list", items);
	const hint = empty ? h("div.side-hint", empty) : null;
	const head = h("div.side-head", h("button.side-title", { type: "button", title: "Fold" }, h("span.section-label", title)), action || null);
	const section = h("section.side-section", { class: collapsed ? "collapsed" : "" }, head, list, hint);
	head.firstChild.addEventListener("click", () => {
		collapsed = !collapsed;
		section.classList.toggle("collapsed", collapsed);
		try {
			localStorage.setItem(`nas.side.${id || title}`, collapsed ? "1" : "0");
		} catch (error) {}
	});
	section.setItems = next => {
		clear(list);
		next.forEach(item => list.appendChild(item));
		if (hint) hint.hidden = next.length > 0;
		else section.hidden = next.length === 0;
	};
	if (hint) hint.hidden = items.length > 0;
	return section;
}

const TAG_TONES = ["var(--primary)", "var(--secondary)", "var(--success)", "var(--warning)", "var(--tertiary)", "var(--danger)"];

function buildSidebar() {
	const statusDot = h("span.live-dot");
	const settingsBtn = h("a.icon-btn.small", { href: "#/settings", title: "Settings" }, icon("cog_outline"));
	const foldBtn = h("button.icon-btn.small.hide-mobile", { type: "button", title: "Hide the sidebar (Ctrl+B)" }, icon("dock_left"));
	foldBtn.addEventListener("click", () => toggleSidebar());
	const brand = h("div.brand",
		h("div.app-tile", icon("server")),
		h("div.brand-text", h("div.brand-name.ellipsis", state.hello?.name || "NAS"), h("div.brand-sub", statusDot, h("span.brand-state", "Connecting…"))),
		settingsBtn, foldBtn);

	const taskBadge = h("span.side-badge", { hidden: true });
	const main = h("div.side-list.top",
		sideItem({ label: "Home", iconName: "home_outline", route: "home", href: "#/home" }),
		sideItem({ label: "Recent", iconName: "history", route: "search", href: "#/search?recent=1" }),
		sideItem({ label: "Photos", iconName: "image_multiple_outline", route: "photos", href: "#/photos" }));

	const rootItem = sideItem({ label: state.hello?.name || "NAS", iconName: "harddisk", route: "files", path: "/", href: "#/files/" });
	const places = sideSection("Places", [rootItem], { id: "places" });
	const favorites = sideSection("Favorites", [], { id: "favorites", empty: "Drop folders here to keep them at hand." });
	const tags = sideSection("Tags", [], { id: "tags", empty: "Tags come from a file's menu › Tags." });
	const tools = sideSection("Tools", [
		sideItem({ label: "Storage", iconName: "chart_donut", route: "storage", href: "#/storage" }),
		sideItem({ label: "Duplicates", iconName: "content_duplicate", route: "dupes", href: "#/dupes" }),
		sideItem({ label: "Shared links", iconName: "link_variant", route: "shares", href: "#/shares" }),
		sideItem({ label: "Tasks", iconName: "cog_transfer_outline", route: "tasks", href: "#/tasks", badge: taskBadge }),
		sideItem({ label: "Activity", iconName: "chart_timeline_variant", route: "activity", href: "#/activity" })
	], { id: "tools" });
	const system = sideSection("System", [
		sideItem({ label: "Health", iconName: "heart_pulse", route: "health", href: "#/health" }),
		sideItem({ label: "Devices", iconName: "devices", route: "devices", href: "#/devices" }),
		sideItem({ label: "Settings", iconName: "cog_outline", route: "settings", href: "#/settings" })
	], { id: "system" });

	// the disk and who computes, as the file manager shows its drives
	const diskBar = h("div.drive-bar", h("i", { style: { width: "0%" } }));
	const disk = h("a.side-item.drive", { href: "#/storage", title: "What takes the space", dataset: { route: "storage-disk" } },
		h("span.side-mark"), icon("harddisk"), h("span.drive-text", h("span.side-label.ellipsis", "Data disk"), diskBar));
	const worker = h("a.side-item.worker", { href: "#/tasks", dataset: { route: "tasks-worker" } }, h("span.side-mark"), icon("chip"), h("span.side-label.ellipsis", "…"), h("span.worker-dot"));
	const drives = sideSection("Drives", [disk, worker], { id: "drives" });

	const trash = sideItem({ label: "Trash", iconName: "trash_can_outline", route: "trash", href: "#/trash" });
	const scroller = h("div.side-scroll", main, places, favorites, tags, tools, system, drives);
	const aside = h("aside.sidebar", brand, scroller, h("div.side-foot", trash));
	aside.addEventListener("dragover", event => {
		const item = event.target.closest(".side-item[data-path]");
		if (!item || !item.dataset.path) return;
		event.preventDefault();
		item.classList.add("drop");
	});
	aside.addEventListener("dragleave", event => event.target.closest?.(".side-item")?.classList.remove("drop"));
	aside.addEventListener("drop", event => {
		const item = event.target.closest(".side-item[data-path]");
		if (!item?.dataset.path) return;
		event.preventDefault();
		item.classList.remove("drop");
		import("./actions.js").then(m => m.dropOn(item.dataset.path, event));
	});

	// places: the folders at the top of the tree
	const loadPlaces = async () => {
		try {
			const listing = await api.get("/api/ls", { path: "/" }, { quiet: true });
			const dirs = (listing.entries || []).filter(e => e.dir).slice(0, 12);
			places.setItems([rootItem, ...dirs.map(d => sideItem({ label: d.name, iconName: placeIcon(d.name), route: "files", path: d.path, href: `#/files${encodePath(d.path)}` }))]);
			markNav(app.route || routeOf());
		} catch (error) {}
	};
	loadPlaces();
	api.on("changed", data => (data.paths || []).includes("/") && loadPlaces());

	onStore("favorites", list => {
		favorites.setItems(list.map(p => sideItem({ label: nameOf(p), iconName: "folder_star_outline", route: "files", path: p, href: `#/files${encodePath(p)}` })));
		if (app.route) markNav(app.route);
	});
	onStore("tags", list => {
		tags.setItems(list.map((t, i) => sideItem({ label: t, dot: TAG_TONES[i % TAG_TONES.length], route: "tag", path: `tag:${t}`, href: `#/tag/${encodeURIComponent(t)}` })));
		if (app.route) markNav(app.route);
	});
	const showStatus = s => {
		if (!s) return;
		const d = s.disk || {};
		const used = d.total ? (d.used ?? d.total - d.free) / d.total : 0;
		diskBar.firstChild.style.width = `${Math.max(2, Math.round(used * 100))}%`;
		diskBar.className = `drive-bar${used > 0.9 ? " bad" : used > 0.75 ? " warn" : ""}`;
		disk.title = d.total ? `${fmtSize(d.free)} free of ${fmtSize(d.total)}` : "";
		const pc = s.worker?.connected;
		worker.classList.toggle("pc", !!pc);
		worker.querySelector(".side-label").textContent = pc ? `${s.worker.device || "PC"} computes` : state.settings?.pi_compute === false ? "Waits for the PC" : "The Pi computes";
		worker.title = pc ? "A PC is connected as a worker: every task runs there" : "No PC connected: the Pi runs the tasks itself";
		const busy = (s.tasks?.running || 0) + (s.tasks?.queued || 0);
		taskBadge.hidden = !busy;
		taskBadge.textContent = busy;
		system.hidden = !isAdmin();
		settingsBtn.hidden = !isAdmin();
	};
	onStore("status", showStatus);
	onStore("settings", () => showStatus(state.status));
	api.onSocketState(s => {
		statusDot.className = `live-dot ${s}`;
		brand.querySelector(".brand-state").textContent = s === "open" ? "pshell NAS" : s === "connecting" ? "Connecting…" : "Offline – retrying";
	});
	system.hidden = !isAdmin();
	return aside;
}

function toggleSidebar() {
	if (isMobile()) {
		openDrawer();
		return;
	}
	setView({ sidebar: !state.view.sidebar });
	app.el.root.classList.toggle("no-sidebar", !state.view.sidebar);
}

function placeIcon(name) {
	const n = name.toLowerCase();
	if (n.includes("photo") || n.includes("picture") || n.includes("bilder")) return "image_outline";
	if (n.includes("backup")) return "backup_restore";
	if (n.includes("game")) return "gamepad_variant";
	if (n.includes("download")) return "download_outline";
	if (n.includes("shelf")) return "tray";
	if (n.includes("obsidian") || n.includes("notes")) return "notebook";
	if (n.includes("music") || n.includes("song")) return "music_note";
	if (n.includes("video") || n.includes("film") || n.includes("movie")) return "filmstrip";
	if (n.includes("doc")) return "file_document_outline";
	if (n.includes("upload")) return "cloud_upload_outline";
	if (n.includes("code")) return "code_braces";
	return "folder_outline";
}

function openDrawer() {
	app.el.root.classList.add("drawer-open");
}
function closeDrawer() {
	app.el.root?.classList.remove("drawer-open");
}

// ── top bar (TopBar.qml): the page as a tab, search, palette, transfers;
// below it the way back and the crumbs, the view's own tools at the right
function buildTopBar() {
	const menuBtn = h("button.icon-btn.only-mobile", { title: "Places" }, icon("menu"));
	menuBtn.addEventListener("click", openDrawer);
	const unfold = h("button.icon-btn.unfold", { title: "Show the sidebar (Ctrl+B)" }, icon("dock_left"));
	unfold.addEventListener("click", () => toggleSidebar());
	const tab = h("div.tab", h("span.tab-icon", icon("home_outline")), h("span.tab-title.ellipsis", ""));

	// search: in this folder, or everywhere; by name, or by meaning
	const input = h("input", { type: "search", placeholder: "Search your files", spellcheck: false, autocomplete: "off", enterkeyhint: "search" });
	const search = h("label.search", icon("magnify"), input);
	const meaning = h("button.icon-btn.meaning", { type: "button", title: "Search by meaning (the semantic index)" }, icon("creation"));
	const palette = h("button.palette-chip.hide-mobile", { type: "button", title: "Command palette" }, icon("console_line"), h("span", "Ctrl K"));
	palette.addEventListener("click", () => openPalette());
	let semantic = false;
	try {
		semantic = localStorage.getItem("nas.semantic") === "1";
	} catch (error) {}
	meaning.classList.toggle("on", semantic);
	meaning.addEventListener("click", event => {
		event.preventDefault();
		semantic = !semantic;
		meaning.classList.toggle("on", semantic);
		toast(semantic ? "Search finds files by meaning too" : "Search goes by names", { icon: "creation", timeout: 1600 });
		try {
			localStorage.setItem("nas.semantic", semantic ? "1" : "0");
		} catch (error) {}
		if (input.value.trim()) runSearch();
	});
	let scope = "";
	const runSearch = () => {
		const q = input.value.trim();
		if (!q) {
			if (app.route?.name === "search" && !app.route.query.recent) history.back();
			return;
		}
		const params = new URLSearchParams({ q });
		if (semantic) params.set("semantic", "1");
		if (scope && scope !== "/") params.set("path", scope);
		go(`#/search?${params}`, { replace: app.route?.name === "search" });
	};
	const later = debounce(runSearch, 320);
	input.addEventListener("input", later);
	input.addEventListener("keydown", event => {
		if (event.key === "Enter") {
			later.cancel();
			runSearch();
		}
		if (event.key === "Escape") {
			input.value = "";
			input.blur();
		}
		if (event.key === "ArrowDown") {
			event.preventDefault();
			input.blur();
			app.view?.focusList?.();
		}
	});

	const uploadBtn = h("button.icon-btn", { title: "Upload files (U)" }, icon("upload_outline"));
	uploadBtn.addEventListener("click", event => {
		const folder = app.view?.folder?.() ?? "/";
		const r = uploadBtn.getBoundingClientRect();
		showMenu([
			{ header: `Into ${folder === "/" ? state.hello?.name || "the NAS" : nameOf(folder)}` },
			{ label: "Upload files…", icon: "file_plus_outline", run: () => uploads.pick(folder, false) },
			{ label: "Upload a folder…", icon: "folder_plus_outline", run: () => uploads.pick(folder, true) }
		], r.right - 220, r.bottom + 6);
	});
	const trayRing = ring(0, { size: 30, stroke: 2.5 });
	const trayCount = h("span.tray-count");
	const tray = h("button.icon-btn.tray-btn", { title: "Transfers and tasks" }, icon("swap_vertical"), trayRing, trayCount);
	tray.addEventListener("click", () => jobs.showTray(tray));
	jobs.onSummary(({ active, progress }) => {
		tray.classList.toggle("busy", active > 0);
		trayRing.set(active ? progress : 0);
		trayCount.textContent = active ? String(active) : "";
	});

	const avatar = h("button.avatar", { title: "Account" }, (state.me?.name || state.me?.user || "?").slice(0, 1).toUpperCase());
	avatar.addEventListener("click", () => {
		const rect = avatar.getBoundingClientRect();
		showMenu([
			{ header: state.me?.name || state.me?.user || "" },
			{ label: "Settings", icon: "cog_outline", run: () => go("#/settings") },
			{ label: "Password and two-step login", icon: "shield_key_outline", run: () => go("#/settings?section=account") },
			{ label: "Command palette", icon: "console_line", shortcut: "Ctrl+K", run: openPalette },
			{ label: "Keyboard shortcuts", icon: "keyboard_outline", shortcut: "?", run: showShortcuts },
			{ separator: true },
			{ label: "Log out", icon: "logout", danger: true, run: logout }
		], rect.right - 4, rect.bottom + 6);
	});

	const back = h("button.icon-btn.small", { title: "Back (Alt+←)" }, icon("arrow_left"));
	back.addEventListener("click", () => history.back());
	const forward = h("button.icon-btn.small.hide-mobile", { title: "Forward (Alt+→)" }, icon("arrow_right"));
	forward.addEventListener("click", () => history.forward());
	const up = h("button.icon-btn.small", { title: "Up (Backspace)" }, icon("arrow_up"));
	up.addEventListener("click", () => {
		const folder = app.view?.folder?.();
		if (app.route?.name === "files" && folder && folder !== "/") app.go(`#/files${encodePath(folder.replace(/\/[^/]+$/, "") || "/")}?select=${encodeURIComponent(nameOf(folder))}`);
	});
	const titleSlot = h("div.nav-crumbs");
	const toolsSlot = h("div.nav-tools");

	const row1 = h("div.top-row", menuBtn, unfold, tab, h("div.top-gap"), search, meaning, palette, uploadBtn, tray, avatar);
	const row2 = h("div.nav-row", h("div.nav-buttons", back, forward, up), titleSlot, toolsSlot);
	const bar = h("header.topbar", row1, row2);
	bar.setTitle = view => {
		clear(titleSlot);
		clear(toolsSlot);
		const title = view.tabTitle?.() || view.title || "";
		tab.querySelector(".tab-title").textContent = title;
		tab.querySelector(".tab-icon").replaceChildren(icon(view.tabIcon?.() || view.icon || "folder_outline"));
		animate(tab, [{ opacity: 0.4, transform: "scale(0.96)" }, { opacity: 1, transform: "none" }], { duration: 320, easing: EASE.spring, fill: "none" });
		if (view.titleEl) titleSlot.appendChild(view.titleEl);
		else if (view.title) titleSlot.appendChild(h("div.crumb-pill", view.icon ? icon(view.icon) : null, h("span.ellipsis", view.title)));
		if (view.toolsEl) toolsSlot.appendChild(view.toolsEl);
		up.disabled = !(app.route?.name === "files" && view.folder?.() && view.folder() !== "/");
		scope = app.route?.name === "files" ? view.folder?.() || "" : app.route?.name === "search" ? app.route.query.path || "" : "";
		input.placeholder = scope && scope !== "/" ? `Search in ${nameOf(scope)}` : "Search your files";
	};
	bar.refreshTab = view => {
		tab.querySelector(".tab-title").textContent = view.tabTitle?.() || view.title || "";
		up.disabled = !(app.route?.name === "files" && view.folder?.() && view.folder() !== "/");
		scope = app.route?.name === "files" ? view.folder?.() || "" : scope;
		input.placeholder = scope && scope !== "/" ? `Search in ${nameOf(scope)}` : "Search your files";
	};
	bar.setRoute = route => {
		if (route.name === "search") {
			if (document.activeElement !== input && route.query.q !== undefined) input.value = route.query.q || "";
			semantic = route.query.semantic === "1" || semantic;
			meaning.classList.toggle("on", semantic);
		} else if (document.activeElement !== input) {
			input.value = "";
		}
	};
	bar.focusSearch = () => {
		input.focus();
		input.select();
	};
	return bar;
}

async function logout() {
	try {
		await api.post("/api/logout");
	} catch (error) {}
	api.disconnectEvents();
	location.hash = "";
	location.reload();
}

// ── bottom navigation (phones) ─────────────────────────────────────────────
function buildBottomNav() {
	const item = (label, iconName, route, href) => h("a.nav-item", { href, dataset: { route } }, h("span.nav-pill", icon(iconName)), h("span.nav-label", label));
	const more = h("button.nav-item", { type: "button" }, h("span.nav-pill", icon("menu")), h("span.nav-label", "More"));
	more.addEventListener("click", openDrawer);
	const nav = h("nav.bottom-nav.panel-glass",
		item("Home", "home_outline", "home", "#/home"),
		item("Files", "folder_outline", "files", "#/files/"),
		item("Photos", "image_multiple_outline", "photos", "#/photos"),
		item("Tasks", "cog_transfer_outline", "tasks", "#/tasks"),
		more);
	const scrim = h("div.drawer-scrim");
	scrim.addEventListener("click", closeDrawer);
	return h("div.mobile-chrome", nav, scrim);
}

// ── keys ───────────────────────────────────────────────────────────────────
function installKeys() {
	document.addEventListener("keydown", event => {
		const typing = event.target.closest?.("input, textarea, select, [contenteditable]");
		if (document.querySelector(".dialog-wrap, .menu-layer, .quicklook")) {
			if (!(event.ctrlKey && event.key.toLowerCase() === "k")) return;
		}
		const mod = event.ctrlKey || event.metaKey;
		if (mod && event.key.toLowerCase() === "k") {
			event.preventDefault();
			openPalette();
			return;
		}
		if (mod && event.key.toLowerCase() === "f") {
			event.preventDefault();
			app.el.top.focusSearch();
			return;
		}
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
		if (typing) return;
		if (event.key === "/") {
			event.preventDefault();
			app.el.top.focusSearch();
			return;
		}
		if (event.key === "?" ) {
			showShortcuts();
			return;
		}
		app.view?.onKey?.(event);
	});
}

export async function openPalette() {
	const { openPalette: open } = await import("./palette.js");
	open(app);
}

function showShortcuts() {
	const rows = [
		["Ctrl K", "Command palette"],
		["/ or Ctrl F", "Search"],
		["Space", "Quick look"],
		["Enter", "Open"],
		["Backspace / Alt ←", "Up / back"],
		["F2", "Rename"],
		["Delete", "Move to the trash"],
		["Shift Delete", "Delete for good (when allowed)"],
		["Ctrl A", "Pick all"],
		["Ctrl C / X / V", "Copy, cut, paste"],
		["Ctrl D", "Favorite"],
		["Alt Enter", "Details"],
		["Ctrl Shift N", "New folder"],
		["U", "Upload"],
		["Ctrl + / −", "Card size"],
		["Ctrl B", "Sidebar"]
	];
	import("./ui.js").then(({ openDialog }) => openDialog({
		title: "Keyboard",
		icon: "keyboard_outline",
		body: h("div.shortcuts", rows.map(([k, v]) => h("div.shortcut-row", h("span", v), h("span.kbd", k))))
	}));
}

export { closeDrawer };
