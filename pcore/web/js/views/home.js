// Home: the services as tiles (state, memory, open in a new tab), the Pi's
// gauges, the guard when it is not calm, the newest security events.
import { h, icon, clear, when, mem, uptime, plural } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, myName, setting } from "../store.js";
import { stagger, ring, rollText, animate, EASE } from "../motion.js";
import { stateChip, serviceIcon, memBar, logKind, detailText, sectionHead, emptyRow, throttledText, guardActions } from "./common.js";

const GREETING = () => {
	const hour = new Date().getHours();
	return hour < 5 ? "Good night" : hour < 11 ? "Good morning" : hour < 17 ? "Hello" : hour < 22 ? "Good evening" : "Good night";
};

export default function home(route, app) {
	const heroLine = h("div.hero-line");
	const banner = h("div.guard-banner-slot");
	const tiles = h("div.svc-grid", { role: "list" });
	const gauges = h("div.gauge-grid");
	const recent = h("div.activity-mini");
	const root = h("div.page-scroll", h("div.page.home-page",
		h("div.hero", h("h1", `${GREETING()}, ${myName() || "there"}`), heroLine),
		banner,
		h("section.home-section", sectionHead("Services", "Open one in a new tab – you are signed in there too", h("a.show-all", { href: "/services" }, "Details", icon("chevron_right"))), tiles),
		h("div.home-split",
			h("section.home-section", sectionHead("Raspberry Pi", "netcore right now", h("a.show-all", { href: "/health" }, "Health", icon("chevron_right"))), gauges),
			h("section.home-section", sectionHead("Recent security", "Sign-ins, devices, alerts", h("a.show-all", { href: "/security?log=1" }, "Log", icon("chevron_right"))), recent))));

	let tilesBuilt = false;
	const tileEls = new Map();

	function renderServices(list) {
		if (!list.length) {
			clear(tiles).appendChild(state.booted || tilesBuilt ? emptyRow("server_network", "No services yet") : h("div.skeleton", { style: { height: "128px", gridColumn: "1 / -1" } }));
			return;
		}
		const names = list.map(s => s.name).join(",");
		if (tiles.dataset.names !== names) {
			clear(tiles);
			tileEls.clear();
			tiles.dataset.names = names;
			for (const s of list) {
				const el = tile(s);
				tileEls.set(s.name, el);
				tiles.appendChild(el);
			}
			if (!tilesBuilt) stagger(tiles.children, { step: 36, distance: 14 });
			tilesBuilt = true;
		} else {
			for (const s of list) {
				const old = tileEls.get(s.name);
				const fresh = tile(s);
				if (old.dataset.state !== fresh.dataset.state) animate(fresh, [{ transform: "scale(0.97)" }, { transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
				old.replaceWith(fresh);
				tileEls.set(s.name, fresh);
			}
		}
		const up = list.filter(s => s.state === "up").length;
		const bad = list.filter(s => s.state === "down" || s.state === "degraded").length;
		clear(heroLine).append(
			h("span", `${plural(list.length, "service")}`), h("span.hero-dot", "·"),
			h("span", { class: bad ? "bad-text" : "" }, bad ? `${bad} need${bad === 1 ? "s" : ""} a look` : `${up} up`),
			...(state.health?.uptime ? [h("span.hero-dot", "·"), h("span", `the Pi is up for ${uptime(state.health.uptime)}`)] : []));
	}

	function tile(s) {
		const st = s.state || "unknown";
		const c = s.container || {};
		const open = s.url && st !== "stopped";
		const link = h(open ? "a.svc-link" : "span.svc-link", open ? { href: s.url, target: "_blank", rel: "noopener", title: `Open ${s.title || s.name} in a new tab` } : {}, h("span.svc-name.ellipsis", s.title || s.name));
		return h(`div.svc-tile.${st}`, { role: "listitem", dataset: { state: st } },
			h("div.svc-top",
				h("div.svc-icon", icon(serviceIcon(s))),
				h("div.svc-titles", link, h("div.svc-desc.ellipsis", s.description || (s.port ? `port ${s.port}` : ""))),
				h("a.icon-btn.small.svc-more", { href: `/services/${encodeURIComponent(s.name)}`, title: "Details", "aria-label": `${s.title || s.name}: details` }, icon("dots_horizontal"))),
			h("div.svc-mid", stateChip(st), s.http?.ms !== undefined && s.http?.ms !== null ? h("span.chip.small", icon("speedometer"), `${Math.round(s.http.ms)} ms`) : null, s.critical ? h("span.chip.small.warn", icon("shield_outline"), "critical") : null, open ? h("span.svc-open", icon("open_in_new")) : null),
			s.container ? memBar(c) : h("div.mem-line.none", h("span.subtle", s.home_only ? "Only at home" : "No container")));
	}

	// ── the Pi's gauges ───────────────────────────────────────────────────
	const g = {};
	function gauge(key, title, iconName, unit) {
		const r = ring(0, { size: 92, stroke: 8 });
		const value = h("strong", "–");
		const sub = h("div.gauge-sub", "");
		const el = h("a.gauge-tile", { href: "/health", title },
			h("div.gauge", r, h("div.gauge-value", value, h("span", unit))),
			h("div.gauge-text", h("div.gauge-title", icon(iconName), title), sub));
		g[key] = { el, r, value, sub };
		gauges.appendChild(el);
	}
	gauge("mem", "Memory", "memory", "GB free");
	gauge("temp", "Temperature", "thermometer", "°C");
	gauge("load", "Load", "speedometer", "1 min");
	gauge("disk", "Disk", "harddisk", "used");
	stagger(gauges.children, { step: 50 });

	function renderHealth(s) {
		if (!s) return;
		const tightB = setting("tight_mb", 900) * 1048576;
		const critB = setting("critical_mb", 450) * 1048576;
		if (s.mem_total) {
			const used = 1 - s.mem_available / s.mem_total;
			const tone = s.mem_available < critB ? "var(--danger)" : s.mem_available < tightB ? "var(--warning)" : "var(--primary)";
			g.mem.r.set(used, tone);
			rollText(g.mem.value, (s.mem_available / 1073741824).toFixed(2));
			g.mem.sub.textContent = `${mem(s.mem_total - s.mem_available, 1)} of ${mem(s.mem_total, 1)} in use${s.swap_used ? ` · swap ${mem(s.swap_used)}` : ""}`;
			g.mem.el.classList.toggle("warn", s.mem_available < tightB);
		}
		if (s.temp !== null) {
			const p = Math.max(0, Math.min(1, (s.temp - 30) / 55));
			g.temp.r.set(p, s.temp >= 75 ? "var(--danger)" : s.temp >= 62 ? "var(--warning)" : "var(--success)");
			rollText(g.temp.value, s.temp.toFixed(1));
			g.temp.sub.textContent = throttledText(s.throttled) ? `throttled ${throttledText(s.throttled)}` : s.temp >= 75 ? "hot" : s.temp >= 62 ? "warm" : "cool";
		}
		if (s.load1 !== null) {
			g.load.r.set(Math.min(1, s.load1 / 4), s.load1 > 4 ? "var(--danger)" : s.load1 > 3 ? "var(--warning)" : "var(--tertiary)");
			rollText(g.load.value, Number(s.load1).toFixed(2));
			g.load.sub.textContent = `${[s.load5, s.load15].map(v => (v === null ? "–" : Number(v).toFixed(2))).join(" · ")} (5, 15 min)${s.cpu !== null ? ` · CPU ${Math.round(s.cpu)} %` : ""}`;
		}
		if (s.disk?.total) {
			const used = s.disk.used / s.disk.total;
			g.disk.r.set(used, used > 0.9 ? "var(--danger)" : used > 0.8 ? "var(--warning)" : "var(--secondary)");
			rollText(g.disk.value, `${Math.round(used * 100)}%`);
			g.disk.sub.textContent = `${mem(s.disk.total - s.disk.used, 0)} free of ${mem(s.disk.total, 0)}`;
		}
	}

	function renderGuard(guard) {
		clear(banner);
		if (!guard || !guard.level || guard.level === "ok") return;
		const crit = guard.level === "critical";
		const last = guardActions(guard).slice(0, 2);
		const el = h(`div.guard-banner.${guard.level}`, { role: "alert" },
			h("div.guard-icon", icon(crit ? "alert_outline" : "memory")),
			h("div.guard-text",
				h("strong", crit ? "Memory is critical" : "Memory is tight"),
				h("div", `since ${when(guard.since)} – ${crit ? "the guard stops what it may and pauses the rest" : "services were told to pause their background work"}`),
				guard.stopped?.length ? h("div", `Stopped by the guard: ${guard.stopped.join(", ")} – they stay stopped until started by hand.`) : null,
				last.length ? h("div.subtle", last.map(a => `${when(a.at)}: ${a.what}`).join(" · ")) : null),
			h("a.btn.small", { href: "/health" }, "Health", icon("chevron_right")));
		banner.appendChild(el);
		animate(el, [{ opacity: 0, transform: "translateY(-8px) scale(0.98)" }, { opacity: 1, transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
	}

	async function loadLog() {
		try {
			const list = api.listOf(await api.get("/api/log", { limit: 6 }, { quiet: true }), "log", "entries");
			clear(recent);
			if (!list.length) recent.appendChild(emptyRow("shield_check_outline", "Nothing happened yet"));
			for (const e of list.slice(0, 6)) {
				const k = logKind(e.kind);
				recent.appendChild(h(`div.mini-row.${k.tone || "plain"}`,
					h("div.mini-icon", icon(k.icon)),
					h("div.mini-text", h("div.ellipsis", h("strong", k.label), e.who ? ` · ${e.who}` : ""), h("div.subtle.ellipsis", [when(e.at), e.ip, detailText(e.detail)].filter(Boolean).join(" · ")))));
			}
			stagger(recent.children, { step: 30, distance: 8 });
		} catch (error) {
			clear(recent).appendChild(emptyRow("shield_outline", error.status === 403 ? "Only admins see the log" : error.message));
		}
	}

	renderServices(state.services);
	renderHealth(state.health);
	renderGuard(state.guard);
	loadLog();
	const offs = [
		onStore("services", renderServices),
		onStore("health", renderHealth),
		onStore("guard", renderGuard),
		onStore("settings", () => renderHealth(state.health)),
		...["login", "login_failed", "locked", "device", "pressure", "service"].map(t => api.on(t, () => setTimeout(loadLog, 400)))
	];
	return { el: root, title: "Home", icon: "home_outline", refresh: loadLog, unmount: () => offs.forEach(o => o()) };
}
