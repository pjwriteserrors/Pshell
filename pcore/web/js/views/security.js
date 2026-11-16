// Security: your password and two-step sign-in, the users (admins), and the
// security log with filters.
import { h, icon, clear, when, plural, fullDate, dayLabel, toDate, debounce } from "../util.js";
import * as api from "../api.js";
import { state, isAdmin, myName, user, refreshMe, setting } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { toast, errorToast, openDialog, formDialog, confirm, segmented, shake, showMenu } from "../ui.js";
import { critical } from "../confirm.js";
import { LOG_KINDS, logKind, detailText } from "./common.js";

const timeFmt = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit" });

export default function security(route, app) {
	const admin = isAdmin();
	const body = h("div.settings-body");
	const root = h("div.page-scroll", h("div.page.narrow",
		h("div.page-head", h("div", h("h1", "Security"), h("div.subtle", "Your sign-in, the people who may sign in, and what happened."))),
		body));

	function group(id, title, iconName, sub, ...cards) {
		return h("section.set-group", { dataset: { section: id } },
			h("div.set-group-head", h("div.set-icon", icon(iconName)), h("div.set-group-titles", h("h2", title), sub ? h("div.subtle", sub) : null)),
			...cards);
	}

	// ── you ──────────────────────────────────────────────────────────────
	function youGroup() {
		const u = user();
		if (!u) return group("you", "You", "account_circle", "Signed in with a device token – nothing to change here.");
		const totp = !!u.totp;
		const required = setting("totp_required", false);
		return group("you", "You", "account_circle", "",
			h("div.set-card",
				h("div.set-row", h("div.row-icon.avatar-icon", u.name.slice(0, 1).toUpperCase()), h("div.set-text", h("div.set-title", u.name, u.role === "admin" ? h("span.chip.small.warn", "admin") : h("span.chip.small", "user")), h("div.set-hint", u.created ? `since ${when(u.created)}` : "One sign-in for every pshell service here"))),
				h("div.set-row", h("div.set-text", h("div.set-title", "Password"), h("div.set-hint", "At least 8 characters; your other sessions stay signed in")), h("div.set-control", h("button.btn.small", { onclick: changePassword }, icon("key_outline"), "Change…"))),
				h(`div.set-row${required && !totp ? ".critical" : ""}`,
					h("div.set-text", h("div.set-title", "Two-step sign-in", totp ? h("span.chip.small.good", icon("check"), "On") : h("span.chip.small", "Off")), h("div.set-hint", required && !totp ? "Required here – set it up now" : "A six-digit code from an authenticator app at every sign-in")),
					h("div.set-control", totp
						? h("button.btn.small.danger", { onclick: totpOff }, "Turn off…")
						: h("button.btn.small.primary", { onclick: totpSetup }, icon("shield_key_outline"), "Set up…")))));
	}

	async function changePassword() {
		const v = await formDialog({
			title: "Change your password",
			icon: "key_outline",
			fields: [
				{ key: "old", label: "Your password now", type: "password" },
				{ key: "new", label: "New password", type: "password", hint: "At least 8 characters" },
				{ key: "again", label: "Once more", type: "password" }
			],
			confirmLabel: "Change"
		});
		if (!v) return;
		if ((v.new || "").length < 8) return toast("The new one needs at least 8 characters", { tone: "bad", icon: "alert_circle_outline" });
		if (v.new !== v.again) return toast("The two do not match", { tone: "bad", icon: "alert_circle_outline" });
		try {
			await api.post("/api/auth/password", { old: v.old, new: v.new });
			toast("Password changed", { icon: "key_outline", tone: "good" });
			loadLog();
		} catch (error) {
			errorToast(error);
		}
	}

	async function totpSetup() {
		let data;
		try {
			data = await api.post("/api/auth/totp/start", {});
		} catch (error) {
			errorToast(error);
			return;
		}
		let svg = data.svg;
		if (!svg && data.uri) svg = (await import("../../vendor/qrcode.js")).qrSvg(data.uri);
		const code = h("input.code-input", { inputmode: "numeric", maxlength: 6, placeholder: "123456", autocomplete: "one-time-code", "aria-label": "The code" });
		const body = h("div.form",
			h("p.dialog-intro", "Scan it with an authenticator app (Aegis, 2FAS, Google Authenticator …), then type the code it shows."),
			h("div.totp-qr", { html: svg || "" }),
			h("div.secret", { title: "Or type this into the app" }, (data.secret || "").replace(/(.{4})/g, "$1 ").trim()),
			h("label.form-row", h("span", "The code"), h("div.field", code)));
		const dialog = openDialog({
			title: "Two-step sign-in",
			icon: "shield_key_outline",
			body,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Turn on", primary: true, run: async () => {
					try {
						await api.post("/api/auth/totp/finish", { code: code.value.trim() });
					} catch (error) {
						shake(code.parentElement);
						code.select();
						toast(error.message || "That code did not fit", { tone: "bad", icon: "alert_circle_outline" });
						return false;
					}
					toast("Two-step sign-in is on", { icon: "shield_check_outline", tone: "good" });
					await refreshMe();
					rebuild();
				} }
			]
		});
		code.addEventListener("input", () => {
			code.value = code.value.replace(/\D/g, "").slice(0, 6);
			if (code.value.length === 6) dialog.buttons[1].click();
		});
	}

	async function totpOff() {
		const ok = await critical({
			title: "Turn two-step sign-in off?",
			body: setting("totp_required", false) ? "It is required here – you will be asked to set it up again at the next sign-in." : "Signing in then needs only the password.",
			confirmLabel: "Turn off",
			icon: "shield_outline",
			run: () => api.post("/api/auth/totp/off", {}),
			success: "Two-step sign-in is off"
		});
		if (!ok) return;
		await refreshMe();
		rebuild();
	}

	// ── users ────────────────────────────────────────────────────────────
	function usersGroup() {
		const listEl = h("div.set-card");
		const add = h("button.btn.small.soft", icon("account_plus"), "Add a user");
		const load = async () => {
			try {
				const users = api.listOf(await api.get("/api/users"), "users");
				const admins = users.filter(u => u.role === "admin").length;
				clear(listEl);
				for (const u of users) {
					const me = u.name === myName();
					const lastAdmin = u.role === "admin" && admins <= 1;
					const role = segmented([{ value: "user", label: "User" }, { value: "admin", label: "Admin" }], u.role, async next => {
						if (next === "user" && lastAdmin) {
							toast("The last admin stays an admin", { tone: "bad", icon: "shield_alert_outline" });
							return load();
						}
						if (next === "admin" && !(await confirm({ title: `Make ${u.name} an admin?`, body: "Admins change every setting, device and user – of every pshell service.", confirmLabel: "Make admin", danger: true, icon: "shield_account_outline" }))) return load();
						try {
							await api.patch(`/api/users/${encodeURIComponent(u.name)}`, { role: next });
							toast("Saved", { icon: "check", timeout: 1200 });
							if (me) await refreshMe();
						} catch (error) {
							errorToast(error);
						}
						load();
					});
					listEl.appendChild(h("div.set-row.user-row",
						h("div.row-icon", u.name.slice(0, 1).toUpperCase()),
						h("div.set-text", h("div.set-title", u.name, me ? h("span.chip.small.accent", "you") : null, u.totp ? h("span.chip.small.good", icon("shield_check_outline"), "2-step") : null), h("div.set-hint", `${u.role}${u.created ? ` · since ${when(u.created)}` : ""}${u.last_login ? ` · last sign-in ${when(u.last_login)}` : ""}`)),
						h("div.set-control",
							role,
							h("button.icon-btn.small", { title: "Set a new password", "aria-label": `${u.name}: new password`, onclick: () => resetPassword(u) }, icon("key_outline")),
							u.totp && !me ? h("button.icon-btn.small", { title: "Turn their two-step sign-in off", "aria-label": `${u.name}: two-step off`, onclick: () => totpOffFor(u) }, icon("shield_outline")) : null,
							h("button.icon-btn.small", { title: lastAdmin ? "The last admin cannot go" : me ? "You cannot remove yourself here" : "Remove", "aria-label": `${u.name}: remove`, disabled: lastAdmin || me, onclick: () => removeUser(u) }, icon("delete_outline")))));
				}
				stagger(listEl.children, { step: 30, distance: 8 });
			} catch (error) {
				clear(listEl).appendChild(h("div.set-row", h("div.subtle", error.message)));
			}
		};
		const resetPassword = async u => {
			const v = await formDialog({ title: `New password for ${u.name}`, icon: "key_outline", fields: [{ key: "password", label: "New password", type: "password", hint: "At least 8 characters – tell it to them in person" }], confirmLabel: "Set it" });
			if (!v) return;
			if ((v.password || "").length < 8) return toast("At least 8 characters", { tone: "bad", icon: "alert_circle_outline" });
			try {
				await api.patch(`/api/users/${encodeURIComponent(u.name)}`, { password: v.password });
				toast(`New password for ${u.name}`, { icon: "key_outline", tone: "good" });
			} catch (error) {
				errorToast(error);
			}
		};
		const totpOffFor = async u => {
			const ok = await critical({
				title: `Turn off two-step sign-in for ${u.name}?`,
				body: "For when their phone is gone: they sign in with the password only and set it up again.",
				confirmLabel: "Turn off",
				icon: "shield_outline",
				run: () => api.post("/api/auth/totp/off", { name: u.name }),
				success: `Two-step sign-in off for ${u.name}`
			});
			if (ok) load();
		};
		const removeUser = async u => {
			const ok = await critical({
				title: `Remove ${u.name}?`,
				body: "Their sessions end at once, everywhere. Devices they added stay.",
				confirmLabel: "Remove",
				icon: "account_outline",
				run: () => api.del(`/api/users/${encodeURIComponent(u.name)}`),
				success: `${u.name} removed`
			});
			if (ok) load();
		};
		add.addEventListener("click", async () => {
			const v = await formDialog({ title: "Add a user", icon: "account_plus", fields: [
				{ key: "name", label: "Name", type: "text", hint: "Letters, digits, . _ -" },
				{ key: "password", label: "Password", type: "password", hint: "At least 8 characters" },
				{ key: "role", label: "Role", type: "choice", default: "user", choices: [{ value: "user", label: "User" }, { value: "admin", label: "Admin" }] }
			], confirmLabel: "Add" });
			if (!v) return;
			if (!v.name?.trim() || (v.password || "").length < 8) return toast("A name and a password of 8 characters", { tone: "bad", icon: "alert_circle_outline" });
			try {
				await api.post("/api/users", { name: v.name.trim(), password: v.password, role: v.role });
				toast(`${v.name.trim()} added`, { icon: "account_plus", tone: "good" });
				load();
			} catch (error) {
				errorToast(error);
			}
		});
		load();
		return group("users", "Users", "account_multiple_outline", "Who may sign in – to the portal and every service on core.", h("div.group-tools", add), listEl);
	}

	// ── the log ──────────────────────────────────────────────────────────
	const logEl = h("div.timeline.log-list");
	let kind = route.query.kind || "";
	let who = "";
	let limit = 100;
	let entries = [];
	const KIND_GROUPS = [
		{ value: "", label: "All" },
		{ value: "sign-in", label: "Sign-ins", kinds: ["login", "login_failed", "locked", "logout", "confirm"] },
		{ value: "devices", label: "Devices", kinds: ["device_added", "device_revoked", "token_rotated"] },
		{ value: "account", label: "Accounts", kinds: ["password_changed", "totp_on", "totp_off", "user_added", "user_removed"] },
		{ value: "system", label: "System", kinds: ["container_action", "pressure", "service_down", "service_up"] }
	];
	const kindBtn = h("button.btn.small", { type: "button" }, icon("filter_variant"), h("span", "Every kind"));
	const exact = () => (kind && !KIND_GROUPS.some(g => g.value === kind) ? kind : "");
	const group0 = () => KIND_GROUPS.find(g => g.value === kind) || (exact() ? null : KIND_GROUPS[0]);
	const seg = segmented(KIND_GROUPS.map(g => ({ value: g.value, label: g.label })), group0()?.value ?? "", v => {
		kind = v;
		kindBtn.lastChild.textContent = "Every kind";
		loadLog();
	});
	kindBtn.addEventListener("click", () => {
		const r = kindBtn.getBoundingClientRect();
		showMenu([{ header: "One kind" }, { label: "Every kind", icon: "filter_outline", checked: !exact(), run: () => pickKind("") }, { separator: true },
			...Object.keys(LOG_KINDS).map(k => ({ label: logKind(k).label, icon: logKind(k).icon, checked: kind === k, run: () => pickKind(k) }))], r.left, r.bottom + 4);
	});
	const pickKind = k => {
		kind = k;
		seg.select(k ? "__none" : "");
		kindBtn.lastChild.textContent = k ? logKind(k).label : "Every kind";
		loadLog();
	};
	const whoInput = h("input", { type: "search", placeholder: "Name or address", "aria-label": "Filter by name or address", spellcheck: false });
	whoInput.addEventListener("input", debounce(() => {
		who = whoInput.value.trim().toLowerCase();
		renderLog();
	}, 200));
	const more = h("button.btn.small.ghost", icon("chevron_down"), "Older");
	more.addEventListener("click", () => {
		limit += 200;
		loadLog();
	});

	async function loadLog() {
		logEl.classList.add("loading");
		try {
			const g = KIND_GROUPS.find(x => x.value === kind && x.kinds);
			// a group of kinds is filtered here; one kind asks the server
			const data = await api.get("/api/log", { kind: g ? undefined : kind || undefined, limit: g ? limit * 3 : limit });
			entries = api.listOf(data, "log", "entries");
			if (g) entries = entries.filter(e => g.kinds.includes(e.kind)).slice(0, limit);
			renderLog(true);
		} catch (error) {
			clear(logEl).appendChild(h("div.empty", icon("shield_outline"), h("h3", "No log"), h("p", error.status === 403 ? "Only admins read the security log." : error.message)));
		} finally {
			logEl.classList.remove("loading");
		}
	}

	function renderLog(animateIn) {
		clear(logEl);
		const shown = entries.filter(e => !who || [e.who, e.ip, detailText(e.detail)].some(x => String(x || "").toLowerCase().includes(who)));
		if (!shown.length) {
			logEl.appendChild(h("div.empty", icon("shield_check_outline"), h("h3", "Nothing here"), h("p", who || kind ? "Nothing matches the filter." : "Nothing happened yet.")));
			more.hidden = true;
			return;
		}
		let day = "";
		for (const e of shown) {
			const d = toDate(e.at);
			const label = dayLabel(d);
			if (label !== day) {
				day = label;
				logEl.appendChild(h("div.day-head", label));
			}
			const k = logKind(e.kind);
			logEl.appendChild(h(`div.event-row${k.tone ? "." + k.tone : ""}`, { title: fullDate(d) },
				h("span.event-time", d ? timeFmt.format(d) : ""),
				h("span.event-dot", icon(k.icon)),
				h("div.event-main",
					h("div.ellipsis", h("strong", k.label), e.who ? ` · ${e.who}` : ""),
					h("div.subtle.ellipsis", [e.ip, detailText(e.detail)].filter(Boolean).join(" · ") || " "))));
		}
		more.hidden = entries.length < limit;
		if (animateIn) stagger([...logEl.querySelectorAll(".event-row")].slice(0, 24), { step: 14, distance: 6 });
	}

	function logGroup() {
		return group("log", "Security log", "shield_search", "Sign-ins, devices, accounts and the guard – kept 90 days.",
			h("div.log-filters", seg, kindBtn, h("label.filter-box", icon("magnify"), whoInput)),
			logEl,
			h("div.load-more", more));
	}

	function rebuild() {
		clear(body);
		body.append(...[youGroup(), admin ? usersGroup() : null, logGroup()].filter(Boolean));
		stagger(body.children, { step: 60, distance: 12 });
	}

	rebuild();
	loadLog();
	if (route.query.log) setTimeout(() => body.querySelector('[data-section="log"]')?.scrollIntoView({ behavior: "smooth", block: "start" }), 350);
	if (route.query.totp && user() && !user().totp) setTimeout(totpSetup, 400);
	const later = debounce(loadLog, 600);
	const offs = ["login", "login_failed", "locked", "device", "pressure", "service"].map(t => api.on(t, later));
	return { el: root, title: "Security", icon: "shield_lock_outline", refresh: loadLog, unmount: () => offs.forEach(o => o()), update: next => {
		if (next.query.log) body.querySelector('[data-section="log"]')?.scrollIntoView({ behavior: "smooth", block: "start" });
		if (next.query.totp && user() && !user().totp) totpSetup();
	} };
}
