// Services: the list with state and memory, a detail per service (probe,
// container, actions behind a confirm sheet) and, for admins, the editor
// over its entry in services.json.
import { h, icon, clear, when, mem, uptime, plural } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, isAdmin, refreshServices, patchService } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { toast, errorToast, openDialog, buildForm, confirm, shake } from "../ui.js";
import { critical, needsConfirm } from "../confirm.js";
import { stateChip, serviceIcon, memBar, sectionHead, emptyRow } from "./common.js";

const ACTION = {
	restart: { label: "Restart", icon: "restart", verb: "restarts", done: "restarted" },
	stop: { label: "Stop", icon: "stop", verb: "stops", done: "stopped" },
	start: { label: "Start", icon: "play", verb: "starts", done: "started" },
	pause: { label: "Pause", icon: "pause", verb: "is paused", done: "paused" },
	unpause: { label: "Resume", icon: "play_pause", verb: "resumes", done: "resumed" }
};

// what a container in this state may do
function actionsFor(s) {
	const cs = s.container?.state;
	// core never stops itself
	if (!s.container || s.container_name === "pshell-core" || s.name === "core") return [];
	if (cs === "paused") return ["unpause", "stop"];
	if (cs === "running") return ["restart", "pause", "stop"];
	return ["start"];
}

