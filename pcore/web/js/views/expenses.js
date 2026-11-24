// Expenses (docs/core.md "Expenses"): groups of monthly costs, shared with
// other members to read or write, with a split of who carries what.
// /expenses: your part of everything, the income and what is left, where it
// goes, the last twelve months, what is due soon and terms to give notice.
// /expenses/<group>: one group, its entries, its members and its split.
import { h, icon, clear, plural } from "../util.js";
import * as api from "../api.js";
import { stagger } from "../motion.js";
import { confirm, toast, errorToast, openDialog, buildForm, segmented, showMenu, shake } from "../ui.js";
import { sectionHead, emptyRow } from "./common.js";

const COLORS = ["#4f8ef7", "#2fa3a3", "#3fa66b", "#e3b341", "#f07c3c", "#e0457b", "#b462d6", "#7b6cf6", "#8d8d8d"];
const ICONS = ["home_outline", "television", "wifi", "cellphone", "lightning_bolt_outline", "shield_check_outline", "bank_outline", "receipt_outline",
	"dumbbell", "music_note", "gamepad_variant_outline", "book_open_outline", "heart_outline", "paw", "baby_face_outline", "airplane",
	"washing_machine", "cloud_sync", "tag_outline", "account_group_outline"];
const INTERVALS = [
	{ value: "monthly", label: "Monthly" },
	{ value: "weekly", label: "Weekly" },
	{ value: "quarterly", label: "Quarterly" },
	{ value: "halfyearly", label: "Half-yearly" },
	{ value: "yearly", label: "Yearly" }
];
const PER = { weekly: "a week", monthly: "a month", quarterly: "a quarter", halfyearly: "a half-year", yearly: "a year" };
const REMIND = [{ value: 0, label: "None" }, { value: 1, label: "1 day before" }, { value: 3, label: "3 days before" }, { value: 7, label: "1 week before" }, { value: 14, label: "2 weeks before" }];
const NOTICE = [{ value: 0, label: "None" }, { value: 14, label: "2 weeks" }, { value: 30, label: "1 month" }, { value: 60, label: "2 months" }, { value: 90, label: "3 months" }];
const RENEW = [{ value: 0, label: "Ends" }, { value: 1, label: "Every month" }, { value: 12, label: "Every year" }, { value: 24, label: "Every 2 years" }];

