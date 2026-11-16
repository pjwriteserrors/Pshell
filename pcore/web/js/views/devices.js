// Devices: every token that talks to a pshell service – what each may do
// per service (scopes), when and where it was last seen; a new one shows its
// token once with a QR code; rename, rotate, revoke.
import { h, icon, clear, when, copyText, plural } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, isAdmin, refreshServices } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { openDialog, confirm, toast, errorToast, prompt, showMenu, toggle, segmented, shake } from "../ui.js";
import { critical } from "../confirm.js";
import { KIND_ICON, KIND_LABEL, serviceIcon } from "./common.js";

const CORE_CAPS = [
	{ cap: "read", label: "Read", hint: "State, health, services" },
	{ cap: "admin", label: "Admin", hint: "Everything here that needs an admin" }
];

export default function devices(route, app) {
	const admin = isAdmin();
	let list = [];
	let filter = "all";
	const grid = h("div.device-grid");
	const addBtn = admin ? h("button.btn.primary.small", icon("plus"), "New device") : null;
	const counts = h("div.subtle", "Every token that may talk to a pshell service.");
	const filters = segmented([{ value: "all", label: "All" }, { value: "online", label: "Online" }, { value: "pc", label: "PCs" }, { value: "phone", label: "Phones" }], filter, v => {
		filter = v;
		render(true);
	});
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Devices"), counts), h("div.page-tools", filters, addBtn)),
		grid);
	const root = h("div.page-scroll", page);

	async function load(first) {
		if (first) clear(grid).append(...[1, 2, 3].map(() => h("div.skeleton", { style: { height: "188px", borderRadius: "22px" } })));
		try {
			list = api.listOf(await api.get("/api/devices"), "devices");
			list.sort((a, b) => Number(!!b.online) - Number(!!a.online) || String(a.name).localeCompare(String(b.name)));
			const online = list.filter(d => d.online).length;
			counts.textContent = `${plural(list.length, "device")} · ${online} online now`;
			render(first);
		} catch (error) {
			clear(grid).appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("devices"), h("h3", "Could not load the devices"), h("p", error.message)));
		}
	}

	const svcTitle = name => (name === "core" ? "Core" : state.services.find(s => s.name === name)?.title || name);

	function render(animateIn) {
		clear(grid);
		const shown = list.filter(d => filter === "all" || (filter === "online" ? d.online : filter === "pc" ? d.kind === "pc" || d.kind === "laptop" : d.kind === filter));
		if (!shown.length) {
			grid.appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("devices"), h("h3", list.length ? "None here" : "No devices yet"), h("p", list.length ? "Another filter shows the rest." : "The PC adds itself during its setup; phones and laptops get a token here.")));
			return;
		}
		for (const d of shown) {
			const scopes = Object.entries(d.scopes || {}).filter(([, caps]) => caps?.length);
			const mine = state.me?.device?.id === d.id;
			const el = h(`div.device-card${d.online ? ".online" : ""}`,
				h("div.device-top",
					h("div.device-icon", icon(KIND_ICON[d.kind] || "devices"), h(`span.live-dot.${d.online ? "open" : "idle"}`, { title: d.online ? "Online" : "Not seen in the last two minutes" })),
					h("div.row-main", h("div.row-title", h("span.ellipsis", d.name), mine ? h("span.chip.small.accent", "this one") : null), h("div.row-sub", `${KIND_LABEL[d.kind] || d.kind || "device"} · ${d.id}`)),
					admin ? h("button.icon-btn.small", { title: "More", "aria-label": `${d.name}: more`, onclick: event => menu(d, event) }, icon("dots_vertical")) : null),
				h("div.device-caps", scopes.length ? scopes.map(([svc, caps]) => h(`span.scope${svc === "core" ? ".core" : ""}`, { title: `${svcTitle(svc)}: ${caps.join(", ")}` }, h("span.scope-svc", svcTitle(svc)), caps.map(c => h(`span.scope-cap${c === "admin" ? ".admin" : ""}`, c)))) : h("span.subtle", "No scopes – it may do nothing")),
				h("div.device-foot",
					h("span.device-seen", icon(d.online ? "access_point" : "clock_outline"), d.last_seen ? `${d.online ? "Online" : `Seen ${when(d.last_seen)}`}${d.last_ip ? ` · ${d.last_ip}` : ""}${d.last_service ? ` · ${svcTitle(d.last_service)}` : ""}` : "Never seen yet"),
					admin ? h("button.btn.small.soft", { onclick: () => editScopes(d) }, icon("tune_variant"), "Scopes") : null));
			grid.appendChild(el);
		}
		if (animateIn) stagger(grid.children, { step: 40, distance: 14 });
	}

	function menu(d, event) {
		const r = event.currentTarget.getBoundingClientRect();
		showMenu([
			{ header: d.name },
			{ label: "Rename…", icon: "form_textbox", run: async () => {
				const name = await prompt({ title: "Rename the device", label: "Name", value: d.name, icon: "form_textbox", confirmLabel: "Rename" });
				if (name && name !== d.name) patch(d, { name }, "Renamed");
			} },
			{ label: "Scopes…", icon: "tune_variant", run: () => editScopes(d) },
			{ label: d.mac ? "MAC address…" : "Add a MAC address…", icon: "lan", run: async () => {
				const mac = await prompt({ title: "MAC address", label: "aa:bb:cc:dd:ee:ff", value: d.mac || "", icon: "lan", hint: "For waking it on the LAN.", confirmLabel: "Save" });
				if (mac !== null) patch(d, { mac }, "Saved");
			} },
			{ separator: true },
			{ label: "Rotate the token…", icon: "key_variant", run: () => rotate(d) },
			{ label: "Revoke…", icon: "link_variant_off", danger: true, run: () => revoke(d) }
		], r.right - 220, r.bottom + 4, { keyboard: event.detail === 0 });
	}

	async function patch(d, data, message) {
		try {
			await api.patch(`/api/devices/${encodeURIComponent(d.id)}`, data);
			toast(message || "Saved", { icon: "check", tone: "good", timeout: 1400 });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	// per service its caps as toggles; core's own read/admin at the end
	function scopesEditor(initial = {}) {
		const value = {};
		for (const [k, v] of Object.entries(initial)) value[k] = [...(v || [])];
		const servicesWithCaps = state.services.filter(s => s.auth === "core" || s.caps?.length);
		const blocks = [...servicesWithCaps.map(s => ({ name: s.name, title: s.title || s.name, icon: serviceIcon(s), caps: (s.caps || []).map(c => ({ cap: c, label: c })) })), { name: "core", title: "Core", icon: "server", caps: CORE_CAPS }];
		// scopes for services that are gone stay as they are
		for (const k of Object.keys(value)) if (!blocks.some(b => b.name === k)) blocks.push({ name: k, title: k, icon: "help_circle_outline", caps: value[k].map(c => ({ cap: c, label: c })) });
		const el = h("div.scope-editor", blocks.map(b => h("div.scope-block",
			h("div.scope-head", icon(b.icon), h("strong", b.title), h("span.subtle", b.name)),
			b.caps.length ? h("div.scope-caps", b.caps.map(c => {
				const on = (value[b.name] || []).includes(c.cap);
				const t = toggle(on, next => {
					const caps = new Set(value[b.name] || []);
					if (next) caps.add(c.cap);
					else caps.delete(c.cap);
					value[b.name] = [...caps];
				});
				t.setAttribute("aria-label", `${b.title}: ${c.label}`);
				return h(`label.scope-cap-row${c.cap === "admin" ? ".admin" : ""}`, h("div", h("div.scope-cap-name", c.label), c.hint ? h("div.form-hint", c.hint) : null), t);
			})) : h("div.form-hint", "This service declares no caps."))));
		el.value = () => {
			const out = {};
			for (const [k, v] of Object.entries(value)) if (v.length) out[k] = v;
			return out;
		};
		return el;
	}

	function editScopes(d) {
		const editor = scopesEditor(d.scopes);
		openDialog({
			title: `What ${d.name} may do`,
			subtitle: "Per service, the caps of its token",
			icon: "tune_variant",
			body: editor,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Save", primary: true, run: async () => {
					const scopes = editor.value();
					const becomesAdmin = Object.values(scopes).some(c => c.includes("admin")) && !Object.values(d.scopes || {}).some(c => c.includes("admin"));
					if (becomesAdmin && !(await confirm({ title: `Give ${d.name} admin?`, body: "An admin token may change settings, devices and users. Only your own PC should hold one.", confirmLabel: "Yes, admin", danger: true, icon: "shield_account_outline" }))) return false;
					await api.patch(`/api/devices/${encodeURIComponent(d.id)}`, { scopes });
					toast("Scopes saved", { icon: "check", tone: "good", timeout: 1400 });
					load();
				} }
			]
		});
	}

	async function rotate(d) {
		const ok = await confirm({ title: `New token for ${d.name}?`, body: "The old token dies at once – the device has to get the new one before it can talk again.", confirmLabel: "Rotate", danger: true, icon: "key_variant" });
		if (!ok) return;
		try {
			const made = await api.post(`/api/devices/${encodeURIComponent(d.id)}/rotate`, {});
			showToken({ ...d, ...(made.device || {}) }, made.token, "New token");
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function revoke(d) {
		const mine = state.me?.device?.id === d.id;
		const text = `Its token stops working at once, for every service.${d.online ? " It is online right now." : ""}`;
		const run = () => api.del(`/api/devices/${encodeURIComponent(d.id)}`);
		let ok;
		if (mine) {
			ok = await critical({ title: `Revoke ${d.name}?`, body: `${text} This is the device you use right now.`, confirmLabel: "Revoke", icon: "link_variant_off", run });
		} else {
			ok = await confirm({ title: `Revoke ${d.name}?`, body: text, confirmLabel: "Revoke", danger: true, icon: "link_variant_off" });
			if (ok) {
				try {
					await run();
				} catch (error) {
					errorToast(error);
					return;
				}
			}
		}
		if (!ok) return;
		toast(`${d.name} revoked`, { icon: "link_variant_off" });
		load();
	}

	addBtn?.addEventListener("click", async () => {
		if (!state.services.length) await refreshServices();
		const name = h("input", { placeholder: "e.g. phone", autocomplete: "off", spellcheck: false });
		let kind = "phone";
		const kinds = segmented(["pc", "laptop", "phone", "other"].map(k => ({ value: k, label: KIND_LABEL[k], icon: KIND_ICON[k] })), kind, v => (kind = v));
		const mac = h("input", { placeholder: "aa:bb:cc:dd:ee:ff (optional)", autocomplete: "off", spellcheck: false });
		const nas = state.services.find(s => s.name === "nas");
		const editor = scopesEditor({ ...(nas ? { nas: (nas.user_caps || ["files"]).slice() } : {}), core: ["read"] });
		const body = h("div.form",
			h("p.dialog-intro", "It gets a token for the pshell services. The token is shown once – put it into the device right away."),
			h("label.form-row", h("span", "Name"), h("div.field", name)),
			h("div.form-row", h("span.form-label", "Kind"), kinds),
			h("div.form-row", h("span.form-label", "Scopes"), editor),
			h("label.form-row", h("span", "MAC address"), h("div.field", mac)));
		openDialog({
			title: "New device",
			icon: "devices",
			body,
			wide: true,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: "Make the token", primary: true, icon: "key_outline", run: async () => {
					if (!name.value.trim()) {
						shake(name.parentElement);
						name.focus();
						return false;
					}
					const scopes = editor.value();
					if (Object.values(scopes).some(c => c.includes("admin")) && !(await confirm({ title: "An admin device?", body: "It may change settings, devices and users. Only your own PC should be one.", confirmLabel: "Yes, admin", danger: true, icon: "shield_account_outline" }))) return false;
					const made = await api.post("/api/devices", { name: name.value.trim(), kind, scopes, mac: mac.value.trim() || undefined });
					setTimeout(() => showToken(made.device || { name: name.value.trim(), kind }, made.token, "Device added"), 120);
					load();
				} }
			]
		});
	});

	// the token, once: text, copy, QR (core url, id and token for the apps)
	async function showToken(device, token, heading) {
		const { qrSvg } = await import("../../vendor/qrcode.js");
		const payload = JSON.stringify({ core: location.origin, id: device.id, name: device.name, token });
		const copy = h("button.btn.small.soft", { type: "button" }, icon("content_copy"), "Copy");
		copy.addEventListener("click", () => copyText(token).then(() => {
			copy.replaceChildren(icon("check"), "Copied");
			animate(copy, [{ transform: "scale(0.92)" }, { transform: "none" }], { duration: 420, easing: EASE.spring, fill: "none" });
			setTimeout(() => copy.replaceChildren(icon("content_copy"), "Copy"), 1800);
		}));
		const body = h("div.token-box",
			h("div.token-warn", icon("alert_outline"), h("div", "Shown only now. Whoever has it can do what the device may do.")),
			h("div.token-line", h("div.token", { tabindex: 0 }, token), copy),
			h("div.qr-wrap", h("div.qr", { html: qrSvg(payload) }), h("div.form-hint", "The QR holds the core address, the device id and the token – the phone app reads it.")),
			device.id ? h("div.form-hint", { style: { textAlign: "center" } }, `Device id ${device.id}`) : null);
		openDialog({
			title: `${heading}: ${device.name || "device"}`,
			icon: "key_outline",
			tone: "var(--warning)",
			body,
			dismissable: false,
			actions: [{ label: "I have it", primary: true }]
		});
	}

	const offs = [api.on("device", () => load()), onStore("services", () => list.length && render())];
	load(true);
	const timer = setInterval(() => document.visibilityState === "visible" && load(), 60000);
	return { el: root, title: "Devices", icon: "devices", refresh: load, unmount: () => {
		offs.forEach(o => o());
		clearInterval(timer);
	} };
}
