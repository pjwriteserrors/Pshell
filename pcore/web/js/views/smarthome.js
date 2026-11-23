// Smart home (docs/core.md "Smart home"): a canvas with the Tasmota plugs
// core reads and the devices put on it – from Home Assistant or the user's
// own (a name and an icon) – each hanging on the plug it is plugged into. A click opens a node, a cable pulled out of a
// plug's socket or a double click on the board puts a device there. All
// plugs hang on the provider in the notch at the top of the board: what
// they used and what that costs.
import { h, icon, clear, when, plural } from "../util.js";
import * as api from "../api.js";
import { isAdmin } from "../store.js";
import { stagger } from "../motion.js";
import { openDialog, confirm, toast, errorToast, prompt, showMenu, formDialog } from "../ui.js";
import { createCanvas, glideDialog } from "./smarthome-canvas.js";
import vacuumPage from "./vacuum.js";
import washerPage from "./washer.js";

const watts = w => (w == null ? "–" : w >= 1000 ? `${(w / 1000).toFixed(2)} kW` : `${Math.round(w)} W`);
const OWN_ICONS = ["monitor", "laptop", "television", "speaker", "headphones", "lightbulb", "fan", "coffee",
	"gamepad_variant", "printer_3d", "cellphone", "access_point", "server", "harddisk", "battery_charging", "devices"];
const euro = new Intl.NumberFormat(undefined, { style: "currency", currency: "EUR" });
const eur = v => (v == null ? "–" : euro.format(v));
const kwh = v => (v == null ? "–" : `${v < 10 ? v.toFixed(2) : v.toFixed(1)} kWh`);

// "docked" → "Docked", 21.5 °C → "21.5 °C"
function stateText(entity) {
	if (!entity || entity.state == null) return "";
	const value = String(entity.state);
	if (entity.unit) return `${value} ${entity.unit}`;
	const text = value.replace(/_/g, " ");
	return text.charAt(0).toUpperCase() + text.slice(1);
}

function signalIcon(dbm) {
	if (dbm == null) return "wifi";
	return dbm > -60 ? "wifi_strength_3" : dbm > -70 ? "wifi_strength_2" : "wifi_strength_1";
}

// the nodes as last seen, so a device's own page knows its name before it loads
const knownNodes = new Map();

// devices with a page of their own, by node.view.ui (hass.py), and the name their head morphs under
const PAGES = { vacuum: [vacuumPage, "vac-hero"], washer: [washerPage, "wm-hero"] };

export default function smarthome(route, app) {
	const id = route.parts[0];
	if (!id) return canvasPage(route, app);
	const known = knownNodes.get(id);
	if (PAGES[known?.view?.ui]) return PAGES[known.view.ui][0](route, app, known);
	return devicePage(route, app);
}

// a device's page opened straight from its address: which kind it is comes with the nodes
function devicePage(route, app) {
	const id = route.parts[0];
	const el = h("div.sh-device-host", { style: { position: "absolute", inset: "0" } });
	let inner = null;
	let gone = false;
	const view = {
		el,
		title: "Smart home",
		icon: "power_plug",
		tabTitle: () => inner?.tabTitle?.() || "Smart home",
		tabIcon: () => inner?.tabIcon?.() || "power_plug",
		crumbs: () => inner?.crumbs?.() || [{ label: "Smart home", icon: "power_plug", href: "/smarthome" }],
		refresh: () => inner?.refresh?.(),
		unmount: () => {
			gone = true;
			inner?.unmount?.();
		}
	};
	api.get("/api/smarthome").then(got => {
		(got.nodes || []).forEach(n => knownNodes.set(n.id, n));
		if (gone) return;
		const node = knownNodes.get(id);
		const page = PAGES[node?.view?.ui]?.[0];
		if (!page) {
			el.appendChild(h("div.empty", icon("devices"), h("h3", "This device has no page of its own"),
				h("a.btn.small", { href: "/smarthome" }, icon("arrow_left"), "Smart home")));
			return;
		}
		inner = page(route, app, node);
		el.appendChild(inner.el);
		inner.mounted?.();
		app.el?.top?.setTitle(view);
	}, error => {
		if (!gone) el.appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Smart home did not load"), h("p", error.message)));
	});
	return view;
}