const eur = new Intl.NumberFormat(undefined, { style: "currency", currency: "EUR" });
const eur0 = new Intl.NumberFormat(undefined, { style: "currency", currency: "EUR", maximumFractionDigits: 0 });
const money = v => eur.format(v || 0);
const pct = v => `${Math.round((v || 0) * 10) / 10} %`;
const dayOf = key => new Date(`${key}T00:00`);
const todayKey = () => {
	const d = new Date();
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
const daysTo = key => Math.round((dayOf(key) - dayOf(todayKey())) / 86400000);
const shortDay = key => dayOf(key).toLocaleDateString(undefined, { day: "numeric", month: "short" });
const longDay = key => dayOf(key).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short", year: dayOf(key).getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
const monthName = key => new Date(`${key}-01T00:00`).toLocaleDateString(undefined, { month: "short" });
const when = key => {
	const n = daysTo(key);
	return n === 0 ? "today" : n === 1 ? "tomorrow" : n > 1 && n < 7 ? `in ${n} days` : shortDay(key);
};

function tint(el, color) {
	if (color) el.style.setProperty("--g", color);
	return el;
}

function groupIcon(g, extra = "") {
	return tint(h(`div.exp-icon${extra}`, icon(g.icon || "currency_eur")), g.color);
}

export default function expenses(route, app) {
	let data = null;
	let groupId = route.parts[0] || "";
	let loading = null;

	const sub = h("div.subtle", "");
	const titleEl = h("h1", "Expenses");
	const tools = h("div.page-tools");
	const body = h("div.exp-body", h("div.skeleton", { style: { height: "120px" } }));
	const root = h("div.page-scroll", h("div.page.exp-page", h("div.page-head", h("div", titleEl, sub), tools), body));

	const group = () => data?.groups.find(g => g.id === groupId) || null;

	async function load() {
		const mine = (loading = api.get("/api/expenses"));
		try {
			const got = await mine;
			if (mine !== loading) return;
			data = got;
			draw();
		} catch (error) {
			if (mine !== loading) return;
			clear(body).appendChild(h("div.empty", icon("currency_eur"), h("h3", "Could not load the expenses"), h("p", error.message)));
		}
	}

	let shownTitle = "Expenses";
	function draw() {
		if (!data) return;
		if (groupId && !group()) {
			groupId = "";
			history.replaceState(null, "", "/expenses");
		}
		if (groupId) drawGroup(group());
		else drawOverview();
		// the group's name is known only now: the tab and the crumbs follow
		if (app.view === view && view.tabTitle() !== shownTitle) app.el.top.setTitle(view);
		shownTitle = view.tabTitle();
	}

	// ── the overview ──────────────────────────────────────────────────────
	function drawOverview() {
		titleEl.textContent = "Expenses";
		sub.textContent = data.groups.length ? `${plural(data.groups.length, "group")} · ${money(data.part)} a month is yours` : "";
		const add = h("button.btn.primary.small", { type: "button" }, icon("plus"), "New group");
		add.addEventListener("click", () => groupDialog());
		clear(tools).append(add);

		if (!data.groups.length) {
			const first = h("button.btn.primary", { type: "button" }, icon("plus"), "New group");
			first.addEventListener("click", () => groupDialog());
			clear(body).append(h("div.empty", icon("currency_eur"), h("h3", "No expenses yet"), first));
			return;
		}

		const incomeTile = tile("Income", data.income === null || data.income === undefined ? "–" : money(data.income),
			data.income === null || data.income === undefined ? "Set" : "a month", "bank_outline", { button: true });
		incomeTile.classList.toggle("bad", data.left !== null && data.left < 0);
		incomeTile.addEventListener("click", incomeDialog);
		const share = data.income ? Math.min(100, (data.part / data.income) * 100) : null;
		const tiles = h("div.stat-grid.exp-tiles",
			tile("Your part", money(data.part), `${money(data.yearly)} a year`, "account_outline", { accent: true }),
			incomeTile,
			share !== null ? tile("Of the income", pct(share), data.left >= 0 ? `${money(data.left)} left` : `${money(-data.left)} short`, "chart_donut") : null,
			tile("All groups", money(data.total), plural(data.groups.reduce((n, g) => n + g.active, 0), "entry", "entries"), "receipt_outline"));

		const cards = h("div.exp-cards", data.groups.map(groupCard));
		const upcoming = data.upcoming.length
			? h("div.list-card", data.upcoming.slice(0, 12).map(dueRow))
			: emptyRow("calendar_month", "Nothing due in the next weeks");
		const notices = data.notices.length ? h("section.exp-section",
			sectionHead("Notice periods"),
			h("div.list-card", data.notices.map(noticeRow))) : null;

		clear(body).append(
			tiles,
			notices,
			h("div.exp-split",
				h("section.exp-section", sectionHead("Where it goes"), spread(data.groups)),
				h("section.exp-section", sectionHead("Twelve months"), monthBars(data.months, "part"))),
			h("section.exp-section", sectionHead("Groups"), cards),
			h("section.exp-section", sectionHead("Due soon"), upcoming));
		stagger(cards.children, { step: 30, distance: 10 });
	}

	function tile(label, value, line, iconName, { accent, button } = {}) {
		return h(`${button ? "button" : "div"}.stat-tile.exp-tile${accent ? ".accent" : ""}`, button ? { type: "button" } : null,
			h("div.tile-icon", icon(iconName)),
			h("div.stat-body", h("span.section-label", label), h("div.stat-big", value), h("div.stat-sub", line)));
	}

	function groupCard(g) {
		const card = tint(h("a.exp-card", { href: `/expenses/${encodeURIComponent(g.id)}` },
			h("div.exp-card-top", groupIcon(g), h("div.exp-card-titles", h("div.exp-card-name.ellipsis", g.name),
				h("div.subtle", plural(g.active, "entry", "entries"))), g.access !== "owner" ? h("span.chip.small", icon("share_variant_outline"), g.owner) : null),
			h("div.exp-card-money", h("span.exp-card-part", money(g.part)), g.part !== g.total ? h("span.subtle", `of ${money(g.total)}`) : null),
			g.members.length ? h("div.exp-people", people(g)) : null), g.color);
		return card;
	}

	function people(g) {
		const list = [{ user: g.owner, share: g.owner_share }, ...g.members.map(m => ({ user: m.user, share: g.split[m.user] || 0, access: m.access }))];
		return list.map(p => h("span.exp-person", { title: `${p.user}${p.access ? ` · ${p.access === "write" ? "can edit" : "can read"}` : " · owner"}` },
			h("span.exp-avatar", p.user.slice(0, 1).toUpperCase()), h("span", p.user), p.share ? h("span.subtle", pct(p.share)) : null));
	}

	function spread(groups) {
		const list = groups.filter(g => g.part > 0).sort((a, b) => b.part - a.part);
		const sum = list.reduce((n, g) => n + g.part, 0);
		if (!sum) return emptyRow("chart_donut", "Nothing to carry yet");
		const bar = h("div.exp-spread", list.map(g => tint(h("i", { style: { flexGrow: g.part }, title: `${g.name} · ${money(g.part)}` }), g.color)));
		const legend = h("div.exp-legend", list.map(g => tint(h("a.exp-legend-row", { href: `/expenses/${encodeURIComponent(g.id)}` },
			h("i"), h("span.ellipsis", g.name), h("span.subtle", pct((g.part / sum) * 100)), h("b", money(g.part))), g.color)));
		return h("div.exp-spread-card", bar, legend);
	}

	function monthBars(months, key) {
		const high = Math.max(1, ...months.map(m => Math.max(m[key], m.total)));
		const now = months[months.length - 1]?.month;
		return h("div.exp-months", months.map(m => h(`div.exp-month${m.month === now ? ".now" : ""}`, { title: `${new Date(`${m.month}-01T00:00`).toLocaleDateString(undefined, { month: "long", year: "numeric" })} · ${money(m[key])}${key === "part" && m.total !== m.part ? ` of ${money(m.total)}` : ""}` },
			h("div.exp-month-bar",
				key === "part" && m.total > m.part ? h("i.whole", { style: { height: `${(m.total / high) * 100}%` } }) : null,
				h("i", { style: { height: `${(m[key] / high) * 100}%` } })),
			h("span.exp-month-value", m[key] ? eur0.format(m[key]) : ""),
			h("span.exp-month-name", monthName(m.month)))));
	}

	function dueRow(d) {
		const row = tint(h("a.list-row.exp-due", { href: `/expenses/${encodeURIComponent(d.group)}` },
			h("div.exp-date", h("b", dayOf(d.date).getDate()), h("span", dayOf(d.date).toLocaleDateString(undefined, { month: "short" }))),
			h("div.row-main", h("div.row-title", h("span.ellipsis", d.name)), h("div.row-sub", `${d.group_name} · ${when(d.date)}`)),
			h("div.row-side.exp-amount", h("b", money(d.part)), d.part !== d.amount ? h("span.subtle", `of ${money(d.amount)}`) : null)), d.color);
		return row;
	}

	function noticeRow(n) {
		const late = n.notice === "late";
		return h(`a.list-row.exp-notice${late ? ".late" : ""}`, { href: `/expenses/${encodeURIComponent(n.group)}` },
			h("div.row-icon", icon(late ? "repeat" : "alert_outline")),
			h("div.row-main", h("div.row-title", h("span.ellipsis", n.name)), h("div.row-sub", `${n.group_name} · ${late ? `renews ${longDay(n.term)}` : `give notice by ${longDay(n.cancel_by)}`}`)),
			h("div.row-side", h(`span.chip.small.${late ? "bad" : "warn"}`, late ? "Too late" : when(n.cancel_by))));
	}

	async function incomeDialog() {
		const form = buildForm([{ key: "amount", label: "Net income a month", type: "number", min: 0, step: 0.01, suffix: "€" }], { amount: data.income ?? "" });
		openDialog({
			title: "Income",
			icon: "bank_outline",
			body: form.el,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Save", primary: true, run: async () => {
					const value = form.values.amount;
					await api.put("/api/expenses/income", { amount: value === "" ? null : value });
					await load();
				} }
			]
		});
	}

	// ── one group ─────────────────────────────────────────────────────────
	function drawGroup(g) {
		titleEl.textContent = g.name;
		const write = g.access !== "read";
		sub.textContent = [g.access === "owner" ? null : `${g.owner}'s · ${g.access === "write" ? "you can edit" : "to read"}`, plural(g.items.length, "entry", "entries")].filter(Boolean).join(" · ");
		const addBtn = h("button.btn.primary.small", { type: "button" }, icon("plus"), "Entry");
		addBtn.addEventListener("click", () => itemDialog(g, null));
		const shareBtn = h("button.btn.small", { type: "button" }, icon("share_variant_outline"), "Share");
		shareBtn.addEventListener("click", () => shareDialog(g));
		const more = h("button.icon-btn.small", { type: "button", title: "More" }, icon("dots_vertical"));
		more.addEventListener("click", () => {
			const r = more.getBoundingClientRect();
			showMenu(g.access === "owner" ? [
				{ label: "Name and look", icon: "pencil_outline", run: () => groupDialog(g) },
				{ label: "Share", icon: "share_variant_outline", run: () => shareDialog(g) },
				{ separator: true },
				{ label: "Delete group", icon: "delete_outline", danger: true, run: () => deleteGroup(g) }
			] : [
				{ label: "Leave group", icon: "logout", danger: true, run: () => leaveGroup(g) }
			], r.right - 200, r.bottom + 6);
		});
		clear(tools).append(...[write ? addBtn : null, g.access === "owner" ? shareBtn : null, more].filter(Boolean));

		const shared = g.members.length > 0;
		const tiles = h("div.stat-grid.exp-tiles",
			tile("A month", money(g.total), `${money(g.yearly)} a year`, g.icon || "currency_eur", { accent: true }),
			shared ? tile("Your part", money(g.part), g.total ? pct((g.part / g.total) * 100) : "", "account_outline") : null,
			tile("Entries", String(g.active), g.items.length > g.active ? `${g.items.length - g.active} not counting` : "", "receipt_outline"));
		tint(tiles, g.color);

		const sorted = [...g.items].sort((a, b) => (counts(b) - counts(a)) || b.monthly - a.monthly || a.name.localeCompare(b.name));
		const list = sorted.length ? h("div.list-card.exp-items", sorted.map(i => itemRow(g, i, write))) : h("div.empty.small", icon("receipt_outline"), h("h3", "No entries"),
			write ? h("button.btn.primary", { type: "button", onclick: () => itemDialog(g, null) }, icon("plus"), "Entry") : null);

		clear(body).append(
			tiles,
			shared ? h("div.exp-people.wide", people(g)) : null,
			h("section.exp-section", list),
			g.items.length ? h("section.exp-section", sectionHead("Twelve months"), monthBars(g.months, shared ? "part" : "total")) : null);
		if (sorted.length) stagger(list.children, { step: 24, distance: 8 });
	}

	const counts = i => (i.monthly > 0 ? 1 : 0);

	function itemRow(g, i, write) {
		const chips = [];
		if (i.interval !== "monthly" && !i.source) chips.push(h("span.chip.small", `${money(i.amount)} ${PER[i.interval]}`));
		if (i.source) chips.push(h("span.chip.small.accent", icon("lightning_bolt_outline"), i.source === "power_monthly" ? "Payment" : "Forecast"));
		if (i.paused) chips.push(h("span.chip.small", icon("pause"), "Paused"));
		if (i.ended) chips.push(h("span.chip.small", `Ended ${shortDay(i.term)}`));
		if (i.notice === "soon") chips.push(h("span.chip.small.warn", `Notice by ${shortDay(i.cancel_by)}`));
		if (i.notice === "late") chips.push(h("span.chip.small", icon("repeat"), `Renews ${shortDay(i.term)}`));
		if (i.split && g.members.length) chips.push(h("span.chip.small", icon("account_group_outline"), "Own split"));
		const line = [i.next && !i.paused && !i.ended ? `due ${when(i.next)}` : null,
			i.term && !i.ended && !i.notice ? `term until ${shortDay(i.term)}` : null,
			i.note || null].filter(Boolean).join(" · ");
		const row = h(`div.list-row.exp-item${i.monthly > 0 ? "" : ".off"}`, { tabindex: write ? 0 : -1, role: write ? "button" : null },
			tint(h("div.row-icon", icon(i.source ? "lightning_bolt_outline" : g.icon || "currency_eur")), g.color),
			h("div.row-main", h("div.row-title", h("span.ellipsis", i.name), chips), line ? h("div.row-sub", line) : null),
			h("div.row-side", h("div.exp-amount", h("b", money(i.monthly)),
				g.members.length && i.part !== i.monthly ? h("span.subtle", `yours ${money(i.part)}`) : null)));
		if (write) {
			const menu = h("button.icon-btn.small", { type: "button", title: "More" }, icon("dots_vertical"));
			menu.addEventListener("click", event => {
				event.stopPropagation();
				const r = menu.getBoundingClientRect();
				showMenu([
					{ label: "Edit", icon: "pencil_outline", run: () => itemDialog(g, i) },
					{ label: i.paused ? "Resume" : "Pause", icon: i.paused ? "play" : "pause", run: () => patchItem(g, i, { paused: i.paused ? null : true }) },
					i.prices.length > 1 ? { label: "Price history", icon: "history", run: () => priceHistory(i) } : null,
					{ separator: true },
					{ label: "Delete", icon: "delete_outline", danger: true, run: () => deleteItem(g, i) }
				].filter(Boolean), r.right - 200, r.bottom + 6);
			});
			row.querySelector(".row-side").appendChild(menu);
			row.addEventListener("click", () => itemDialog(g, i));
			row.addEventListener("keydown", event => { if (event.key === "Enter") itemDialog(g, i); });
		} else if (i.prices.length > 1) {
			row.addEventListener("click", () => priceHistory(i));
		}
		return row;
	}

	async function patchItem(g, i, patch) {
		try {
			await api.patch(`/api/expenses/groups/${encodeURIComponent(g.id)}/items/${encodeURIComponent(i.id)}`, patch);
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function deleteItem(g, i) {
		const ok = await confirm({ title: `Delete “${i.name}”?`, confirmLabel: "Delete", danger: true, icon: "delete_outline" });
		if (!ok) return;
		try {
			await api.del(`/api/expenses/groups/${encodeURIComponent(g.id)}/items/${encodeURIComponent(i.id)}`);
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	function priceHistory(i) {
		const rows = [...i.prices].reverse().map((p, n) => h("div.list-row.exp-price",
			h("div.row-main", h("div.row-title", n === 0 ? "Now" : `From ${longDay(p.from)}`), n === 0 ? h("div.row-sub", `since ${longDay(p.from)}`) : null),
			h("div.row-side.exp-amount", h("b", `${money(p.amount)}`), h("span.subtle", PER[p.interval]))));
		openDialog({ title: i.name, icon: "history", body: h("div.list-card", rows), actions: [{ label: "Close", ghost: true }] });
	}

	// ── an entry ──
	function itemDialog(g, i) {
		const members = g.members.map(m => m.user);
		const ownSplit = !!(i && i.split);
		const values = i ? {
			name: i.name, amount: i.amount, interval: i.interval, source: i.source, since: todayKey(), due: i.next || i.due || "", remind: i.remind,
			term_end: i.term_end || "", notice_days: i.notice_days, renew_months: i.renew_months, note: i.note, own: ownSplit
		} : { interval: "monthly", source: "", remind: 0, notice_days: 0, renew_months: 12, own: false };
		for (const m of members) values[`split_${m}`] = ownSplit ? (i.split[m] || 0) : (g.split[m] || 0);
		const changedPrice = v => i && (Number(v.amount) !== i.amount || v.interval !== i.interval) && !v.source;
		const fields = [
			{ key: "name", label: "Name", type: "text", wide: true },
			data.power ? { key: "source", label: "Amount from", wide: true, type: "choice", select: true, choices: [
				{ value: "", label: "Fixed" },
				{ value: "power_monthly", label: `Electricity: payment${data.power.monthly !== null && data.power.monthly !== undefined ? ` (${money(data.power.monthly)})` : ""}` },
				{ value: "power_forecast", label: `Electricity: forecast${data.power.forecast !== null && data.power.forecast !== undefined ? ` (${money(data.power.forecast)})` : ""}` }
			] } : null,
			{ key: "amount", label: "Amount", type: "number", min: 0, step: 0.01, suffix: "€", shown: v => !v.source },
			{ key: "interval", label: "Every", type: "choice", select: true, choices: INTERVALS, shown: v => !v.source },
			i ? { key: "since", label: "New amount from", type: "date", wide: true, shown: changedPrice } : null,
			{ key: "due", label: "Due on", type: "date" },
			{ key: "remind", label: "Reminder", type: "choice", select: true, choices: REMIND, shown: v => !!v.due },
			{ key: "term_end", label: "Term until", type: "date", wide: true },
			{ key: "notice_days", label: "Notice period", type: "choice", select: true, choices: NOTICE, shown: v => !!v.term_end },
			{ key: "renew_months", label: "Then", type: "choice", select: true, choices: RENEW, shown: v => !!v.term_end },
			members.length ? { key: "own", label: "Own split", type: "bool", wide: true } : null,
			...members.map(m => ({ key: `split_${m}`, label: `${m} carries`, type: "number", min: 0, max: 100, step: 1, suffix: "%", shown: v => v.own })),
			{ key: "note", label: "Note", type: "text", wide: true }
		].filter(Boolean);
		const form = buildForm(fields, values);
		// two columns: the pairs side by side, the rest across
		form.el.classList.add("exp-form");
		fields.forEach((f, n) => f.wide && form.el.children[n]?.classList.add("wide"));
		openDialog({
			title: i ? i.name : "New entry",
			icon: g.icon || "currency_eur",
			tone: g.color || undefined,
			body: form.el,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: i ? "Save" : "Add", primary: true, run: async () => {
					const v = form.values;
					if (!String(v.name || "").trim()) {
						shake(form.el.querySelector("input"));
						return false;
					}
					const out = {
						name: v.name, note: v.note || "", source: v.source || "", due: v.due || null, remind: Number(v.remind) || 0,
						term_end: v.term_end || null, notice_days: Number(v.notice_days) || 0, renew_months: Number(v.renew_months) || 0
					};
					if (!v.source) {
						out.amount = v.amount === "" || v.amount === undefined ? 0 : Number(v.amount);
						out.interval = v.interval;
						if (changedPrice(v) && v.since) out.since = v.since;
					} else if (!i) {
						out.amount = 0;
					}
					if (members.length) out.split = v.own ? Object.fromEntries(members.map(m => [m, Number(v[`split_${m}`]) || 0])) : null;
					const base = `/api/expenses/groups/${encodeURIComponent(g.id)}/items`;
					if (i) await api.patch(`${base}/${encodeURIComponent(i.id)}`, out);
					else await api.post(base, out);
					await load();
				} }
			]
		});
	}

	// ── a group: name, colour, icon ──
	function groupDialog(g) {
		const state = { color: g?.color || COLORS[(data?.groups.length || 0) % COLORS.length], icon: g?.icon || "currency_eur" };
		const name = h("input", { type: "text", value: g?.name || "", placeholder: "Flat, Subscriptions …", autocomplete: "off" });
		const swatches = h("div.exp-swatches", COLORS.map(c => {
			const b = h("button.exp-swatch", { type: "button", title: c, "aria-label": c });
			b.style.background = c;
			b.classList.toggle("on", c === state.color);
			b.addEventListener("click", () => {
				state.color = c;
				swatches.querySelectorAll(".exp-swatch").forEach(x => x.classList.toggle("on", x === b));
				icons.style.setProperty("--g", c);
			});
			return b;
		}));
		const icons = tint(h("div.exp-icons", ["currency_eur", ...ICONS].map(n => {
			const b = h("button.exp-icon-pick", { type: "button", title: n.replace(/_outline$/, "").replace(/_/g, " ") }, icon(n));
			b.classList.toggle("on", n === state.icon);
			b.addEventListener("click", () => {
				state.icon = n;
				icons.querySelectorAll(".exp-icon-pick").forEach(x => x.classList.toggle("on", x === b));
			});
			return b;
		})), state.color);
		const form = h("div.form",
			h("label.form-row", h("span", "Name"), h("div.field", name)),
			h("div.form-row", h("span", "Colour"), swatches),
			h("div.form-row", h("span", "Icon"), icons));
		openDialog({
			title: g ? "Name and look" : "New group",
			icon: "currency_eur",
			body: form,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: g ? "Save" : "Create", primary: true, run: async () => {
					if (!name.value.trim()) {
						shake(name.parentElement);
						return false;
					}
					const payload = { name: name.value.trim(), color: state.color, icon: state.icon };
					if (g) {
						await api.patch(`/api/expenses/groups/${encodeURIComponent(g.id)}`, payload);
						await load();
					} else {
						const got = await api.post("/api/expenses/groups", payload);
						await load();
						app.go(`/expenses/${encodeURIComponent(got.group.id)}`);
					}
				} }
			]
		});
	}

	// ── sharing and the split ──
	function shareDialog(g) {
		const access = Object.fromEntries(g.members.map(m => [m.user, m.access]));
		const split = { ...g.split };
		const users = [...new Set([...data.users, ...g.members.map(m => m.user)])].sort();
		const ownerShare = h("b", "");
		const showOwner = () => {
			const rest = 100 - users.reduce((n, u) => n + (access[u] ? Number(split[u]) || 0 : 0), 0);
			ownerShare.textContent = pct(Math.max(0, rest));
			ownerShare.classList.toggle("bad-text", rest < 0);
			return rest;
		};
		const rows = users.map(u => {
			const input = h("input", { type: "number", min: 0, max: 100, step: 1, value: split[u] || "", placeholder: "0" });
			const field = h("div.field.exp-pct", input, h("span.subtle", "%"));
			const setEnabled = () => {
				input.disabled = !access[u];
				field.classList.toggle("off", !access[u]);
			};
			input.addEventListener("input", () => {
				split[u] = input.value === "" ? 0 : Number(input.value);
				showOwner();
			});
			const seg = segmented([{ value: "", label: "No" }, { value: "read", label: "Read" }, { value: "write", label: "Edit" }], access[u] || "", value => {
				if (value) access[u] = value;
				else delete access[u];
				setEnabled();
				showOwner();
			});
			setEnabled();
			return h("div.exp-share-row", h("span.exp-avatar", u.slice(0, 1).toUpperCase()), h("span.exp-share-name.ellipsis", u), seg, field);
		});
		showOwner();
		const content = h("div.exp-share",
			users.length ? rows : emptyRow("account_outline", "No other members"),
			h("div.exp-share-row.owner", h("span.exp-avatar", g.owner.slice(0, 1).toUpperCase()), h("span.exp-share-name.ellipsis", `${g.owner} (you)`), h("span"), ownerShare));
		openDialog({
			title: `Share “${g.name}”`,
			icon: "share_variant_outline",
			body: content,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Save", primary: true, run: async () => {
					if (showOwner() < 0) {
						shake(ownerShare);
						return false;
					}
					const members = Object.fromEntries(Object.entries(access).filter(([, a]) => a));
					const shares = Object.fromEntries(Object.keys(members).map(u => [u, Number(split[u]) || 0]).filter(([, v]) => v > 0));
					await api.put(`/api/expenses/groups/${encodeURIComponent(g.id)}/members`, { members, split: shares });
					await load();
				} }
			]
		});
	}

	async function deleteGroup(g) {
		const ok = await confirm({ title: `Delete “${g.name}”?`, body: g.members.length ? `${plural(g.items.length, "entry", "entries")}, also for ${g.members.map(m => m.user).join(", ")}.` : plural(g.items.length, "entry", "entries"), confirmLabel: "Delete", danger: true, icon: "delete_outline" });
		if (!ok) return;
		try {
			await api.del(`/api/expenses/groups/${encodeURIComponent(g.id)}`);
			app.go("/expenses");
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function leaveGroup(g) {
		const ok = await confirm({ title: `Leave “${g.name}”?`, confirmLabel: "Leave", danger: true, icon: "logout" });
		if (!ok) return;
		try {
			await api.post(`/api/expenses/groups/${encodeURIComponent(g.id)}/leave`);
			toast(`Left ${g.name}`, { icon: "logout", timeout: 2000 });
			app.go("/expenses");
			await load();
		} catch (error) {
			errorToast(error);
		}
	}

	let timer = 0;
	const later = () => {
		clearTimeout(timer);
		timer = setTimeout(load, 250);
	};
	const offs = [api.on("expenses", later), api.on("socket", data => data.open && later())];
	load();

	const view = {
		el: root,
		title: "Expenses",
		icon: "currency_eur",
		tabTitle: () => (groupId && group() ? group().name : "Expenses"),
		tabIcon: () => (groupId && group()?.icon) || "currency_eur",
		crumbs: () => {
			const g = groupId && group();
			return g ? [{ label: "Expenses", icon: "currency_eur", href: "/expenses" }, { label: g.name, icon: g.icon || undefined }] : [{ label: "Expenses", icon: "currency_eur" }];
		},
		refresh: load,
		update(next) {
			groupId = next.parts[0] || "";
			root.scrollTop = 0;
			draw();
		},
		unmount: () => {
			clearTimeout(timer);
			offs.forEach(off => off());
		}
	};
	return view;
}