export default function services(route, app) {
	const admin = isAdmin();
	const body = h("div.svc-page");
	const root = h("div.page-scroll", h("div.page", body));
	let current = route.parts[0] || null;
	let built = null;

	// ── the list ──────────────────────────────────────────────────────────
	function list() {
		const rows = h("div.list-card", { role: "list" });
		const add = admin ? h("button.btn.primary.small", { onclick: () => editService(null) }, icon("plus"), "Add a service") : null;
		const el = h("div",
			h("div.page-head", h("div", h("h1", "Services"), h("div.subtle", "What runs on netcore, as core sees it every 30 seconds.")), h("div.page-tools", add)),
			rows);
		const paint = items => {
			clear(rows);
			if (!items.length) {
				rows.appendChild(state.booted ? h("div.empty", icon("server_network"), h("h3", "No services"), h("p", "services.json is empty.")) : h("div.skeleton", { style: { height: "240px" } }));
				return;
			}
			for (const s of items) {
				const c = s.container || {};
				rows.appendChild(h(`a.list-row.svc-row.${s.state || "unknown"}`, { href: `/services/${encodeURIComponent(s.name)}`, role: "listitem" },
					h("div.row-icon.svc-icon", icon(serviceIcon(s))),
					h("div.row-main",
						h("div.row-title", h("span.ellipsis", s.title || s.name), stateChip(s.state), s.critical ? h("span.chip.small.warn", "critical") : null),
						h("div.row-sub", [s.port ? `port ${s.port}` : null, s.container ? (s.container.name || s.container_name || (typeof s.container === "string" ? s.container : null) || s.name) : "no container", s.auth === "core" ? "signs in with core" : s.auth === "own" ? "own sign-in" : null, s.http?.ms !== undefined && s.http?.ms !== null ? `${Math.round(s.http.ms)} ms` : null].filter(Boolean).join(" · "))),
					h("div.row-side.svc-side", s.container ? memBar(c) : null, c.cpu !== undefined && c.cpu !== null ? h("span.chip.small", `${Number(c.cpu).toFixed(1)} % CPU`) : null, icon("chevron_right", "row-chev"))));
			}
		};
		el.paint = paint;
		paint(state.services);
		requestAnimationFrame(() => stagger(rows.children, { step: 26, distance: 10 }));
		return el;
	}

	// ── one service ───────────────────────────────────────────────────────
	function detail(name) {
		const el = h("div.svc-detail");
		el.paint = items => {
			const s = items.find(x => x.name === name);
			clear(el);
			if (!s) {
				el.appendChild(state.booted ? h("div.empty", icon("server_network"), h("h3", `No service “${name}”`), h("p", h("a", { href: "/services" }, "All services"))) : h("div.skeleton", { style: { height: "300px" } }));
				return;
			}
			const c = s.container || null;
			const st = s.state || "unknown";
			const actions = actionsFor(s);
			const head = h(`div.svc-hero.${st}`,
				h("div.svc-hero-icon", icon(serviceIcon(s))),
				h("div.svc-hero-text",
					h("h1", s.title || s.name),
					h("div.svc-hero-line", stateChip(st), s.critical ? h("span.chip.small.warn", icon("shield_outline"), "critical") : null, s.home_only ? h("span.chip.small", icon("home_outline"), "home only") : null, s.since || s.changed ? h("span.subtle", `since ${when(s.since ?? s.changed)}`) : null),
					s.description ? h("div.subtle", s.description) : null),
				h("div.svc-hero-tools",
					s.url ? h("a.btn.primary", { href: s.url, target: "_blank", rel: "noopener" }, icon("open_in_new"), "Open") : null));
			const actionRow = h("div.action-row",
				admin ? actions.map(a => h(`button.btn${a === "stop" ? ".danger" : ""}`, { type: "button", onclick: event => act(s, a, event.currentTarget) }, icon(ACTION[a].icon), ACTION[a].label)) : null,
				!admin && actions.length ? h("span.subtle", "Only admins start and stop containers.") : null);

			const probe = h("div.info-card",
				h("h3", icon("speedometer"), "HTTP probe"),
				kv([
					["Address", `127.0.0.1:${s.port ?? "?"}${s.health || s.path || "/"}`],
					["Answer", s.http ? (s.http.status ? `HTTP ${s.http.status}` : s.http.error || "none") : "not probed yet", s.http?.status >= 200 && s.http?.status < 400 ? "good" : s.http ? "bad" : ""],
					["Took", s.http?.ms !== undefined && s.http?.ms !== null ? `${Math.round(s.http.ms)} ms` : "–"],
					["Checked", s.http?.at ? when(s.http.at) : s.checked ? when(s.checked) : "every 30 s"]
				]));
			const box = h("div.info-card",
				h("h3", icon("docker"), "Container"),
				c ? [
					kv([
						["Name", c.name || (typeof s.container === "string" ? s.container : s.name)],
						["State", c.state || "unknown", c.state === "running" ? "good" : c.state === "exited" || c.state === "dead" ? "bad" : ""],
						c.health ? ["Health check", c.health, c.health === "healthy" ? "good" : c.health === "unhealthy" ? "bad" : ""] : null,
						["Up for", c.started && c.state === "running" ? uptime(Date.now() / 1000 - toSeconds(c.started)) : "–"],
						["Restarts", String(c.restarts ?? 0), c.restarts > 3 ? "bad" : ""],
						["CPU", c.cpu !== undefined && c.cpu !== null ? `${Number(c.cpu).toFixed(1)} %` : "–"]
					]),
					h("div.subtle.mem-label", "Memory against its limit"),
					memBar(c)
				] : h("div.subtle", "No container is named for this service."));
			const cfg = h("div.info-card.wide",
				h("h3", icon("code_braces"), "Entry in services.json", admin ? h("div.card-tools", h("button.btn.small", { onclick: () => editService(s) }, icon("pencil_outline"), "Edit"), h("button.btn.small.danger", { onclick: () => removeService(s) }, icon("delete_outline"), "Remove")) : null),
				kv([
					["Name", s.name],
					["Port", String(s.port ?? "–")],
					["Path", s.path || "/"],
					["Health path", s.health || "(the path)"],
					["Sign-in", s.auth === "core" ? "pshell core" : s.auth === "own" ? "its own" : s.auth || "–"],
					s.caps?.length ? ["Caps", s.caps.join(", ")] : null,
					s.user_caps?.length ? ["Users get", s.user_caps.join(", ")] : null,
					["Under pressure", { pressure: "told to pause", stop: "stopped at critical", never: "never touched" }[s.shed || (s.critical ? "never" : "never")] || s.shed]
				]));
			el.append(head, actionRow, h("div.info-grid", probe, box, cfg));
			if (!el.dataset.shown) {
				el.dataset.shown = "1";
				stagger([head, actionRow, ...el.querySelectorAll(".info-card")], { step: 50, distance: 12 });
			}
		};
		el.paint(state.services);
		return el;
	}

	function kv(rows) {
		return h("div.kv-list", rows.filter(Boolean).map(([k, v, tone]) => h(`div.kv-row${tone ? "." + tone : ""}`, h("span", k), h("span", v))));
	}

	async function act(s, action, button) {
		const a = ACTION[action];
		const quiet = action === "start" || action === "unpause";
		const title = s.title || s.name;
		const run = async () => {
			const result = await api.post(`/api/services/${encodeURIComponent(s.name)}/action`, { action, really: s.critical ? true : undefined });
			patchService(s.name, { container: { ...(s.container || {}), state: action === "stop" ? "exited" : action === "pause" ? "paused" : "running" } });
			setTimeout(refreshServices, 800);
			return result;
		};
		const ok = await critical({
			title: `${a.label} ${title}?`,
			body: h("div",
				h("p", quiet ? `${title} ${a.verb}.` : `${title} ${a.verb}${action === "restart" ? " – it is gone for a few seconds" : " until someone starts it again"}.`),
				s.critical ? h("div.warn-box.danger-box", icon("alert_outline"), h("div", `${title} is critical: ${s.name === "pihole" ? "without it no device at home resolves names" : s.name === "wg-easy" ? "without it the VPN – and this page over the VPN – is gone" : "other things depend on it"}.`)) : null),
			confirmLabel: a.label,
			danger: !quiet,
			icon: a.icon,
			really: s.critical ? `${title} is marked critical.` : false,
			run,
			success: `${title} ${a.done}`
		});
		if (ok) animate(button.closest(".svc-detail") || button, [{ opacity: 0.6 }, { opacity: 1 }], { duration: 600, fill: "none" });
	}

	// ── the editor (admins): a form over the fields of docs/core.md ────────
	function editService(s) {
		const isNew = !s;
		// the raw entry when the server sends it (config), else the view minus what GET added
		const entryOf = x => x.config || { ...x, container: x.container_name ?? (typeof x.container === "string" ? x.container : x.container?.name) };
		const base = s ? entryOf(s) : null;
		const fields = [
			...(isNew ? [{ key: "name", label: "Name (the key in services.json)", type: "text", placeholder: "e.g. push", hint: "Lowercase letters, digits and -" }] : []),
			{ key: "title", label: "Title", type: "text", placeholder: "NAS" },
			{ key: "description", label: "Description", type: "text", placeholder: "Files, photos, backups" },
			{ key: "icon", label: "Icon", type: "text", placeholder: "folder, shield, home, calendar, vpn, globe, database …" },
			{ key: "port", label: "Port", type: "number", min: 1, max: 65535 },
			{ key: "path", label: "Path to open", type: "text", placeholder: "/" },
			{ key: "health", label: "Health path (probed every 30 s)", type: "text", placeholder: "empty: the path" },
			{ key: "container", label: "Container", type: "text", placeholder: "docker container name" },
			{ key: "auth", label: "Sign-in", type: "choice", default: "own", choices: [{ value: "core", label: "pshell core" }, { value: "own", label: "Its own" }] },
			{ key: "caps", label: "Caps it knows", type: "text", placeholder: "files, worker, admin", shown: v => v.auth === "core", hint: "Comma-separated; admins get all of them" },
			{ key: "user_caps", label: "Caps a user gets", type: "text", placeholder: "files", shown: v => v.auth === "core" },
			{ key: "shed", label: "Under memory pressure", type: "choice", default: "", choices: [{ value: "pressure", label: "Pause work" }, { value: "stop", label: "Stop it" }, { value: base?.shed === "never" ? "never" : "", label: "Leave it" }], hint: "Pause: core tells it to pause its background work. Stop: the guard stops the container at critical. Changing this needs your password." },
			{ key: "critical", label: "Critical", type: "bool", hint: "Stopping it needs an extra “really”; the guard never touches it. Changing this needs your password." },
			{ key: "home_only", label: "Only at home", type: "bool", hint: "Not linked over the VPN" }
		];
		const values = base ? { ...base, caps: (base.caps || []).join(", "), user_caps: (base.user_caps || []).join(", "), shed: base.shed || "" } : { auth: "own", shed: "", path: "/" };
		const form = buildForm(fields, values);
		const iconPreview = h("span.icon-preview", icon(values.icon || "server"));
		const iconInput = form.el.querySelectorAll("input")[isNew ? 3 : 2];
		iconInput?.parentElement.prepend(iconPreview);
		iconInput?.addEventListener("input", () => iconPreview.replaceChildren(icon(iconInput.value.trim() || "server")));
		openDialog({
			title: isNew ? "Add a service" : `Edit ${s.title || s.name}`,
			subtitle: isNew ? "A new entry in services.json" : `services.json › ${s.name}`,
			icon: isNew ? "plus" : "pencil_outline",
			body: form.el,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: isNew ? "Add" : "Save", primary: true, run: async () => {
					const v = form.values;
					const name = isNew ? String(v.name || "").trim() : s.name;
					if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(name)) {
						shake(form.el.querySelector("input"));
						toast("The name: up to 32 small letters, digits, - or _", { tone: "bad", icon: "alert_circle_outline" });
						return false;
					}
					if (isNew && state.services.some(x => x.name === name)) {
						toast(`There is a service “${name}” already`, { tone: "bad", icon: "alert_circle_outline" });
						return false;
					}
					const list = text => String(text || "").split(",").map(x => x.trim()).filter(Boolean);
					const entry = {
						title: v.title?.trim() || name,
						description: v.description?.trim() || undefined,
						icon: v.icon?.trim() || undefined,
						port: v.port === "" || v.port === undefined ? undefined : Number(v.port),
						path: v.path?.trim() || undefined,
						health: v.health?.trim() || undefined,
						container: v.container?.trim() || undefined,
						auth: v.auth,
						caps: v.auth === "core" ? list(v.caps) : undefined,
						user_caps: v.auth === "core" ? list(v.user_caps) : undefined,
						shed: v.shed || undefined,
						critical: !!v.critical || undefined,
						home_only: !!v.home_only || undefined
					};
					for (const k of Object.keys(entry)) if (entry[k] === undefined) delete entry[k];
					const stray = (entry.user_caps || []).filter(c => !(entry.caps || []).includes(c));
					if (stray.length) {
						toast(`Users get only caps it knows: ${stray.join(", ")}`, { tone: "bad", icon: "alert_circle_outline" });
						return false;
					}
					const put = () => api.put(`/api/services/${encodeURIComponent(name)}`, entry);
					try {
						await put();
					} catch (error) {
						if (!needsConfirm(error)) throw error;
						// what the guard may do with it changed: the confirm sheet first
						const ok = await critical({ title: "Change what the guard may do?", body: `${entry.title}: under pressure “${{ pressure: "pause work", stop: "stop it", never: "never", "": "leave it" }[entry.shed || ""]}”${entry.critical ? ", critical" : ""}.`, confirmLabel: "Save", danger: false, icon: "memory", run: put });
						if (!ok) return false;
					}
					toast(isNew ? `${entry.title} added` : "Saved", { icon: "check", tone: "good", timeout: 1800 });
					await refreshServices();
					if (isNew) app.go(`/services/${encodeURIComponent(name)}`);
				} }
			]
		});
	}

	async function removeService(s) {
		const ok = await confirm({ title: `Remove ${s.title || s.name}?`, body: "Only its entry in services.json goes – the container keeps running, core just stops watching it. Its key file stays.", confirmLabel: "Remove", danger: true, icon: "delete_outline", typeToConfirm: s.critical ? s.name : undefined });
		if (!ok) return;
		try {
			await api.del(`/api/services/${encodeURIComponent(s.name)}`);
			toast(`${s.title || s.name} removed`, { icon: "delete_outline" });
			await refreshServices();
			app.go("/services");
		} catch (error) {
			errorToast(error);
		}
	}

	function show(name, first) {
		current = name;
		const next = name ? detail(name) : list();
		if (built && !first) {
			const old = built;
			const forward = !!name;
			animate(old, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: `translateX(${forward ? -24 : 24}px)` }], { duration: 140, easing: EASE.accel }).finished.then(() => {
				old.remove();
				body.appendChild(next);
				animate(next, [{ opacity: 0, transform: `translateX(${forward ? 30 : -30}px)` }, { opacity: 1, transform: "none" }], { duration: 420, easing: EASE.spring, fill: "none" });
			});
		} else {
			body.appendChild(next);
		}
		built = next;
		root.scrollTop = 0;
	}

	show(current, true);
	const off = onStore("services", items => built?.paint(items));
	const view = {
		el: root,
		title: "Services",
		icon: "server_network",
		tabTitle: () => (current ? state.services.find(s => s.name === current)?.title || current : "Services"),
		tabIcon: () => (current ? serviceIcon(state.services.find(s => s.name === current)) : "server_network"),
		crumbs: () => current ? [{ label: "Services", icon: "server_network", href: "/services" }, { label: state.services.find(s => s.name === current)?.title || current }] : [{ label: "Services", icon: "server_network" }],
		update: next => show(next.parts[0] || null),
		refresh: refreshServices,
		unmount: off
	};
	return view;
}

function toSeconds(v) {
	if (typeof v === "number") return v > 1e12 ? v / 1000 : v;
	const t = Date.parse(v);
	return Number.isNaN(t) ? Date.now() / 1000 : t / 1000;
}
