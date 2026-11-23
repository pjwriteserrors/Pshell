// Calendar: your Baikal calendars (docs/core.md "Calendar"). "Month": the
// month with every event of every calendar, the picked day beside it, a line
// of text as an event (the rules of the shell's >cal), the editor and the
// details of an event (a repeating one: its series). "Calendars": add one with
// a colour, rename, recolour, delete (or leave one shared with you), and share
// each with the other members: no, read, or read and write.
import { h, icon, clear, plural } from "../util.js";
import * as api from "../api.js";
import { stagger } from "../motion.js";
import { confirm, toast, errorToast, prompt, segmented, popover, openDialog } from "../ui.js";
import { parseText } from "../when.js";

const COLORS = ["#e0457b", "#f07c3c", "#e3b341", "#3fa66b", "#2fa3a3", "#4f8ef7", "#7b6cf6", "#b462d6", "#8d8d8d"];
const REPEATS = [{ value: "", label: "Once" }, { value: "daily", label: "Daily" }, { value: "weekly", label: "Weekly" }, { value: "monthly", label: "Monthly" }, { value: "yearly", label: "Yearly" }];
const REMINDERS = [{ value: "-1", label: "None" }, { value: "0", label: "At the start" }, { value: "10", label: "10 min before" }, { value: "30", label: "30 min before" }, { value: "60", label: "1 hour before" }, { value: "1440", label: "1 day before" }];

