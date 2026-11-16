// Settings: every key of docs/nas.md › Settings, grouped; the risky ones ask
// first. Your account (password, two-step login), users, snapshots and the
// old filebrowser container.
import { h, icon, clear, when, plural, fullDate, copyText } from "../util.js";
import * as api from "../api.js";
import { state, refreshSettings, isAdmin, on as onStore } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { toggle, segmented, confirm, toast, errorToast, openDialog, formDialog, prompt, shake } from "../ui.js";
import { typeIcon } from "../actions.js";
import * as jobs from "../jobs.js";

const POLICY_HELP = { pc: "PC only (waits)", pc_or_pi: "PC, else Pi", pi: "Pi only" };
const HEAVY = new Set(["upscale", "describe", "embed", "faces", "transcode", "convert", "translate"]);

export default function settings(route, app) {
	const admin = isAdmin();
	const sections = [
		{ id: "account", label: "You", icon: "account_circle" },
		...(admin ? [
			{ id: "users", label: "Users", icon: "account_multiple_outline" },
			{ id: "sharing", label: "Sharing", icon: "link_variant" },
			{ id: "files", label: "Files and trash", icon: "folder_outline" },
			{ id: "snapshots", label: "Snapshots", icon: "history" },
			{ id: "computing", label: "Computing", icon: "chip" },
			{ id: "safety", label: "Safety", icon: "shield_check_outline" },
			{ id: "filebrowser", label: "Filebrowser", icon: "docker" },
			{ id: "about", label: "About", icon: "information_outline" }
		] : [])
	];
	const nav = h("nav.settings-nav", sections.map(s => h("a", { href: `#/settings?section=${s.id}`, dataset: { id: s.id }, onclick: event => {
		event.preventDefault();
		jump(s.id);
	} }, icon(s.icon), s.label)));
	const body = h("div.settings-body");
	const head = h("div.page-head", h("div", h("h1", "Settings"), h("div.subtle", admin ? "Everything the NAS does – changes apply at once." : "Your account.")));
	const root = h("div.page-scroll", h("div.settings", nav, h("div.settings-main", head, body)));
	let values = {};

	function jump(id, smooth = true) {
		const target = body.querySelector(`[data-section="${id}"]`);
		if (target) root.scrollTo({ top: target.offsetTop - 8, behavior: smooth ? "smooth" : "auto" });
		nav.querySelectorAll("a").forEach(a => a.classList.toggle("active", a.dataset.id === id));
		history.replaceState(null, "", `#/settings?section=${id}`);
	}

	root.addEventListener("scroll", () => {
		let current = sections[0].id;
		for (const g of body.querySelectorAll("[data-section]")) if (g.offsetTop - 60 <= root.scrollTop) current = g.dataset.section;
		nav.querySelectorAll("a").forEach(a => a.classList.toggle("active", a.dataset.id === current));
	}, { passive: true });

	function group(id, title, iconName, sub, ...cards) {
		return h("section.set-group", { dataset: { section: id } },
			h("div.set-group-head", h("div.set-icon", icon(iconName)), h("div.set-group-titles", h("h2", title), sub ? h("div.subtle", sub) : null)),
			...cards);
	}

	// one setting row; control(value, set) returns the control element
	function row({ key, title, hint, critical, control, ask }) {
		const el = h(`div.set-row${critical ? ".critical" : ""}`, h("div.set-text", h("div.set-title", title), hint ? h("div.set-hint", hint) : null));
		const set = async value => {
			if (ask) {
				const ok = await ask(value);
				if (!ok) return false;
			}
			try {
				const patchBody = typeof key === "function" ? key(value) : { [key]: value };
				values = await api.patch("/api/settings", patchBody);
				state.settings = values;
				el.classList.remove("saved");
				void el.offsetWidth;
				el.classList.add("saved");
				return true;
			} catch (error) {
				errorToast(error);
				return false;
			}
		};
		el.appendChild(h("div.set-control", control(typeof key === "function" ? null : values[key], set)));
		return el;
	}

	function boolRow(key, title, hint, opts = {}) {
		return row({ key, title, hint, critical: opts.critical, ask: opts.ask, control: (v, set) => {
			const t = toggle(!!v, next => {
				// a risky one flips only once it is confirmed and saved
				if (opts.ask) {
					set(next).then(ok => ok && t.set(next));
					return false;
				}
				set(next).then(ok => !ok && t.set(!next));
			});
			return t;
		} });
	}

	function numberRow(key, title, hint, { min = 0, max = 9999, suffix = "", critical } = {}) {
		return row({ key, title, hint, critical, control: (v, set) => {
			const input = h("input", { type: "number", min, max, value: v ?? "" });
			input.addEventListener("change", () => {
				const n = Number(input.value);
				if (Number.isNaN(n) || n < min || n > max) {
					shake(input.parentElement);
					input.value = values[key];
					return;
				}
				set(n);
			});
			return h("div.field.short", input, suffix ? h("span.subtle", suffix) : null);
		} });
	}

	function textRow(key, title, hint, { secret, placeholder } = {}) {
		return row({ key, title, hint, control: (v, set) => {
			const input = h("input", { type: secret ? "password" : "text", value: secret ? "" : v ?? "", placeholder: secret ? (v === "set" ? "•••••••• (set)" : "not set") : placeholder || "", autocomplete: "off" });
			input.addEventListener("change", () => set(input.value).then(ok => ok && secret && (input.value = "", input.placeholder = input.value || "•••••••• (set)")));
			return h("div.field", input);
		} });
	}

	const warnConfirm = (title, text, label = "Switch it on", typed) => value => (value ? confirm({ title, body: text, confirmLabel: label, danger: true, icon: "alert_outline", typeToConfirm: typed }) : Promise.resolve(true));

	// ── you ──────────────────────────────────────────────────────────────
	function accountGroup() {
		const me = state.me || {};
		const name = me.name || me.user;
		const isUser = (me.kind || "user") === "user" && name;
		const totpOn = !!me.totp;
		const card = h("div.set-card");
		card.append(
			h("div.set-row", h("div.row-icon", { style: { background: "linear-gradient(135deg, var(--primary), var(--secondary))", color: "var(--on-primary)", fontWeight: 800 } }, (name || "?").slice(0, 1).toUpperCase()), h("div.set-text", h("div.set-title", name || "?"), h("div.set-hint", `${me.role || (me.caps || []).join(", ")}${me.kind === "device" ? " · a device" : ""}`))),
			isUser ? h("div.set-row", h("div.set-text", h("div.set-title", "Password"), h("div.set-hint", "At least 8 characters")), h("div.set-control", h("button.btn.small", { onclick: () => changePassword(name, !admin) }, icon("key_outline"), "Change…"))) : null,
			isUser ? h(`div.set-row${state.settings?.totp_required && !totpOn ? ".critical" : ""}`, h("div.set-text", h("div.set-title", "Two-step login", totpOn ? h("span.chip.good", icon("check"), "On") : h("span.chip", "Off")), h("div.set-hint", "A six-digit code from an authenticator app at every login")),
				h("div.set-control", totpOn
					? h("button.btn.small.danger", { onclick: () => totpOff(name) }, "Switch off")
					: h("button.btn.small.primary", { onclick: () => totpSetup(name) }, icon("shield_key_outline"), "Set up…"))) : null);
		return group("account", "You", "account_circle", "", card);
	}

	async function changePassword(name, needOld) {
		const values2 = await formDialog({
			title: needOld ? "Change your password" : `New password for ${name}`,
			icon: "key_outline",
			fields: [
				...(needOld ? [{ key: "old", label: "The old password", type: "password" }] : []),
				{ key: "password", label: "New password", type: "password", hint: "At least 8 characters" },
				{ key: "again", label: "Once more", type: "password" }
			],
			confirmLabel: "Change"
		});
		if (!values2) return;
		if (values2.password !== values2.again) {
			toast("The two do not match", { tone: "bad", icon: "alert_circle_outline" });
			return;
		}
		try {
			await api.patch(`/api/users/${encodeURIComponent(name)}`, { password: values2.password, old: values2.old });
			toast("Password changed", { icon: "key_outline", tone: "good" });
		} catch (error) {
			errorToast(error);
		}
	}

	async function totpSetup(name) {
		let data;
		try {
			data = await api.post(`/api/users/${encodeURIComponent(name)}/totp`, {});
		} catch (error) {
			errorToast(error);
			return;
		}
		const code = h("input", { inputmode: "numeric", maxlength: 6, placeholder: "123456", autocomplete: "one-time-code", style: { textAlign: "center", letterSpacing: "0.3em", fontSize: "20px", fontFamily: "var(--mono)" } });
		let qr = h("div.totp-qr", { html: data.svg || "" });
		if (!data.svg) {
			const { qrSvg } = await import("../../vendor/qrcode.js");
			qr = h("div.totp-qr", { html: qrSvg(data.uri) });
		}
		const body = h("div.form",
			h("p.dialog-intro", "Scan it with an authenticator app (Aegis, 2FAS, Google Authenticator …), then type the code it shows."),
			qr,
			h("div.secret", data.secret || ""),
			h("label.form-row", h("span", "The code"), h("div.field", code)));
		const dialog = openDialog({
			title: "Two-step login",
			icon: "shield_key_outline",
			body,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Switch on", primary: true, run: async () => {
					try {
						await api.post(`/api/users/${encodeURIComponent(name)}/totp/confirm`, { code: code.value.trim() });
						toast("Two-step login is on", { icon: "shield_check_outline", tone: "good" });
						state.me = await api.get("/api/me");
						rebuild();
					} catch (error) {
						shake(code.parentElement);
						errorToast(error);
						return false;
					}
				} }
			]
		});
		code.addEventListener("input", () => code.value.replace(/\D/g, "").length === 6 && dialog.buttons[1].click());
	}

	async function totpOff(name) {
		const ok = await confirm({ title: "Switch two-step login off?", body: state.settings?.totp_required ? "Two-step login is required on this NAS – you will be asked to set it up again." : "Logging in then needs only the password.", confirmLabel: "Switch off", danger: true, icon: "shield_outline" });
		if (!ok) return;
		try {
			await api.patch(`/api/users/${encodeURIComponent(name)}`, { totp: false });
			state.me = await api.get("/api/me");
			rebuild();
		} catch (error) {
			errorToast(error);
		}
	}

	// ── users ────────────────────────────────────────────────────────────
	function usersGroup() {
		const listEl = h("div.set-card");
		const add = h("button.btn.small.soft", icon("account_plus"), "Add a user");
		const load = async () => {
			try {
				const users = await api.get("/api/users");
				clear(listEl);
				for (const u of users) {
					const me = u.name === (state.me?.name || state.me?.user);
					listEl.appendChild(h("div.set-row.user-row",
						h("div.row-icon", u.name.slice(0, 1).toUpperCase()),
						h("div.set-text", h("div.set-title", u.name, me ? h("span.chip.accent", "you") : null, u.totp ? h("span.chip.good", icon("shield_check_outline"), "2-step") : null), h("div.set-hint", `${u.role}${u.created ? ` · since ${when(u.created)}` : ""}`)),
						h("div.set-control",
							segmented([{ value: "user", label: "User" }, { value: "admin", label: "Admin" }], u.role, async role => {
								if (role === "admin" && !(await confirm({ title: `Make ${u.name} an admin?`, body: "Admins change every setting, devices and users.", confirmLabel: "Make admin", danger: true }))) return load();
								try {
									await api.patch(`/api/users/${encodeURIComponent(u.name)}`, { role });
									toast("Saved", { icon: "check", timeout: 1200 });
								} catch (error) {
									errorToast(error);
									load();
								}
							}),
							h("button.icon-btn.small", { title: "New password", onclick: () => changePassword(u.name, false) }, icon("key_outline")),
							u.totp && !me ? h("button.icon-btn.small", { title: "Switch two-step login off", onclick: () => totpOff(u.name) }, icon("shield_outline")) : null,
							!me ? h("button.icon-btn.small", { title: "Remove", onclick: async () => {
								const ok = await confirm({ title: `Remove ${u.name}?`, body: "Their sessions end at once.", confirmLabel: "Remove", danger: true, typeToConfirm: u.name });
								if (!ok) return;
								try {
									await api.patch(`/api/users/${encodeURIComponent(u.name)}`, { delete: true });
									load();
								} catch (error) {
									errorToast(error);
								}
							} }, icon("delete_outline")) : null)));
				}
			} catch (error) {
				clear(listEl).appendChild(h("div.subtle", { style: { padding: "14px" } }, error.message));
			}
		};
		add.addEventListener("click", async () => {
			const v = await formDialog({ title: "Add a user", icon: "account_plus", fields: [
				{ key: "name", label: "Name", type: "text", hint: "Letters, digits, . _ -" },
				{ key: "password", label: "Password", type: "password", hint: "At least 8 characters" },
				{ key: "role", label: "Role", type: "choice", default: "user", choices: [{ value: "user", label: "User" }, { value: "admin", label: "Admin" }] }
			], confirmLabel: "Add" });
			if (!v) return;
			try {
				await api.post("/api/users", v);
				toast(`${v.name} added`, { icon: "account_plus", tone: "good" });
				load();
			} catch (error) {
				errorToast(error);
			}
		});
		load();
		return group("users", "Users", "account_multiple_outline", "Who logs in to the web interface.", h("div", { style: { display: "flex", justifyContent: "flex-end" } }, add), listEl);
	}

	// ── sharing ──────────────────────────────────────────────────────────
	function sharingGroup() {
		const hint = values._router_hint || "Forward TCP 443 on the Fritzbox to 192.168.178.22 for public links.";
		return group("sharing", "Sharing", "link_variant", "",
			h("div.set-card",
				boolRow("public_shares", "Links from the internet", `Shared links also work outside, through ${values.public_host || "netcore-iseeu.duckdns.org"} (Caddy on 443 proxies only /s/ and /u/).`, {
					critical: true,
					ask: warnConfirm("Open links to the internet?", h("div", h("p", "Every shared link becomes reachable by anyone who has it, from anywhere – not only at home or over the VPN."), h("p", "Only the share pages are exposed, never the login or the files themselves. Then run deploy.sh public on the PC."), h("div.warn-box", icon("lan"), h("div", hint))), "Open to the internet", "public")
				}),
				boolRow("upload_links", "Upload links", "Links that only take files into a fresh folder under /Uploads"),
				textRow("public_host", "Public address", "The name the Caddy container answers for", { placeholder: "netcore-iseeu.duckdns.org" })),
			values.public_shares ? h("div.warn-box", icon("lan"), h("div", h("strong", "Your step: "), hint)) : null);
	}

	// ── files ────────────────────────────────────────────────────────────
	function filesGroup() {
		const folders = h("div.field", { style: { width: "260px" } }, h("input", { value: (values.photo_folders || []).join(", "), placeholder: "/Phone photos, /" }));
		folders.firstChild.addEventListener("change", async () => {
			const list = folders.firstChild.value.split(",").map(s => s.trim()).filter(Boolean).map(s => (s.startsWith("/") ? s : `/${s}`));
			try {
				values = await api.patch("/api/settings", { photo_folders: list });
				toast("Saved", { icon: "check", timeout: 1200 });
			} catch (error) {
				errorToast(error);
			}
		});
		return group("files", "Files and trash", "folder_outline", "",
			h("div.set-card",
				boolRow("permanent_delete", "Delete for good", "Allow deleting without the trash (Shift+Delete)", {
					critical: true,
					ask: warnConfirm("Allow deleting for good?", "Then a slip of Shift+Delete removes files without the trash. Snapshots may still hold older copies, but nothing else.", "Allow it")
				}),
				numberRow("trash_days", "Keep the trash", "Then it is emptied by itself", { min: 1, max: 3650, suffix: "days" }),
				boolRow("index_hidden", "Index hidden files", "Files starting with a dot are searchable too"),
				boolRow("faces", "Group faces", "Find people in the photos (on the PC when it is there)"),
				row({ key: "photo_folders", title: "Where photos are", hint: "Comma-separated NAS folders the Photos page looks in", control: () => folders })));
	}

	// ── snapshots ────────────────────────────────────────────────────────
	function snapshotsGroup() {
		const snap = values.snapshots || { on: true, every: "daily", keep: 7 };
		const listEl = h("div.set-card");
		const now = h("button.btn.small.soft", icon("camera_outline"), "Take one now");
		now.addEventListener("click", async () => {
			now.classList.add("busy");
			try {
				const { job } = await api.post("/api/snapshots", {});
				await jobs.jobPromise(job);
				toast("Snapshot taken", { icon: "history", tone: "good" });
				loadList();
			} catch (error) {
				errorToast(error);
			} finally {
				now.classList.remove("busy");
			}
		});
		const loadList = async () => {
			try {
				const data = await api.get("/api/snapshots");
				const list = data.snapshots || data || [];
				clear(listEl);
				listEl.appendChild(h("div.set-row", h("div.set-text", h("div.set-title", `${plural(list.length, "snapshot")}`), h("div.set-hint", [data.last ? `Last ${when(data.last)}` : "", data.next ? `next ${when(data.next)}` : ""].filter(Boolean).join(" · ") || "None yet")), h("div.set-control", now)));
				for (const s of list.slice(0, 12)) listEl.appendChild(h("div.set-row", icon("history"), h("div.set-text", h("div.set-title", fullDate(s.at)), h("div.set-hint", s.id))));
			} catch (error) {
				clear(listEl).appendChild(h("div.set-row", h("div.subtle", error.message), h("div.set-control", now)));
			}
		};
		loadList();
		const set = async patch => {
			const next = { ...(values.snapshots || snap), ...patch };
			try {
				values = await api.patch("/api/settings", { snapshots: next });
				toast("Saved", { icon: "check", timeout: 1200 });
			} catch (error) {
				errorToast(error);
			}
		};
		const onToggle = toggle(snap.on !== false, on => {
			(async () => {
				if (!on) {
					const ok = await confirm({ title: "Switch snapshots off?", body: "Without them a file that was overwritten or deleted from the trash is gone. Existing snapshots stay until they age out.", confirmLabel: "Switch off", danger: true, icon: "history" });
					if (!ok) return;
				}
				await set({ on });
				onToggle.set(on);
			})();
			return false;
		});
		const keep = h("input", { type: "number", min: 1, max: 365, value: snap.keep ?? 7 });
		keep.addEventListener("change", () => set({ keep: Number(keep.value) }));
		return group("snapshots", "Snapshots", "history", "Hard-link copies of the whole tree – they cost almost no space and give every file its earlier versions.",
			h("div.set-card",
				h("div.set-row.critical", h("div.set-text", h("div.set-title", "Snapshots"), h("div.set-hint", "Earlier versions of every file")), h("div.set-control", onToggle)),
				h("div.set-row", h("div.set-text", h("div.set-title", "How often")), h("div.set-control", segmented([{ value: "hourly", label: "Hourly" }, { value: "daily", label: "Daily" }], snap.every || "daily", every => set({ every })))),
				h("div.set-row", h("div.set-text", h("div.set-title", "How many to keep")), h("div.set-control", h("div.field.short", keep)))),
			listEl);
	}

	// ── computing ────────────────────────────────────────────────────────
	function computingGroup() {
		const types = state.types.length ? state.types : Object.keys(values).filter(k => k.startsWith("policy.")).map(k => ({ type: k.slice(7), label: k.slice(7) }));
		const policies = h("div.set-card", h("div.policy-grid", types.map(t => {
			const key = `policy.${t.type}`;
			const current = values[key] ?? t.policy ?? "pc_or_pi";
			const seg = segmented([{ value: "pc", label: "PC" }, { value: "pc_or_pi", label: "PC or Pi" }, { value: "pi", label: "Pi" }], current, async value => {
				if (value === "pi" && HEAVY.has(t.type)) {
					const ok = await confirm({ title: `${t.label} only on the Pi?`, body: "This is heavy work for a Raspberry Pi: it can take very long, run hot and slow everything else down. With “PC or Pi” the PC takes it whenever it is connected.", confirmLabel: "Only on the Pi", danger: true, icon: "chip" });
					if (!ok) {
						seg.select(values[key] ?? current);
						return;
					}
				}
				try {
					values = await api.patch("/api/settings", { [key]: value });
					toast(`${t.label}: ${POLICY_HELP[value]}`, { icon: typeIcon(t.type), timeout: 1600 });
				} catch (error) {
					errorToast(error);
					seg.select(values[key] ?? current);
				}
			});
			return h("div.policy-row", h("div.set-title", { style: { fontWeight: 550 } }, h("span.i", { style: { color: "var(--text-muted)" } }), t.label), seg);
		})));
		// icons in the policy rows
		policies.querySelectorAll(".policy-row").forEach((r, i) => r.querySelector(".set-title .i").replaceWith(icon(typeIcon(types[i].type))));
		return group("computing", "Computing", "chip", "When a PC is connected as a worker, every task goes to it. Without it the Pi works – or waits.",
			h("div.set-card",
				boolRow("pi_compute", "The Pi computes", "Thumbnails, scans and conversions run on the Pi when no PC is there", {
					critical: true,
					ask: value => value ? Promise.resolve(true) : confirm({ title: "Stop the Pi from computing?", body: "Every “PC or Pi” task then waits for the PC – thumbnails of new photos too, until the PC connects.", confirmLabel: "Only the PC", danger: true, icon: "chip" })
				}),
				boolRow("pi_ai", "AI on the Pi", "An Ollama container with nomic-embed-text for searching by meaning (≈ 1 GB of memory)", {
					critical: true,
					ask: value => confirm({ title: value ? "Start AI on the Pi?" : "Stop AI on the Pi?", body: value ? "The Ollama container takes about a gigabyte of the Pi's memory and the CPU while it indexes." : "Searching by meaning then only works while the PC is connected.", confirmLabel: value ? "Start it" : "Stop it", danger: !!value, icon: "creation" })
				}),
				numberRow("pi_jobs", "Tasks at once on the Pi", "More is faster but hotter (nice 15 either way)", { min: 1, max: 4, critical: false }),
				textRow("ollama_url", "Ollama address", "Where the Pi's Ollama answers", { placeholder: "http://127.0.0.1:11434" })),
			h("h3", { style: { marginTop: "6px" } }, "Where each task runs"),
			policies);
	}

	// ── safety ───────────────────────────────────────────────────────────
	function safetyGroup() {
		return group("safety", "Safety", "shield_check_outline", "",
			h("div.set-card",
				boolRow("totp_required", "Two-step login for everyone", "Users without it are asked to set it up at their next login", {
					critical: true,
					ask: value => value && !state.me?.totp ? confirm({ title: "Require two-step login?", body: "You have not set it up yourself yet – do that first under You, or you will be asked at the next login.", confirmLabel: "Require it", danger: true, icon: "shield_key_outline" }) : Promise.resolve(true)
				}),
				numberRow("session_days", "Stay logged in", "A session that is used stays alive this long", { min: 1, max: 365, suffix: "days" }),
				boolRow("vt_upload", "Upload unknown files to VirusTotal", "Without it only the checksum is looked up – the file never leaves the NAS", {
					critical: true,
					ask: warnConfirm("Upload files to VirusTotal?", "Files VirusTotal does not know yet would be uploaded to it – and anything uploaded there can be downloaded by its paying users. Never for private documents.", "Allow uploads", "upload")
				}),
				textRow("vt_key", "VirusTotal API key", "From virustotal.com › API key", { secret: true }),
				numberRow("disk_warn", "Warn when the disk is fuller than", "", { min: 50, max: 99, suffix: "%" }),
				boolRow("wake", "Wake devices", "The NAS sends wake-on-LAN packets for devices with a MAC address")));
	}

	// ── filebrowser ──────────────────────────────────────────────────────
	function filebrowserGroup() {
		const card = h("div.set-card", h("div.set-row", h("div.spinner")));
		const load = async () => {
			try {
				const fb = await api.get("/api/filebrowser");
				clear(card);
				if (!fb.exists) {
					card.appendChild(h("div.set-row", icon("check_circle_outline"), h("div.set-text", h("div.set-title", "Gone"), h("div.set-hint", "The old filebrowser container is not there (any more). pshell-nas serves the files."))));
					return;
				}
				const running = fb.state === "running";
				const act = (action, opts) => async () => {
					const ok = await confirm(opts);
					if (!ok) return;
					try {
						await api.post("/api/filebrowser", { action });
						toast(`Filebrowser: ${action}`, { icon: "docker", tone: "good" });
						load();
					} catch (error) {
						errorToast(error);
					}
				};
				card.append(
					h("div.set-row", h(`span.live-dot.${running ? "open" : "closed"}`), h("div.set-text", h("div.set-title", fb.name || "filebrowser"), h("div.set-hint", `${fb.image || ""} · ${fb.status || fb.state || ""}`))),
					h("div.set-row", h("div.set-text", h("div.set-hint", "It used the same folder (/storage/filerise/uploads) – files stay where they are, whatever you do here.")),
						h("div.set-control",
							running
								? h("button.btn.small", { onclick: act("stop", { title: "Stop filebrowser?", body: "Its web page goes away until it is started again.", confirmLabel: "Stop", icon: "stop" }) }, icon("stop"), "Stop")
								: h("button.btn.small", { onclick: act("start", { title: "Start filebrowser again?", body: "Both then serve the same folder.", confirmLabel: "Start", icon: "play" }) }, icon("play"), "Start"),
							h("button.btn.small.danger", { onclick: act("remove", { title: "Remove the filebrowser container?", body: "The container goes for good (docker rm -f). The files in the folder stay – only filebrowser itself and its own settings are gone.", confirmLabel: "Remove it", danger: true, icon: "delete_outline", typeToConfirm: "filebrowser" }) }, icon("delete_outline"), "Remove…"))));
			} catch (error) {
				clear(card).appendChild(h("div.set-row", h("div.subtle", error.message)));
			}
		};
		load();
		return group("filebrowser", "Filebrowser", "docker", "The old file server this NAS replaces.", card);
	}

	// ── about ────────────────────────────────────────────────────────────
	function aboutGroup() {
		const index = h("div.set-hint", "");
		api.get("/api/index", null, { quiet: true }).then(s => {
			index.textContent = `${Number(s.files || 0).toLocaleString("en-US")} files, ${Number(s.folders || 0).toLocaleString("en-US")} folders${s.scanning ? " · reading now" : s.last_full ? ` · read ${when(s.last_full)}` : ""}`;
		}).catch(() => {});
		return group("about", "About", "information_outline", "",
			h("div.set-card",
				h("div.set-row", h("div.set-text", h("div.set-title", state.hello?.name || "NAS"), h("div.set-hint", `pshell-nas ${state.hello?.version || state.status?.version || ""} · server ${state.hello?.server_id || ""}`))),
				h("div.set-row", h("div.set-text", h("div.set-title", "The index"), index), h("div.set-control", h("button.btn.small", { onclick: async () => {
					try {
						await api.post("/api/index/rescan", {});
						toast("Reading everything again", { icon: "refresh" });
					} catch (error) {
						errorToast(error);
					}
				} }, icon("refresh"), "Read everything again")))));
	}

	function rebuild() {
		const scroll = root.scrollTop;
		clear(body);
		body.appendChild(accountGroup());
		if (admin) {
			body.append(usersGroup(), sharingGroup(), filesGroup(), snapshotsGroup(), computingGroup(), safetyGroup(), filebrowserGroup(), aboutGroup());
		}
		root.scrollTop = scroll;
	}

	(async () => {
		values = (await refreshSettings()) || {};
		rebuild();
		stagger(body.children, { step: 40, distance: 16, from: 1 });
		const section = route.query.section;
		if (section) requestAnimationFrame(() => jump(section, false));
		else nav.querySelector("a")?.classList.add("active");
	})();

	return { el: root, title: "Settings", icon: "cog_outline", update(next) {
		if (next.query.section) jump(next.query.section);
	}, accepts: () => true };
}