function canvasPage(route, app) {
	const admin = isAdmin();
	let list = [];
	let nodes = [];
	let ha = { configured: false, connected: false };
	let provider = null;
	const sub = h("div.subtle", "");
	const haBtn = h("button.btn.small.sh-ha", { type: "button" }, h("span.live-dot.idle"), "Home Assistant");
	const centerBtn = h("button.icon-btn.small", { type: "button", title: "Center", "aria-label": "Center" }, icon("crop_free"));
	const addBtn = admin ? h("button.btn.primary.small", { type: "button" }, icon("plus"), "Add") : null;
	haBtn.addEventListener("click", () => (admin ? connectDialog() : null));
	centerBtn.addEventListener("click", () => board.fit());
	addBtn?.addEventListener("click", event => {
		const r = event.currentTarget.getBoundingClientRect();
		showMenu([
			{ label: "Device…", icon: "devices", run: () => pick(null, null) },
			{ label: "Search plugs…", icon: "radar", run: scan },
			{ label: "Plug by address…", icon: "lan", run: () => add() }
		], r.right - 220, r.bottom + 4, { keyboard: event.detail === 0 });
	});

	const notch = h("button.sh-notch", { type: "button", hidden: true });
	notch.addEventListener("click", () => {
		const r = notch.getBoundingClientRect();
		openProvider({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
	});

	const board = createCanvas({
		admin,
		notch,
		renderNode,
		onOpen: (id, kind, origin) => (kind === "plug" ? openPlug(id, origin) : openNode(id, origin)),
		onMenu: (id, kind, x, y) => (kind === "plug" ? plugMenu(list.find(d => d.id === id), x, y) : deviceMenu(nodes.find(n => n.id === id), x, y)),
		onWire: (id, x, y) => {
			const node = nodes.find(n => n.id === id);
			if (!node || !admin) return;
			showMenu([{ header: node.view?.name || "Device" }, { label: "Unplug", icon: "power_plug_off", run: () => setSocket(node, null) }], x, y);
		},
		onCable: (socket, id) => {
			const node = nodes.find(n => n.id === id);
			if (node && node.socket !== socket) setSocket(node, socket);
		},
		onEmpty: (at, socket) => pick(at, socket),
		onBackground: (at, x, y) => {
			if (!admin) return;
			showMenu([
				{ label: "Device…", icon: "devices", run: () => pick(at, null) },
				{ label: "Search plugs…", icon: "radar", run: scan },
				{ separator: true },
				{ label: "Center", icon: "crop_free", run: () => board.fit() }
			], x, y);
		},
		onSave: positions => api.put("/api/smarthome/layout", { positions }).catch(errorToast)
	});

	const root = h("div.sh-page",
		h("div.page-head.sh-head", h("div", h("h1", "Smart home"), sub), h("div.page-tools", haBtn, centerBtn, addBtn)),
		board.el);

	async function load(first) {
		try {
			const got = await api.get("/api/smarthome");
			list = api.listOf(got, "devices");
			nodes = got.nodes || [];
			nodes.forEach(n => knownNodes.set(n.id, n));
			ha = got.ha || ha;
			provider = got.provider || provider;
			render();
		} catch (error) {
			if (first) root.appendChild(h("div.empty.sh-failed", icon("power_plug"), h("h3", "Could not load the devices"), h("p", error.message)));
		}
	}

	function render() {
		const online = list.filter(d => d.online);
		const drawing = online.reduce((sum, d) => sum + (d.reading?.power || 0), 0);
		sub.textContent = list.length ? `${plural(list.length, "plug")} · ${watts(drawing)} now` : "";
		haBtn.querySelector(".live-dot").className = `live-dot ${ha.connected ? "open" : ha.configured ? "closed" : "idle"}`;
		haBtn.title = ha.connected ? `Home Assistant ${ha.version || ""}`.trim() : ha.error || "";
		notch.hidden = !list.length || !provider;
		if (!notch.hidden) renderProvider(notch, provider);
		board.sync(list, nodes);
	}

	// ── nodes ──
	function bars(days, tall) {
		const top = Math.max(...days.map(d => d.kwh), 0.001);
		const last = days.length - 1;
		return h(`div.sh-bars${tall ? ".tall" : ""}`, days.map((d, i) => h(`span${i === last ? ".today" : ""}`, {
			style: { height: `${Math.max(3, (d.kwh / top) * 100)}%` },
			title: `${new Date(d.day).toLocaleDateString(undefined, { day: "numeric", month: "short" })} · ${kwh(d.kwh)}`
		})));
	}

	// the month against the payment: + more to pay, − back
	function difference(p) {
		if (p.difference == null) return null;
		const more = p.difference < 0;
		return h(`span.sh-diff.${more ? "bad" : "good"}`, `${more ? "+" : "−"}${eur(Math.abs(p.difference))}`);
	}

	// the provider in the notch: who, how much now, the month's forecast against the payment, 30 days
	function renderProvider(el, p) {
		const priced = p.price != null;
		clear(el).append(
			h("span.sh-notch-id",
				h("span.sh-dev-icon", icon("lightning_bolt")),
				h("span.sh-dev-text", h("strong.ellipsis", p.name || "Provider"), h("span", watts(p.now)))),
			h("span.sh-figure.main", h("span.subtle", "Forecast"), h("strong", priced ? eur(p.forecast_cost) : kwh(p.forecast))),
			h("span.sh-figure.so-far", h("span.subtle", "So far"), h("strong", priced ? eur(p.cost) : kwh(p.month))),
			p.monthly != null ? h("span.sh-figure", h("span.subtle", "Payment"), h("strong", eur(p.monthly)), difference(p)) : null,
			bars(p.days || []));
	}

	function renderNode(el, kind, item) {
		if (kind === "plug") {
			const r = item.reading || {};
			const value = item.online && item.energy ? watts(r.power) : "–";
			const problem = !item.online ? (item.error === "password" ? "lock_outline" : "wifi_off") : null;
			el.classList.toggle("online", !!item.online);
			el.classList.toggle("off", item.on === false);
			clear(el).append(
				h("div.sh-plug",
					h("span.sh-plug-icon", icon(problem || (item.on === false ? "power_plug_off" : "power_plug"))),
					h("strong.sh-watts", value),
					admin ? h("span.sh-port", { title: "Plug in a device" }) : null),
				h("div.sh-label", item.name));
			return;
		}
		const d = item.view || {};
		el.classList.toggle("gone", d.known === false);
		el.classList.toggle("away", d.available === false);
		clear(el).append(
			h("div.sh-dev",
				h("span.sh-dev-icon", icon(d.known === false ? "help_circle_outline" : d.icon || "devices")),
				h("span.sh-dev-text",
					h("strong.ellipsis", d.name || "Unknown device"),
					item.kind === "own" ? null : h("span.ellipsis", d.known === false ? "Not in Home Assistant" : d.available === false ? "Unavailable" : stateText(d.head)))));
	}

	function deviceMenu(node, x, y) {
		if (!node || !admin) return;
		const sockets = list.map(d => ({ label: d.name, icon: node.socket === d.id ? "check" : "power_plug", run: () => setSocket(node, d.id) }));
		if (node.socket) sockets.push({ separator: true }, { label: "Unplug", icon: "power_plug_off", run: () => setSocket(node, null) });
		showMenu([
			{ header: node.view?.name || "Device" },
			{ label: "Open", icon: "open_in_new", run: () => openNode(node.id) },
			{ label: "Socket", icon: "power_plug", children: sockets.length ? sockets : [{ label: "No plugs", enabled: false }] },
			node.kind === "own" ? { label: "Rename…", icon: "form_textbox", run: async () => {
				const name = await prompt({ title: "Rename", label: "Name", value: node.view.name, icon: "form_textbox", confirmLabel: "Rename" });
				if (name && name !== node.view.name) changeNode(node, { name });
			} } : null,
			node.kind === "own" ? { label: "Icon", icon: node.view.icon, children: OWN_ICONS.map(name => ({ label: name.replace(/_/g, " "), icon: name, run: () => changeNode(node, { icon: name }) })) } : null,
			{ separator: true },
			{ label: "Take off", icon: "delete_outline", danger: true, run: () => takeOff(node) }
		], x, y);
	}

	function plugMenu(d, x, y) {
		if (!d || !admin) return;
		menu(d, { currentTarget: { getBoundingClientRect: () => ({ right: x + 220, bottom: y - 4 }) }, detail: 1 });
	}

	async function changeNode(node, data) {
		try {
			await api.patch(`/api/smarthome/nodes/${encodeURIComponent(node.id)}`, data);
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	const setSocket = (node, socket) => changeNode(node, { socket });

	async function takeOff(node) {
		try {
			await api.del(`/api/smarthome/nodes/${encodeURIComponent(node.id)}`);
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	// ── the provider opened: what it costs, per plug, and the tariff ──
	function openProvider(origin) {
		const body = h("div.sh-detail");
		const dialog = openDialog({ title: provider?.name || "Provider", icon: "lightning_bolt", body, origin, className: "sh-dialog" });
		glideDialog(dialog);
		const field = (key, label, suffix, step) => {
			const input = h("input", { type: key === "name" ? "text" : "number", min: 0, step, value: provider?.[key] ?? "", autocomplete: "off", disabled: !admin });
			input.addEventListener("change", async () => {
				try {
					provider = (await api.patch("/api/smarthome/provider", { [key]: key === "name" ? input.value : input.value === "" ? null : Number(input.value) })).provider;
					render();
					fill();
				} catch (error) {
					errorToast(error);
				}
			});
			return h("label.sh-tariff-field", h("span.subtle", label), h("div.field", input, suffix ? h("span.subtle", suffix) : null));
		};
		const tariff = h("div.sh-tariff",
			field("name", "Name"), field("monthly", "Monthly payment", "€", "0.01"),
			field("price", "Price", "ct/kWh", "0.01"), field("base", "Base fee", "€/month", "0.01"));
		const live = h("div.sh-detail");
		const fill = () => {
			const p = provider;
			if (!p) return;
			const priced = p.price != null;
			const total = (p.plugs || []).reduce((sum, x) => sum + x.kwh, 0) || 1;
			clear(live).append(
				h("div.sh-prov-money.big",
					h("div", h("span.subtle", "Forecast"), h("strong.sh-prov-big", priced ? eur(p.forecast_cost) : kwh(p.forecast)), priced ? h("span.subtle", kwh(p.forecast)) : null),
					h("div", h("span.subtle", "So far"), h("strong", priced ? eur(p.cost) : kwh(p.month)), priced ? h("span.subtle", kwh(p.month)) : null),
					p.monthly != null ? h("div", h("span.subtle", "Payment"), h("strong", eur(p.monthly)), difference(p)) : null,
					h("div", h("span.subtle", "Last month"), h("strong", kwh(p.last_month)), priced ? h("span.subtle", eur(p.last_month * p.price / 100 + (p.base || 0))) : null)),
				bars(p.days || [], true),
				h("div.list-card.sh-share", (p.plugs || []).slice().sort((a, b) => b.kwh - a.kwh).map(x => {
					const plug = list.find(d => d.id === x.id);
					return h("div.sh-share-row",
						h("span.ellipsis", plug?.name || x.id),
						h("span.sh-share-bar", h("span", { style: { width: `${(x.kwh / total) * 100}%` } })),
						h("strong", kwh(x.kwh)),
						priced ? h("span.subtle", eur(x.kwh * p.price / 100)) : null);
				})));
		};
		body.append(live, tariff);
		fill();
		const off = api.on("smarthome", data => {
			if (data.provider) fill();
		});
		dialog.done.then(off);
	}

	// ── a node opened ──
	function openPlug(id, origin) {
		const d = list.find(x => x.id === id);
		if (!d) return;
		const holder = h("div.sh-detail", card(d));
		const dialog = openDialog({ title: d.name, icon: "power_plug", body: holder, origin, className: "sh-dialog" });
		glideDialog(dialog);
		const off = api.on("smarthome", data => {
			const fresh = (data.devices || []).find(x => x.id === id);
			if (fresh) clear(holder).appendChild(card(fresh));
		});
		dialog.done.then(off);
	}

	// a device with a page of its own grows into it (the card becomes the page's head)
	function openNode(id, origin) {
		const node = nodes.find(n => n.id === id);
		const page = PAGES[node?.view?.ui];
		if (!page) return openDevice(id, origin);
		const card = board.el.querySelector(`.sh-node[data-id="${CSS.escape(id)}"] .sh-dev`);
		if (card) card.style.viewTransitionName = page[1];
		app.go(`/smarthome/${encodeURIComponent(id)}`);
	}

	function openDevice(id, origin) {
		const node = nodes.find(n => n.id === id);
		if (!node) return;
		const d = node.view || {};
		const body = h("div.sh-detail");
		const dialog = openDialog({ title: d.name || "Device", subtitle: [d.model, d.manufacturer].filter(Boolean).join(" · "),
			icon: d.icon || "devices", body, origin, className: "sh-dialog" });
		glideDialog(dialog);
		const fill = async () => {
			try {
				const got = (await api.get(`/api/smarthome/nodes/${encodeURIComponent(id)}`)).node;
				const socket = list.find(p => p.id === got.socket);
				clear(body).append(
					h("div.sh-socket", icon(socket ? "power_plug" : "power_plug_off"),
						h("span.grow", socket ? socket.name : "No socket"),
						socket?.online && socket.energy ? h("strong", watts(socket.reading?.power)) : null),
					got.view.list?.length ? h("div.list-card.sh-entities", got.view.list.map(e => h("div.list-row",
						h("div.row-main", h("div.row-title", h("span.ellipsis", e.name))),
						h("div.row-side", h("span.sh-state", stateText(e)))))) : null);
			} catch (error) {
				clear(body).appendChild(h("div.empty", icon("alert_circle_outline"), h("p", error.message)));
			}
		};
		fill();
		let timer = 0;
		const off = api.on("smarthome", () => {
			clearTimeout(timer);
			timer = setTimeout(fill, 400);
		});
		dialog.done.then(() => {
			off();
			clearTimeout(timer);
		});
	}

	// ── a device of Home Assistant onto the board ──
	async function pick(at, socket) {
		const holder = h("div.sh-pick");
		const dialog = openDialog({ title: "Add a device", icon: "devices", body: holder, className: "sh-dialog",
			origin: at ? board.toScreen(at.x, at.y) : undefined });
		glideDialog(dialog);
		let made = false;

		async function showList() {
			clear(holder).appendChild(h("div.plug-scanning", icon("radar"), h("span", "Loading…")));
			let devices;
			try {
				devices = (await api.get("/api/smarthome/ha/devices")).devices;
			} catch (error) {
				if (error.code === "ha_offline") return showOwn("");
				clear(holder).appendChild(h("div.empty", icon("alert_circle_outline"), h("p", error.message)));
				return;
			}
			const search = h("input", { placeholder: "Search", autocomplete: "off", spellcheck: false, autofocus: true });
			const rows = h("div.sh-pick-list");
			const fill = () => {
				const q = search.value.trim().toLowerCase();
				clear(rows);
				const shown = devices.filter(d => !q || `${d.name} ${d.model || ""} ${d.manufacturer || ""}`.toLowerCase().includes(q));
				const own = h("button.sh-pick-row.own", { type: "button" },
					h("span.sh-dev-icon", icon("plus")),
					h("span.sh-dev-text", h("strong.ellipsis", search.value.trim() || "Own device")));
				own.addEventListener("click", () => showOwn(search.value.trim(), true));
				rows.appendChild(own);
				for (const d of shown) {
					const row = h(`button.sh-pick-row${d.added ? ".added" : ""}`, { type: "button", disabled: d.added },
						h("span.sh-dev-icon", icon(d.icon || "devices")),
						h("span.sh-dev-text", h("strong.ellipsis", d.name), h("span.ellipsis", [d.model, d.manufacturer].filter(Boolean).join(" · "))),
						d.added ? icon("check") : h("span.sh-state", d.available === false ? "Unavailable" : stateText(d.head)));
					row.addEventListener("click", () => choose(d, row));
					rows.appendChild(row);
				}
			};
			search.addEventListener("input", fill);
			clear(holder).append(h("div.field", icon("magnify"), search), rows);
			fill();
			stagger(rows.children, { step: 22, distance: 10 });
			setTimeout(() => search.focus(), 40);
		}

		// a device of the user's own: a name and an icon
		function showOwn(name, fromList) {
			let chosen = "devices";
			const field = h("input", { value: name, placeholder: "Name", autocomplete: "off", spellcheck: false });
			const icons = h("div.sh-icons", OWN_ICONS.map(n => {
				const b = h(`button.icon-btn.sh-icon-choice${n === chosen ? ".on" : ""}`, { type: "button", title: n.replace(/_/g, " "), "aria-label": n.replace(/_/g, " ") }, icon(n));
				b.addEventListener("click", () => {
					chosen = n;
					icons.querySelectorAll(".on").forEach(x => x.classList.remove("on"));
					b.classList.add("on");
				});
				return b;
			}));
			const go = h("button.btn.primary", { type: "button" }, icon("plus"), "Add");
			const other = fromList
				? h("button.btn.ghost", { type: "button", onclick: showList }, icon("arrow_left"), "Home Assistant")
				: h("button.btn.ghost", { type: "button", onclick: () => showConnect(holder, showList) }, icon("home_outline"), "Home Assistant");
			const run = () => {
				if (!field.value.trim()) return field.focus();
				choose({ name: field.value.trim(), icon: chosen }, go);
			};
			go.addEventListener("click", run);
			field.addEventListener("keydown", event => {
				if (event.key === "Enter") {
					event.preventDefault();
					run();
				}
			});
			clear(holder).append(h("div.field", icon("form_textbox"), field), icons, h("div.sh-own-go", admin ? other : null, go));
			setTimeout(() => field.focus(), 40);
		}

		async function choose(d, row) {
			row.classList.add("busy");
			try {
				const spot = at ? [at.x, at.y] : await centerSpot();
				await api.post("/api/smarthome/nodes", d.id ? { device: d.id, at: spot, socket } : { name: d.name, icon: d.icon, at: spot, socket });
				made = true;
				dialog.close();
				await load();
			} catch (error) {
				row.classList.remove("busy");
				errorToast(error);
			}
		}

		async function centerSpot() {
			const r = board.el.getBoundingClientRect();
			const w = board.toScreen(0, 0);
			const k = board.toScreen(1, 0).x - w.x;
			return [(r.left + r.width / 2 - w.x) / k, (r.top + r.height / 2 - w.y) / k];
		}

		if (ha.connected) showList();
		else showOwn("");
		await dialog.done;
		return made;
	}

	// the address and a long-lived token of Home Assistant
	function showConnect(holder, then) {
		const url = h("input", { value: ha.url || "http://127.0.0.1:8123", autocomplete: "off", spellcheck: false });
		const token = h("input", { type: "password", placeholder: ha.configured ? "••••••••" : "Long-lived access token", autocomplete: "off" });
		const error = h("div.sh-error", ha.configured && ha.error ? ha.error : "");
		const go = h("button.btn.primary", { type: "button" }, icon("link_variant"), "Connect");
		const run = async () => {
			if (go.classList.contains("busy")) return;
			go.classList.add("busy");
			error.textContent = "";
			try {
				const got = await api.put("/api/smarthome/ha", { url: url.value.trim(), token: token.value.trim() });
				ha = got.ha;
				render();
				then?.();
			} catch (e) {
				error.textContent = e.message;
			} finally {
				go.classList.remove("busy");
			}
		};
		go.addEventListener("click", run);
		token.addEventListener("keydown", event => {
			if (event.key === "Enter") {
				event.preventDefault();
				run();
			}
		});
		clear(holder).append(h("div.sh-connect",
			h("label.sh-field-label", "Address"), h("div.field", icon("lan"), url),
			h("label.sh-field-label", "Token"), h("div.field", icon("key_variant"), token),
			error, h("div.sh-connect-go", go)));
		setTimeout(() => (ha.configured ? go : token).focus(), 40);
	}

	function connectDialog() {
		const holder = h("div.sh-pick");
		const dialog = openDialog({ title: "Home Assistant", icon: "home_outline", body: holder, className: "sh-dialog",
			actions: ha.configured ? [{ label: "Disconnect", danger: true, ghost: true, run: async () => {
				ha = (await api.del("/api/smarthome/ha")).ha;
				render();
			} }] : [] });
		glideDialog(dialog);
		showConnect(holder, () => dialog.close());
	}

	// a plug, opened: what it draws now, today and in all
	function card(d) {
		const r = d.reading || {};
		const info = d.info || {};
		const state = d.on == null ? null : h(`span.chip.small${d.on ? ".good" : ""}`, icon(d.on ? "power_plug" : "power_plug_off"), d.on ? "On" : "Off");
		const problem = !d.online ? h("span.chip.small.bad", icon(d.error === "password" ? "lock_outline" : "wifi_off"), d.error === "password" ? "Password" : "Offline") : null;
		return h(`div.plug-card${d.online ? ".online" : ""}`,
			h("div.plug-now", h("span.plug-watts", d.online && d.energy ? watts(r.power) : "–"), state, problem,
				admin ? h("button.icon-btn.small", { title: "More", "aria-label": `${d.name}: more`, onclick: event => menu(d, event) }, icon("dots_vertical")) : null),
			d.energy ? h("div.plug-stats",
				stat("Today", kwh(r.today)), stat("Yesterday", kwh(r.yesterday)), stat("Total", kwh(r.total)),
				stat("Voltage", r.voltage == null ? "–" : `${r.voltage} V`), stat("Current", r.current == null ? "–" : `${r.current.toFixed(2)} A`), stat("Factor", r.factor == null ? "–" : r.factor.toFixed(2))) : null,
			h("div.device-foot",
				h("span.device-seen", icon(signalIcon(info.signal)), info.signal != null ? `${info.signal} dBm${info.ssid ? ` · ${info.ssid}` : ""}` : d.seen ? `Seen ${when(d.seen)}` : "Never seen"),
				h("span.subtle", [d.host, info.firmware ? `Tasmota ${String(info.firmware).replace(/\(.*$/, "")}` : ""].filter(Boolean).join(" · "))));
	}

	const stat = (label, value) => h("div.plug-stat", h("span.subtle", label), h("strong", value));

	function menu(d, event) {
		const r = event.currentTarget.getBoundingClientRect();
		showMenu([
			{ header: d.name },
			{ label: "Rename…", icon: "form_textbox", run: async () => {
				const name = await prompt({ title: "Rename", label: "Name", value: d.name, icon: "form_textbox", confirmLabel: "Rename" });
				if (name && name !== d.name) patch(d, { name });
			} },
			{ label: "Address…", icon: "lan", run: async () => {
				const host = await prompt({ title: "Address", label: "IP address", value: d.host, icon: "lan", confirmLabel: "Save" });
				if (host && host !== d.host) patch(d, { host });
			} },
			{ label: "Web password…", icon: "key_variant", run: async () => {
				const values = await formDialog({ title: "Web password", icon: "key_variant", confirmLabel: "Save",
					fields: [{ key: "user", label: "User", default: "admin" }, { key: "password", label: "Password", type: "password" }] });
				if (values) patch(d, values);
			} },
			{ separator: true },
			{ label: "Calibrate…", icon: "tune_variant", run: () => calibrate(d) },
			d.calibrated ? { label: "Undo calibration", icon: "undo", run: () => calibrateCall(d, { reset: true }, "Calibration undone") } : null,
			{ separator: true },
			{ label: "Remove…", icon: "delete_outline", danger: true, run: () => remove(d) }
		], r.right - 220, r.bottom + 4, { keyboard: event.detail === 0 });
	}

	async function patch(d, data) {
		try {
			await api.patch(`/api/smarthome/devices/${encodeURIComponent(d.id)}`, data);
			toast("Saved", { icon: "check", tone: "good", timeout: 1400 });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function calibrate(d) {
		const values = await formDialog({ title: `Calibrate ${d.name}`, icon: "tune_variant", confirmLabel: "Calibrate",
			values: { voltage: 230 },
			fields: [
				{ key: "voltage", label: "Mains voltage", type: "number", suffix: "V", min: 90, max: 260 },
				{ key: "power", label: "Resistive load", type: "number", suffix: "W", min: 5, max: 4000, placeholder: "60" }
			] });
		if (!values) return;
		const body = {};
		if (values.voltage !== "") body.voltage = values.voltage;
		if (values.power !== "") body.power = values.power;
		calibrateCall(d, body, "Calibrated");
	}

	async function calibrateCall(d, body, message) {
		try {
			await api.post(`/api/smarthome/devices/${encodeURIComponent(d.id)}/calibrate`, body);
			toast(message, { icon: "check", tone: "good", timeout: 1600 });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function remove(d) {
		const ok = await confirm({ title: `Remove ${d.name}?`, confirmLabel: "Remove", danger: true, icon: "delete_outline" });
		if (!ok) return;
		try {
			await api.del(`/api/smarthome/devices/${encodeURIComponent(d.id)}`);
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	async function add(preset = {}) {
		const values = await formDialog({ title: "Add a plug", icon: "power_plug", confirmLabel: "Add", values: preset,
			fields: [
				{ key: "host", label: "IP address", placeholder: "192.168.178.…", icon: "lan" },
				{ key: "name", label: "Name", placeholder: preset.suggested || "" },
				{ key: "password", label: "Web password", type: "password", shown: () => !!preset.locked || !!preset.askPassword }
			] });
		if (!values?.host) return;
		try {
			const body = { host: values.host.trim() };
			if (values.name) body.name = values.name;
			if (values.password) body.password = values.password;
			const got = await api.post("/api/smarthome/devices", body);
			toast(`${got.device.name} added`, { icon: "power_plug", tone: "good" });
			load();
		} catch (error) {
			if (error.code === "password") return add({ ...values, locked: true });
			errorToast(error);
		}
	}

	async function scan() {
		const listEl = h("div.list-card.plug-found", h("div.plug-scanning", icon("radar"), h("span", "Searching…")));
		const dialog = openDialog({ title: "Plugs on the network", icon: "radar", body: listEl, actions: [{ label: "Close", ghost: true }] });
		try {
			const got = await api.post("/api/smarthome/scan", {});
			clear(listEl);
			if (!got.found.length) {
				listEl.appendChild(h("div.empty", icon("power_plug_off"), h("h3", "None found"), h("p", got.subnet)));
				return;
			}
			for (const f of got.found) {
				const action = f.known
					? h("span.chip.small.good", icon("check"), "Added")
					: h("button.btn.small.primary", { type: "button", onclick: () => {
						dialog?.close?.();
						add({ host: f.host, suggested: f.name, locked: f.locked });
					} }, icon("plus"), "Add");
				listEl.appendChild(h("div.list-row",
					h("div.row-icon", icon(f.locked ? "lock_outline" : "power_plug")),
					h("div.row-main", h("div.row-title", h("span.ellipsis", f.name || f.host)), h("div.row-sub", [f.host, f.mac, f.hardware].filter(Boolean).join(" · "))),
					h("div.row-side", action)));
			}
			load();
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Search failed"), h("p", error.message)));
		}
	}

	const offs = [api.on("smarthome", data => {
		if (Array.isArray(data.devices)) list = data.devices;
		if (Array.isArray(data.nodes)) {
			nodes = data.nodes;
			nodes.forEach(n => knownNodes.set(n.id, n));
		}
		if (data.ha) ha = data.ha;
		if (data.provider) provider = data.provider;
		render();
	})];
	load(true);
	return { el: root, title: "Smart home", icon: "power_plug", refresh: load, unmount: () => {
		offs.forEach(o => o());
		board.destroy();
	} };
}
