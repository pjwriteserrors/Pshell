// A robot vacuum of Home Assistant on its own page (/smarthome/<node>, docs/core.md
// "Smart home"): what it does now and the buttons for it on top, the real map
// (rooms to pick, a zone, a point, driving it), mode, station, runs and care,
// and every deeper setting folded away below. Everything comes from
// /api/smarthome/nodes/<id>/vacuum (entities by short keys, vacuum.py) and
// moves with event `hass`; the map comes again when its camera moves on.
import { h, icon, clear, when } from "../util.js";
import * as api from "../api.js";
import { isAdmin } from "../store.js";
import { animate, EASE, stagger, countUp, reduced } from "../motion.js";
import { toast, errorToast, segmented, toggle, showMenu } from "../ui.js";

const SVG = "http://www.w3.org/2000/svg";
const svg = (tag, attrs = {}, parent) => {
	const el = document.createElementNS(SVG, tag);
	for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
	parent?.appendChild(el);
	return el;
};
const cap = s => (s ? s.charAt(0).toUpperCase() + s.slice(1) : "");
const WORDS = {
	sweeping: "Vacuum", mopping: "Mop", sweeping_and_mopping: "Both", mopping_after_sweeping: "Mop after",
	quiet: "Quiet", standard: "Standard", strong: "Strong", turbo: "Turbo", slightly_dry: "Slightly dry", moist: "Moist", wet: "Wet",
	quick: "Quick", off: "Off", in_deep_mode: "Deep mode", in_all_modes: "Always", avoidance: "Avoid", adaptation: "Adapt",
	vacuum_and_mop: "Vacuum & mop", ignore: "Ignore", high_frequency: "Often", low_frequency: "Rarely", by_area: "Area",
	by_time: "Time", by_room: "Room", light: "Light", deep: "Deep", intelligent: "Smart", high: "High",
	routine_cleaning: "Genius", deep_cleaning: "Deep", mop_after_vacuum: "Mop after", "1x": "1×", "2x": "2×", "3x": "3×",
	horizontal: "Across", vertical: "Along", visible: "Shown", hidden: "Hidden"
};
const word = v => WORDS[v] ?? cap(String(v ?? "").replace(/_/g, " "));
const MODE_ICON = { sweeping: "fan", mopping: "water_outline", sweeping_and_mopping: "broom", mopping_after_sweeping: "sync" };
const ROOM_TONES = ["var(--primary)", "var(--secondary)", "var(--tertiary)", "var(--success)", "var(--warning)", "var(--danger)"];
const PARTS = [
	{ key: "main_brush", name: "Main brush", icon: "broom", reset: "button.reset_main_brush" },
	{ key: "side_brush", name: "Side brush", icon: "fan", reset: "button.reset_side_brush" },
	{ key: "filter", name: "Filter", icon: "weather_windy", reset: "button.reset_filter" },
	{ key: "sensor_dirty", name: "Sensors", icon: "eye_outline", reset: "button.reset_sensor" },
	{ key: "wheel_dirty", name: "Wheel", icon: "sync", reset: "button.reset_wheel" }
];
const PHASE = {
	offline: ["is offline", "var(--text-subtle)"], docked: ["is docked", "var(--success)"], idle: ["is waiting", "var(--primary)"],
	cleaning: ["is cleaning", "var(--primary)"], mapping: ["maps the home", "var(--primary)"], paused: ["paused", "var(--warning)"],
	returning: ["goes home", "var(--secondary)"], washing: ["washes its mop", "var(--primary)"], drying: ["dries its mop", "var(--warning)"],
	emptying: ["empties its bin", "var(--tertiary)"], error: ["needs help", "var(--danger)"], remote: ["is driven by you", "var(--secondary)"]
};
const glyphOf = mdi => String(mdi || "").replace(/^mdi:/, "").replace(/-/g, "_");

