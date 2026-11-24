// Reminders (docs/core.md "Reminders"): what is due now, what comes, what the
// calendar and the expenses remind of, a quick-add line read by the server
// (/api/reminders/parse) and how loud each source is.
import { h, icon, clear } from "../util.js";
import * as api from "../api.js";
import { stagger } from "../motion.js";
import { confirm, errorToast, openDialog, segmented, showMenu, shake, toggle } from "../ui.js";
import { sectionHead, emptyRow } from "./common.js";

const LEVELS = [
	{ value: "quiet", label: "Quiet", icon: "volume_off" },
	{ value: "normal", label: "Normal", icon: "bell_outline" },
	{ value: "important", label: "Important", icon: "bell_ring_outline" },
	{ value: "fullscreen", label: "Fullscreen", icon: "fullscreen" }
];
const TRIGGERS = [
	{ value: "time", label: "Time", icon: "clock_outline" },
	{ value: "unlock", label: "Back at the PC", icon: "monitor" },
	{ value: "leave_home", label: "Leaving home", icon: "walk" },
	{ value: "arrive_home", label: "Arriving home", icon: "home_outline" },
	{ value: "washer_done", label: "Washer done", icon: "washing_machine" },
	{ value: "qtrack_stop", label: "Tracking stops", icon: "timer_outline" },
	{ value: "game_end", label: "Game ends", icon: "gamepad_variant_outline" }
];
const REPEATS = [
	{ value: "", label: "Once" },
	{ value: "day", label: "Daily" },
	{ value: "week", label: "Weekly" },
	{ value: "month", label: "Monthly" },
	{ value: "year", label: "Yearly" }
];
const UNIT = { day: ["day", "days"], week: ["week", "weeks"], month: ["month", "months"], year: ["year", "years"] };
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const SOURCES = {
	own: ["Own", "bell_outline"], calendar: ["Calendar", "calendar_month"], "ms-calendar": ["Outlook calendar", "calendar_month"],
	expenses: ["Expenses", "currency_eur"], washer: ["Washer", "washing_machine"], breaks: ["Breaks", "timer_outline"],
	updates: ["Updates", "restore"], invoice: ["Invoices", "currency_eur"], watch: ["Watch", "alarm"], server: ["Server", "monitor"]
};
const SNOOZES = [
	{ label: "10 minutes", body: { minutes: 10 } },
	{ label: "1 hour", body: { minutes: 60 } },
	{ label: "3 hours", body: { minutes: 180 } },
	{ label: "Tomorrow 9:00", body: () => ({ until: Math.floor(tomorrowAt(9) / 1000) }) },
	{ label: "At the PC", icon: "monitor", body: { pc: true } }
];

const levelOf = v => LEVELS.find(l => l.value === v) || LEVELS[1];
const triggerOf = v => TRIGGERS.find(t => t.value === v) || TRIGGERS[0];
const pad = n => String(n).padStart(2, "0");
const dayKey = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const clockOf = d => `${pad(d.getHours())}:${pad(d.getMinutes())}`;

function tomorrowAt(hour) {
	const d = new Date();
	d.setDate(d.getDate() + 1);
	d.setHours(hour, 0, 0, 0);
	return d.getTime();
}

function whenText(ts, allDay) {
	if (ts === null || ts === undefined) return "";
	const d = new Date(ts * 1000);
	const today = new Date();
	today.setHours(0, 0, 0, 0);
	const days = Math.round((new Date(d).setHours(0, 0, 0, 0) - today) / 86400000);
	const day = days === 0 ? "Today" : days === 1 ? "Tomorrow" : days === -1 ? "Yesterday"
		: days > 1 && days < 7 ? d.toLocaleDateString(undefined, { weekday: "long" })
			: d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short", year: d.getFullYear() === today.getFullYear() ? undefined : "numeric" });
	return allDay ? day : `${day} ${clockOf(d)}`;
}

function repeatText(r) {
	if (!r) return "";
	let text = r.n > 1 ? `Every ${r.n} ${UNIT[r.every][1]}` : REPEATS.find(x => x.value === r.every).label;
	if (r.days?.length) text += ` · ${r.days.map(d => DAYS[d - 1]).join(", ")}`;
	if (r.until) text += ` · until ${whenText(r.until, true)}`;
	return text;
}