const pad = n => String(n).padStart(2, "0");
const dayKey = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const wall = d => `${dayKey(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const fromKey = key => new Date(`${key.length === 10 ? key + "T00:00" : key}`);
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const gridStart = month => addDays(new Date(month.getFullYear(), month.getMonth(), 1), -((new Date(month.getFullYear(), month.getMonth(), 1).getDay() + 6) % 7));
const timeOf = key => key.slice(11, 16);
const fmtDay = d => d.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" });

function span(e) {
	if (e.allDay) {
		const last = addDays(fromKey(e.end), -1);
		return dayKey(last) === e.start.slice(0, 10) ? "All day" : `${fromKey(e.start).toLocaleDateString(undefined, { day: "numeric", month: "short" })} – ${last.toLocaleDateString(undefined, { day: "numeric", month: "short" })}`;
	}
	return e.start.slice(0, 10) === e.end.slice(0, 10) ? `${timeOf(e.start)} – ${timeOf(e.end)}` : `${timeOf(e.start)} – ${fromKey(e.end).toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${timeOf(e.end)}`;
}

// the days an event shows on
function daysOf(e) {
	const out = [];
	const start = fromKey(e.start.slice(0, 10));
	const end = fromKey(e.end);
	const last = e.allDay ? addDays(end, -1) : (end > fromKey(e.start) ? new Date(end.getTime() - 1) : end);
	for (let d = start; d <= last && out.length < 60; d = addDays(d, 1)) out.push(dayKey(d));
	return out;
}

export default function calendar(route, app) {
	let mode = route.parts[0] === "calendars" ? "calendars" : "month";
	let data = { calendars: [], members: [], user: "" };
	let events = [];
	let month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
	let picked = dayKey(new Date());
	let open = "";
	let newColor = COLORS[5];

	const sub = h("div.subtle", "");
	const modes = segmented([{ value: "month", label: "Month" }, { value: "calendars", label: "Calendars" }], mode, value => {
		mode = value;
		history.replaceState(null, "", value === "calendars" ? "/calendar/calendars" : "/calendar");
		draw();
	});
	const newBtn = h("button.btn.primary.small", { type: "button" }, icon("plus"), "New event");
	newBtn.addEventListener("click", () => editor(null, picked));
	const body = h("div.cal-body");
	const passwordBox = h("div.card.cal-password", { hidden: true });
	const root = h("div.page-scroll", h("div.page.cal-page",
		h("div.page-head", h("div", h("h1", "Calendar"), sub), h("div.page-tools", modes, newBtn)),
		passwordBox, body));

	// ── loading ──
	async function load() {
		const start = gridStart(month);
		try {
			const got = await api.get("/api/calendar/events", { from: dayKey(start), to: dayKey(addDays(start, 42)) });
			if (got.need === "password") return askPassword(got.user);
			passwordBox.hidden = true;
			events = got.events || [];
			data.calendars = got.calendars || [];
			data.user = got.user;
			if (mode === "calendars" || !data.members.length) {
				const more = await api.get("/api/calendar/calendars");
				if (more.calendars) data = more;
			}
			draw();
		} catch (error) {
			clear(body).appendChild(h("div.empty", icon("calendar_month"), h("h3", "Could not load the calendar"), h("p", error.message)));
		}
	}

	function askPassword(user) {
		clear(body);
		newBtn.hidden = true;
		const input = h("input", { type: "password", placeholder: "Baikal password", autocomplete: "current-password" });
		const go = h("button.btn.primary.small", { type: "button" }, icon("check"), "Save");
		const send = async () => {
			if (!input.value) return;
			go.disabled = true;
			try {
				await api.post("/api/calendar/account", { password: input.value });
				newBtn.hidden = false;
				await load();
			} catch (error) {
				errorToast(error);
			}
			go.disabled = false;
		};
		go.addEventListener("click", send);
		input.addEventListener("keydown", event => { if (event.key === "Enter") send(); });
		clear(passwordBox).append(h("h3", `Baikal password of ${user}`), h("div.cal-add", h("label.field", icon("lock_outline"), input), go));
		passwordBox.hidden = false;
		setTimeout(() => input.focus(), 50);
	}

	const writable = () => data.calendars.filter(c => c.access !== "read");
	const mine = c => c.access === "" || c.access === "owner";
	const byDay = () => {
		const out = {};
		for (const e of events) for (const key of daysOf(e)) (out[key] ||= []).push(e);
		for (const key of Object.keys(out)) out[key].sort((a, b) => (b.allDay - a.allDay) || a.start.localeCompare(b.start));
		return out;
	};

	function draw() {
		newBtn.hidden = mode !== "month";
		sub.textContent = data.user ? `${plural(data.calendars.length, "calendar")} · ${data.user}` : "";
		if (mode === "month") drawMonth();
		else drawCalendars(true);
	}

	// ── the month ──
	function drawMonth() {
		const days = byDay();
		const start = gridStart(month);
		const today = dayKey(new Date());

		const quick = h("input", { type: "text", placeholder: "morgen 15 Uhr Zahnarzt @Praxis", "aria-label": "A new event as a line of text" });
		const hint = h("div.cal-quick-hint.subtle", "");
		const showHint = () => {
			const text = quick.value.trim();
			if (!text) return (hint.textContent = "");
			const f = parseText(text, new Date());
			const when = f.allDay ? f.start.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }) : `${f.start.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" })} · ${pad(f.start.getHours())}:${pad(f.start.getMinutes())} – ${pad(f.end.getHours())}:${pad(f.end.getMinutes())}`;
			hint.textContent = `${f.title || "Title?"} · ${when}${f.repeat ? ` · ${f.repeat}` : ""}${f.location ? ` · ${f.location}` : ""}`;
		};
		quick.addEventListener("input", showHint);
		quick.addEventListener("keydown", async event => {
			if (event.key !== "Enter" || !quick.value.trim()) return;
			const f = parseText(quick.value.trim(), new Date());
			if (!f.title) return;
			const calendarHref = defaultCalendar();
			if (!calendarHref) return toast("No calendar you may write to", { tone: "bad" });
			const end = f.allDay ? addDays(f.end, 0) : f.end;
			try {
				await api.post("/api/calendar/event", {
					calendar: calendarHref, title: f.title, location: f.location, notes: "", allDay: f.allDay,
					start: f.allDay ? dayKey(f.start) : wall(f.start), end: f.allDay ? dayKey(end) : wall(end),
					repeat: f.repeat, reminder: f.allDay ? -1 : 10
				});
				toast(f.title, { icon: "calendar_check", tone: "good", timeout: 1600 });
				quick.value = "";
				hint.textContent = "";
				picked = dayKey(f.start);
				month = new Date(f.start.getFullYear(), f.start.getMonth(), 1);
				await load();
			} catch (error) {
				errorToast(error);
			}
		});

		const title = h("button.cal-month-title", { type: "button", title: "Today" }, month.toLocaleDateString(undefined, { month: "long", year: "numeric" }));
		title.addEventListener("click", () => {
			month = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
			picked = today;
			load();
		});
		const prev = h("button.icon-btn.small", { type: "button", title: "Previous month" }, icon("chevron_left"));
		const next = h("button.icon-btn.small", { type: "button", title: "Next month" }, icon("chevron_right"));
		prev.addEventListener("click", () => { month = new Date(month.getFullYear(), month.getMonth() - 1, 1); load(); });
		next.addEventListener("click", () => { month = new Date(month.getFullYear(), month.getMonth() + 1, 1); load(); });

		const grid = h("div.cal-grid");
		for (let i = 0; i < 7; i += 1) grid.appendChild(h("div.cal-weekday", addDays(start, i).toLocaleDateString(undefined, { weekday: "short" })));
		for (let i = 0; i < 42; i += 1) {
			const d = addDays(start, i);
			const key = dayKey(d);
			const list = days[key] || [];
			const cell = h(`div.cal-cell${d.getMonth() !== month.getMonth() ? ".out" : ""}${key === today ? ".today" : ""}${key === picked ? ".picked" : ""}`, { tabindex: 0 },
				h("div.cal-num", String(d.getDate())),
				list.slice(0, 3).map(e => {
					const chip = h(`div.cal-chip${e.cancelled ? ".cancelled" : ""}`, { title: `${e.title} · ${span(e)}` },
						e.allDay ? null : h("span.cal-chip-time", timeOf(e.start)), h("span.ellipsis", e.title));
					// a custom property has to go through setProperty
					chip.style.setProperty("--c", e.color || "var(--secondary)");
					return chip;
				}),
				list.length > 3 ? h("div.cal-more", `+${list.length - 3}`) : null);
			cell.addEventListener("click", () => { picked = key; drawMonth(); });
			cell.addEventListener("dblclick", () => editor(null, key));
			cell.addEventListener("keydown", event => { if (event.key === "Enter") { picked = key; drawMonth(); } });
			grid.appendChild(cell);
		}

		const dayList = days[picked] || [];
		const add = h("button.icon-btn.small", { type: "button", title: "New event this day" }, icon("plus"));
		add.addEventListener("click", () => editor(null, picked));
		const side = h("div.cal-day.card",
			h("div.cal-day-head", h("h3", fmtDay(fromKey(picked))), add),
			dayList.length ? dayList.map(e => {
				const row = h("button.cal-event", { type: "button" },
					h("span.cal-bar", { style: { background: e.color || "var(--secondary)" } }),
					h("span.cal-event-main", h("span.cal-event-title", e.title, e.recurring ? icon("repeat") : null), h("span.subtle", [span(e), e.location].filter(Boolean).join(" · "))));
				row.addEventListener("click", () => details(e));
				return row;
			}) : h("div.subtle", "No events"));

		clear(body).append(
			h("label.field.cal-quick", icon("calendar_plus"), quick), hint,
			h("div.cal-layout",
				h("div.cal-month", h("div.cal-month-head", title, h("div.cal-nav", prev, next)), grid),
				side));
	}

	function defaultCalendar() {
		let last = "";
		try {
			last = localStorage.getItem("pcore.calendar.last") || "";
		} catch (error) {}
		return (writable().find(c => c.href === last) || writable()[0])?.href || "";
	}

	// ── one event ──
	function details(e) {
		const calendar = data.calendars.find(c => c.href === e.calendar);
		const rows = [
			h("div.cal-detail", icon("clock_outline"), h("div", h("div", fmtDay(fromKey(e.start))), h("div.subtle", span(e)))),
			e.location ? h("div.cal-detail", icon("map_marker_outline"), e.location) : null,
			h("div.cal-detail", h("span.cal-dot.small", { style: { background: e.color || "var(--secondary)" } }), e.calendarName + (calendar && !mine(calendar) ? " · shared with you" : "")),
			e.reminder >= 0 ? h("div.cal-detail", icon("bell_outline"), e.reminder === 0 ? "At the start" : `${e.reminder} min before`) : null,
			e.notes ? h("div.cal-notes", e.notes) : null
		];
		const actions = e.readOnly ? [{ label: "Close", ghost: true }] : [
			{ label: e.recurring ? "Delete series" : "Delete", danger: true, icon: "delete_outline", run: async () => {
				const ok = await confirm({ title: `Delete “${e.title}”?`, body: e.recurring ? "Every date of the series goes." : span(e), confirmLabel: "Delete", danger: true, icon: "delete_outline" });
				if (!ok) return false;
				await api.del(api.withQuery("/api/calendar/event", { href: e.href, etag: e.etag }));
				await load();
			} },
			{ label: e.recurring ? "Edit series" : "Edit", primary: true, icon: "pencil", run: () => { setTimeout(() => editor(e), 0); } }
		];
		openDialog({ title: e.title, icon: "calendar_month", tone: e.color || undefined, body: h("div.cal-details", rows), actions });
	}

	async function editor(e, dayOrNull) {
		let fields;
		let etag = "";
		if (e) {
			try {
				const got = await api.get("/api/calendar/event", { href: e.href });
				fields = got.event;
				etag = got.etag;
			} catch (error) {
				return errorToast(error);
			}
		} else {
			const now = new Date();
			const day = fromKey(dayOrNull || dayKey(now));
			const start = dayKey(day) === dayKey(now) ? new Date(day.getFullYear(), day.getMonth(), day.getDate(), Math.min(23, now.getHours() + 1)) : new Date(day.getFullYear(), day.getMonth(), day.getDate(), 9);
			fields = { title: "", location: "", notes: "", allDay: false, start: wall(start), end: wall(new Date(start.getTime() + 3600000)), repeat: "", reminder: -1 };
		}
		// whole days end the day after: the editor shows the last day
		const startD = fromKey(fields.start);
		const endD = fields.allDay ? addDays(fromKey(fields.end), -1) : fromKey(fields.end);
		const state = { allDay: !!fields.allDay, repeat: fields.repeat ?? "", reminder: fields.reminder === null ? "keep" : String(fields.reminder ?? -1), calendar: e ? e.calendar : defaultCalendar() };

		const title = h("input", { type: "text", placeholder: "Title", value: fields.title });
		const startDate = h("input", { type: "date", value: dayKey(startD) });
		const startTime = h("input", { type: "time", value: `${pad(startD.getHours())}:${pad(startD.getMinutes())}` });
		const endDate = h("input", { type: "date", value: dayKey(endD) });
		const endTime = h("input", { type: "time", value: `${pad(endD.getHours())}:${pad(endD.getMinutes())}` });
		const place = h("input", { type: "text", placeholder: "Place", value: fields.location || "" });
		const notes = h("textarea", { rows: 3, placeholder: "Notes" });
		notes.value = fields.notes || "";
		// the start moved: the end keeps the length
		let length = fromKey(fields.end) - fromKey(fields.start);
		const startAt = () => fromKey(`${startDate.value}T${state.allDay ? "00:00" : startTime.value || "00:00"}`);
		const onStart = () => {
			const s = startAt();
			const end = new Date(s.getTime() + (state.allDay ? Math.max(0, length - 86400000) : length));
			endDate.value = dayKey(end);
			if (!state.allDay) endTime.value = `${pad(end.getHours())}:${pad(end.getMinutes())}`;
		};
		startDate.addEventListener("change", onStart);
		startTime.addEventListener("change", onStart);
		const remember = () => { length = fromKey(`${endDate.value}T${endTime.value || "00:00"}`) - startAt() + (state.allDay ? 86400000 : 0); };
		endDate.addEventListener("change", remember);
		endTime.addEventListener("change", remember);

		const allDay = h(`button.toggle${state.allDay ? ".on" : ""}`, { type: "button", role: "switch", "aria-checked": String(state.allDay) });
		const times = [startTime, endTime];
		const showTimes = () => times.forEach(t => (t.closest(".field").hidden = state.allDay));
		allDay.addEventListener("click", () => {
			state.allDay = !state.allDay;
			allDay.classList.toggle("on", state.allDay);
			allDay.setAttribute("aria-checked", String(state.allDay));
			showTimes();
		});

		const choose = (list, current, key) => {
			const select = h("select", list.map(c => h("option", { value: c.value, selected: c.value === current }, c.label)));
			select.addEventListener("change", () => (state[key] = select.value));
			return h("div.field", select, icon("chevron_down"));
		};
		const repeats = REPEATS.concat(state.repeat === "custom" || fields.repeat === null ? [{ value: "custom", label: "As set" }] : []);
		const reminders = REMINDERS.concat(state.reminder === "keep" ? [{ value: "keep", label: "As set" }] : (REMINDERS.some(r => r.value === state.reminder) ? [] : [{ value: state.reminder, label: `${state.reminder} min before` }]));
		const calendars = writable();
		const form = h("div.form.cal-form",
			h("label.form-row", h("span", "Title"), h("div.field", title)),
			!e && calendars.length > 1 ? h("label.form-row", h("span", "Calendar"), choose(calendars.map(c => ({ value: c.href, label: c.name })), state.calendar, "calendar")) : null,
			h("div.form-switch", h("div", h("div.form-switch-label", "All day")), allDay),
			h("div.cal-form-when",
				h("label.form-row", h("span", "From"), h("div.cal-form-pair", h("div.field", startDate), h("div.field", startTime))),
				h("label.form-row", h("span", "To"), h("div.cal-form-pair", h("div.field", endDate), h("div.field", endTime)))),
			h("div.cal-form-pair",
				h("label.form-row", h("span", "Repeat"), choose(repeats, state.repeat, "repeat")),
				h("label.form-row", h("span", "Reminder"), choose(reminders, state.reminder, "reminder"))),
			h("label.form-row", h("span", "Place"), h("div.field", icon("map_marker_outline"), place)),
			h("label.form-row", h("span", "Notes"), h("div.field.area", notes)));
		showTimes();

		openDialog({
			title: e ? (e.recurring ? "Edit the series" : "Edit") : "New event",
			icon: "calendar_month",
			body: form,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Save", primary: true, icon: "check", run: async () => {
					if (!title.value.trim()) {
						toast("The event needs a title", { tone: "bad" });
						return false;
					}
					let end = state.allDay ? dayKey(addDays(fromKey(endDate.value), 1)) : `${endDate.value}T${endTime.value}`;
					const start = state.allDay ? startDate.value : `${startDate.value}T${startTime.value}`;
					const request = {
						title: title.value.trim(), location: place.value.trim(), notes: notes.value, allDay: state.allDay, start, end,
						repeat: state.repeat === "custom" ? null : state.repeat, reminder: state.reminder === "keep" ? null : Number(state.reminder)
					};
					if (e) Object.assign(request, { href: e.href, etag });
					else request.calendar = state.calendar;
					await api.post("/api/calendar/event", request);
					if (!e) {
						try {
							localStorage.setItem("pcore.calendar.last", state.calendar);
						} catch (error) {}
					}
					picked = startDate.value;
					month = new Date(fromKey(startDate.value).getFullYear(), fromKey(startDate.value).getMonth(), 1);
					await load();
				} }
			]
		});
		setTimeout(() => { if (!e) title.focus(); }, 60);
	}

	// ── the calendars ──
	function drawCalendars(animateIn) {
		const listEl = h("div.list-card", { role: "list" });
		const nameInput = h("input", { type: "text", placeholder: "New calendar", "aria-label": "Name of the new calendar" });
		const swatches = h("div.cal-swatches");
		const addBtn = h("button.btn.primary.small", { type: "button" }, icon("plus"), "Add");
		const drawSwatches = () => clear(swatches).append(...COLORS.map(c => {
			const b = h(`button.cal-swatch${c === newColor ? ".on" : ""}`, { type: "button", title: c, style: { background: c } });
			b.addEventListener("click", () => { newColor = c; drawSwatches(); });
			return b;
		}));
		drawSwatches();
		const add = async () => {
			const name = nameInput.value.trim();
			if (!name) return;
			addBtn.disabled = true;
			try {
				await api.post("/api/calendar/calendars", { name, color: newColor });
				toast("Calendar added", { icon: "calendar_plus", tone: "good", timeout: 1400 });
				await load();
			} catch (error) {
				errorToast(error);
			}
			addBtn.disabled = false;
		};
		addBtn.addEventListener("click", add);
		nameInput.addEventListener("keydown", event => { if (event.key === "Enter") add(); });

		const accessLabel = c => (c.access === "read" ? "Shared with you · read" : c.access === "write" ? `Shared with you${c.owner ? ` by ${c.owner}` : ""}` : "");
		for (const c of data.calendars) {
			const dot = h("button.cal-dot", { type: "button", title: "Colour", style: { background: c.color || "var(--secondary)" } });
			dot.addEventListener("click", () => pickColor(c, dot));
			const rename = h("button.icon-btn.small", { type: "button", title: "Rename", "aria-label": `${c.name}: rename` }, icon("pencil"));
			rename.addEventListener("click", async () => {
				const name = await prompt({ title: "Rename the calendar", label: "Name", value: c.name, icon: "pencil", confirmLabel: "Rename" });
				if (name && name.trim() && name !== c.name) change(c, { name: name.trim() });
			});
			const shareBtn = mine(c) ? h(`button.btn.small${open === c.href ? ".primary" : ".soft"}`, { type: "button" }, icon("account_multiple_plus"), c.sharees?.length ? `Shared · ${c.sharees.length}` : "Share") : null;
			shareBtn?.addEventListener("click", () => { open = open === c.href ? "" : c.href; drawCalendars(false); });
			const remove = h("button.btn.small.danger", { type: "button" }, icon(mine(c) ? "delete_outline" : "logout"), mine(c) ? "Delete" : "Leave");
			remove.addEventListener("click", () => drop(c));
			listEl.appendChild(h("div.list-row", { role: "listitem" },
				dot,
				h("div.row-main", h("div.row-title", h("span.ellipsis", c.name)), accessLabel(c) ? h("div.row-sub", accessLabel(c)) : null),
				h("div.row-side", rename, shareBtn, remove)));
			if (open === c.href) {
				const panel = h("div.cal-share");
				if (!data.members.length) panel.appendChild(h("div.subtle", "No other members"));
				for (const m of data.members) {
					const entry = (c.sharees || []).find(s => s.email.toLowerCase() === String(m.email).toLowerCase());
					const current = entry ? (entry.write ? "write" : "read") : "";
					const seg = segmented([{ value: "", label: "No" }, { value: "read", label: "Read" }, { value: "write", label: "Read & write" }], current, value => share(c, m, value));
					panel.appendChild(h("div.cal-member", icon("account_outline"), h("span.ellipsis", m.display || m.name), seg));
				}
				listEl.appendChild(panel);
			}
		}
		if (!data.calendars.length) listEl.appendChild(h("div.empty", icon("calendar_month"), h("h3", "No calendar yet")));
		clear(body).append(listEl, h("div.cal-add", h("label.field", icon("calendar_plus"), nameInput), swatches, addBtn));
		if (animateIn) stagger(listEl.children, { step: 30, distance: 10 });
	}

	function pickColor(c, anchor) {
		const grid = h("div.cal-swatches.pop");
		const pop = popover(anchor, grid, { align: "start" });
		grid.append(...COLORS.map(color => {
			const b = h(`button.cal-swatch${color === c.color ? ".on" : ""}`, { type: "button", title: color, style: { background: color } });
			b.addEventListener("click", () => { pop?.close?.(); change(c, { color }); });
			return b;
		}));
	}

	async function change(c, fields) {
		try {
			await api.patch("/api/calendar/calendars", { href: c.href, ...fields });
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function share(c, member, modeValue) {
		try {
			await api.post("/api/calendar/share", { href: c.href, email: member.email, name: member.display || member.name, mode: modeValue });
			toast(modeValue ? `Shared with ${member.display || member.name}` : `No longer shared with ${member.display || member.name}`, { icon: "account_multiple", tone: "good", timeout: 1600 });
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function drop(c) {
		const ok = await confirm({
			title: mine(c) ? `Delete “${c.name}”?` : `Leave “${c.name}”?`,
			body: mine(c) ? "The calendar and every event in it go, also for everyone it is shared with." : "It is no longer shared with you.",
			confirmLabel: mine(c) ? "Delete" : "Leave",
			danger: true,
			icon: mine(c) ? "delete_outline" : "logout"
		});
		if (!ok) return;
		try {
			await api.del(api.withQuery("/api/calendar/calendars", { href: c.href }));
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	load();
	return { el: root, title: "Calendar", icon: "calendar_month", refresh: () => load() };
}
