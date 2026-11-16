// Settings: the table of docs/core.md › Settings, grouped; the critical ones
// open the confirm sheet (and ask the password when the session is not
// confirmed) before they change.
import { h, icon, clear } from "../util.js";
import * as api from "../api.js";
import { state, isAdmin, setting, setSettings, isCriticalSetting } from "../store.js";
import { stagger, animate } from "../motion.js";
import { toggle, toast, errorToast, shake } from "../ui.js";
import { critical } from "../confirm.js";

export default function settings(route, app) {
	const admin = isAdmin();
	const body = h("div.settings-body");
	const root = h("div.page-scroll", h("div.page.narrow",
		h("div.page-head", h("div", h("h1", "Settings"), h("div.subtle", admin ? "How core behaves – changes apply at once." : "Only admins change these; this is how they are."))),
		body));

	function group(id, title, iconName, sub, ...rows) {
		return h("section.set-group", { dataset: { section: id } },
			h("div.set-group-head", h("div.set-icon", icon(iconName)), h("div.set-group-titles", h("h2", title), sub ? h("div.subtle", sub) : null)),
			h("div.set-card", rows));
	}

	async function save(key, value) {
		const next = await api.patch("/api/settings", { [key]: value });
		setSettings(next && typeof next === "object" && Object.keys(next).length ? next : { ...(state.settings || {}), [key]: value });
	}

	function flash(row) {
		row.classList.remove("saved");
		void row.offsetWidth;
		row.classList.add("saved");
	}

	// a switch; critical: {title, on, off} words for the sheet
	function boolRow(key, title, hint, crit) {
		if (!isCriticalSetting(key)) crit = null;
		const row = h(`div.set-row${crit ? ".critical" : ""}`, h("div.set-text", h("div.set-title", title), hint ? h("div.set-hint", hint) : null));
		const t = toggle(!!setting(key, false), next => {
			if (!admin) return false;
			(async () => {
				try {
					if (crit) {
						const ok = await critical({ title: next ? crit.on : crit.off, body: next ? crit.onBody : crit.offBody, confirmLabel: next ? "Turn on" : "Turn off", danger: !!(!next || crit.dangerOn), icon: crit.icon, run: () => save(key, next) });
						if (!ok) return;
					} else {
						await save(key, next);
					}
					t.set(next);
					flash(row);
				} catch (error) {
					errorToast(error);
				}
			})();
			return false;
		});
		t.setAttribute("aria-label", title);
		if (!admin) t.disabled = true;
		row.appendChild(h("div.set-control", t));
		return row;
	}

	function numberRow(key, title, hint, { min = 0, max = 99999, suffix = "", fallback } = {}) {
		const row = h(`div.set-row${isCriticalSetting(key) ? ".critical" : ""}`, h("div.set-text", h("div.set-title", title), hint ? h("div.set-hint", hint) : null));
		const input = h("input", { type: "number", min, max, value: setting(key, fallback) ?? "", disabled: !admin, "aria-label": title, inputmode: "numeric" });
		input.addEventListener("change", async () => {
			const n = Number(input.value);
			if (input.value === "" || Number.isNaN(n) || n < min || n > max) {
				shake(input.parentElement);
				input.value = setting(key, fallback);
				toast(`${title}: between ${min} and ${max}`, { tone: "bad", icon: "alert_circle_outline", timeout: 2400 });
				return;
			}
			try {
				if (isCriticalSetting(key)) {
					const ok = await critical({ title: `Change “${title}”?`, body: `From ${setting(key, fallback)} to ${n}${suffix ? ` ${suffix}` : ""}.`, confirmLabel: "Change", danger: false, icon: "tune_variant", run: () => save(key, n) });
					if (!ok) {
						input.value = setting(key, fallback);
						return;
					}
				} else {
					await save(key, n);
				}
				flash(row);
			} catch (error) {
				errorToast(error);
				input.value = setting(key, fallback);
			}
		});
		row.appendChild(h("div.set-control", h("div.field.short", input, suffix ? h("span.subtle", suffix) : null)));
		return row;
	}

	function rebuild() {
		clear(body);
		body.append(
			group("sign-in", "Sign-in", "shield_key_outline", "For the portal and every service that signs in with core.",
				numberRow("session_days", "Stay signed in", "A session lasts this long after its last use", { min: 1, max: 365, suffix: "days", fallback: 30 }),
				boolRow("totp_required", "Require two-step sign-in", "Users without it are asked to set it up after signing in", {
					on: "Require two-step sign-in?", off: "Stop requiring two-step sign-in?", icon: "shield_key_outline",
					onBody: "Everybody without an authenticator is asked to set one up right after the next sign-in.",
					offBody: "Users may then sign in with only a password – and turn their two-step off."
				})),
			group("alerts", "Alerts", "bell_outline", "Events and log entries that the shell and the phone turn into notifications.",
				boolRow("alerts.login_new_ip", "Sign-in from a new address", "Tell when a user signs in from an address not seen before"),
				numberRow("alerts.failed", "Failed sign-ins", "This many within 10 minutes raise an alert", { min: 1, max: 100, suffix: "tries", fallback: 3 })),
			group("guard", "Memory guard", "memory", "The Pi has 4 GB; the guard keeps it from swapping itself to a halt.",
				numberRow("tight_mb", "Tight below", "Available memory; services with “pause” are told to pause their background work", { min: 50, max: 16384, suffix: "MB", fallback: 900 }),
				numberRow("tight_psi", "…or pressure above", "PSI some, avg 10 s", { min: 1, max: 100, suffix: "%", fallback: 20 }),
				numberRow("critical_mb", "Critical below", "Available memory", { min: 20, max: 16384, suffix: "MB", fallback: 450 }),
				numberRow("critical_psi", "…or pressure above", "PSI full, avg 10 s", { min: 1, max: 100, suffix: "%", fallback: 10 }),
				boolRow("guard_stop", "Stop containers when critical", "Services with “stop” (e.g. ollama) are stopped at critical; they stay stopped until started by hand", {
					on: "Let the guard stop containers?", off: "Never stop containers?", icon: "docker", dangerOn: true,
					onBody: "At critical memory the guard stops every container marked “stop”. Critical services are never touched.",
					offBody: "At critical memory the guard then only warns – the Pi may run out of memory and stall."
				})),
			group("history", "History", "chart_line", "",
				numberRow("history_days", "Keep health samples", "Minute averages after the first day", { min: 1, max: 30, suffix: "days", fallback: 7 })));
		stagger(body.children, { step: 60, distance: 12 });
	}

	rebuild();
	// another admin (or the shell) changed something: show it
	api.get("/api/settings", null, { quiet: true }).then(s => {
		const before = JSON.stringify([state.settings, state.settingsCritical]);
		setSettings(s);
		if (JSON.stringify([state.settings, state.settingsCritical]) !== before) rebuild();
	}).catch(() => {});
	return { el: root, title: "Settings", icon: "tune_variant" };
}