export default function reminders(route, app) {
	let data = null;
	let loading = null;

	const body = h("div.rem-body", h("div.skeleton", { style: { height: "120px" } }));
	const levelsBtn = h("button.btn.small", { type: "button" }, icon("tune_variant"), "Levels");
	levelsBtn.addEventListener("click", () => levelsDialog());
	const sub = h("div.subtle", "");

	// ── quick add ──
	const input = h("input", { type: "text", placeholder: "New reminder", autocomplete: "off", spellcheck: false });
	const preview = h("div.rem-preview");
	const addBtn = h("button.btn.primary", { type: "button", disabled: true }, icon("plus"), "Add");
	const moreBtn = h("button.icon-btn", { type: "button", title: "Details" }, icon("pencil_outline"));
	const quick = h("div.rem-quick", h("div.field.rem-quick-field", icon("bell_outline"), input, moreBtn), addBtn, preview);
	let parsed = null;
	let parseSeq = 0;
	let parseTimer = 0;

	async function parseNow() {
		const text = input.value.trim();
		const seq = ++parseSeq;
		if (!text) {
			parsed = null;
			showPreview();
			return null;
		}
		try {
			const got = await api.post("/api/reminders/parse", { text }, { quiet: true });
			if (seq !== parseSeq) return null;
			parsed = got;
		} catch (error) {
			if (seq !== parseSeq) return null;
			parsed = null;
		}
		showPreview();
		return parsed;
	}

	function showPreview() {
		addBtn.disabled = !parsed;
		clear(preview);
		if (!parsed) return;
		const t = triggerOf(parsed.trigger);
		const chips = [
			parsed.trigger !== "time" ? h("span.chip.small", icon(t.icon), t.label) : null,
			parsed.at ? h("span.chip.small", icon("clock_outline"), whenText(parsed.at, parsed.all_day)) : null,
			parsed.repeat ? h("span.chip.small", icon("repeat"), repeatText(parsed.repeat)) : null,
			parsed.level ? h(`span.chip.small.rem-level-${parsed.level}`, icon(levelOf(parsed.level).icon), levelOf(parsed.level).label) : null
		];
		preview.append(h("b.ellipsis", parsed.title), ...chips.filter(Boolean));
	}

	input.addEventListener("input", () => {
		clearTimeout(parseTimer);
		parseTimer = setTimeout(parseNow, 200);
	});
	input.addEventListener("keydown", async event => {
		if (event.key !== "Enter") return;
		event.preventDefault();
		await quickAdd();
	});
	addBtn.addEventListener("click", () => quickAdd());
	moreBtn.addEventListener("click", async () => {
		clearTimeout(parseTimer);
		const got = input.value.trim() ? await parseNow() : null;
		editDialog(null, got || (input.value.trim() ? { title: input.value.trim() } : null));
	});

	async function quickAdd() {
		clearTimeout(parseTimer);
		const got = await parseNow();
		if (!got) {
			shake(quick.firstChild);
			return;
		}
		try {
			await api.post("/api/reminders", got);
			input.value = "";
			parsed = null;
			showPreview();
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	const root = h("div.page-scroll", h("div.page.rem-page",
		h("div.page-head", h("div", h("h1", "Reminders"), sub), h("div.page-tools", levelsBtn)),
		quick,
		body));

	async function load() {
		const mine = (loading = api.get("/api/reminders"));
		try {
			const got = await mine;
			if (mine !== loading) return;
			data = got;
			draw();
		} catch (error) {
			if (mine !== loading) return;
			clear(body).appendChild(h("div.empty", icon("bell_outline"), h("h3", "Could not load the reminders"), h("p", error.message)));
		}
	}

	function draw() {
		const open = data.reminders.filter(r => r.state === "open");
		const now = open.filter(r => r.pending.length);
		const coming = open.filter(r => !r.pending.length);
		const done = data.reminders.filter(r => r.state === "done").sort((a, b) => b.updated - a.updated).slice(0, 10);
		sub.textContent = now.length ? `${now.length} now` : "";
		const lists = [];
		if (now.length) lists.push(h("section.rem-section", sectionHead("Now"), h("div.list-card.rem-now", now.map(row))));
		lists.push(h("section.rem-section", sectionHead("Coming"), coming.length ? h("div.list-card", coming.map(row)) : emptyRow("bell_outline", "Nothing planned")));
		if (data.sources.length) lists.push(h("section.rem-section", sectionHead("Calendar and expenses"), h("div.list-card", data.sources.map(sourceRow))));
		if (done.length) lists.push(h("section.rem-section", sectionHead("Done"), h("div.list-card.rem-done", done.map(row))));
		clear(body).append(...lists);
		for (const card of body.querySelectorAll(".list-card")) stagger(card.children, { step: 20, distance: 6 });
	}

	function row(r) {
		const t = triggerOf(r.trigger);
		const level = levelOf(r.level);
		const pending = r.pending.length > 0;
		const subParts = [];
		if (pending) subParts.push(whenText(r.pending[r.pending.length - 1]));
		else if (r.snoozed_until) subParts.push(`Snoozed · ${whenText(r.snoozed_until)}`);
		else if (r.trigger !== "time") subParts.push(r.at && r.at * 1000 > Date.now() ? `${t.label} · from ${whenText(r.at, r.all_day)}` : t.label);
		else if (r.state === "open" && r.next) subParts.push(whenText(r.next, r.all_day));
		else if (r.at) subParts.push(whenText(r.at, r.all_day));
		if (r.repeat) subParts.push(repeatText(r.repeat));
		if (r.note) subParts.push(r.note.split("\n")[0]);
		const side = h("div.row-side");
		if (r.level !== "normal") side.append(h(`span.chip.small.rem-level-${r.level}`, { title: level.label }, icon(level.icon)));
		if (r.state === "open") {
			const doneBtn = h(`button.btn.small${pending ? ".primary" : ".ghost"}`, { type: "button", title: "Done" }, icon("check"), pending ? "Done" : null);
			doneBtn.addEventListener("click", event => {
				event.stopPropagation();
				ack(r);
			});
			const snoozeBtn = h("button.icon-btn.small", { type: "button", title: "Snooze" }, icon("bell_sleep_outline"));
			snoozeBtn.addEventListener("click", event => {
				event.stopPropagation();
				const box = snoozeBtn.getBoundingClientRect();
				showMenu(SNOOZES.map(s => ({ label: s.label, icon: s.icon || "bell_sleep_outline", run: () => snooze(r, typeof s.body === "function" ? s.body() : s.body) })), box.right - 200, box.bottom + 6);
			});
			if (pending || r.next || r.trigger === "time") side.append(snoozeBtn);
			side.append(doneBtn);
		}
		const more = h("button.icon-btn.small", { type: "button", title: "More" }, icon("dots_vertical"));
		more.addEventListener("click", event => {
			event.stopPropagation();
			const box = more.getBoundingClientRect();
			showMenu([
				{ label: "Edit", icon: "pencil_outline", run: () => editDialog(r) },
				r.state === "done" ? { label: "Open again", icon: "restore", run: () => change(r, { state: "open" }) } : null,
				r.state === "open" && r.trigger !== "time" ? { label: "Fire now", icon: "bell_ring_outline", run: () => fire(r) } : null,
				{ separator: true },
				{ label: "Delete", icon: "delete_outline", danger: true, run: () => remove(r) }
			].filter(Boolean), box.right - 200, box.bottom + 6);
		});
		side.append(more);
		const el = h(`div.list-row.rem-row${pending ? ".pending" : ""}${r.state === "done" ? ".done" : ""}`, { tabindex: 0 },
			h(`div.row-icon.rem-icon.rem-level-${r.level}`, icon(r.trigger !== "time" ? t.icon : pending ? "bell_ring_outline" : r.repeat ? "repeat" : "bell_outline")),
			h("div.row-main", h("div.row-title", h("span.ellipsis", r.title)), subParts.length ? h("div.row-sub", subParts.join(" · ")) : null),
			side);
		el.addEventListener("click", () => editDialog(r));
		el.addEventListener("keydown", event => {
			if (event.key === "Enter") editDialog(r);
		});
		return el;
	}

	function sourceRow(s) {
		const [label, iconName] = SOURCES[s.source] || [s.source, "bell_outline"];
		const el = h(`${s.url ? "a" : "div"}.list-row.rem-row.source`, s.url ? { href: s.url } : null,
			h(`div.row-icon.rem-icon.rem-level-${s.level}`, icon(iconName)),
			h("div.row-main", h("div.row-title", h("span.ellipsis", s.title)), h("div.row-sub", [whenText(s.at), s.body || label].filter(Boolean).join(" · "))),
			h("div.row-side", s.level !== "normal" ? h(`span.chip.small.rem-level-${s.level}`, { title: levelOf(s.level).label }, icon(levelOf(s.level).icon)) : null));
		return el;
	}

	// ── actions ──
	const path = r => `/api/reminders/${encodeURIComponent(r.id)}`;

	async function run(promise) {
		try {
			await promise;
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	const ack = r => run(api.post(`${path(r)}/ack`, {}));
	const snooze = (r, b) => run(api.post(`${path(r)}/snooze`, b));
	const fire = r => run(api.post(`${path(r)}/fire`, {}));
	const change = (r, b) => run(api.patch(path(r), b));

	async function remove(r) {
		const ok = await confirm({ title: `Delete “${r.title}”?`, confirmLabel: "Delete", danger: true, icon: "delete_outline" });
		if (ok) await run(api.del(path(r)));
	}

	// ── a reminder in full ──
	function editDialog(r, start) {
		const v = r ? { ...r } : { title: "", note: "", at: null, all_day: false, repeat: null, level: null, escalate_min: 10, trigger: "time", ...(start || {}) };
		if (!r && !v.level) v.level = data?.levels?.own || "normal";
		const at = v.at ? new Date(v.at * 1000) : new Date(Date.now() + 3600000);
		if (!v.at) at.setMinutes(0, 0, 0);
		const state = {
			trigger: v.trigger || "time", allDay: !!v.all_day, level: v.level || "normal",
			every: v.repeat?.every || "", days: new Set(v.repeat?.days || []), hasTime: !!v.at
		};

		const title = h("input", { type: "text", value: v.title || "", autocomplete: "off" });
		const note = h("textarea", { rows: 3 });
		note.value = v.note || "";
		const date = h("input", { type: "date", value: dayKey(at) });
		const clock = h("input", { type: "time", value: clockOf(at) });
		const n = h("input", { type: "number", min: 1, max: 999, value: v.repeat?.n || 1 });
		const until = h("input", { type: "date", value: v.repeat?.until ? dayKey(new Date(v.repeat.until * 1000)) : "" });
		const escalate = h("input", { type: "number", min: 0, max: 1440, value: v.escalate_min ?? 10 });

		const trigger = h("select", TRIGGERS.map(t => h("option", { value: t.value, selected: t.value === state.trigger }, t.label)));
		const repeat = h("select", REPEATS.map(x => h("option", { value: x.value, selected: x.value === state.every }, x.label)));
		const allDay = toggle(state.allDay, on => {
			state.allDay = on;
			refresh();
		});
		const timed = toggle(state.hasTime, on => {
			state.hasTime = on;
			refresh();
		});
		const days = h("div.rem-days", DAYS.map((d, i) => {
			const b = h("button.chip.small", { type: "button", class: state.days.has(i + 1) ? "on" : "" }, d);
			b.addEventListener("click", () => {
				if (state.days.has(i + 1)) state.days.delete(i + 1);
				else state.days.add(i + 1);
				b.classList.toggle("on", state.days.has(i + 1));
			});
			return b;
		}));
		const level = segmented(LEVELS.map(l => ({ value: l.value, label: l.label })), state.level, value => {
			state.level = value;
			refresh();
		});

		const row = (label, control, cls = "") => h(`div.form-row${cls}`, h("span", label), control);
		const rows = {
			trigger: row("When", h("div.field", trigger, icon("chevron_down")), ".wide"),
			timed: h("div.form-switch.wide", h("div", h("div.form-switch-label", "From a time")), timed),
			date: row("Day", h("div.field", date)),
			clock: row("Time", h("div.field", clock)),
			allDay: h("div.form-switch.wide", h("div", h("div.form-switch-label", "All day")), allDay),
			repeat: row("Repeat", h("div.field", repeat, icon("chevron_down"))),
			n: row("Every", h("div.field", n, h("span.subtle.rem-unit", ""))),
			days: row("On", days, ".wide"),
			until: row("Until", h("div.field", until)),
			level: row("Level", level, ".wide"),
			escalate: row("Fullscreen after", h("div.field", escalate, h("span.subtle", "min"))),
			note: row("Note", h("div.field.area", note), ".wide")
		};
		const form = h("div.form.rem-form",
			row("Title", h("div.field", title), ".wide"),
			rows.trigger, rows.timed, rows.date, rows.clock, rows.allDay, rows.repeat, rows.n, rows.days, rows.until, rows.level, rows.escalate, rows.note);

		function refresh() {
			state.trigger = trigger.value;
			state.every = repeat.value;
			const isTime = state.trigger === "time";
			const hasAt = isTime || state.hasTime;
			rows.timed.hidden = isTime;
			rows.date.hidden = !hasAt;
			rows.clock.hidden = !hasAt || state.allDay;
			rows.allDay.hidden = !hasAt;
			rows.repeat.hidden = !hasAt;
			rows.n.hidden = !hasAt || !state.every;
			rows.days.hidden = !hasAt || state.every !== "week";
			rows.until.hidden = !hasAt || !state.every;
			rows.escalate.hidden = state.level !== "important";
			if (state.every) rows.n.querySelector(".rem-unit").textContent = UNIT[state.every][Number(n.value) === 1 ? 0 : 1];
		}
		trigger.addEventListener("change", refresh);
		repeat.addEventListener("change", refresh);
		n.addEventListener("input", refresh);
		refresh();

		openDialog({
			title: r ? r.title : "New reminder",
			icon: "bell_outline",
			body: form,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: r ? "Save" : "Add", primary: true, run: async () => {
					if (!title.value.trim()) {
						shake(title.parentElement);
						return false;
					}
					const hasAt = state.trigger === "time" || state.hasTime;
					let stamp = null;
					if (hasAt) {
						if (!date.value) {
							shake(date.parentElement);
							return false;
						}
						const when = new Date(`${date.value}T${state.allDay ? "00:00" : clock.value || "09:00"}`);
						stamp = Math.floor(when.getTime() / 1000);
					}
					let rep = null;
					if (hasAt && state.every) {
						rep = { every: state.every, n: Math.max(1, Number(n.value) || 1) };
						if (state.every === "week" && state.days.size) rep.days = [...state.days].sort();
						if (until.value) rep.until = Math.floor(new Date(`${until.value}T23:59:59`).getTime() / 1000);
					}
					const out = {
						title: title.value.trim(), note: note.value, trigger: state.trigger, at: stamp, all_day: hasAt && state.allDay,
						repeat: rep, level: state.level, escalate_min: Math.max(0, Number(escalate.value) || 0)
					};
					if (r) await api.patch(path(r), out);
					else await api.post("/api/reminders", out);
					if (!r) {
						input.value = "";
						parsed = null;
						showPreview();
					}
					await load();
				} }
			]
		});
		if (!r) requestAnimationFrame(() => title.focus());
	}

	// ── how loud each source is ──
	function levelsDialog() {
		const levels = { ...(data?.levels || {}) };
		const keys = [...new Set([...Object.keys(SOURCES), ...Object.keys(levels)])];
		const list = h("div.rem-levels", keys.map(key => {
			const [label, iconName] = SOURCES[key] || [key, "bell_outline"];
			const select = h("select", LEVELS.map(l => h("option", { value: l.value, selected: (levels[key] || "normal") === l.value }, l.label)));
			select.addEventListener("change", () => {
				levels[key] = select.value;
			});
			return h("div.list-row.rem-level-row", h("div.row-icon", icon(iconName)), h("div.row-main", h("div.row-title", label)), h("div.field", select, icon("chevron_down")));
		}));
		openDialog({
			title: "Levels",
			icon: "tune_variant",
			body: list,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Save", primary: true, run: async () => {
					await api.put("/api/reminders/levels", levels);
					await load();
				} }
			]
		});
	}

	let timer = 0;
	const later = () => {
		clearTimeout(timer);
		timer = setTimeout(load, 200);
	};
	const offs = ["reminders", "reminder", "reminder_ack", "reminder_snooze", "expenses"].map(kind => api.on(kind, later));
	offs.push(api.on("socket", d => d.open && later()));
	load();

	return {
		el: root,
		title: "Reminders",
		icon: "bell_outline",
		refresh: load,
		update() {
			root.scrollTop = 0;
			if (data) draw();
		},
		onKey(event) {
			if (event.key === "n" || event.key === "/") {
				event.preventDefault();
				input.focus();
			}
		},
		unmount: () => {
			clearTimeout(timer);
			clearTimeout(parseTimer);
			offs.forEach(off => off());
		}
	};
}
