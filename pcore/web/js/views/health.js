// Health: the Pi over the last day or week – memory available against the
// guard's limits, memory pressure (PSI), temperature, load, CPU, and the
// containers' memory stacked – and the guard with what it did.
import { h, icon, clear, when, mem, uptime, plural, fullDate } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, normSample, setting, refreshGuard } from "../store.js";
import { stagger, animate, EASE, ring, rollText } from "../motion.js";
import { segmented, errorToast } from "../ui.js";
import { timeChart } from "../charts.js";
import { throttledText, guardActions } from "./common.js";

const serviceOf = container => state.services.find(s => s.container_name === container || s.container?.name === container || s.container === container || s.name === container);

// categorical order for the containers, never cycled; the rest is "other"
const CAT = ["var(--primary)", "var(--secondary)", "var(--tertiary)", "color-mix(in srgb, var(--primary) 45%, var(--success))", "color-mix(in srgb, var(--tertiary) 50%, var(--danger))"];
const OTHER = "color-mix(in srgb, var(--fg) 34%, var(--bg))";
const GUARD_WORD = { ok: "Calm", tight: "Tight", critical: "Critical" };

export default function health(route, app) {
	let hours = Number(route.query.hours) === 168 ? 168 : 24;
	let samples = [];
	const range = segmented([{ value: 24, label: "24 hours" }, { value: 168, label: "7 days" }], hours, v => {
		hours = Number(v);
		history.replaceState(null, "", hours === 168 ? "/health?hours=168" : "/health");
		load();
	});
	const stamp = h("span.subtle.hide-mobile");
	const guardSlot = h("div.guard-card");
	const now = h("div.now-strip");
	const charts = h("div.chart-grid");
	const root = h("div.page-scroll", h("div.page",
		h("div.page-head", h("div", h("h1", "Health"), h("div.subtle", "netcore, a Raspberry Pi 4, sampled every 30 seconds.")), h("div.page-tools", stamp, range)),
		h("div.health-top", guardSlot, now),
		charts));

	// ── the guard ─────────────────────────────────────────────────────────
	function renderGuard(g) {
		const level = g?.level || "ok";
		const actions = guardActions(g);
		clear(guardSlot).append(...[
			h("div.guard-head",
				h(`div.guard-orb.${level}`, h("i"), icon(level === "ok" ? "shield_check_outline" : "shield_alert_outline")),
				h("div",
					h("div.section-label", "Memory guard"),
					h("div.guard-level", GUARD_WORD[level] || level),
					h("div.subtle", g?.since ? `since ${when(g.since)}` : "no change recorded"))),
			h("div.guard-limits",
				h("span.chip.small.warn", `tight < ${setting("tight_mb", 900)} MB or some > ${setting("tight_psi", 20)} %`),
				h("span.chip.small.bad", `critical < ${setting("critical_mb", 450)} MB or full > ${setting("critical_psi", 10)} %`)),
			g?.stopped?.length ? h("div.warn-box.danger-box", icon("stop_circle_outline"), h("div", h("strong", "Stopped by the guard: "), g.stopped.map(n => h("a", { href: `/services/${encodeURIComponent(serviceOf(n)?.name || n)}`, style: { marginRight: "8px" } }, serviceOf(n)?.title || n)), h("div.subtle", "They stay stopped – start them by hand when memory is calm."))) : null,
			h("div.section-label", { style: { marginTop: "4px" } }, "What it did"),
			actions.length
				? h("div.guard-actions", actions.slice(0, 8).map(a => h("div.guard-action", { title: fullDate(a.at) }, h("span.event-time", when(a.at)), h("span", a.what))))
				: h("div.subtle", "Nothing yet – the Pi has had enough memory.")].filter(Boolean));
		guardSlot.className = `guard-card ${level}`;
	}

	// ── now ───────────────────────────────────────────────────────────────
	const tiles = {};
	function nowTile(key, title, iconName) {
		const value = h("strong.now-value", "–");
		const sub = h("div.now-sub", "");
		const el = h("div.now-tile", h("div.now-title", icon(iconName), title), value, sub);
		tiles[key] = { el, value, sub };
		now.appendChild(el);
	}
	nowTile("mem", "Available", "memory");
	nowTile("psi", "Pressure", "gauge");
	nowTile("temp", "Temperature", "thermometer");
	nowTile("load", "Load", "speedometer");
	nowTile("disk", "Disk", "harddisk");
	nowTile("up", "Up for", "clock_outline");
	stagger(now.children, { step: 40 });

	function renderNow(s) {
		if (!s) return;
		const set = (key, value, sub, tone) => {
			rollText(tiles[key].value, value);
			tiles[key].sub.textContent = sub;
			tiles[key].el.className = `now-tile${tone ? " " + tone : ""}`;
		};
		const tightB = setting("tight_mb", 900) * 1048576;
		set("mem", mem(s.mem_available, 2), s.mem_total ? `of ${mem(s.mem_total, 1)}${s.swap_used ? ` · swap ${mem(s.swap_used)}` : ""}` : "", s.mem_available < setting("critical_mb", 450) * 1048576 ? "bad" : s.mem_available < tightB ? "warn" : "");
		set("psi", s.psi_some10 === null ? "–" : `${Number(s.psi_some10).toFixed(1)} %`, s.psi_full10 === null ? "some, avg 10 s" : `some · full ${Number(s.psi_full10).toFixed(1)} %`, s.psi_full10 > setting("critical_psi", 10) ? "bad" : s.psi_some10 > setting("tight_psi", 20) ? "warn" : "");
		set("temp", s.temp === null ? "–" : `${s.temp.toFixed(1)} °C`, throttledText(s.throttled) ? `throttled ${throttledText(s.throttled)}` : "not throttled", s.temp >= 75 ? "bad" : s.temp >= 62 ? "warn" : "");
		set("load", s.load1 === null ? "–" : Number(s.load1).toFixed(2), `${[s.load5, s.load15].map(v => (v === null ? "–" : Number(v).toFixed(2))).join(" · ")}${s.cpu !== null ? ` · CPU ${Math.round(s.cpu)} %` : ""}`, s.load1 > 4 ? "bad" : s.load1 > 3 ? "warn" : "");
		const du = s.disk?.total ? s.disk.used / s.disk.total : null;
		set("disk", du === null ? "–" : `${Math.round(du * 100)} %`, du === null ? "" : `${mem(s.disk.total - s.disk.used, 0)} free`, du > 0.9 ? "bad" : du > 0.8 ? "warn" : "");
		set("up", s.uptime ? uptime(s.uptime) : "–", s.at ? `sample ${when(s.at)}` : "", "");
		stamp.textContent = s.at ? `as of ${when(s.at)}` : "";
	}

	// ── charts ────────────────────────────────────────────────────────────
	const cards = [];
	function card(title, sub, chart) {
		const el = h("div.chart-card", h("div.chart-head", h("h3", title), sub ? h("span.subtle", sub) : null), chart);
		el.chart = chart;
		cards.push(el);
		charts.appendChild(el);
		return el;
	}

	const toMs = v => (typeof v === "number" ? (v < 1e12 ? v * 1000 : v) : Date.parse(v));
	const pts = pick => samples.map(s => ({ t: toMs(s.at), v: pick(s) }));
	const MB = 1048576;

	function build() {
		cards.forEach(c => c.chart.destroy?.());
		cards.length = 0;
		clear(charts);
		card("Memory available", "the guard watches this", timeChart({
			series: [{ key: "a", label: "Available", tone: "var(--primary)" }],
			points: pts(s => ({ a: s.mem_available === null ? null : s.mem_available / MB })),
			format: v => (v >= 1024 ? `${(v / 1024).toFixed(2)} GB` : `${Math.round(v)} MB`),
			axisFormat: v => (v >= 1000 ? `${(v / 1024).toFixed(1)} G` : `${Math.round(v)} M`),
			min: 0,
			thresholds: [{ value: setting("tight_mb", 900), label: "tight", tone: "var(--warning)" }, { value: setting("critical_mb", 450), label: "critical", tone: "var(--danger)" }]
		}));
		card("Memory pressure", "PSI, avg 10 s", timeChart({
			series: [{ key: "some", label: "some", tone: "var(--warning)" }, { key: "full", label: "full", tone: "var(--danger)" }],
			points: pts(s => ({ some: s.psi_some10, full: s.psi_full10 })),
			format: v => `${v.toFixed(1)} %`,
			axisFormat: v => `${Math.round(v)} %`,
			min: 0,
			thresholds: [{ value: setting("tight_psi", 20), label: "tight (some)", tone: "var(--warning)" }, { value: setting("critical_psi", 10), label: "critical (full)", tone: "var(--danger)" }]
		}));
		card("Temperature", "SoC", timeChart({
			series: [{ key: "t", label: "Temperature", tone: "var(--secondary)" }],
			points: pts(s => ({ t: s.temp })),
			format: v => `${v.toFixed(1)} °C`,
			axisFormat: v => `${Math.round(v)}°`,
			thresholds: [{ value: 80, label: "throttles at 80 °C", tone: "var(--danger)" }]
		}));
		card("Load", "4 cores", timeChart({
			series: [{ key: "l1", label: "1 min", tone: "var(--tertiary)" }, { key: "l5", label: "5 min", tone: "var(--primary)" }, { key: "l15", label: "15 min", tone: "var(--secondary)" }],
			points: pts(s => ({ l1: s.load1, l5: s.load5, l15: s.load15 })),
			format: v => v.toFixed(2),
			axisFormat: v => (Number.isInteger(v) ? String(v) : v.toFixed(1)),
			min: 0
		}));
		card("CPU", "all cores", timeChart({
			series: [{ key: "c", label: "CPU", tone: "var(--tertiary)" }],
			points: pts(s => ({ c: s.cpu })),
			format: v => `${Math.round(v)} %`,
			min: 0,
			max: 100
		}));
		// containers: the biggest five by their average, the rest as "other"
		const avg = {};
		for (const s of samples) for (const [k, v] of Object.entries(s.containers || {})) if (v) avg[k] = (avg[k] || 0) + v;
		const names = Object.keys(avg).sort((a, b) => avg[b] - avg[a]);
		const top = names.slice(0, CAT.length);
		const rest = names.slice(CAT.length);
		const title = n => state.services.find(s => s.container?.name === n || s.container_name === n || s.container === n)?.title || n;
		const series = top.map((n, i) => ({ key: n, label: title(n), tone: CAT[i] }));
		if (rest.length) series.push({ key: "__other", label: `${plural(rest.length, "other")}`, tone: OTHER });
		card("Containers", "memory, stacked", series.length ? timeChart({
			series,
			stacked: true,
			points: pts(s => {
				const v = {};
				for (const n of top) v[n] = s.containers?.[n] === undefined ? 0 : s.containers[n] / MB;
				if (rest.length) v.__other = rest.reduce((sum, n) => sum + (s.containers?.[n] || 0) / MB, 0);
				return v;
			}),
			format: v => (v >= 1024 ? `${(v / 1024).toFixed(2)} GB` : `${Math.round(v)} MB`),
			axisFormat: v => (v >= 1000 ? `${(v / 1024).toFixed(1)} G` : `${Math.round(v)} M`),
			min: 0,
			height: 220
		}) : h("div.chart-empty", "No container numbers (no docker socket?)"));
		cards[cards.length - 1].classList.add("wide");
		stagger(charts.children, { step: 50, distance: 14 });
	}

	async function load() {
		charts.classList.add("loading");
		if (!samples.length) clear(charts).append(...[1, 2, 3, 4].map(() => h("div.skeleton", { style: { height: "250px", borderRadius: "22px" } })));
		try {
			const data = await api.get("/api/health/history", { hours });
			samples = api.listOf(data, "samples", "history").map(normSample).filter(s => s && s.at !== null);
			build();
		} catch (error) {
			clear(charts).appendChild(h("div.empty", icon("chart_line"), h("h3", "No history"), h("p", error.message)));
		} finally {
			charts.classList.remove("loading");
		}
	}

	// a new sample moves the 24 h lines along
	const onSample = s => {
		renderNow(s);
		if (!s || hours !== 24 || !samples.length || s.at === samples[samples.length - 1].at) return;
		samples.push(s);
		const cutoff = toMs(s.at) - 24 * 3600e3;
		while (samples.length && toMs(samples[0].at) < cutoff) samples.shift();
		const keys = ["mem", "psi", "temp", "load", "cpu"];
		cards.slice(0, keys.length).forEach((c, i) => c.chart.update?.(rebuildPoints(i)));
	};
	function rebuildPoints(i) {
		return [
			() => pts(s => ({ a: s.mem_available === null ? null : s.mem_available / MB })),
			() => pts(s => ({ some: s.psi_some10, full: s.psi_full10 })),
			() => pts(s => ({ t: s.temp })),
			() => pts(s => ({ l1: s.load1, l5: s.load5, l15: s.load15 })),
			() => pts(s => ({ c: s.cpu }))
		][i]();
	}

	renderGuard(state.guard);
	renderNow(state.health);
	refreshGuard();
	load();
	const offs = [onStore("guard", renderGuard), onStore("health", onSample), onStore("settings", () => {
		renderGuard(state.guard);
		if (samples.length) build();
	})];
	return { el: root, title: "Health", icon: "heart_pulse", refresh: load, unmount: () => {
		offs.forEach(o => o());
		cards.forEach(c => c.chart.destroy?.());
	}, update: next => {
		const want = Number(next.query.hours) === 168 ? 168 : 24;
		if (want !== hours) {
			hours = want;
			range.select(want);
			load();
		}
	} };
}
