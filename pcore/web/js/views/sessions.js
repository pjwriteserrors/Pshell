// Sessions: where you (admins: everybody) are signed in – browser, address,
// last use; end one, or every other one.
import { h, icon, clear, when, fullDate, plural } from "../util.js";
import * as api from "../api.js";
import { isAdmin, sessionId, myName } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { confirm, toast, errorToast } from "../ui.js";
import { agentOf } from "./common.js";

export default function sessions(route, app) {
	const admin = isAdmin();
	const listEl = h("div.list-card", { role: "list" });
	const endOthers = h("button.btn.small.danger", icon("logout"), "End all others");
	const sub = h("div.subtle", admin ? "Every browser signed in to netcore – yours and everybody's." : "Where you are signed in.");
	const root = h("div.page-scroll", h("div.page",
		h("div.page-head", h("div", h("h1", "Sessions"), sub), h("div.page-tools", endOthers)),
		listEl));
	let list = [];

	const isCurrent = s => s.current || (sessionId() && (s.id === sessionId() || s.hash === sessionId()));

	async function load(first) {
		if (first) clear(listEl).append(...[1, 2, 3].map(() => h("div.skeleton", { style: { height: "56px", margin: "4px" } })));
		try {
			list = api.listOf(await api.get("/api/sessions"), "sessions");
			list.sort((a, b) => Number(!!isCurrent(b)) - Number(!!isCurrent(a)) || num(b.last_used ?? b.last_seen) - num(a.last_used ?? a.last_seen));
			render(first);
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("account_switch_outline"), h("h3", "Could not load the sessions"), h("p", error.message)));
		}
	}

	function render(animateIn) {
		clear(listEl);
		const others = list.filter(s => !isCurrent(s) && (s.user ?? myName()) === myName());
		endOthers.disabled = !others.length;
		sub.textContent = `${plural(list.length, "session")}${admin ? " of all users" : ""} · ${others.length ? `${plural(others.length, "other")} of yours` : "only this one of yours"}`;
		if (!list.length) {
			listEl.appendChild(h("div.empty", icon("account_switch_outline"), h("h3", "No sessions"), h("p", "Odd – this one should be here.")));
			return;
		}
		let lastUser = null;
		const byUser = admin && new Set(list.map(s => s.user)).size > 1;
		for (const s of byUser ? [...list].sort((a, b) => String(a.user).localeCompare(String(b.user))) : list) {
			if (byUser && s.user !== lastUser) {
				lastUser = s.user;
				listEl.appendChild(h("div.list-group", icon("account_outline"), s.user || "?"));
			}
			const a = agentOf(s.agent);
			const current = isCurrent(s);
			const end = h("button.btn.small" + (current ? ".ghost" : ".danger"), { type: "button" }, icon("logout"), current ? "Sign out" : "End");
			end.addEventListener("click", () => endOne(s, current, end));
			listEl.appendChild(h(`div.list-row.session-row${current ? ".current" : ""}`, { role: "listitem" },
				h("div.row-icon", icon(a.icon)),
				h("div.row-main",
					h("div.row-title", h("span.ellipsis", `${a.browser}${a.os ? ` on ${a.os}` : ""}`), current ? h("span.chip.small.accent", icon("check"), "this browser") : null, !byUser && admin && s.user && s.user !== myName() ? h("span.chip.small", s.user) : null),
					h("div.row-sub", { title: s.agent || "" }, [s.ip || s.last_ip, s.address, `last used ${when(s.last_used ?? s.last_seen ?? s.created)}`, s.created ? `since ${when(s.created)}` : null].filter(Boolean).join(" · "))),
				h("div.row-side", h("span.subtle.hide-mobile", { title: fullDate(s.expires) }, s.expires ? `until ${when(s.expires)}` : ""), end)));
		}
		if (animateIn) stagger(listEl.children, { step: 30, distance: 10 });
	}

	async function endOne(s, current, button) {
		if (current) {
			const ok = await confirm({ title: "Sign out here?", body: "This browser is signed out of netcore and every pshell service on this host.", confirmLabel: "Sign out", icon: "logout" });
			if (!ok) return;
		}
		button.classList.add("busy");
		try {
			await api.del(`/api/sessions/${encodeURIComponent(s.id)}`);
			if (current) {
				location.href = "/login";
				return;
			}
			const row = button.closest(".list-row");
			await animate(row, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(40px)" }], { duration: 220, easing: EASE.accel }).finished;
			toast("Session ended", { icon: "logout", timeout: 1600 });
			load();
		} catch (error) {
			errorToast(error);
			button.classList.remove("busy");
		}
	}

	endOthers.addEventListener("click", async () => {
		const ok = await confirm({ title: "End every other session?", body: "Every other browser where you are signed in has to sign in again. This one stays.", confirmLabel: "End them", danger: true, icon: "logout" });
		if (!ok) return;
		try {
			const r = await api.post("/api/sessions/others/end", {});
			toast(r?.ended !== undefined ? `${plural(r.ended, "session")} ended` : "Other sessions ended", { icon: "logout", tone: "good" });
			load();
		} catch (error) {
			errorToast(error);
		}
	});

	const offs = [api.on("login", () => load()), api.on("logout", () => load())];
	load(true);
	return { el: root, title: "Sessions", icon: "account_switch_outline", refresh: load, unmount: () => offs.forEach(o => o()) };
}

function num(v) {
	if (typeof v === "number") return v;
	const t = Date.parse(v);
	return Number.isNaN(t) ? 0 : t;
}
