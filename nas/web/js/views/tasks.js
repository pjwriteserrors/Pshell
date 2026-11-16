// Tasks: what computes, where (the PC or the Pi), live from the events.
import { h, icon, clear, nameOf, when, plural, size as fmtSize } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, refreshStatus, setting } from "../store.js";
import { ring, stagger, animate, EASE, roll, rollText } from "../motion.js";
import { segmented, toast, errorToast } from "../ui.js";
import { typeIcon } from "../actions.js";

const FILTERS = {
	active: "queued,running,waiting_pc",
	done: "done",
	failed: "failed,cancelled",
	all: ""
};

export default function tasks(route, app) {
	let filter = route.query.state || "active";
	let list = [];
	const openIds = new Set(route.query.open ? [route.query.open] : []);
	const rows = new Map();

	const pcTile = h("div.where-tile.pc", h("div.tile-icon", icon("monitor")), h("div.stat-body", h("div.section-label", "PC"), h("span.stat-big", "…"), h("div.stat-sub.subtle", "")));
	const piTile = h("div.where-tile.pi", h("div.tile-icon", icon("chip")), h("div.stat-body", h("div.section-label", "Pi"), h("span.stat-big", "…"), h("div.stat-sub.subtle", "")));
	const showWhere = s => {
		if (!s) return;
		const pc = s.worker?.connected;
		pcTile.classList.toggle("off", !pc);
		pcTile.querySelector(".stat-big").textContent = pc ? `${s.worker.device || "PC"} computes` : "Not connected";
		pcTile.querySelector(".stat-sub").textContent = pc ? "Every task goes to it" : "Tasks marked “PC” wait for it";
		const piOn = setting("pi_compute", true) !== false;
		// pshell-core's memory guard: the Pi takes nothing new while its memory is tight
		const paused = s.pressure && s.pressure !== "ok";
		piTile.classList.toggle("off", !!pc || !piOn || paused);
		piTile.querySelector(".stat-big").textContent = paused ? "Paused" : pc ? "Resting" : piOn ? "Computes" : "Off";
		piTile.querySelector(".stat-sub").textContent = paused
			? `Pi memory ${s.pressure === "critical" ? "critical" : "tight"} – its work waits${pc ? ", the PC goes on" : ""}`
			: piOn ? `At most ${setting("pi_jobs", 1)} at a time, gently (nice 15)` : "Pi computing is off in the settings";
	};

	const seg = segmented([
		{ value: "active", label: "Running" },
		{ value: "done", label: "Done" },
		{ value: "failed", label: "Failed" },
		{ value: "all", label: "All" }
	], filter, value => {
		filter = value;
		history.replaceState(null, "", `#/tasks?state=${value}`);
		load(true);
	});
	const clearBtn = h("button.btn.small.ghost", icon("broom"), "Clear finished");
	clearBtn.hidden = true;
	const listEl = h("div.list-card");
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Tasks"), h("div.subtle", "Thumbnails, conversions, scans, AI – on the PC when it is there, else on the Pi.")), h("div.page-tools", seg)),
		h("div.where-split", pcTile, piTile),
		listEl);
	const root = h("div.page-scroll", page);

	const offs = [onStore("status", showWhere), onStore("settings", () => showWhere(state.status))];
	showWhere(state.status);
	refreshStatus();

	async function load(animateIn) {
		if (!list.length) clear(listEl).append(...[1, 2, 3].map(() => h("div.skeleton", { style: { height: "58px", margin: "4px" } })));
		try {
			const data = await api.get("/api/tasks", { state: FILTERS[filter] || undefined, limit: 300 });
			list = Array.isArray(data) ? data : data.tasks || [];
			render(animateIn);
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Could not load the tasks"), h("p", error.message)));
		}
	}

	function render(animateIn) {
		clear(listEl);
		rows.clear();
		if (!list.length) {
			listEl.appendChild(h("div.empty", icon(filter === "failed" ? "emoticon_happy_outline" : "check_all"), h("h3", filter === "active" ? "Nothing running" : filter === "failed" ? "Nothing failed" : "No tasks"), h("p", filter === "active" ? "Right-click files for scans, conversions, PDF tools and more." : "")));
			return;
		}
		for (const t of list) {
			const el = taskRow(t);
			rows.set(t.id, el);
			listEl.appendChild(el);
		}
		if (animateIn) stagger(listEl.children, { step: 22, distance: 10 });
	}

	function taskRow(t) {
		const tone = t.state === "failed" ? "var(--danger)" : t.state === "done" ? "var(--success)" : t.where === "pc" ? "var(--secondary)" : "var(--tertiary)";
		const r = ring(t.state === "running" ? t.progress || null : t.state === "done" ? 1 : 0, { size: 42, stroke: 3.5, tone });
		const stateIcon = { queued: "timer_sand", running: t.icon && false ? t.icon : typeIcon(t.type), waiting_pc: "monitor", done: "check", failed: "alert_circle_outline", cancelled: "cancel" }[t.state] || "cog_outline";
		const paths = t.paths || [];
		const sub = [
			paths.length === 1 ? nameOf(paths[0]) : plural(paths.length, "item"),
			t.state === "running" ? t.text || `${Math.round((t.progress || 0) * 100)} %` : t.state === "waiting_pc" ? "waits for the PC" : t.state === "queued" ? "queued" : t.state === "failed" ? t.error || "failed" : t.finished ? when(t.finished) : when(t.created),
			t.by ? `by ${t.by}` : ""
		].filter(Boolean).join(" · ");
		const cancel = ["queued", "running", "waiting_pc"].includes(t.state) ? h("button.btn.small.ghost", { onclick: async event => {
			event.stopPropagation();
			try {
				await api.del(`/api/tasks/${t.id}`);
				toast("Cancelled", { icon: "cancel", timeout: 1500 });
			} catch (error) {
				errorToast(error);
			}
		} }, "Cancel") : null;
		const again = ["failed", "cancelled"].includes(t.state) ? h("button.btn.small.soft", { onclick: async event => {
			event.stopPropagation();
			try {
				await api.post("/api/tasks", { type: t.type, paths, options: t.options || {} });
				toast("Started again", { icon: "restart", timeout: 1500 });
				load();
			} catch (error) {
				errorToast(error);
			}
		} }, icon("restart"), "Again") : null;
		const detail = h("div.task-detail");
		const el = h(`div.list-row.task-row.${t.state}`, { dataset: { id: t.id } },
			h("div.row-icon", r, icon(stateIcon)),
			h("div.row-main", h("div.row-title", h("span.ellipsis", t.label || t.type)), h("div.row-sub", sub), detail),
			h("div.row-side", t.where ? h(`span.chip.${t.where}`, icon(t.where === "pc" ? "monitor" : "chip"), t.where === "pc" ? "PC" : "Pi") : null, again, cancel));
		el.addEventListener("click", () => {
			if (openIds.has(t.id)) openIds.delete(t.id);
			else openIds.add(t.id);
			fillDetail(detail, t);
		});
		fillDetail(detail, t);
		return el;
	}

	function fillDetail(detail, t) {
		clear(detail);
		if (!openIds.has(t.id)) return;
		const r = t.result;
		const box = h("div.task-result");
		if (t.error) box.appendChild(h("div", { style: { color: "var(--danger)" } }, t.error));
		if (r && typeof r === "object") {
			// scan verdicts
			const verdicts = r.verdicts || r.files || r.results;
			if (Array.isArray(verdicts)) {
				const list = h("div.verdict");
				for (const v of verdicts.slice(0, 200)) {
					const bad = v.infected || v.malicious > 0 || v.verdict === "infected" || v.ok === false;
					list.appendChild(h(`div.verdict-row.${bad ? "bad" : "good"}`, icon(bad ? "shield_alert_outline" : "shield_check_outline"), h("span.ellipsis", nameOf(v.path || "")), h("span.subtle", v.virus || v.name || (v.malicious !== undefined ? `${v.malicious}/${v.total || "?"} engines` : bad ? "found" : "clean"))));
				}
				box.appendChild(list);
			}
			if (r.text || r.answer || r.description) box.appendChild(h("div", r.text || r.answer || r.description));
			if (Array.isArray(r.outputs)) box.appendChild(h("div", r.outputs.map(o => h("div", h("a", { href: `#/files${(o.path || o).split("/").slice(0, -1).join("/") || "/"}?select=${encodeURIComponent(nameOf(o.path || o))}` }, icon("file_outline"), " ", o.path || o)))));
			if (!box.childNodes.length) box.appendChild(h("pre.mono", { style: { margin: 0 } }, JSON.stringify(r, null, 2).slice(0, 4000)));
		} else if (r) {
			box.appendChild(h("div", String(r)));
		}
		if (t.paths?.length > 1) box.appendChild(h("div.subtle", t.paths.slice(0, 20).join("\n")));
		if (box.childNodes.length) {
			detail.appendChild(box);
			animate(box, [{ opacity: 0, transform: "translateY(-6px)" }, { opacity: 1, transform: "none" }], { duration: 260, easing: EASE.spatial, fill: "none" });
		}
	}

	// live: one task changes in place, a new one rises in
	offs.push(api.on("task", data => {
		const t = data.task || data;
		if (!t?.id || t.auto) return;
		const states = FILTERS[filter] ? FILTERS[filter].split(",") : null;
		const fits = !states || states.includes(t.state);
		const i = list.findIndex(x => x.id === t.id);
		if (i >= 0) {
			list[i] = { ...list[i], ...t };
			const old = rows.get(t.id);
			if (!fits) {
				animate(old, [{ opacity: 1 }, { opacity: 0, transform: "translateX(30px)" }], { duration: 280, easing: EASE.accel }).finished.then(() => {
					list.splice(list.indexOf(list.find(x => x.id === t.id)), 1);
					render();
				});
				return;
			}
			const next = taskRow(list[i]);
			rows.set(t.id, next);
			old?.replaceWith(next);
		} else if (fits) {
			list.unshift(t);
			const el = taskRow(t);
			rows.set(t.id, el);
			if (listEl.querySelector(".empty")) clear(listEl);
			listEl.prepend(el);
			animate(el, [{ opacity: 0, transform: "translateY(-12px) scale(0.98)" }, { opacity: 1, transform: "none" }], { duration: 420, easing: EASE.spring, fill: "none" });
		}
	}));

	load(true);
	return { el: root, title: "Tasks", icon: "cog_transfer_outline", unmount: () => offs.forEach(off => off()), refresh: () => load() };
}
