// Devices: the PC, the laptop, the phone – what each may do, when it was
// last seen, a new one with its token shown once, wake-on-LAN.
import { h, icon, clear, when, copyText, plural } from "../util.js";
import * as api from "../api.js";
import { state, setting, on as onStore, coreInfo, portalUrl } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { openDialog, formDialog, confirm, toast, errorToast, prompt, showMenu, portalCard } from "../ui.js";

const KIND_ICON = { pc: "monitor", laptop: "laptop", phone: "cellphone" };
const CAP_LABEL = { files: "Files", worker: "Computes", admin: "Admin" };

export default function devices(route, app) {
	let list = [];
	let awake = {};
	const grid = h("div.device-grid");
	// with pshell-core the devices are kept there: this page only shows them (and wakes them)
	const core = coreInfo();
	const addBtn = core
		? h("a.btn.primary.small", { href: portalUrl("/"), target: "_blank", rel: "noopener" }, icon("open_in_new"), "Open the portal")
		: h("button.btn.primary.small", icon("plus"), "Add a device");
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Devices"), h("div.subtle", core ? "What may talk to the NAS with a token – kept by the sign-in server." : "What may talk to the NAS with a token: files, computing, admin.")), h("div.page-tools", addBtn)),
		core ? h("div", { style: { marginBottom: "14px" } }, portalCard({ title: "Devices are managed in the portal", text: "New tokens, what each device may do, renaming and removing happen at the sign-in server, for every pshell service at once.", url: portalUrl("/"), iconName: "devices" })) : null,
		grid);
	const root = h("div.page-scroll", page);

	async function load(first) {
		if (first) clear(grid).append(...[1, 2, 3].map(() => h("div.skeleton", { style: { height: "170px", borderRadius: "22px" } })));
		try {
			const [devs, kv] = await Promise.all([api.get("/api/devices"), api.get("/api/kv/devices", null, { quiet: true }).catch(() => ({}))]);
			list = Array.isArray(devs) ? devs : devs.devices || [];
			awake = kv || {};
			render(first);
		} catch (error) {
			clear(grid).appendChild(h("div.empty", icon("devices"), h("h3", "Could not load the devices"), h("p", error.message)));
		}
	}

	function isAwake(d) {
		const rec = awake[d.id] || awake[d.name];
		const v = rec?.value ?? rec;
		if (v && typeof v === "object" && "awake" in v) return !!v.awake;
		return d.last_seen && Date.now() / 1000 - d.last_seen < 180;
	}

	function render(animateIn) {
		clear(grid);
		if (!list.length) {
			grid.appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("devices"), h("h3", "No devices yet"), h("p", "The PC adds itself during its setup; the phone and the laptop get their tokens through the PC.")));
			return;
		}
		const worker = state.status?.worker;
		for (const d of list) {
			const on = isAwake(d);
			const computing = worker?.connected && (worker.device === d.name || worker.device === d.id);
			const el = h("div.device-card",
				h("div.device-top",
					h("div.device-icon", icon(KIND_ICON[d.kind] || "devices"), h(`span.live-dot.${on ? "open" : "closed"}`)),
					h("div.row-main", h("div.row-title", h("span.ellipsis", d.name)), h("div.row-sub", `${d.kind} · ${d.id}`)),
					core ? null : h("button.icon-btn.small", { title: "More", onclick: event => menu(d, event) }, icon("dots_vertical"))),
				h("div.device-caps", (d.caps || []).map(c => h(`span.chip${c === "admin" ? ".warn" : c === "worker" ? ".pc" : ""}`, icon(c === "admin" ? "shield_account_outline" : c === "worker" ? "chip" : "folder_outline"), CAP_LABEL[c] || c)), computing ? h("span.chip.good", icon("cog_transfer_outline"), "Computing now") : null),
				h("div.device-foot",
					h("span", d.last_seen ? `Seen ${when(d.last_seen)}${d.last_address ? ` from ${d.last_address}` : ""}` : "Never seen yet"),
					d.mac && setting("wake", true) !== false ? h("button.btn.small.soft", { onclick: event => wake(d, event.currentTarget) }, icon("power"), "Wake") : null));
			grid.appendChild(el);
		}
		if (animateIn) stagger(grid.children, { step: 40, distance: 14 });
	}

	function menu(d, event) {
		showMenu([
			{ label: "Rename…", icon: "form_textbox", run: async () => {
				const name = await prompt({ title: "Rename the device", label: "Name", value: d.name, icon: "form_textbox" });
				if (name) patch(d, { name });
			} },
			{ label: d.mac ? "Change the MAC address…" : "Add a MAC address (for waking)…", icon: "lan", run: async () => {
				const mac = await prompt({ title: "MAC address", label: "aa:bb:cc:dd:ee:ff", value: d.mac || "", icon: "lan", hint: "The NAS sends the wake-up packet to it on the LAN." });
				if (mac !== null) patch(d, { mac });
			} },
			{ label: "What it may do", icon: "shield_account_outline", children: ["files", "worker", "admin"].map(cap => ({
				label: CAP_LABEL[cap],
				icon: cap === "admin" ? "shield_account_outline" : cap === "worker" ? "chip" : "folder_outline",
				checked: (d.caps || []).includes(cap),
				run: async () => {
					const caps = (d.caps || []).includes(cap) ? d.caps.filter(c => c !== cap) : [...(d.caps || []), cap];
					if (cap === "admin" && caps.includes("admin")) {
						const ok = await confirm({ title: `Make ${d.name} an admin?`, body: "An admin device may change every setting, add devices and users.", confirmLabel: "Make admin", danger: true, icon: "shield_account_outline" });
						if (!ok) return;
					}
					patch(d, { caps });
				}
			})) },
			{ label: "Kind", icon: "devices", children: ["pc", "laptop", "phone"].map(kind => ({ label: kind, icon: KIND_ICON[kind], checked: d.kind === kind, run: () => patch(d, { kind }) })) },
			{ separator: true },
			{ label: "Remove…", icon: "delete_outline", danger: true, run: () => remove(d) }
		], event.clientX, event.clientY);
	}

	async function patch(d, data) {
		try {
			await api.patch(`/api/devices/${encodeURIComponent(d.id)}`, data);
			toast("Saved", { icon: "check", timeout: 1200 });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function remove(d) {
		const ok = await confirm({ title: `Remove ${d.name}?`, body: "Its token stops working at once. A PC that is removed has to be set up again.", confirmLabel: "Remove", danger: true, icon: "delete_outline", typeToConfirm: (d.caps || []).includes("admin") ? d.name : undefined });
		if (!ok) return;
		try {
			await api.del(`/api/devices/${encodeURIComponent(d.id)}`);
			toast(`${d.name} removed`, { icon: "delete_outline" });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function wake(d, button) {
		button.classList.add("busy");
		try {
			await api.post("/api/wake", { device: d.id });
			toast(`Wake-up sent to ${d.name}`, { icon: "power", tone: "good", body: "It may take a minute to show up." });
			const card = button.closest(".device-card");
			animate(card, [{ boxShadow: "0 0 0 0 var(--primary)" }, { boxShadow: "0 0 0 14px transparent" }], { duration: 900, easing: "ease-out", fill: "none" });
		} catch (error) {
			errorToast(error);
		} finally {
			button.classList.remove("busy");
		}
	}

	if (!core) addBtn.addEventListener("click", async () => {
		const values = await formDialog({
			title: "Add a device",
			icon: "devices",
			intro: "It gets a token to talk to the NAS. The token is shown once – copy it into the device right away.",
			fields: [
				{ key: "name", label: "Name", type: "text", placeholder: "e.g. phone" },
				{ key: "kind", label: "Kind", type: "choice", default: "phone", choices: [{ value: "pc", label: "PC" }, { value: "laptop", label: "Laptop" }, { value: "phone", label: "Phone" }] },
				{ key: "files", label: "Files", type: "bool", default: true, hint: "Browse, upload, download" },
				{ key: "worker", label: "Computes", type: "bool", default: false, hint: "Takes tasks (thumbnails, conversions, AI)" },
				{ key: "admin", label: "Admin", type: "bool", default: false, hint: "Settings, devices, users – only for your own PC" },
				{ key: "mac", label: "MAC address (optional, for waking)", type: "text", placeholder: "aa:bb:cc:dd:ee:ff" }
			],
			confirmLabel: "Make the token"
		});
		if (!values) return;
		if (!values.name?.trim()) {
			toast("A device needs a name", { tone: "bad", icon: "alert_circle_outline" });
			return;
		}
		if (values.admin) {
			const ok = await confirm({ title: "An admin device?", body: "It may change every setting, add devices and users. Only your own PC should be one.", confirmLabel: "Yes, admin", danger: true, icon: "shield_account_outline" });
			if (!ok) return;
		}
		try {
			const caps = ["files", "worker", "admin"].filter(c => values[c]);
			const made = await api.post("/api/devices", { name: values.name.trim(), kind: values.kind, caps, mac: values.mac || undefined });
			showToken(made);
			load();
		} catch (error) {
			errorToast(error);
		}
	});

	async function showToken(made) {
		const { qrSvg } = await import("../../vendor/qrcode.js");
		const payload = JSON.stringify({ id: made.id, token: made.token, server_id: made.server_id, addresses: made.addresses });
		const token = h("div.token", made.token);
		const body = h("div.token-box",
			h("div.token-warn", icon("alert_outline"), h("div", "This token is shown only now. Whoever has it can do what the device may do.")),
			h("label.form-row", h("span", "Device id"), h("div.token", made.id)),
			h("label.form-row", h("span", "Token"), token),
			h("div.qr", { style: { margin: "0 auto" }, html: qrSvg(payload) }),
			h("div.form-hint", { style: { textAlign: "center" } }, "The QR holds id, token and the addresses (for the phone app)."));
		openDialog({
			title: `${made.name || "Device"} added`,
			icon: "key_outline",
			tone: "var(--warning)",
			body,
			dismissable: false,
			actions: [
				{ label: "Copy the token", icon: "content_copy", run: () => copyText(made.token).then(() => {
					toast("Token copied", { icon: "content_copy", timeout: 1400 });
					return false;
				}) },
				{ label: "I have it", primary: true }
			]
		});
	}

	const offs = [api.on("kv", data => data.ns === "devices" && load()), onStore("status", () => list.length && render())];
	load(true);
	return { el: root, title: "Devices", icon: "devices", unmount: () => offs.forEach(o => o()) };
}