export default function vacuumPage(route, app, known) {
	const id = route.parts[0];
	const admin = isAdmin();
	const E = {};                 // short key → {s, a, c, id, off}
	const byId = {};              // entity id → short key
	let node = known || null;
	let map = null;
	let mapVersion = null;
	let mapTimer = 0;
	let gone = false;
	const ui = { tool: "rooms", rooms: [], zone: null, zoneRep: 1, pin: null, remote: false };
	const binders = [];           // repaint functions of the parts that follow the entities

	const st = k => E[k]?.s;
	const at = k => E[k]?.a || {};
	const has = k => !!E[k] && !E[k].off;
	const live = k => has(k) && E[k].s !== "unavailable" && E[k].s !== "unknown" && E[k].s != null;
	const num = k => {
		const v = parseFloat(st(k));
		return Number.isFinite(v) ? v : null;
	};

	async function call(service, key, data) {
		if (!admin) {
			toast("Only admins can steer it", { icon: "lock_outline", tone: "warn" });
			throw new Error("not admin");
		}
		try {
			await api.post(`/api/smarthome/nodes/${encodeURIComponent(id)}/vacuum/call`, { service, entity: key ? E[key]?.id : undefined, data });
		} catch (error) {
			errorToast(error);
			throw error;
		}
	}
	// a setting changed here shows at once; Home Assistant's answer comes as event hass
	async function set(key, value, service, data) {
		const before = E[key]?.s;
		if (E[key]) E[key].s = value;
		paint();
		try {
			await call(service, key, data);
		} catch (error) {
			if (E[key]) E[key].s = before;
			paint();
		}
	}
	const setSelect = (key, option) => set(key, option, key.startsWith("input_select.") ? "input_select.select_option" : "select.select_option", { option });
	const setSwitch = (key, on) => {
		const domain = key.split(".")[0];
		return set(key, on ? "on" : "off", `${domain}.turn_${on ? "on" : "off"}`, {});
	};
	const setNumber = (key, value) => set(key, String(value), "number.set_value", { value });
	const press = key => call("button.press", key, {}).then(() => true, () => false);

	// ── the frame ──
	const page = h("div.vac-page");
	const root = h("div.page-scroll.vac-scroll", page);

	// ══ HERO ══════════════════════════════════════════════════════════════
	const ring = svg("circle", { class: "vac-ring", cx: 66, cy: 66, r: 60, pathLength: 100, "stroke-dasharray": 100, "stroke-dashoffset": 100 });
	const botSvg = svg("svg", { class: "vac-bot", viewBox: "0 0 132 132" });
	svg("circle", { class: "vac-ring-bg", cx: 66, cy: 66, r: 60 }, botSvg);
	botSvg.appendChild(ring);
	svg("circle", { class: "vac-shimmer", cx: 66, cy: 66, r: 60, pathLength: 100, "stroke-dasharray": "6 94" }, botSvg);
	const body = svg("g", { class: "vac-body" }, botSvg);
	svg("path", { class: "vac-beam", d: "M66 54 L110 34 A48 48 0 0 1 112 66 Z" }, body);
	svg("circle", { class: "vac-shell", cx: 66, cy: 66, r: 38 }, body);
	svg("path", { class: "vac-bumper", d: "M38 50 A36 36 0 0 1 94 50" }, body);
	svg("circle", { class: "vac-lidar", cx: 66, cy: 54, r: 10 }, body);
	svg("circle", { class: "vac-eye", cx: 66, cy: 54, r: 3 }, body);
	for (const x of [44, 88]) {
		const brush = svg("g", { class: "vac-brush" }, body);
		svg("line", { x1: x, y1: 77, x2: x, y2: 93 }, brush);
		svg("line", { x1: x - 7, y1: 89, x2: x + 7, y2: 81 }, brush);
		svg("line", { x1: x - 7, y1: 81, x2: x + 7, y2: 89 }, brush);
	}
	const zz = [svg("text", { class: "vac-zz", x: 98, y: 34 }, botSvg), svg("text", { class: "vac-zz", x: 106, y: 26 }, botSvg)];
	zz.forEach(z => (z.textContent = "z"));
	const battIcon = h("span.vac-batt-icon", icon("battery_charging"));
	const battText = h("span.vac-num", "–");
	const titleBox = h("div.vac-swap");
	const subBox = h("div.vac-swap");
	const fact = (label) => {
		const value = h("b.vac-num", "–");
		const unit = h("small");
		const name = h("span", label);
		const el = h("div.vac-fact", h("div.vac-fact-v", value, unit), name);
		return { el, value, unit, name };
	};
	const fArea = fact("Last run");
	const fTime = fact("Time");
	const fRoom = fact("Room");
	const fWifi = fact("Wi-Fi");
	const progress = h("div.vac-progress", h("i"));
	const ctlDock = h("button.vac-ctl.round", { type: "button", title: "Station", "aria-label": "Station" }, icon("home"));
	const ctlStop = h("button.vac-ctl.round", { type: "button", title: "Stop", "aria-label": "Stop" }, icon("stop"));
	const mainIcon = h("span.vac-main-icon", icon("play"));
	const mainLabel = h("span.vac-swap.vac-main-label");
	const ctlMain = h("button.vac-ctl.main", { type: "button" }, mainIcon, mainLabel);
	const hero = h("section.vac-hero",
		h("div.vac-bot-wrap", botSvg, h("div.vac-batt", battIcon, battText)),
		h("div.vac-status", titleBox, subBox, h("div.vac-facts", fArea.el, fTime.el, fRoom.el, fWifi.el), progress),
		h("div.vac-controls", ctlDock, ctlStop, ctlMain));
	hero.style.viewTransitionName = "vac-hero";

	function swap(box, text, html) {
		const current = box.querySelector(":scope > :not(.out)");
		if (current && current.dataset.text === text) return;
		if (current) {
			current.classList.add("out");
			setTimeout(() => current.remove(), 340);
		}
		const next = h("span.in", { dataset: { text } });
		if (html) next.innerHTML = html;
		else next.textContent = text;
		box.appendChild(next);
	}

	// ══ MAP ═══════════════════════════════════════════════════════════════
	const toolSeg = segmented([
		{ value: "rooms", label: "Rooms", icon: "gesture_tap" },
		{ value: "zone", label: "Zone", icon: "selection_drag" },
		{ value: "point", label: "Point", icon: "map_marker" },
		{ value: "drive", label: "Drive", icon: "gamepad_variant" }
	], "rooms", v => setTool(v));
	toolSeg.classList.add("vac-tools");
	const mapSvg = svg("svg", { class: "vac-map-svg" });
	const defs = svg("defs", {}, mapSvg);
	const soft = svg("filter", { id: `vac-soft-${id}`, x: "-10%", y: "-10%", width: "120%", height: "120%" }, defs);
	svg("feGaussianBlur", { stdDeviation: "0.75" }, soft);
	const transfer = svg("feComponentTransfer", {}, soft);
	svg("feFuncA", { type: "table", tableValues: "0 0 1 1" }, transfer);
	const gRooms = svg("g", { class: "vac-rooms" }, mapSvg);
	const gWalls = svg("path", { class: "vac-walls", filter: `url(#vac-soft-${id})` }, mapSvg);
	const gBand = svg("path", { class: "vac-band" }, mapSvg);
	const gPath = svg("path", { class: "vac-path" }, mapSvg);
	const gZones = svg("g", { class: "vac-zones" }, mapSvg);
	const gPick = svg("g", {}, mapSvg);
	const overlay = h("div.vac-overlay");
	const world = h("div.vac-world", mapSvg, overlay);
	const robotEl = h("div.vac-robot.vac-pin", h("span.vac-robot-halo"), h("span.vac-robot-disc", h("span.vac-robot-nose")));
	const chargerEl = h("div.vac-charger.vac-pin", icon("lightning_bolt"));
	const zonePop = h("div.vac-zone-pop.vac-pin");
	const joyKnob = h("div.vac-joy-knob");
	const joy = h("div.vac-joy", ["arrow_up", "arrow_down", "arrow_left", "arrow_right"].map(n => h(`span.vac-joy-ar.${n}`, icon(n))), joyKnob);
	const fitBtn = h("button.icon-btn.small", { type: "button", title: "Fit", "aria-label": "Fit" }, icon("crosshairs_gps"));
	const pathBtn = h("button.icon-btn.small.on", { type: "button", title: "Path", "aria-label": "Path" }, icon("vector_curve"));
	const mapBox = h("div.vac-map", world, h("div.vac-map-float", pathBtn, fitBtn), joy, h("div.vac-map-empty", icon("map_outline")));
	const seq = h("div.vac-seq");
	const mapNotch = h("div.vac-notch", toolSeg);
	const mapCard = h("section.vac-card.vac-map-card", notchShape(), mapNotch, mapBox, seq);

	// ══ MODE ══════════════════════════════════════════════════════════════
	const scopeSeg = segmented([{ value: "all", label: "All rooms" }, { value: "rooms", label: "Per room" }], "all", v => setSwitch("switch.customized_cleaning", v === "rooms"));
	scopeSeg.classList.add("small");
	const geniusSeg = segmented([{ value: "off", label: "Off" }, { value: "routine_cleaning", label: "Genius", icon: "creation" }, { value: "deep_cleaning", label: "Deep" }],
		"off", v => setSelect("select.cleangenius", v));
	geniusSeg.classList.add("small");
	const modeSeg = h("div.vac-modes");
	const levels = h("div.vac-levels");
	const fan = h("span.vac-fan", icon("fan"));
	const suctionVal = h("span.vac-val", "");
	const drops = h("div.vac-drops");
	const wetVal = h("span.vac-val.vac-num", "");
	const wet = slider(1, 32, 1, v => setNumber("number.wetness_level", v));
	const routeSeg = segmented([{ value: "quick", label: "Quick" }, { value: "standard", label: "Standard" }], "standard", v => setSelect("select.cleaning_route", v));
	routeSeg.classList.add("small");
	const roomList = h("div.vac-room-list");
	const suctionBox = fold(h("div.vac-field", h("div.vac-field-head", fan, "Suction", suctionVal), levels));
	const waterBox = fold(h("div.vac-field", h("div.vac-field-head", icon("water_percent"), "Water", wetVal), drops, wet));
	const routeRow = h("div.vac-field-head.vac-route", icon("vector_line"), "Route", h("span.vac-grow"), routeSeg);
	const allBox = fold(h("div.vac-all", modeSeg, suctionBox, waterBox, routeRow));
	const roomsBox = fold(roomList);
	const geniusBox = fold(h("div.vac-genius", icon("star_four_points"), h("div", h("b", "CleanGenius"), h("span.vac-sub-small", ""))));
	const geniusRow = h("div.vac-field-head.vac-genius-row", icon("creation"), "CleanGenius", h("span.vac-grow"), geniusSeg);
	const modeCard = h("section.vac-card",
		h("div.vac-card-head", icon("tune_variant"), h("h2", "Mode"), h("div.vac-card-tools", scopeSeg)),
		geniusBox, allBox, roomsBox, geniusRow);

	// ══ STATION ═══════════════════════════════════════════════════════════
	const station = stationSvg();
	const phaseRing = svg("circle", { class: "vac-pr", cx: 19, cy: 19, r: 15, pathLength: 100, "stroke-dasharray": 100, "stroke-dashoffset": 100 });
	const phaseSvg = svg("svg", { viewBox: "0 0 38 38" });
	svg("circle", { class: "vac-pr-bg", cx: 19, cy: 19, r: 15 }, phaseSvg);
	phaseSvg.appendChild(phaseRing);
	const phaseTitle = h("b", "");
	const phaseSub = h("span.vac-sub-small.vac-num", "");
	const phaseBox = fold(h("div.vac-phase", phaseSvg, h("div", phaseTitle, phaseSub)));
	const stChip = h("span.chip.good", icon("check_circle"), "Ready");
	const stRows = h("div.vac-st-list");
	const stActions = h("div.vac-st-actions",
		h("button.btn.small.tonal", { type: "button", onclick: () => press("button.start_auto_empty") }, icon("tray_arrow_down"), "Empty"),
		h("button.btn.small.tonal", { type: "button", onclick: () => press("button.self_clean") }, icon("water_outline"), "Wash mop"),
		h("button.btn.small.tonal", { type: "button", onclick: () => press("button.manual_drying") }, icon("weather_windy"), "Dry"));
	const stationCard = h("section.vac-card",
		h("div.vac-card-head", icon("home_variant_outline"), h("h2", "Station"), h("div.vac-card-tools", stChip)),
		h("div.vac-station", station.el, h("div.vac-st-side", phaseBox, stRows)), stActions);

	// ══ RUNS ══════════════════════════════════════════════════════════════
	const blockedChip = h("span.chip.warn", { hidden: true });
	const hist = h("div.vac-hist");
	const totals = h("div.vac-totals");
	const schedToggle = toggle(false, on => {
		setSwitch("input_boolean.schedule_enabled", on);
	});
	const schedText = h("div.vac-sched-text", h("b", ""), h("span", ""));
	const sched = h("div.vac-sched", icon("calendar_clock"), schedText, schedToggle);
	const runsCard = h("section.vac-card",
		h("div.vac-card-head", icon("history"), h("h2", "Runs"), h("div.vac-card-tools", blockedChip)),
		hist, totals, sched);

	// ══ CARE ══════════════════════════════════════════════════════════════
	const parts = h("div.vac-parts");
	const careCard = h("section.vac-card", h("div.vac-card-head", icon("wrench_outline"), h("h2", "Care")), parts);

	// ══ SETTINGS ══════════════════════════════════════════════════════════
	const groupsEl = h("div.vac-groups");
	const settingsHead = h("div.vac-set-head", h("span.section-label", "Settings"));

	page.append(hero,
		h("div.vac-grid", mapCard, h("div.vac-col", modeCard, stationCard)),
		h("div.vac-row", runsCard, careCard),
		settingsHead, groupsEl);
	const loading = h("div.vac-loading", icon("robot_vacuum"));
	page.appendChild(loading);

	// ── pieces ──
	function fold(inner) {
		const el = h("div.vac-fold", h("div", inner));
		el.show = on => el.classList.toggle("shut", !on);
		return el;
	}

	function slider(min, max, step, onDone, unit = "") {
		const fill = h("div.vac-sl-fill");
		const knob = h("div.vac-sl-knob");
		const bubble = h("div.vac-sl-bubble");
		const el = h("div.vac-slider", h("div.vac-sl-track", fill), knob, bubble);
		let value = min;
		const show = v => {
			value = Math.max(min, Math.min(max, Math.round(v / step) * step));
			el.style.setProperty("--v", `${((value - min) / (max - min)) * 100}%`);
			bubble.textContent = `${value}${unit}`;
		};
		const at = event => {
			const r = el.getBoundingClientRect();
			show(min + ((event.clientX - r.left) / r.width) * (max - min));
			el.onMove?.(value);
		};
		el.addEventListener("pointerdown", event => {
			if (el.classList.contains("off")) return;
			el.setPointerCapture(event.pointerId);
			el.classList.add("drag");
			at(event);
		});
		el.addEventListener("pointermove", event => el.classList.contains("drag") && at(event));
		const end = () => {
			if (!el.classList.contains("drag")) return;
			el.classList.remove("drag");
			onDone(value);
		};
		el.addEventListener("pointerup", end);
		el.addEventListener("pointercancel", end);
		el.set = v => {
			if (!el.classList.contains("drag") && v != null) show(v);
		};
		show(min);
		return el;
	}

	// the map card's outline: a notch cut into its top for the tools (Fillet.qml's
	// inner corners curving into the edge), like the smart home board's
	function notchShape() {
		const s = svg("svg", { class: "vac-card-shape", "aria-hidden": "true" });
		const p = svg("path", {}, s);
		s.update = () => {
			const card = s.parentElement;
			if (!card) return;
			const W = card.offsetWidth, H = card.offsetHeight;
			const n = card.querySelector(".vac-notch");
			const R = 22, r = 18, c = 14;
			s.setAttribute("viewBox", `0 0 ${W} ${H}`);
			if (!n || !n.offsetWidth) {
				p.setAttribute("d", `M0,${R} A${R},${R} 0 0 1 ${R},0 L${W - R},0 A${R},${R} 0 0 1 ${W},${R} L${W},${H - R} A${R},${R} 0 0 1 ${W - R},${H} L${R},${H} A${R},${R} 0 0 1 0,${H - R} Z`);
				return;
			}
			// the notch is centred with translateX(-50%), which offsetLeft does not see
			const x0 = n.offsetLeft - n.offsetWidth / 2, x1 = x0 + n.offsetWidth, d = n.offsetHeight;
			p.setAttribute("d", `M0,${R} A${R},${R} 0 0 1 ${R},0 L${x0 - c},0 A${c},${c} 0 0 1 ${x0},${c} L${x0},${d - r} `
				+ `A${r},${r} 0 0 0 ${x0 + r},${d} L${x1 - r},${d} A${r},${r} 0 0 0 ${x1},${d - r} L${x1},${c} A${c},${c} 0 0 1 ${x1 + c},0 `
				+ `L${W - R},0 A${R},${R} 0 0 1 ${W},${R} L${W},${H - R} A${R},${R} 0 0 1 ${W - R},${H} L${R},${H} A${R},${R} 0 0 1 0,${H - R} Z`);
		};
		return s;
	}

	function stationSvg() {
		const el = svg("svg", { class: "vac-base", viewBox: "0 0 96 124" });
		const d = svg("defs", {}, el);
		const c1 = svg("clipPath", { id: `vac-t1-${id}` }, d);
		svg("rect", { x: 14, y: 12, width: 30, height: 62, rx: 7 }, c1);
		const c2 = svg("clipPath", { id: `vac-t2-${id}` }, d);
		svg("rect", { x: 52, y: 12, width: 30, height: 62, rx: 7 }, c2);
		svg("rect", { class: "vac-base-frame", x: 6, y: 4, width: 84, height: 116, rx: 14 }, el);
		svg("rect", { class: "vac-tank", x: 14, y: 12, width: 30, height: 62, rx: 7 }, el);
		svg("rect", { class: "vac-tank", x: 52, y: 12, width: 30, height: 62, rx: 7 }, el);
		const g1 = svg("g", { "clip-path": `url(#vac-t1-${id})` }, el);
		const w1 = svg("g", { class: "vac-wave" }, g1);
		svg("path", { class: "vac-w1", d: "M0 30 q6 -4 12 0 t12 0 t12 0 t12 0 t12 0 t12 0 V80 H0Z" }, w1);
		const g2 = svg("g", { "clip-path": `url(#vac-t2-${id})` }, el);
		const w2 = svg("g", { class: "vac-wave" }, g2);
		svg("path", { class: "vac-w2", d: "M38 30 q6 -4 12 0 t12 0 t12 0 t12 0 t12 0 t12 0 V80 H38Z" }, w2);
		svg("circle", { class: "vac-dust", cx: 48, cy: 22, r: 7 }, el);
		svg("rect", { class: "vac-tray", x: 14, y: 82, width: 68, height: 30, rx: 8 }, el);
		const bubbles = svg("g", { class: "vac-bubbles" }, el);
		[[30, 100, 2], [44, 102, 1.6], [56, 99, 2.2], [68, 101, 1.6]].forEach(([cx, cy, r]) => svg("circle", { cx, cy, r }, bubbles));
		const heat = svg("g", { class: "vac-heat" }, el);
		[34, 48, 62].forEach(x => svg("path", { d: `M${x} 106 q3 -4 0 -8 t0 -8` }, heat));
		return { el, w1, w2 };
	}

	// ══ LOADING ═══════════════════════════════════════════════════════════
	async function load() {
		try {
			const got = await api.get(`/api/smarthome/nodes/${encodeURIComponent(id)}/vacuum`);
			if (gone) return;
			node = got.node;
			for (const key of Object.keys(E)) delete E[key];
			for (const [key, value] of Object.entries(got.entities || {})) {
				E[key] = value;
				byId[value.id] = key;
			}
			if (!page.dataset.ready) build();
			paint();
			app.el?.top?.setTitle(view);
			loadMap();
		} catch (error) {
			if (gone) return;
			clear(page).appendChild(h("div.empty", icon("robot_vacuum"), h("h3", "The robot did not load"), h("p", error.message),
				h("a.btn.small", { href: "/smarthome" }, icon("arrow_left"), "Smart home")));
		}
	}

	async function loadMap() {
		try {
			const got = await api.get(`/api/smarthome/nodes/${encodeURIComponent(id)}/vacuum/map`, undefined, { quiet: true });
			if (gone) return;
			drawMap(got.map);
		} catch (error) {
			mapBox.classList.add("no-map");
		}
	}

	function onStates(data) {
		let touched = false;
		let mapMoved = false;
		for (const [entityId, value] of Object.entries(data.states || {})) {
			const key = byId[entityId];
			if (!key) continue;
			E[key] = { ...E[key], ...value };
			touched = true;
			if (key === "camera.map_data" && value.s !== mapVersion) mapMoved = true;
		}
		if (touched) paint();
		if (mapMoved && !mapTimer) {
			// while it cleans the map moves every few seconds: at most every 2.5 s here
			mapTimer = setTimeout(() => {
				mapTimer = 0;
				loadMap();
			}, 2500);
		}
	}

	// ══ BUILD (once the entities are known) ═══════════════════════════════
	function build() {
		page.dataset.ready = "1";
		loading.remove();
		buildModes();
		buildSettings();
		stagger(page.querySelectorAll(":scope > *, .vac-grid > *, .vac-col > *, .vac-row > *"), { step: 45, distance: 18, from: 0.97 });
		requestAnimationFrame(() => mapCard.querySelector(".vac-card-shape").update());
	}

	function buildModes() {
		const options = at("select.cleaning_mode").options || Object.keys(MODE_ICON);
		const seg = segmented(options.map(o => ({ value: o, label: word(o), icon: MODE_ICON[o] || "broom" })), st("select.cleaning_mode"), v => setSelect("select.cleaning_mode", v));
		seg.classList.add("big");
		modeSeg.appendChild(seg);
		modeSeg.seg = seg;
		const suctions = at("select.suction_level").options || ["quiet", "standard", "strong", "turbo"];
		suctions.forEach((o, i) => {
			const b = h("button.vac-level", { type: "button", dataset: { v: o } },
				h("span.vac-bars", [0, 1, 2, 3].map(k => h("i", { class: k <= i ? "l" : "", style: { height: `${6 + k * 4}px` } }))), word(o));
			b.addEventListener("click", () => setSelect("select.suction_level", o));
			levels.appendChild(b);
		});
		const hums = at("select.mop_pad_humidity").options || ["slightly_dry", "moist", "wet"];
		hums.forEach((o, i) => {
			const liquid = svg("rect", { class: "vac-liquid", x: 0, y: 0, width: 24, height: 24 });
			const s = svg("svg", { viewBox: "0 0 24 24" });
			const clip = svg("clipPath", { id: `vac-drop-${id}-${i}` }, svg("defs", {}, s));
			svg("path", { d: "M12 3 C12 3 5 11 5 15 a7 7 0 0 0 14 0 C19 11 12 3 12 3Z" }, clip);
			svg("g", { "clip-path": `url(#vac-drop-${id}-${i})` }, s).appendChild(liquid);
			svg("path", { class: "vac-drop-shape", d: "M12 3 C12 3 5 11 5 15 a7 7 0 0 0 14 0 C19 11 12 3 12 3Z" }, s);
			const b = h("button.vac-drop", { type: "button", dataset: { v: o } }, s, word(o));
			b.liquid = liquid;
			b.level = (i + 1) / hums.length;
			b.addEventListener("click", () => setSelect("select.mop_pad_humidity", o));
			drops.appendChild(b);
		});
	}

	// ══ PAINT ═════════════════════════════════════════════════════════════
	let painting = 0;
	function paint() {
		if (painting) return;
		painting = requestAnimationFrame(() => {
			painting = 0;
			if (!page.dataset.ready) return;
			paintHero();
			paintMode();
			paintStation();
			paintRuns();
			paintCare();
			paintRobot();
			paintSeq();
			binders.forEach(fn => fn());
		});
	}

	function phase() {
		const v = st("vacuum");
		const a = at("vacuum");
		if (!E.vacuum || v === "unavailable") return "offline";
		if (ui.remote) return "remote";
		if (v === "error") return "error";
		if (v === "cleaning") return a.mapping ? "mapping" : "cleaning";
		if (v === "paused") return "paused";
		if (v === "returning") return "returning";
		if (a.washing || st("sensor.self_wash_base_status") === "washing") return "washing";
		if (a.drying || st("sensor.self_wash_base_status") === "drying") return "drying";
		if (["active", "emptying", "collecting"].includes(st("sensor.auto_empty_status"))) return "emptying";
		if (v === "docked") return "docked";
		return "idle";
	}

	function lastRun() {
		const runs = history();
		return runs.length ? runs[runs.length - 1] : null;
	}

	function paintHero() {
		const p = phase();
		const [verb, tone] = PHASE[p];
		page.style.setProperty("--state", tone);
		hero.dataset.state = p;
		const name = node?.view?.name || "Robot";
		swap(titleBox, `${name} ${verb}`, `${escape(name)} <em>${verb}</em>`);
		const batt = num("sensor.battery_level");
		const room = st("sensor.current_room");
		// per room the global mode is unavailable: the room's own says what it does
		const here = map?.rooms.find(r => r.name === room);
		const mode = live("select.cleaning_mode") ? word(st("select.cleaning_mode")) : here && live(`select.room_${here.id}_cleaning_mode`) ? word(st(`select.room_${here.id}_cleaning_mode`)) : null;
		let sub = "";
		if (p === "docked") sub = batt >= 100 ? `Fully charged${lastRun() ? ` · last run ${lastRun().label}` : ""}` : `Charging · ${batt ?? "–"} %`;
		else if (p === "cleaning" || p === "paused") sub = [room, st("select.cleangenius") && st("select.cleangenius") !== "off" ? "CleanGenius" : mode && { Both: "Vacuum and mop", "Mop after": "Mop after vacuum" }[mode] || mode].filter(Boolean).join(" · ");
		else if (p === "returning") sub = "Back to the station";
		else if (p === "washing") sub = "Station · clean water";
		else if (p === "drying") sub = live("sensor.drying_left") ? `Station · ${minutes(num("sensor.drying_left"))} left` : "Station";
		else if (p === "emptying") sub = "Station · dust bag";
		else if (p === "error") sub = at("sensor.error").description || word(st("sensor.error"));
		else if (p === "offline") sub = "Home Assistant has no contact";
		else if (p === "remote") sub = "Remote control";
		else sub = [room, batt != null ? `${batt} %` : null].filter(Boolean).join(" · ");
		swap(subBox, sub);
		ring.setAttribute("stroke-dashoffset", 100 - (batt ?? 0));
		battText.textContent = batt != null ? `${batt}%` : "–";
		battIcon.replaceChildren(icon(st("binary_sensor.charging_state") === "on" || p === "docked" ? "battery_charging" : "battery"));
		const running = p === "cleaning" || p === "paused";
		setFact(fArea, num("sensor.cleaned_area"), "m²", running ? "Cleaned" : "Last run");
		setFact(fTime, num("sensor.cleaning_time"), "min", "Time");
		fRoom.value.textContent = room || "–";
		fRoom.unit.textContent = "";
		const rssi = at("vacuum").ap?.rssi;
		setFact(fWifi, rssi, "dBm", "Wi-Fi");
		const pct = num("sensor.cleaning_progress");
		progress.classList.toggle("on", running);
		progress.firstChild.style.width = `${running && pct != null ? pct : 0}%`;
		paintControls(p);
	}

	function setFact(f, value, unit, label) {
		const text = value == null ? "–" : String(Math.round(value));
		if (f.value.textContent !== text) {
			if (value != null && !reduced() && f.value.textContent !== "–") countUp(f.value, value);
			else f.value.textContent = text;
		}
		f.unit.textContent = value == null ? "" : unit;
		f.name.textContent = label;
	}

	function mainAction() {
		if (ui.tool === "zone" && ui.zone) return ["play", "Clean zone"];
		if (ui.tool === "point" && ui.pin) return ["map_marker", "Go here"];
		if (ui.tool === "rooms" && ui.rooms.length) return ["play", `Clean ${ui.rooms.length} room${ui.rooms.length > 1 ? "s" : ""}`];
		return ["play", "Clean all"];
	}

	function paintControls(p) {
		let main = null, stop = false, dock = false;
		if (p === "docked" || p === "idle") {
			main = mainAction();
			dock = p === "idle";
		} else if (p === "cleaning" || p === "mapping") {
			main = ["pause", "Pause"];
			stop = dock = true;
		} else if (p === "paused") {
			main = ["play", "Resume"];
			stop = dock = true;
		} else if (p === "returning") {
			main = ["pause", "Pause"];
			stop = true;
		} else if (p === "washing" || p === "drying" || p === "emptying") main = ["stop", "Stop"];
		else if (p === "error") {
			main = ["check", "Clear"];
			dock = true;
		} else if (p === "remote") {
			main = ["check", "Done"];
			dock = true;
		}
		ctlStop.classList.toggle("show", stop);
		ctlDock.classList.toggle("show", dock);
		ctlMain.classList.toggle("show", !!main);
		ctlMain.disabled = !admin;
		if (main) {
			mainIcon.replaceChildren(icon(main[0]));
			swap(mainLabel, main[1]);
		}
	}

	ctlMain.addEventListener("click", async () => {
		const p = phase();
		try {
			if (p === "docked" || p === "idle") await start();
			else if (p === "cleaning" || p === "mapping" || p === "returning") await call("vacuum.pause");
			else if (p === "paused") await call("vacuum.start");
			else if (p === "washing") await press("button.self_clean");
			else if (p === "drying") await press("button.manual_drying");
			else if (p === "emptying") await call("vacuum.stop");
			else if (p === "error") await (has("button.clear_warning") && live("button.clear_warning") ? press("button.clear_warning") : call("vacuum.stop"));
			else if (p === "remote") stopRemote();
		} catch (error) {}
	});
	ctlStop.addEventListener("click", () => call("vacuum.stop").catch(() => {}));
	ctlDock.addEventListener("click", () => {
		stopRemote();
		call("vacuum.return_to_base").catch(() => {});
	});

	async function start() {
		if (ui.tool === "zone" && ui.zone) {
			const z = ui.zone;
			const a = toRobot(z.x, z.y + z.h);
			const b = toRobot(z.x + z.w, z.y);
			await call("dreame_vacuum.vacuum_clean_zone", null, { zone: [a[0], a[1], b[0], b[1]], repeats: ui.zoneRep });
			toast("Zone on its way", { icon: "selection_drag" });
		} else if (ui.tool === "point" && ui.pin) {
			const [x, y] = toRobot(ui.pin.x, ui.pin.y);
			await call("dreame_vacuum.vacuum_goto", null, { x, y });
			toast("On its way", { icon: "map_marker" });
		} else if (ui.tool === "rooms" && ui.rooms.length) {
			await call("dreame_vacuum.vacuum_clean_segment", null, { segments: [...ui.rooms], repeats: 1 });
			toast(`${ui.rooms.length} room${ui.rooms.length > 1 ? "s" : ""} on the list`, { icon: "play" });
		} else await call("vacuum.start");
	}

	// map pixels → the robot's own mm
	function toRobot(x, y) {
		const cm = map.pixel;
		return [Math.round((x * cm - map.size[0] / 2) * 10), Math.round((map.size[1] / 2 - y * cm) * 10)];
	}

	function paintMode() {
		const genius = st("select.cleangenius");
		if (geniusSeg.dataset.value !== genius && genius) geniusSeg.select(genius);
		geniusSeg.classList.toggle("off", !live("select.cleangenius"));
		geniusRow.hidden = !has("select.cleangenius");
		const g = genius && genius !== "off";
		const custom = st("switch.customized_cleaning") === "on";
		const scope = custom ? "rooms" : "all";
		if (scopeSeg.dataset.value !== scope) scopeSeg.select(scope);
		scopeSeg.hidden = !has("switch.customized_cleaning");
		scopeSeg.classList.toggle("off", !live("switch.customized_cleaning") || g);
		const mode = st("select.cleaning_mode");
		if (modeSeg.seg && mode && modeSeg.seg.dataset.value !== mode) modeSeg.seg.select(mode);
		modeSeg.seg?.classList.toggle("off", !live("select.cleaning_mode"));
		geniusBox.show(g);
		geniusBox.querySelector(".vac-sub-small").textContent = genius === "deep_cleaning" ? "Deep · re-mops dirty spots" : "Suction and water by the floor";
		allBox.show(!g && !custom);
		roomsBox.show(!g && custom);
		paintRoomList();
		suctionBox.show(mode !== "mopping");
		waterBox.show(mode !== "sweeping");
		const suction = st("select.suction_level");
		const index = [...levels.children].findIndex(b => b.dataset.v === suction);
		[...levels.children].forEach((b, i) => {
			b.classList.toggle("on", i === index);
			b.classList.toggle("lit", i === index);
		});
		suctionVal.textContent = word(suction);
		fan.style.setProperty("--fan", `${[2.4, 1.3, 0.7, 0.32][Math.max(0, index)] || 1.3}s`);
		const hum = st("select.mop_pad_humidity");
		const hi = [...drops.children].findIndex(b => b.dataset.v === hum);
		[...drops.children].forEach((b, i) => {
			b.classList.toggle("on", i === hi);
			b.liquid.style.transform = `translateY(${24 - 24 * (i <= hi ? b.level * 0.85 + 0.1 : 0)}px)`;
		});
		const w = num("number.wetness_level");
		wet.set(w);
		wetVal.textContent = w ?? "";
		const route = st("select.cleaning_route");
		if (route && routeSeg.dataset.value !== route) routeSeg.select(route);
		routeRow.hidden = !has("select.cleaning_route");
	}

	// per room: mode, suction, water and passes, each room a row; a row lights its room on the map
	const MINI = {
		cleaning_mode: o => icon(MODE_ICON[o] || "broom"),
		suction_level: (o, i) => h("span.vac-bars.mini", [0, 1, 2, 3].map(k => h("i", { class: k <= i ? "l" : "", style: { height: `${4 + k * 3}px` } }))),
		mop_pad_humidity: (o, i, n) => h("span.vac-dropmini", { style: { "--l": `${((i + 1) / n) * 100}%` } }),
		cleaning_times: o => word(o)
	};
	function paintRoomList() {
		if (!map) return;
		const rooms = [...map.rooms].sort((a, b) => (a.order ?? 99) - (b.order ?? 99));
		const sig = rooms.map(r => `${r.id}:${r.name}`).join("|");
		if (roomList.dataset.sig !== sig) {
			roomList.dataset.sig = sig;
			clear(roomList).append(...rooms.map(room => {
				const minis = Object.keys(MINI).map(name => {
					const key = `select.room_${room.id}_${name}`;
					if (!has(key)) return null;
					const options = at(key).options || [];
					const el = h("span.vac-mini", { title: { cleaning_mode: "Mode", suction_level: "Suction", mop_pad_humidity: "Water", cleaning_times: "Passes" }[name] });
					options.forEach((o, i) => {
						const b = h("button", { type: "button", dataset: { v: o }, title: word(o) }, MINI[name](o, i, options.length));
						b.addEventListener("click", () => setSelect(key, o));
						el.appendChild(b);
					});
					el.key = key;
					return el;
				}).filter(Boolean);
				const passes = minis.find(m => m.key.endsWith("_cleaning_times"));
				const row = h("div.vac-rl-row", { dataset: { id: room.id } },
					h("div.vac-rl-name", icon(roomIcon(room)), h("span", room.name), passes || null),
					h("div.vac-rl-ctl", minis.filter(m => m !== passes)));
				row.addEventListener("pointerenter", () => roomEls.get(room.id)?.path.classList.add("hl"));
				row.addEventListener("pointerleave", () => roomEls.get(room.id)?.path.classList.remove("hl"));
				return row;
			}));
			if (!reduced()) stagger(roomList.children, { step: 35, distance: 8 });
		}
		roomList.querySelectorAll(".vac-mini").forEach(m => {
			m.classList.toggle("off", !live(m.key));
			m.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.v === st(m.key)));
		});
	}

	function paintStation() {
		const p = phase();
		const sp = ["washing", "drying", "emptying"].includes(p) ? p : "idle";
		stationCard.dataset.station = sp;
		phaseBox.show(sp !== "idle");
		const titles = { washing: "Washing mop", drying: "Drying mop", emptying: "Emptying dust" };
		if (sp === "idle") {
			stChip.className = "chip good";
			stChip.replaceChildren(icon("check_circle"), "Ready");
		} else {
			stChip.className = "chip accent";
			stChip.replaceChildren(icon(sp === "drying" ? "weather_windy" : sp === "washing" ? "water_outline" : "tray_arrow_down"), titles[sp]);
		}
		if (sp !== "idle") {
			phaseTitle.textContent = titles[sp];
			const k = sp === "drying" ? num("sensor.drying_progress") : null;
			phaseRing.style.stroke = sp === "drying" ? "var(--warning)" : sp === "washing" ? "var(--primary)" : "var(--tertiary)";
			phaseRing.setAttribute("stroke-dashoffset", k != null ? 100 - k : 72);
			phaseSvg.classList.toggle("spin", k == null);
			phaseSub.textContent = sp === "drying" && live("sensor.drying_left") ? `${minutes(num("sensor.drying_left"))} left` : k != null ? `${k} %` : "";
		}
		station.w1.style.transform = `translateY(${sp === "washing" ? 34 : 22}px)`;
		station.w2.style.transform = `translateY(${sp === "washing" ? 30 : 46}px)`;
		const rows = [
			["sensor.clean_water_tank_status", "Clean water"], ["sensor.dirty_water_tank_status", "Dirty water"],
			["sensor.detergent_status", "Detergent"], ["sensor.dust_bag_status", "Dust bag"], ["sensor.mop_pad", "Mop pads"],
			["sensor.low_water_warning", "Water"]
		].filter(([k]) => live(k));
		const sig = rows.map(([k]) => `${k}=${st(k)}`).join("|");
		if (stRows.dataset.sig === sig) return;
		stRows.dataset.sig = sig;
		clear(stRows).append(...rows.map(([k, label]) => {
			const v = st(k);
			const good = ["installed", "no_warning", "enabled", "available"].includes(v) || (k === "sensor.detergent_status" && v === "installed");
			return h("div.vac-st-row", h("span", { class: `vac-st-dot${good ? "" : " warn"}` }, icon(good ? "check_circle" : "alert_circle_outline")),
				h("span.vac-st-name", label), h("b", k === "sensor.detergent_status" && good && st("switch.auto_add_detergent") === "on" ? "Auto" : good ? "In" : word(v)));
		}));
	}

	// ── runs ──
	function history() {
		const a = at("sensor.cleaning_history");
		return Object.entries(a).filter(([, v]) => v && typeof v === "object" && v.timestamp).map(([k, v]) => {
			const t = new Date(v.timestamp * 1000);
			return { label: when(t.toISOString()), date: t, key: k, min: parseFloat(v.cleaning_time) || 0, area: parseFloat(v.cleaned_area) || 0,
				done: v.completed !== false, blocked: v.blocked_rooms && typeof v.blocked_rooms === "object" ? v.blocked_rooms : {} };
		}).sort((x, y) => x.date - y.date);
	}

	function paintRuns() {
		const runs = history();
		const sig = runs.map(r => r.key).join("|") + (map ? "|map" : "");
		if (hist.dataset.sig !== sig) {
			hist.dataset.sig = sig;
			const top = Math.max(1, ...runs.map(r => r.area));
			const names = Object.fromEntries((map?.rooms || []).map(r => [String(r.id), r.name]));
			clear(hist).append(...runs.map((r, n) => {
				const blocked = Object.keys(r.blocked);
				const tip = r.done ? `${r.date.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${r.date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })} · ${r.min} min · ${r.area} m²`
					+ (blocked.length ? ` · ${blocked.map(b => names[b] || `room ${b}`).join(", ")} blocked` : "") : "Not finished";
				return h("div", { class: `vac-bar${!r.done ? " fail" : blocked.length ? " blk" : ""}`, style: { "--n": n, height: `${r.done ? Math.max(6, (r.area / top) * 70) : 4}px` } },
					h("span.vac-tip", tip));
			}));
			const counts = {};
			runs.forEach(r => Object.keys(r.blocked).forEach(b => (counts[b] = (counts[b] || 0) + 1)));
			const worst = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
			blockedChip.hidden = !worst || worst[1] < 2;
			if (worst) blockedChip.replaceChildren(icon("alert_circle_outline"), `${names[worst[0]] || `Room ${worst[0]}`} blocked ${worst[1]}×`);
		}
		const tot = [["sensor.cleaning_count", "Runs", ""], ["sensor.total_cleaned_area", "Cleaned", " m²"], ["sensor.total_cleaning_time", "Hours", " h"]];
		if (!totals.childElementCount) {
			totals.append(...tot.map(([, label]) => h("div.vac-tot", h("b.vac-num", "0"), h("span", label))));
		}
		tot.forEach(([k, label, unit], i) => {
			const box = totals.children[i];
			let v = num(k);
			if (k === "sensor.total_cleaning_time" && v != null) v = Math.round(v / 60);
			const b = box.querySelector("b");
			if (v != null && b.dataset.n !== String(v)) countUp(b, v, n => `${Math.round(n).toLocaleString()}${unit}`, 1200);
			if (k === "sensor.total_cleaning_time" && live("sensor.first_cleaning_date")) box.querySelector("span").textContent = `Since ${new Date(st("sensor.first_cleaning_date")).toLocaleDateString(undefined, { day: "numeric", month: "short" })}`;
		});
		sched.hidden = !has("input_boolean.schedule_enabled");
		if (!sched.hidden) {
			schedToggle.set(st("input_boolean.schedule_enabled") === "on");
			const t = String(st("input_datetime.schedule_time") || "").slice(0, 5);
			schedText.firstChild.textContent = t ? `Daily ${t}` : "Daily";
			schedText.lastChild.textContent = st("input_select.schedule_target") || "";
		}
	}

	// ── care: hold a part to reset it ──
	function paintCare() {
		if (!parts.childElementCount) {
			for (const part of PARTS) {
				if (!has(`sensor.${part.key}_left`)) continue;
				const value = svg("circle", { class: "vac-pv", cx: 29, cy: 29, r: 24, pathLength: 100 });
				const hold = svg("circle", { class: "vac-ph", cx: 29, cy: 29, r: 24, pathLength: 100 });
				const s = svg("svg", { viewBox: "0 0 58 58" });
				svg("circle", { class: "vac-pbg", cx: 29, cy: 29, r: 24 }, s);
				s.append(value, hold);
				const ico = svg("text", { class: "vac-pico", x: 29, y: 22 }, s);
				ico.textContent = icon(part.icon).textContent;
				const pct = svg("text", { class: "vac-pct", x: 29, y: 37 }, s);
				const left = h("span", "");
				const el = h("div.vac-part", { title: admin ? "Hold to reset" : "" }, s, h("b", part.name), left);
				Object.assign(el, { value, pct, left, spec: part });
				let timer = 0;
				const up = () => {
					clearTimeout(timer);
					el.classList.remove("holding");
				};
				el.addEventListener("pointerdown", () => {
					if (!admin || !has(part.reset)) return;
					el.classList.add("holding");
					timer = setTimeout(async () => {
						el.classList.remove("holding");
						if (await press(part.reset)) {
							el.classList.add("done");
							setTimeout(() => el.classList.remove("done"), 700);
							toast(`${part.name} reset`, { icon: "check_circle", tone: "good" });
						}
					}, 900);
				});
				el.addEventListener("pointerup", up);
				el.addEventListener("pointerleave", up);
				parts.appendChild(el);
			}
			// the rings fill when the card comes into view
			const seen = new IntersectionObserver(entries => {
				if (!entries.some(e => e.isIntersecting)) return;
				parts.classList.add("seen");
				paintCare();
				seen.disconnect();
			}, { threshold: 0.3 });
			seen.observe(parts);
		}
		for (const el of parts.children) {
			const v = num(`sensor.${el.spec.key}_left`);
			const t = num(`sensor.${el.spec.key}_time_left`);
			const unit = E[`sensor.${el.spec.key}_time_left`]?.a?.unit_of_measurement || "h";
			el.classList.toggle("warn", v != null && v < 10);
			el.value.style.strokeDashoffset = parts.classList.contains("seen") ? 100 - Math.max(2, v ?? 0) : 100;
			el.pct.textContent = v != null ? `${v}%` : "–";
			el.left.textContent = v != null && v < 10 ? "Clean now" : t != null ? `${t} ${unit}` : "";
		}
	}

	// ══ MAP: drawing ══════════════════════════════════════════════════════
	const cam = { x: 0, y: 0, k: 1 };
	let base = null;              // the map's own box in map pixels
	const roomEls = new Map();    // id → {path, label}
	let pathLength = 0;

	function drawMap(m) {
		const first = !map;
		map = m;
		mapVersion = m.version;
		mapBox.classList.remove("no-map");
		const [x0, y0, x1, y1] = m.bounds;
		const pad = 8;
		base = { x: x0 - pad, y: y0 - pad, w: x1 - x0 + pad * 2, h: y1 - y0 + pad * 2 };
		mapSvg.setAttribute("viewBox", `${base.x} ${base.y} ${base.w} ${base.h}`);
		mapBox.style.setProperty("--ratio", `${base.w} / ${base.h}`);
		gWalls.setAttribute("d", runs(m.walls));
		// rooms: kept between maps so a selection and its animation stay
		const seen = new Set();
		m.rooms.forEach((room, index) => {
			seen.add(room.id);
			let r = roomEls.get(room.id);
			if (!r) {
				const path = svg("path", { class: "vac-room", "data-id": room.id, filter: `url(#vac-soft-${id})` }, gRooms);
				const label = h("div.vac-label.vac-pin", { dataset: { id: room.id } }, h("span.vac-label-icon", icon(roomIcon(room))), h("span.vac-label-name", room.name), h("span.vac-badge"));
				overlay.appendChild(label);
				r = { path, label };
				roomEls.set(room.id, r);
				if (first && !reduced()) {
					path.style.animationDelay = `${index * 70}ms`;
					path.classList.add("enter");
					label.style.animationDelay = `${200 + index * 70}ms`;
					label.classList.add("enter");
				}
			}
			r.path.setAttribute("d", runs(room.runs));
			r.path.style.setProperty("--c", ROOM_TONES[(room.color_index ?? index) % ROOM_TONES.length]);
			r.room = room;
			const [lx, ly] = room.label || centerOf(room.runs);
			place(r.label, lx, ly);
			r.label.querySelector(".vac-label-name").textContent = room.name;
		});
		for (const [rid, r] of roomEls) {
			if (seen.has(rid)) continue;
			r.path.remove();
			r.label.remove();
			roomEls.delete(rid);
		}
		ui.rooms = ui.rooms.filter(r => seen.has(r));
		// the path: a soft band where it cleaned and the line it drove; what is new draws itself in
		const d = m.path.map(p => "M" + p.reduce((s, v, i) => s + (i % 2 ? `,${v}` : `${i ? " L" : ""}${v}`), "")).join(" ");
		gBand.setAttribute("d", d);
		gPath.setAttribute("d", d);
		const length = d ? gPath.getTotalLength() : 0;
		if (length && !reduced()) {
			const from = first ? 0 : Math.min(pathLength, length);
			for (const el of [gPath, gBand]) {
				el.style.transition = "none";
				el.style.strokeDasharray = `${length} ${length}`;
				el.style.strokeDashoffset = `${length - from}`;
				void el.getBoundingClientRect();
				el.style.transition = `stroke-dashoffset ${first ? 1800 : 2400}ms ${first ? EASE.spatial : "linear"}`;
				el.style.strokeDashoffset = "0";
			}
		}
		pathLength = length;
		// obstacles
		overlay.querySelectorAll(".vac-obstacle").forEach(o => o.remove());
		for (const o of m.obstacles || []) {
			if (o.ignored) continue;
			const el = h("div.vac-obstacle.vac-pin", { title: [o.type, o.room].filter(Boolean).join(" · ") }, icon(obstacleIcon(o.type)));
			place(el, o.x, o.y);
			overlay.appendChild(el);
		}
		if (m.charger) {
			if (!chargerEl.isConnected) overlay.appendChild(chargerEl);
			place(chargerEl, m.charger.x, m.charger.y);
		}
		if (!robotEl.isConnected) overlay.appendChild(robotEl);
		paintRobot();
		paintSelection();
		paintRuns();
		paintRoomList();
		if (first) fit(true);
		else layout();
	}

	function runs(list) {
		let d = "";
		for (let i = 0; i + 2 < list.length; i += 3) d += `M${list[i]} ${list[i + 1]}h${list[i + 2]}v1h${-list[i + 2]}z`;
		return d;
	}

	function centerOf(list) {
		let sx = 0, sy = 0, n = 0;
		for (let i = 0; i + 2 < list.length; i += 3) {
			sx += (list[i] + list[i + 2] / 2) * list[i + 2];
			sy += (list[i + 1] + 0.5) * list[i + 2];
			n += list[i + 2];
		}
		return n ? [sx / n, sy / n] : [0, 0];
	}

	function roomIcon(room) {
		const name = glyphOf(room.icon);
		return icon(name).textContent ? name : "home_outline";
	}

	function obstacleIcon(type) {
		const t = String(type || "").toLowerCase();
		if (t.includes("power") || t.includes("strip")) return "power_socket_eu";
		if (t.includes("shoe")) return "shoe_sneaker";
		if (t.includes("cable") || t.includes("cord") || t.includes("wire")) return "cable_data";
		if (t.includes("pet") || t.includes("poop") || t.includes("excrement")) return "paw";
		return "sign_caution";
	}

	// overlay items sit on map pixels; they keep their size when the map zooms
	function place(el, x, y) {
		el.dataset.x = x;
		el.dataset.y = y;
		if (base) {
			el.style.left = `${((x - base.x) / base.w) * 100}%`;
			el.style.top = `${((y - base.y) / base.h) * 100}%`;
		}
	}

	function paintRobot() {
		if (!map) return;
		const p = phase();
		const docked = p === "docked" || p === "washing" || p === "drying" || p === "emptying";
		const spot = (docked && map.charger) || map.robot || map.charger;
		robotEl.hidden = !spot;
		if (!spot) return;
		place(robotEl, spot.x, spot.y);
		robotEl.style.setProperty("--a", `${(spot.a ?? 0) + 90}deg`);
		robotEl.classList.toggle("moving", ["cleaning", "mapping", "returning", "remote"].includes(p));
		chargerEl.classList.toggle("covered", docked);
	}

	// ── zoom and pan (the world is one layer: map and pins together, fitted into the box) ──
	const box = { ox: 0, oy: 0, w: 0, h: 0 };
	function measure() {
		const W = mapBox.clientWidth, H = mapBox.clientHeight;
		if (!base || !W || !H) return false;
		const ratio = base.w / base.h;
		box.w = W / H > ratio ? H * ratio : W;
		box.h = box.w / ratio;
		box.ox = (W - box.w) / 2;
		box.oy = (H - box.h) / 2;
		world.style.width = `${box.w}px`;
		world.style.height = `${box.h}px`;
		return true;
	}

	function layout() {
		if (!measure()) return;
		clampView();
		world.style.transform = `translate(${box.ox + cam.x}px, ${box.oy + cam.y}px) scale(${cam.k})`;
		world.style.setProperty("--k", cam.k);
	}

	function fit(first) {
		cam.x = 0;
		cam.y = 0;
		cam.k = 1;
		if (first) {
			world.classList.add("instant");
			layout();
			void world.offsetWidth;
			world.classList.remove("instant");
		} else layout();
	}

	function zoomAt(cx, cy, factor) {
		const r = mapBox.getBoundingClientRect();
		const k = Math.max(1, Math.min(6, cam.k * factor));
		const px = cx - r.left - box.ox, py = cy - r.top - box.oy;
		cam.x = px - ((px - cam.x) / cam.k) * k;
		cam.y = py - ((py - cam.y) / cam.k) * k;
		cam.k = k;
		layout();
	}

	// the zoomed map always covers the box where it can, and stays centred where it cannot
	function clampView() {
		const W = mapBox.clientWidth, H = mapBox.clientHeight;
		const sw = box.w * cam.k, sh = box.h * cam.k;
		cam.x = sw <= W ? (W - sw) / 2 - box.ox : Math.min(-box.ox, Math.max(W - sw - box.ox, cam.x));
		cam.y = sh <= H ? (H - sh) / 2 - box.oy : Math.min(-box.oy, Math.max(H - sh - box.oy, cam.y));
	}

	mapBox.addEventListener("wheel", event => {
		if (!map) return;
		event.preventDefault();
		world.classList.add("instant");
		zoomAt(event.clientX, event.clientY, Math.exp(-event.deltaY * (event.deltaMode ? 0.05 : 0.0018)));
		clearTimeout(mapBox.wheelTimer);
		mapBox.wheelTimer = setTimeout(() => world.classList.remove("instant"), 120);
	}, { passive: false });
	fitBtn.addEventListener("click", () => fit());
	pathBtn.addEventListener("click", () => {
		pathBtn.classList.toggle("on");
		mapBox.classList.toggle("no-path", !pathBtn.classList.contains("on"));
	});
	mapBox.addEventListener("dblclick", event => {
		if (ui.tool !== "rooms") return;
		if (cam.k > 1.05) fit();
		else zoomAt(event.clientX, event.clientY, 2.2);
	});

	const toMap = event => {
		const p = mapSvg.createSVGPoint();
		p.x = event.clientX;
		p.y = event.clientY;
		return p.matrixTransform(mapSvg.getScreenCTM().inverse());
	};

	// ── tools ──
	let press0 = null;
	mapBox.addEventListener("pointerdown", event => {
		if (!map || event.button !== 0 || event.target.closest(".vac-map-float, .vac-joy, .vac-zone-pop")) return;
		mapBox.setPointerCapture(event.pointerId);
		const p = toMap(event);
		press0 = { x: event.clientX, y: event.clientY, vx: cam.x, vy: cam.y, map: p, moved: false };
		if (ui.tool === "zone") {
			ui.zone = { x: p.x, y: p.y, w: 0, h: 0 };
			press0.zone = true;
			zonePop.classList.remove("show");
			paintZone();
		}
	});
	mapBox.addEventListener("pointermove", event => {
		if (!press0) return;
		const dx = event.clientX - press0.x, dy = event.clientY - press0.y;
		if (Math.hypot(dx, dy) > 4) press0.moved = true;
		if (press0.zone) {
			const p = toMap(event);
			ui.zone = { x: Math.min(p.x, press0.map.x), y: Math.min(p.y, press0.map.y), w: Math.abs(p.x - press0.map.x), h: Math.abs(p.y - press0.map.y) };
			paintZone();
		} else if (press0.moved && cam.k > 1.01) {
			world.classList.add("instant");
			cam.x = press0.vx + dx;
			cam.y = press0.vy + dy;
			layout();
		}
	});
	const release = event => {
		if (!press0) return;
		const p0 = press0;
		press0 = null;
		world.classList.remove("instant");
		if (p0.zone) {
			if (!ui.zone || ui.zone.w < 4 || ui.zone.h < 4) ui.zone = null;
			paintZone(true);
			paintControls(phase());
			return;
		}
		if (p0.moved || event.type === "pointercancel") return;
		if (ui.tool === "rooms") {
			const hit = document.elementsFromPoint(event.clientX, event.clientY).find(el => el.classList?.contains("vac-room") || el.classList?.contains("vac-label"));
			const rid = hit ? Number(hit.dataset.id) : null;
			if (rid == null || Number.isNaN(rid)) return;
			const i = ui.rooms.indexOf(rid);
			if (i >= 0) ui.rooms.splice(i, 1);
			else ui.rooms.push(rid);
			paintSelection();
			paintControls(phase());
		} else if (ui.tool === "point") {
			ui.pin = toMap(event);
			paintPin();
			paintControls(phase());
		}
	};
	mapBox.addEventListener("pointerup", release);
	mapBox.addEventListener("pointercancel", release);
	// rooms can be picked by their label too (it sits above the map)
	overlay.addEventListener("pointerdown", event => {
		if (event.target.closest(".vac-label")) event.target.closest(".vac-label").classList.add("press");
	});

	function setTool(tool) {
		ui.tool = tool;
		mapBox.dataset.tool = tool;
		if (tool !== "zone") ui.zone = null;
		if (tool !== "point") ui.pin = null;
		if (tool !== "rooms") ui.rooms = [];
		joy.classList.toggle("show", tool === "drive");
		if (tool !== "drive") stopRemote();
		paintZone();
		paintPin();
		paintSelection();
		paintControls(phase());
		requestAnimationFrame(() => mapCard.querySelector(".vac-card-shape").update());
	}

	function paintSelection() {
		for (const [rid, r] of roomEls) {
			const n = ui.rooms.indexOf(rid);
			r.path.classList.toggle("sel", n >= 0);
			r.label.classList.toggle("sel", n >= 0);
			const badge = r.label.querySelector(".vac-badge");
			if (n >= 0) {
				if (badge.textContent !== String(n + 1)) {
					badge.textContent = n + 1;
					animate(badge, [{ transform: "scale(0.2)" }, { transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
				}
			} else badge.textContent = "";
			r.path.classList.toggle("cur", phase() === "cleaning" && st("sensor.current_room") === r.room?.name);
		}
		paintSeq();
	}

	// the order of the picked rooms, or the robot's own when none is picked; picked ones drag into order
	function paintSeq() {
		if (!map || ui.tool !== "rooms") {
			seq.classList.add("shut");
			return;
		}
		seq.classList.remove("shut");
		const own = ui.rooms.length > 0;
		const order = own ? ui.rooms : (at("vacuum").cleaning_sequence || [...map.rooms].sort((a, b) => (a.order ?? 99) - (b.order ?? 99)).map(r => r.id));
		const sig = `${own}|${order.join(",")}`;
		if (seq.dataset.sig === sig) return;
		seq.dataset.sig = sig;
		const before = new Map([...seq.querySelectorAll(".vac-chip")].map(c => [c.dataset.id, c.getBoundingClientRect()]));
		clear(seq).append(...order.map((rid, n) => {
			const room = map.rooms.find(r => r.id === rid);
			if (!room) return null;
			return h("span", { class: `vac-chip${own ? "" : " dim"}`, dataset: { id: rid } }, h("b", String(n + 1)), room.name);
		}).filter(Boolean));
		for (const c of seq.children) {
			const from = before.get(c.dataset.id);
			if (!from) {
				animate(c, [{ opacity: 0, transform: "scale(0.6)" }, { opacity: 1, transform: "none" }], { duration: 480, easing: EASE.spring, fill: "none" });
				continue;
			}
			const to = c.getBoundingClientRect();
			if (from.left !== to.left || from.top !== to.top) animate(c, [{ transform: `translate(${from.left - to.left}px, ${from.top - to.top}px)` }, { transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
		}
	}

	(function seqDrag() {
		let drag = null;
		seq.addEventListener("pointerdown", event => {
			const c = event.target.closest(".vac-chip");
			if (!c || c.classList.contains("dim")) return;
			c.setPointerCapture(event.pointerId);
			drag = { c, x: event.clientX, y: event.clientY, id: Number(c.dataset.id) };
			c.classList.add("drag");
		});
		seq.addEventListener("pointermove", event => {
			if (!drag) return;
			drag.c.style.transform = `translate(${event.clientX - drag.x}px, ${event.clientY - drag.y}px) scale(1.05)`;
			const others = [...seq.querySelectorAll(".vac-chip:not(.drag)")];
			let index = 0;
			for (const o of others) {
				const r = o.getBoundingClientRect();
				if (event.clientY > r.bottom || (event.clientY > r.top - 6 && event.clientX > r.left + r.width / 2)) index += 1;
			}
			const cur = ui.rooms.indexOf(drag.id);
			if (index === cur) return;
			const before = drag.c.getBoundingClientRect();
			ui.rooms.splice(cur, 1);
			ui.rooms.splice(index, 0, drag.id);
			paintSelection();
			const nc = seq.querySelector(`.vac-chip[data-id="${drag.id}"]`);
			const after = nc.getBoundingClientRect();
			nc.getAnimations().forEach(a => a.cancel());
			nc.setPointerCapture(event.pointerId);
			nc.classList.add("drag");
			drag = { c: nc, x: drag.x + (after.left - before.left), y: drag.y + (after.top - before.top), id: drag.id };
			nc.style.transform = `translate(${event.clientX - drag.x}px, ${event.clientY - drag.y}px) scale(1.05)`;
		});
		const end = () => {
			if (!drag) return;
			const c = drag.c;
			c.classList.remove("drag");
			animate(c, [{ transform: c.style.transform }, { transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
			c.style.transform = "";
			drag = null;
		};
		seq.addEventListener("pointerup", end);
		seq.addEventListener("pointercancel", end);
	})();

	function paintZone(pop) {
		clear(gZones);
		if (!ui.zone) {
			zonePop.classList.remove("show");
			return;
		}
		const z = ui.zone;
		const g = svg("g", { class: "vac-zone" }, gZones);
		svg("rect", { class: "vac-zone-area", x: z.x, y: z.y, width: z.w, height: z.h, rx: 2 }, g);
		for (const [x, y] of [[z.x, z.y], [z.x + z.w, z.y], [z.x, z.y + z.h], [z.x + z.w, z.y + z.h]]) svg("circle", { class: "vac-zone-handle", cx: x, cy: y, r: 1.4 }, g);
		if (pop) {
			if (!zonePop.isConnected) overlay.appendChild(zonePop);
			clear(zonePop).append(
				h("button.btn.small.ghost", { type: "button", onclick: event => {
					ui.zoneRep = ui.zoneRep % 3 + 1;
					event.currentTarget.textContent = `×${ui.zoneRep}`;
				} }, `×${ui.zoneRep}`),
				h("button.icon-btn.small", { type: "button", title: "Remove", "aria-label": "Remove", onclick: () => {
					ui.zone = null;
					paintZone();
					paintControls(phase());
				} }, icon("delete_outline")));
			place(zonePop, z.x + z.w / 2, z.y);
			requestAnimationFrame(() => zonePop.classList.add("show"));
		}
	}

	function paintPin() {
		clear(gPick);
		if (!ui.pin) return;
		const g = svg("g", { class: "vac-goto", transform: `translate(${ui.pin.x} ${ui.pin.y})` }, gPick);
		svg("circle", { class: "vac-goto-ring", r: 3 }, g);
		const drop = svg("g", { class: "vac-goto-drop" }, g);
		svg("path", { d: "M0 0 C-0.8 -2.4 -3.6 -4 -3.6 -6.8 A3.6 3.6 0 1 1 3.6 -6.8 C3.6 -4 0.8 -2.4 0 0Z" }, drop);
		svg("circle", { class: "vac-goto-eye", cx: 0, cy: -6.8, r: 1.3 }, drop);
	}

	// ── driving: a step every 300 ms while the knob is held ──
	let joyTimer = 0;
	let joyVec = null;
	joy.addEventListener("pointerdown", event => {
		event.stopPropagation();
		if (!admin) return;
		joy.setPointerCapture(event.pointerId);
		joy.classList.add("drag");
		ui.remote = true;
		paint();
		moveKnob(event);
		if (!joyTimer) joyTimer = setInterval(stepRemote, 300);
		stepRemote();
	});
	joy.addEventListener("pointermove", event => joy.classList.contains("drag") && moveKnob(event));
	const joyEnd = () => {
		if (!joy.classList.contains("drag")) return;
		joy.classList.remove("drag");
		joyKnob.style.transform = "";
		joyVec = null;
		clearInterval(joyTimer);
		joyTimer = 0;
		call("dreame_vacuum.vacuum_remote_control_move_step", null, { rotation: 0, velocity: 0 }).catch(() => {});
	};
	joy.addEventListener("pointerup", joyEnd);
	joy.addEventListener("pointercancel", joyEnd);
	function moveKnob(event) {
		const r = joy.getBoundingClientRect();
		let dx = event.clientX - r.left - r.width / 2;
		let dy = event.clientY - r.top - r.height / 2;
		const l = Math.hypot(dx, dy), m = r.width * 0.31;
		if (l > m) {
			dx *= m / l;
			dy *= m / l;
		}
		joyKnob.style.transform = `translate(${dx}px, ${dy}px)`;
		joyVec = { x: dx / m, y: dy / m };
	}
	function stepRemote() {
		if (!joyVec) return;
		const rotation = Math.round(-joyVec.x * 120);
		const velocity = Math.round(-joyVec.y * 250);
		call("dreame_vacuum.vacuum_remote_control_move_step", null, { rotation, velocity }).catch(() => {});
	}
	function stopRemote() {
		if (!ui.remote) return;
		ui.remote = false;
		clearInterval(joyTimer);
		joyTimer = 0;
		paint();
	}

	// ══ SETTINGS ══════════════════════════════════════════════════════════
	const GROUPS = [
		{ id: "cleaning", title: "Cleaning", icon: "broom", rows: [
			["select.carpet_cleaning", "Carpets"], ["switch.carpet_boost", "Carpet boost"], ["switch.intensive_carpet_cleaning", "Intensive carpet cleaning"],
			["switch.clean_carpets_first", "Carpets first"], ["select.auto_recleaning", "Re-clean dirty spots"],
			["switch.mop_extend", "Mop extend", [["select.mop_extend_frequency", "Frequency"]]],
			["switch.mopping_under_furnitures", "Mop under furniture"], ["switch.gap_cleaning_extension", "Gap cleaning extension"],
			["switch.floor_direction_cleaning", "Along the floor boards"], ["switch.max_suction_power", "Max suction power"],
			["switch.stain_avoidance", "Stain avoidance"], ["switch.resume_cleaning", "Resume after charging"]
		] },
		{ id: "station", title: "Station", icon: "home_variant_outline", rows: [
			["select.auto_empty_mode", "Auto empty"],
			["switch.self_clean", "Wash mop while cleaning", [["select.self_clean_frequency", "Every"], ["number.self_clean_area", "Area", " m²"], ["number.self_clean_time", "Time", " min"]]],
			["select.washing_mode", "Washing"], ["select.auto_rewashing", "Re-wash"], ["switch.smart_mop_washing", "Smart mop washing"],
			["switch.auto_drying", "Auto drying", [["select.drying_time", "Duration"]]],
			["switch.auto_add_detergent", "Auto-add detergent"], ["switch.auto_water_refilling", "Auto water refill"],
			["info", "Hot water", "sensor.hot_water_status"],
			["buttons", [["button.base_station_cleaning", "Clean station", "water_outline"], ["button.base_station_self_repair", "Self repair", "wrench_outline"],
				["button.water_tank_draining", "Drain water tank", "water_off"], ["button.empty_water_tank", "Empty water tank", "water_minus_outline"]]]
		] },
		{ id: "obstacles", title: "Obstacles & camera", icon: "eye_outline", rows: [
			["switch.obstacle_avoidance", "Obstacle avoidance"], ["switch.ai_obstacle_detection", "AI obstacle detection"],
			["switch.fuzzy_obstacle_detection", "Fuzzy obstacles"], ["switch.ai_furniture_detection", "Furniture"],
			["switch.ai_pet_detection", "Pets", [["switch.pet_focused_detection", "Pet focused"], ["switch.pet_picture", "Pet pictures"]]],
			["switch.ai_fluid_detection", "Liquids"], ["switch.collision_avoidance", "Collision avoidance"],
			["switch.dynamic_obstacle_cleaning", "Clean around moving obstacles"],
			["switch.ai_obstacle_picture", "Obstacle pictures", [["switch.ai_obstacle_image_upload", "Upload to Dreame"]]],
			["switch.fill_light", "Fill light"], ["switch.camera_light_brightness_auto", "Camera light auto"], ["number.camera_light_brightness", "Camera light", " %"]
		] },
		{ id: "quiet", title: "Quiet hours & charging", icon: "sleep", rows: [
			["switch.dnd", "Do not disturb", [["times", "Time", "time.dnd_start", "time.dnd_end"], ["switch.dnd_reduce_volume", "Lower volume"],
				["switch.dnd_disable_auto_empty", "No auto empty"], ["switch.dnd_disable_resume_cleaning", "No resume"]]],
			["switch.off_peak_charging", "Off-peak charging", [["times", "Time", "time.off_peak_charging_start", "time.off_peak_charging_end"]]]
		] },
		{ id: "voice", title: "Voice", icon: "volume_high", rows: [
			["number.volume", "Volume", " %"], ["switch.streaming_voice_prompt", "Voice prompts while streaming"],
			["switch.voice_assistant", "Voice assistant", [["select.voice_assistant_language", "Language"]]]
		] },
		{ id: "map", title: "Map", icon: "layers_outline", rows: [
			["select.selected_map", "Map"], ["select.map_rotation", "Rotation"], ["switch.multi_floor_map", "Several floors"],
			["buttons", [["button.start_fast_mapping", "Fast mapping", "map_outline"], ["button.backup_saved_map", "Back up map", "history"]]]
		] },
		{ id: "device", title: "Device", icon: "information_outline", rows: [
			["switch.child_lock", "Child lock"], ["switch.human_follow", "Follow me"],
			["info", "Firmware", "sensor.firmware_version"], ["info", "Address", () => at("vacuum").ap?.ip],
			["info", "Wi-Fi", () => (at("vacuum").ap ? `${at("vacuum").ap.ssid} · ${at("vacuum").ap.rssi} dBm` : null)],
			["info", "First run", () => (live("sensor.first_cleaning_date") ? new Date(st("sensor.first_cleaning_date")).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }) : null)],
			["buttons", [["button.clear_warning", "Clear warning", "alert_circle_outline"], ["locate", "Find robot", "volume_high"]]]
		] }
	];
	const groupEls = {};

	function buildSettings() {
		clear(groupsEl);
		for (const g of GROUPS) {
			const rows = h("div.vac-g-inner");
			let n = 0;
			for (const row of g.rows) {
				const made = makeRow(row, false, () => n++);
				if (made) rows.append(...made);
			}
			if (!rows.childElementCount) continue;
			const sum = h("span.vac-g-sum", "");
			const head = h("button.vac-g-head", { type: "button", "aria-expanded": "false" }, icon(g.icon), h("span.vac-g-title", g.title), sum, h("span.vac-chev", icon("chevron_down")));
			const el = h("div.vac-group", { dataset: { g: g.id } }, head, h("div.vac-g-body", h("div", rows)));
			head.addEventListener("click", () => {
				const open = el.classList.toggle("open");
				head.setAttribute("aria-expanded", String(open));
				if (open) el.querySelectorAll(".segmented").forEach(s => s.select?.(s.dataset.value));
			});
			binders.push(() => {
				const on = g.rows.filter(r => r[0].startsWith("switch.") && st(r[0]) === "on").length;
				sum.textContent = g.id === "device" ? (st("sensor.firmware_version") ? `Firmware ${st("sensor.firmware_version")}` : "") : on ? `${on} on` : "";
			});
			groupEls[g.id] = el;
			groupsEl.appendChild(el);
		}
	}

	function makeRow(row, dep, count) {
		const [key] = row;
		const style = () => ({ "--n": count() });
		if (key === "info") {
			const [, label, source] = row;
			const value = h("b", "");
			const el = h("div.vac-s-row.info", { class: dep ? "dep" : "", style: style() }, h("label", label), value);
			binders.push(() => {
				const v = typeof source === "function" ? source() : live(source) ? word(st(source)) : null;
				el.hidden = v == null || v === "";
				value.textContent = v ?? "";
			});
			return [el];
		}
		if (key === "buttons") {
			const buttons = row[1].filter(([k]) => k === "locate" || has(k)).map(([k, label, ic]) => {
				const b = h("button.btn.small", { type: "button" }, icon(ic), label);
				b.addEventListener("click", async () => {
					if (k === "locate") await call("vacuum.locate").catch(() => {});
					else if (await press(k)) toast(label, { icon: ic });
				});
				if (k !== "locate") binders.push(() => (b.disabled = !live(k) && st(k) !== "unknown"));
				return b;
			});
			return buttons.length ? [h("div.vac-s-row.btns", { style: style() }, buttons)] : null;
		}
		if (key === "times") {
			const [, label, a, b] = row;
			if (!has(a) || !has(b)) return null;
			const input = k => {
				const el = h("input", { type: "time", step: 60 });
				el.addEventListener("change", () => el.value && set(k, `${el.value}:00`, "time.set_value", { time: `${el.value}:00` }));
				binders.push(() => {
					if (document.activeElement !== el) el.value = String(st(k) || "").slice(0, 5);
					el.disabled = !live(k);
				});
				return el;
			};
			return [h("div.vac-s-row", { class: dep ? "dep" : "", style: style() }, h("label", label), h("span.vac-times", input(a), h("span.subtle", "–"), input(b)))];
		}
		if (!has(key)) return null;
		const [, label, kidsOrUnit] = row;
		const domain = key.split(".")[0];
		let control;
		if (domain === "switch") {
			control = toggle(st(key) === "on", on => {
				if (!live(key)) return false;
				setSwitch(key, on);
			});
			binders.push(() => control.set(st(key) === "on"));
		} else if (domain === "select") {
			const options = at(key).options || [];
			if (options.length && options.length <= 4) {
				control = segmented(options.map(o => ({ value: o, label: word(o) })), st(key), v => setSelect(key, v));
				control.classList.add("small");
				binders.push(() => st(key) && control.dataset.value !== st(key) && control.select(st(key)));
			} else {
				control = h("button.chip.vac-pick", { type: "button" }, h("span", ""), icon("chevron_down"));
				control.addEventListener("click", event => {
					const r = control.getBoundingClientRect();
					showMenu(options.map(o => ({ label: word(o), checked: st(key) === o, run: () => setSelect(key, o) })), r.right - 180, r.bottom + 4, { keyboard: event.detail === 0 });
				});
				binders.push(() => (control.firstChild.textContent = word(st(key))));
			}
		} else if (domain === "number") {
			const a = at(key);
			const unit = typeof kidsOrUnit === "string" ? kidsOrUnit : "";
			const value = h("span.vac-val.vac-num", "");
			const s = slider(a.min ?? 0, a.max ?? 100, a.step ?? 1, v => setNumber(key, v), unit);
			s.onMove = v => (value.textContent = `${v}${unit}`);
			binders.push(() => {
				s.set(num(key));
				if (!s.classList.contains("drag")) value.textContent = num(key) != null ? `${num(key)}${unit}` : "";
			});
			control = h("span.vac-sl-wrap", s, value);
		}
		if (!control) return null;
		const el = h("div.vac-s-row", { class: dep ? "dep" : "", style: style() }, h("label", label), control);
		binders.push(() => el.classList.toggle("off", !live(key)));
		const out = [el];
		if (Array.isArray(kidsOrUnit)) {
			const kids = [];
			for (const kid of kidsOrUnit) {
				const made = makeRow(kid, true, count);
				if (made) kids.push(...made);
			}
			if (kids.length) {
				const box = fold(h("div.vac-kids", kids));
				binders.push(() => {
					box.show(st(key) === "on");
					// a washing interval shows only the measure it is set to
					if (key === "switch.self_clean") {
						const f = st("select.self_clean_frequency");
						kids.forEach(k => {
							const isArea = k.textContent.startsWith("Area"), isTime = k.textContent.startsWith("Time");
							if (isArea) k.hidden = f !== "by_area";
							if (isTime) k.hidden = f !== "by_time";
						});
					}
				});
				out.push(box);
			}
		}
		return out;
	}

	// ── helpers ──
	function minutes(v) {
		if (v == null) return "";
		const hrs = Math.floor(v / 60), m = Math.round(v % 60);
		return hrs ? `${hrs} h ${String(m).padStart(2, "0")} min` : `${m} min`;
	}
	function escape(s) {
		return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
	}

	// ── life ──
	const resize = new ResizeObserver(() => {
		mapCard.querySelector(".vac-card-shape").update();
		world.classList.add("instant");
		layout();
		requestAnimationFrame(() => world.classList.remove("instant"));
	});
	resize.observe(mapCard);
	resize.observe(mapNotch);
	const offs = [
		api.on("hass", onStates),
		api.on("smarthome", data => {
			const fresh = (data.nodes || []).find(n => n.id === id);
			if (fresh) node = fresh;
		}),
		api.on("socket", data => data.open && load())
	];
	load();

	const view = {
		el: root,
		title: "Smart home",
		icon: "power_plug",
		tabTitle: () => node?.view?.name || "Robot",
		tabIcon: () => "robot_vacuum",
		crumbs: () => [{ label: "Smart home", icon: "power_plug", href: "/smarthome" }, { label: node?.view?.name || "Robot", icon: "robot_vacuum" }],
		refresh: load,
		mounted: () => setTimeout(() => (hero.style.viewTransitionName = ""), 700),
		unmount: () => {
			gone = true;
			offs.forEach(off => off());
			resize.disconnect();
			clearTimeout(mapTimer);
			clearInterval(joyTimer);
		}
	};
	return view;
}
