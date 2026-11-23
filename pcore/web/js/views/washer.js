// A washing machine of Home Assistant on its own page (/smarthome/<node>,
// docs/core.md "Smart home"): what it does now and the one button for it on
// top, the programs (141 of hOn's, folded into families with their steam and
// length variants), the options and when it should be done, presets of
// one's own, the runs, and the device below. Everything comes from
// /api/smarthome/nodes/<id>/washer (washer.py) and moves with event `hass`.
import { h, icon, clear } from "../util.js";
import * as api from "../api.js";
import { isAdmin } from "../store.js";
import { stagger, countUp } from "../motion.js";
import { toast, errorToast, segmented, toggle, showMenu } from "../ui.js";

const SVG = "http://www.w3.org/2000/svg";
const svg = (tag, attrs = {}, parent) => {
	const el = document.createElementNS(SVG, tag);
	for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
	parent?.appendChild(el);
	return el;
};
const sentence = s => s.replace(/_/g, " ").replace(/^./, c => c.toUpperCase());
const escape = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ── programs: hOn's keys → families with steam and length variants ──
const NAMES = {
	"100_custom_wash": "Custom wash", "20_degrees": "20° wash", eco_40_60: "Eco 40–60", all_in_one: "All in one", men_s_trousers: "Trousers",
	resistant_cotton: "Cotton", cotton: "Cotton plus", synthetic_and_coloured: "Synthetics & colours", night_and_day: "Night & day",
	refresh_14_min: "Refresh", checkup: "Check-up", quick_drum_cleaner: "Drum clean", pets_odours_stains_removal: "Pet odours",
	pets_hair_removal: "Pet hair", swimsuits_and_bikinis: "Swimwear", denim_jeans: "Denim", drain_spin: "Drain & spin",
	darks_and_coloured: "Darks & colours", mix_and_coloured: "Mixed & colours", ariel_clean_cycle: "Ariel clean", ariel_cold_cycle: "Ariel cold",
	ariel_fresh_cycle: "Ariel fresh", dash_clean_cycle: "Dash clean", dash_cold_cycle: "Dash cold", dash_fresh_cycle: "Dash fresh",
	masks_sanification: "Mask sanitising", baby_sanitizer: "Baby sanitiser", anti_mites: "Anti-mites", sport_anti_odor: "Sport anti-odour",
	coloured_anti_stain: "Colours anti-stain", handwash_wool: "Hand wash & wool"
};
const CATS = [
	{ value: "recent", label: "Recent", icon: "history" },
	{ value: "presets", label: "Presets", icon: "star_outline" },
	{ value: "everyday", label: "Everyday", icon: "tshirt_crew_outline" },
	{ value: "quick", label: "Quick", icon: "lightning_bolt" },
	{ value: "delicate", label: "Delicate", icon: "flower_outline" },
	{ value: "hygiene", label: "Hygiene", icon: "shield_check_outline" },
	{ value: "stains", label: "Stains", icon: "spray_bottle" },
	{ value: "sport", label: "Sport", icon: "run" },
	{ value: "home", label: "Home", icon: "bed_king_outline" },
	{ value: "steps", label: "Steps", icon: "rotate_right" }
];
const RULES = [
	["steps", /^(rinse|spin|drain_spin|tumbling|autoclean|autocare|quick_drum_cleaner|checkup)$/],
	["quick", /rapid|refresh|^care$|fresh_care|masks_refresh|super_saving/],
	["hygiene", /hygiene|allerg|mites|baby|sanif|bleach|pets/],
	["stains", /stain|ariel|dash/],
	["sport", /fitness|sport|gym|technical|down_jackets|ski|diving|swim|trainers|backpacks|active_wash/],
	["home", /bed_linen|bathrobe|mats|cuddly|playsuits|trousers|denim|curtains|tablecloths/],
	["delicate", /delicate|handwash|wool|silk|cashmere|lingerie|soft_care|new_clothes|shirts/]
];
const ICONS = [
	[/custom/, "tune_variant"], [/eco/, "leaf"], [/20_deg|cold/, "snowflake"], [/night/, "weather_night"], [/rapid|refresh/, "lightning_bolt"],
	[/care$|fresh_care/, "flower_outline"], [/wool|cashmere/, "sheep"], [/hand/, "hand_wash_outline"], [/baby/, "baby_face_outline"],
	[/bed_linen/, "bed_king_outline"], [/curtains/, "curtains"], [/shirts|trousers|tablecloths/, "hanger"], [/pets/, "paw"],
	[/trainers/, "shoe_sneaker"], [/ski|down_jackets|technical|backpacks/, "hiking"], [/swim|diving/, "swim"], [/gym|fitness/, "dumbbell"],
	[/sport|active/, "run"], [/mites|allerg/, "bacteria_outline"], [/masks/, "virus_outline"], [/hygiene|sanit|bleach/, "shield_check_outline"],
	[/ariel|dash/, "bottle_tonic_outline"], [/stain/, "spray_bottle"], [/silk|lingerie|delicate|soft/, "heart_outline"], [/cuddly|playsuits/, "emoticon_outline"],
	[/mats|bathrobe/, "layers_outline"], [/rinse/, "water_outline"], [/drain/, "water_percent"], [/^spin/, "sync"], [/tumbling/, "rotate_right"],
	[/drum|autoclean|autocare/, "broom"], [/checkup/, "check_circle"], [/intensive|all_in_one/, "fire"], [/white/, "star_outline"],
	[/dark/, "weather_night"], [/synthetic|mix/, "tshirt_v_outline"], [/cotton|colou?r|denim/, "tshirt_crew_outline"]
];
// rough lengths where nothing better is known (the machine tells only once it runs)
const BASE_LEN = { everyday: 118, quick: 30, delicate: 62, hygiene: 150, stains: 128, sport: 74, home: 112, steps: 18 };
const STEP_LEN = { rinse: [0, 14, 6], spin: [0, 0, 12], drain_spin: [0, 0, 10], tumbling: [16, 0, 0], autoclean: [70, 14, 6], autocare: [70, 14, 6], quick_drum_cleaner: [40, 10, 5], checkup: [10, 4, 4] };
const PH = [
	{ k: "wash", label: "Wash", icon: "water", c: "var(--primary)", doing: "Washing" },
	{ k: "rinse", label: "Rinse", icon: "water_outline", c: "var(--water)", doing: "Rinsing" },
	{ k: "spin", label: "Spin", icon: "sync", c: "var(--secondary)", doing: "Spinning" }
];
// hOn's prPhase → wash / rinse / spin (washer.py has the same)
const PHASE_OF = n => ([1, 2, 14, 15, 16, 25, 26, 27, 9, 12, 13].includes(n) ? 0 : [4, 5, 6, 17, 18].includes(n) ? 1 : [3, 11].includes(n) ? 2 : null);
const TEMPS = [["0", "Cold", "#7cc3e8"], ["20", "20°", "#8fd3c7"], ["30", "30°", "#b5d68a"], ["40", "40°", "#f0c66b"], ["60", "60°", "#f89f65"], ["90", "90°", "#f17a86"]];
const OPTS = [
	{ k: "prewash", label: "Prewash", icon: "water_plus_outline", num: "number.prewash" },
	{ k: "rinse", label: "Extra rinse", icon: "water_outline", max: 3 },
	{ k: "hygiene", label: "Hygiene+", icon: "shield_check_outline", num: "number.hygiene" },
	{ k: "anticrease", label: "Anti-crease", icon: "iron_outline", num: "number.anticrease" },
	{ k: "acquaplus", label: "AquaPlus", icon: "cup_water", num: "number.acquaplus" },
	{ k: "goodnight", label: "Good night", icon: "weather_night", num: "number.goodnight" },
	{ k: "steam", label: "Steam", icon: "steam" }
];
const STATE_COLOR = { off: "var(--text-faint)", ready: "var(--primary)", scheduled: "var(--tertiary)", done: "var(--success)", paused: "var(--warning)", error: "var(--danger)" };
const SPAN = 24 * 60;

function families(options) {
	const fams = new Map(), keys = {};
	for (const key of options) {
		const steam = key.endsWith("_steam");
		let b = key.replace(/^iot_wash_/, "").replace(/^iot_/, "").replace(/_steam$/, "").replace(/_new_energy_label$/, "").replace(/colored/g, "coloured");
		const m = b.match(/^(.*?)_(\d+|xl)$/);
		const fam = m && !/^(eco_40|refresh_14)/.test(b) ? m[1] : b;
		const len = m && fam !== b ? m[2] : "";
		if (!fams.has(fam)) {
			const cat = (RULES.find(([, re]) => re.test(fam)) || ["everyday"])[0];
			const ic = (ICONS.find(([re]) => re.test(fam)) || [0, "washing_machine"])[1];
			fams.set(fam, { id: fam, name: NAMES[fam] || sentence(fam), cat, icon: ic, keys: {}, lens: [], steam: false });
		}
		const f = fams.get(fam);
		if (len && !f.lens.includes(len)) f.lens.push(len);
		if (steam) f.steam = true;
		// the plain one wins over a twin with the same name (colored / coloured)
		const slot = len + (steam ? "|s" : "");
		if (!f.keys[slot]) f.keys[slot] = key;
		keys[key] = { fam, len, steam };
	}
	for (const f of fams.values()) f.lens.sort((a, b) => (a === "xl") - (b === "xl") || a - b);
	return { fams, keys };
}

const sum = a => a.reduce((x, y) => x + y, 0);
const hm = m => (m >= 60 ? `${Math.floor(m / 60)}:${String(Math.round(m % 60)).padStart(2, "0")}` : String(Math.max(0, Math.round(m))));
const unitOf = m => (m >= 60 ? "h" : "min");
const clock = d => d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const addMin = m => new Date(Date.now() + m * 60000);

export default function washerPage(route, app, known) {
	const id = route.parts[0];
	const admin = isAdmin();
	const E = {};                 // short key → {s, a, c, id, off}
	const byId = {};
	let R = {};                   // roles: program, spin, temp, phase, mode, … → short key
	let node = known || null;
	let presets = [];
	let runs = [];
	let P = { fams: new Map(), keys: {} };
	let gone = false;
	let cat = "recent", query = "";
	let fresh = null;             // a preset just made: it pops in
	let starting = 0;
	// what is set up here for the next run (local until it starts)
	const W = { fam: "", len: "", steam: false, temp: "30", spin: "1200", soil: 1, delay: 0,
		opts: { prewash: 0, rinse: 0, hygiene: 0, anticrease: 0, acquaplus: 0, goodnight: 0 } };

	const st = k => E[k]?.s;
	const at = k => E[k]?.a || {};
	const has = k => !!E[k] && !E[k].off;
	const num = k => {
		const v = parseFloat(st(k));
		return Number.isFinite(v) ? v : null;
	};
	const fam = () => P.fams.get(W.fam);
	const steamOk = () => !!fam()?.keys[W.len + "|s"];
	const programKey = () => {
		const f = fam();
		if (!f) return null;
		return (W.steam && f.keys[W.len + "|s"]) || f.keys[W.len] || f.keys[W.len + "|s"] || Object.values(f.keys)[0];
	};
	const famOfKey = key => {
		const k = P.keys[key];
		return k ? P.fams.get(k.fam) : null;
	};
	const nameOfKey = key => {
		const k = P.keys[key], f = famOfKey(key);
		if (!f) return key ? sentence(String(key).replace(/^iot_wash_|^iot_/, "")) : "";
		return f.name + (k.len ? ` ${k.len === "xl" ? "XL" : k.len + "′"}` : "");
	};

	// ── what the machine does ──
	function machine() {
		const power = st("binary_sensor.status");
		if (power === "off" || power === "unavailable" || st(R.mode) === "unavailable") return "off";
		return { 2: "running", 3: "paused", 4: "scheduled", 5: "error", 7: "done" }[st(R.mode)] || "ready";
	}
	const working = s => ["running", "paused", "scheduled"].includes(s);
	const remote = () => st(R.remote) === "on";

	// ── how long a program takes: its own runs, else its name, else a rough guess ──
	function known_(key) {
		const same = runs.filter(r => r.program === key && sum(r.phases) > 0);
		if (!same.length) return null;
		return [0, 1, 2].map(i => Math.round(sum(same.map(r => r.phases[i])) / same.length));
	}
	function phasesOf(f, len, key) {
		const mine = key && known_(key);
		if (mine) return mine;
		if (STEP_LEN[f.id]) return [...STEP_LEN[f.id]];
		let total = len && len !== "xl" ? +len : len === "xl" ? 90 : BASE_LEN[f.cat];
		if (/eco/.test(f.id)) total = 208;
		if (/20_deg|cold/.test(f.id)) total = 75;
		const a = Math.round(total * 0.62), b = Math.round(total * 0.24);
		return [a, b, total - a - b];
	}
	const isKnown = key => !!known_(key);
	function plan() {
		const f = fam();
		if (!f) return [0, 0, 0];
		const key = programKey();
		const p = phasesOf(f, W.len, key);
		if (isKnown(key)) return p;
		const o = W.opts;
		if (p[0]) {
			p[0] += o.prewash * 16 + o.hygiene * 28 + (W.soil - 1) * 9 + o.goodnight * 34 + o.acquaplus * 6 + (steamOk() && W.steam ? 12 : 0);
			if (W.temp === "90") p[0] += 22;
			else if (W.temp === "60") p[0] += 10;
		}
		if (p[1]) p[1] += o.rinse * 8 + o.acquaplus * 6;
		if (p[2] && W.spin === "0") p[2] = 2;
		if (p[2] && o.anticrease) p[2] += 4;
		return p;
	}

	// ── the frame ──
	const page = h("div.wm-page");
	const root = h("div.page-scroll.wm-scroll", page);

	// ══ HERO ══════════════════════════════════════════════════════════════
	const drum = svg("svg", { class: "wm-drum", viewBox: "0 0 136 136" });
	const defs = svg("defs", {}, drum);
	svg("circle", { cx: 68, cy: 68, r: 42 }, svg("clipPath", { id: `wm-clip-${id}` }, defs));
	const grad = svg("radialGradient", { id: `wm-glass-${id}`, cx: "40%", cy: "35%", r: "75%" }, defs);
	svg("stop", { offset: 0, "stop-color": "#22253a" }, grad);
	svg("stop", { offset: 1, "stop-color": "#0b0d18" }, grad);
	svg("circle", { class: "wm-ring-bg", cx: 68, cy: 68, r: 64 }, drum);
	const ring = svg("circle", { class: "wm-ring", cx: 68, cy: 68, r: 64, pathLength: 100, "stroke-dasharray": 100, "stroke-dashoffset": 100 }, drum);
	const body = svg("g", { class: "wm-body" }, drum);
	svg("circle", { class: "wm-door", cx: 68, cy: 68, r: 55 }, body);
	svg("rect", { class: "wm-handle", x: 117, y: 58, width: 8, height: 20, rx: 4 }, body);
	svg("circle", { class: "wm-glass", cx: 68, cy: 68, r: 43, fill: `url(#wm-glass-${id})` }, body);
	const inside = svg("g", { "clip-path": `url(#wm-clip-${id})` }, body);
	const wave = "M0 6 Q10 0 20 6 T40 6 T60 6 T80 6 T100 6 T120 6 T140 6 T160 6 T180 6 V80 H0 Z";
	const waterBack = svg("g", { class: "wm-water back" }, inside);
	svg("path", { class: "wm-wave", d: wave }, waterBack);
	const tumble = svg("g", { class: "wm-tumble" }, inside);
	for (let k = 0; k < 20; k++) {
		const a = (k / 20) * Math.PI * 2;
		svg("circle", { class: "wm-hole", cx: 68 + Math.cos(a) * 38, cy: 68 + Math.sin(a) * 38, r: 1.3 }, tumble);
	}
	const clothes = svg("g", { class: "wm-clothes" }, tumble);
	[[44, 80, 24, 16, "var(--primary)", -10, 12], [64, 84, 26, 14, "var(--secondary)", 12, 10], [56, 70, 20, 13, "var(--tertiary)", 2, -30],
		[78, 74, 16, 12, "#7cc3e8", 18, -6], [38, 72, 16, 12, "#f0c66b", -20, -8]].forEach(([x, y, w, hh, fill, ox, oy]) =>
		svg("rect", { class: "wm-cloth", x, y, width: w, height: hh, rx: 6.5, fill, style: `--ox:${ox}px;--oy:${oy}px` }, clothes));
	const waterFront = svg("g", { class: "wm-water" }, inside);
	svg("path", { class: "wm-wave", d: wave }, waterFront);
	for (let k = 0; k < 7; k++) svg("circle", { class: "wm-bub", style: `--k:${k}`, cx: 42 + ((k * 37) % 52), cy: 98 - (k % 3) * 6, r: 1.4 + (k % 3) * 0.8 }, inside);
	svg("path", { class: "wm-shine", d: "M44 52 A30 30 0 0 1 62 36" }, body);
	const check = svg("g", { class: "wm-check" }, body);
	svg("circle", { cx: 68, cy: 68, r: 20 }, check);
	svg("path", { d: "M58 68 l7 7 l13 -14" }, check);
	[[96, 36], [104, 26]].forEach(([x, y]) => (svg("text", { class: "wm-zz", x, y }, body).textContent = "z"));
	const badgeText = h("span", "–");
	const titleBox = h("div.wm-swap.wm-title");
	const subBox = h("div.wm-swap.wm-sub");
	const fact = (label, unit = "") => {
		const value = h("b", "–"), u = h("small", unit), name = h("span", label);
		return { el: h("div.wm-fact", h("div.wm-fact-v", value, u), name), value, unit: u, name };
	};
	const fLeft = fact("Left", "min"), fEnd = fact("Ends"), fRuns = fact("Programs"), fTemp = fact("Water", "°C"), fSpin = fact("Drum", "rpm");
	const phasesEl = h("div.wm-phases");
	const holdSvg = svg("svg", { viewBox: "0 0 92 92" });
	svg("circle", { cx: 46, cy: 46, r: 44 }, holdSvg);
	const go = h("button.wm-go", { type: "button", "aria-label": "Start" }, holdSvg,
		icon("play", "ic-play"), icon("stop", "ic-stop"), icon("lock_outline", "ic-lock"));
	const goLabel = h("div.wm-swap.wm-go-label");
	const remoteChip = h("span.wm-remote.hide", icon("remote"), "Remote off");
	const hero = h("section.wm-hero",
		h("div.wm-glow"),
		h("div.wm-drum-wrap", drum, h("div.wm-badge", icon("thermometer"), badgeText)),
		h("div.wm-status", titleBox, subBox, h("div.wm-facts", fLeft.el, fEnd.el, fRuns.el, fTemp.el, fSpin.el), phasesEl),
		h("div.wm-controls", go, goLabel, remoteChip));
	hero.style.viewTransitionName = "wm-hero";

	function swap(box, html) {
		const current = box.querySelector(":scope > :not(.out)");
		if (current && current.dataset.html === html) return;
		if (current) {
			current.classList.add("out");
			setTimeout(() => current.remove(), 340);
		}
		const next = h("span.in", { dataset: { html } });
		next.innerHTML = html;
		box.appendChild(next);
	}

	// ══ PROGRAMS ══════════════════════════════════════════════════════════
	const cats = segmented(CATS.map(c => ({ value: c.value, label: h("span.lbl", c.label), icon: c.icon, title: c.label })), cat, v => {
		cat = v;
		query = "";
		searchInput.value = "";
		search.classList.remove("open");
		paintTiles();
		// the label grows while the thumb moves: follow it
		const t0 = performance.now();
		const follow = t => {
			cats.select(cats.dataset.value);
			if (t - t0 < 560) requestAnimationFrame(follow);
		};
		requestAnimationFrame(follow);
	});
	cats.classList.add("wm-cats");
	const notch = h("div.wm-notch", cats);
	const shape = svg("svg", { class: "wm-shape", "aria-hidden": "true" });
	const shapePath = svg("path", {}, shape);
	const catName = h("h2", "Recent");
	const searchInput = h("input", { placeholder: "Program", "aria-label": "Program" });
	const searchIcon = icon("magnify");
	const search = h("label.wm-search", searchIcon, searchInput);
	const tiles = h("div.wm-tiles");
	const progCard = h("section.wm-card.wm-programs", shape, notch, h("div.wm-card-head", icon("playlist_play"), catName, search), tiles);

	searchIcon.addEventListener("click", event => {
		event.preventDefault();
		search.classList.toggle("open");
		if (search.classList.contains("open")) searchInput.focus();
		else {
			query = "";
			searchInput.value = "";
			paintTiles();
		}
	});
	searchInput.addEventListener("input", () => {
		query = searchInput.value.trim();
		paintTiles();
	});

	function drawShape() {
		const W_ = progCard.offsetWidth, H = progCard.offsetHeight;
		if (!W_) return;
		const R_ = 22, r = 18, c = 14;
		// the notch is centred with translateX(-50%), which offsetLeft does not see
		const x0 = notch.offsetLeft - notch.offsetWidth / 2, x1 = x0 + notch.offsetWidth, d = notch.offsetHeight;
		shape.setAttribute("viewBox", `0 0 ${W_} ${H}`);
		shapePath.setAttribute("d", `M0,${R_} A${R_},${R_} 0 0 1 ${R_},0 L${x0 - c},0 A${c},${c} 0 0 1 ${x0},${c} L${x0},${d - r} `
			+ `A${r},${r} 0 0 0 ${x0 + r},${d} L${x1 - r},${d} A${r},${r} 0 0 0 ${x1},${d - r} L${x1},${c} A${c},${c} 0 0 1 ${x1 + c},0 `
			+ `L${W_ - R_},0 A${R_},${R_} 0 0 1 ${W_},${R_} L${W_},${H - R_} A${R_},${R_} 0 0 1 ${W_ - R_},${H} L${R_},${H} A${R_},${R_} 0 0 1 0,${H - R_} Z`);
	}

	const recentCount = () => {
		const out = {};
		runs.forEach(r => {
			const f = famOfKey(r.program);
			if (f) out[f.id] = (out[f.id] || 0) + 1;
		});
		return out;
	};
	function listFor() {
		const all = [...P.fams.values()];
		if (query) {
			const q = query.toLowerCase();
			return all.filter(f => f.name.toLowerCase().includes(q));
		}
		if (cat === "recent") {
			const counts = recentCount();
			const ids = [...Object.keys(counts).sort((a, b) => counts[b] - counts[a]), W.fam, "eco_40_60", "rapid", "100_custom_wash"];
			return [...new Set(ids)].map(i => P.fams.get(i)).filter(Boolean);
		}
		return all.filter(f => f.cat === cat).sort((a, b) => a.name.localeCompare(b.name));
	}
	function paintTiles() {
		if (cat === "presets" && !query) return paintPresets();
		const list = listFor(), counts = recentCount();
		catName.textContent = query ? `“${query}”` : CATS.find(c => c.value === cat).label;
		clear(tiles);
		if (!list.length) tiles.appendChild(h("div.wm-empty", icon("magnify")));
		list.forEach((f, n) => {
			const key = f.keys[f.lens[0] || ""] || Object.values(f.keys)[0];
			const t = sum(phasesOf(f, f.lens[0] || "", key));
			const meta = f.lens.length > 1 ? f.lens.map(x => (x === "xl" ? "XL" : x + "′")).join(" · ")
				: isKnown(key) || STEP_LEN[f.id] || f.lens.length ? `${hm(t)} ${unitOf(t)}` : "";
			const tile = h("button.wm-tile", { type: "button", class: f.id === W.fam ? "on" : "", style: `--n:${n}`, dataset: { f: f.id } },
				h("span.wm-tic", icon(f.icon)),
				h("span", h("b", f.name), h("small", meta, f.steam ? icon("steam") : null)),
				counts[f.id] ? h("span.wm-count", `${counts[f.id]}×`) : null);
			tiles.appendChild(tile);
		});
		requestAnimationFrame(drawShape);
	}
	tiles.addEventListener("click", event => {
		const tile = event.target.closest(".wm-tile");
		if (!tile || event.target.closest(".wm-more, .wm-rename")) return;
		if (working(machine())) {
			toast("It is washing", { icon: "lock_outline" });
			return;
		}
		if (tile.dataset.p) return applyPreset(tile);
		const f = P.fams.get(tile.dataset.f);
		flyIcon(tile.querySelector(".wm-tic"));
		W.fam = f.id;
		const last = runs.find(r => famOfKey(r.program)?.id === f.id);
		const lastKey = last && P.keys[last.program];
		W.len = lastKey ? lastKey.len : f.lens.includes("44") ? "44" : f.lens[0] || "";
		W.steam = !!lastKey?.steam;
		if (last?.temp != null && TEMPS.some(t => t[0] === String(last.temp))) W.temp = String(last.temp);
		if (last?.spin) W.spin = String(last.spin);
		tiles.querySelectorAll(".wm-tile").forEach(x => x.classList.toggle("on", x === tile));
		paint();
	});

	// the program's icon flies from its tile into the setup card
	function flyIcon(from) {
		const a = from.getBoundingClientRect(), b = setupIcon.getBoundingClientRect();
		if (!a.width || !b.width) return;
		const c = from.cloneNode(true);
		c.style.cssText = `position:fixed;left:${a.left}px;top:${a.top}px;width:${a.width}px;height:${a.height}px;margin:0;z-index:60;background:var(--primary);color:var(--on-primary);transition:none;pointer-events:none`;
		document.body.appendChild(c);
		c.animate([{ transform: "none" }, { transform: `translate(${b.left - a.left}px, ${b.top - a.top}px) scale(${b.width / a.width}) rotate(360deg)` }],
			{ duration: 620, easing: "cubic-bezier(0.2, 0, 0, 1)" }).onfinish = () => {
			c.remove();
			setupIcon.animate([{ transform: "scale(1.25)" }, { transform: "none" }], { duration: 520, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)" });
		};
	}

	// ══ PRESETS ═══════════════════════════════════════════════════════════
	const OPT_ICON = Object.fromEntries(OPTS.map(o => [o.k, o.icon]));
	const snap = () => ({ program: programKey(), temp: W.temp, spin: W.spin, soil: W.soil, ...W.opts });
	const sig = x => JSON.stringify([x.program, x.temp, x.spin, x.soil, ...OPTS.filter(o => o.k !== "steam").map(o => x[o.k] || 0)]);
	const matchPreset = () => {
		const k = sig(snap());
		return presets.find(p => sig(p) === k);
	};
	async function keep(next, before) {
		presets = next;
		paintTiles();
		paintSetup();
		try {
			const got = await api.put(`/api/smarthome/nodes/${encodeURIComponent(id)}/washer/presets`, { presets: next });
			presets = got.presets;
			return true;
		} catch (error) {
			errorToast(error);
			presets = before;
			paintTiles();
			paintSetup();
			return false;
		}
	}
	function paintPresets() {
		catName.textContent = "Presets";
		const now = matchPreset();
		clear(tiles);
		if (!presets.length) tiles.appendChild(h("div.wm-empty", icon("star_outline")));
		presets.forEach((p, n) => {
			const f = famOfKey(p.program) || { icon: "washing_machine" };
			const k = P.keys[p.program] || {};
			const on = OPTS.filter(o => o.k !== "steam" && p[o.k]);
			const tile = h("div.wm-tile.preset", {
				role: "button", tabIndex: 0, draggable: admin, dataset: { p: p.id }, style: `--n:${n}`,
				class: [now?.id === p.id ? "on" : "", fresh === p.id ? "new" : ""].filter(Boolean).join(" ")
			},
			h("span.wm-tic", icon(f.icon)),
			h("span", h("b", p.name),
				h("small", `${nameOfKey(p.program)} · ${p.temp === "0" ? "Cold" : p.temp + "°"} · ${p.spin === "0" ? "No spin" : p.spin}`),
				on.length || k.steam ? h("span.wm-opt-icons", k.steam ? icon("steam") : null, on.map(o => icon(o.icon))) : null),
			admin ? h("button.wm-more", { type: "button", title: "More", "aria-label": "More" }, icon("dots_vertical")) : null);
			tile.addEventListener("keydown", event => event.key === "Enter" && event.target === tile && applyPreset(tile));
			tiles.appendChild(tile);
		});
		fresh = null;
		requestAnimationFrame(drawShape);
	}
	function applyPreset(tile) {
		const p = presets.find(x => x.id === tile.dataset.p);
		const k = P.keys[p.program];
		if (!k) {
			toast("This machine has no such program any more", { icon: "alert_circle_outline", tone: "warn" });
			return;
		}
		flyIcon(tile.querySelector(".wm-tic"));
		Object.assign(W, { fam: k.fam, len: k.len, steam: k.steam, temp: p.temp, spin: p.spin, soil: p.soil || 1 });
		for (const o of OPTS) if (o.k !== "steam") W.opts[o.k] = p[o.k] || 0;
		paint();
	}
	tiles.addEventListener("click", event => {
		const more = event.target.closest(".wm-more");
		if (!more) return;
		event.stopPropagation();
		const tile = more.closest(".wm-tile");
		const p = presets.find(x => x.id === tile.dataset.p);
		const same = sig(p) === sig(snap());
		const r = more.getBoundingClientRect();
		showMenu([
			{ label: "Rename", icon: "pencil_outline", run: () => rename(tile, p) },
			{ label: "Use current settings", icon: "content_save_outline", enabled: !same, run: () => {
				const before = presets;
				fresh = p.id;
				keep(presets.map(x => (x.id === p.id ? { ...x, ...snap() } : x)), before).then(ok => ok && toast(`${p.name} updated`, { icon: "content_save_outline" }));
			} },
			{ separator: true },
			{ label: "Delete", icon: "trash_can_outline", danger: true, run: () => {
				const before = presets;
				tile.classList.add("gone");
				setTimeout(() => keep(presets.filter(x => x.id !== p.id), before).then(ok => ok && toast(`${p.name} deleted`, { icon: "trash_can_outline" })), 400);
			} }
		], r.right - 200, r.bottom + 4, { keyboard: event.detail === 0 });
	}, true);
	function rename(tile, p) {
		const b = tile.querySelector("b"), input = h("input.wm-rename", { value: p.name, maxLength: 40 });
		b.replaceWith(input);
		input.focus();
		input.select();
		let done = false;
		const finish = ok => {
			if (done) return;
			done = true;
			const name = input.value.trim();
			if (ok && name && name !== p.name) keep(presets.map(x => (x.id === p.id ? { ...x, name } : x)), presets);
			else paintTiles();
		};
		input.addEventListener("keydown", event => {
			event.stopPropagation();
			if (event.key === "Enter") finish(true);
			if (event.key === "Escape") finish(false);
		});
		input.addEventListener("click", event => event.stopPropagation());
		input.addEventListener("blur", () => finish(true));
	}
	// drag to reorder
	let dragId = null;
	tiles.addEventListener("dragstart", event => {
		const tile = event.target.closest(".wm-tile.preset");
		if (!tile) return;
		dragId = tile.dataset.p;
		tile.classList.add("dragging");
		event.dataTransfer.effectAllowed = "move";
	});
	tiles.addEventListener("dragover", event => {
		if (!dragId) return;
		event.preventDefault();
		const tile = event.target.closest(".wm-tile.preset");
		tiles.querySelectorAll(".drop-before").forEach(x => x.classList.remove("drop-before"));
		if (tile && tile.dataset.p !== dragId) tile.classList.add("drop-before");
	});
	tiles.addEventListener("drop", event => {
		event.preventDefault();
		if (!dragId) return;
		const tile = event.target.closest(".wm-tile.preset");
		const before = presets;
		const next = presets.filter(p => p.id !== dragId);
		const moved = presets.find(p => p.id === dragId);
		const to = tile ? next.findIndex(p => p.id === tile.dataset.p) : next.length;
		next.splice(to < 0 ? next.length : to, 0, moved);
		dragId = null;
		// FLIP: the tiles glide to their new places
		const rects = new Map([...tiles.children].map(el => [el.dataset.p, el.getBoundingClientRect()]));
		keep(next, before);
		[...tiles.children].forEach(el => {
			el.style.animation = "none";
			const a = rects.get(el.dataset.p), b = el.getBoundingClientRect();
			if (a) el.animate([{ transform: `translate(${a.left - b.left}px, ${a.top - b.top}px)` }, { transform: "none" }], { duration: 480, easing: "cubic-bezier(0.2, 0, 0, 1)" });
		});
	});
	tiles.addEventListener("dragend", () => {
		dragId = null;
		tiles.querySelectorAll(".dragging, .drop-before").forEach(x => x.classList.remove("dragging", "drop-before"));
	});

	// ══ SETUP ═════════════════════════════════════════════════════════════
	const setupIcon = h("div.wm-setup-icon", icon("washing_machine"));
	const setupName = h("div.wm-swap");
	const setupCat = h("div.wm-swap");
	const durV = h("span", "–"), durU = h("small", "min");
	const saveText = h("span", "Save");
	const saveBtn = h("button.btn.small.wm-save", { type: "button", hidden: !admin }, icon("star_outline"), saveText);
	const saveName = h("input", { maxLength: 40, "aria-label": "Name" });
	const saveRow = h("div.wm-save-row", h("div", h("div.wm-save-in", icon("star"), saveName,
		h("button.icon-btn.small", { type: "button", title: "Cancel", "aria-label": "Cancel", onclick: () => openSave(false) }, icon("close")),
		h("button.btn.small.primary", { type: "button", onclick: () => doSave() }, icon("check"), "Save"))));
	const variants = h("div.wm-variants");
	const temps = segmented(TEMPS.map(([value, label]) => ({ value, label })), W.temp, v => {
		W.temp = v;
		paint();
	});
	temps.classList.add("fill");
	const tempVal = h("span.wm-val", "");
	const spins = segmented(["0", "400", "800", "1200", "1600"].map(v => ({ value: v, label: v === "0" ? "Off" : v })), W.spin, v => {
		W.spin = v;
		paint();
	});
	spins.classList.add("fill");
	const spinVal = h("span.wm-val", "");
	const spinIc = icon("sync", "wm-spin-ic");
	const soilDots = n => h("span.wm-soil", [1, 2, 3].map(k => h("i", { class: k <= n ? "on" : "" })));
	const soil = segmented([1, 2, 3].map(v => ({ value: v, label: h("span", soilDots(v), " ", ["Light", "Normal", "Heavy"][v - 1]) })), W.soil, v => {
		W.soil = +v;
		paint();
	});
	soil.classList.add("small");
	const optEls = OPTS.map(o => {
		const b = h("button.wm-opt", { type: "button", dataset: { k: o.k } }, icon(o.icon), o.label,
			o.max ? h("span.wm-pips", Array.from({ length: o.max }, () => h("i"))) : null);
		b.addEventListener("click", () => {
			if (o.k === "steam") W.steam = !W.steam;
			else W.opts[o.k] = o.max ? (W.opts[o.k] + 1) % (o.max + 1) : 1 - W.opts[o.k];
			paint();
		});
		return b;
	});
	const finishV = h("div.wm-swap");
	const finishS = h("span", "");
	const finishNow = h("button.btn.small", { type: "button", onclick: () => {
		W.delay = 0;
		paint();
	} }, icon("close"), "Now");
	const ruler = h("div.wm-ruler");
	const runBlock = h("div.wm-run", icon("washing_machine"));
	const setupCard = h("section.wm-card.wm-setup",
		h("div.wm-card-head", setupIcon, h("div.wm-setup-name", setupName, setupCat), h("span.wm-dur", durV, durU), saveBtn),
		saveRow, variants,
		h("div.wm-field", h("div.wm-field-head", icon("thermometer"), "Temperature", tempVal), temps, h("div.wm-scale")),
		h("div.wm-field", h("div.wm-field-head", spinIc, "Spin", spinVal), spins),
		h("div.wm-field", h("div.wm-field-head", icon("tshirt_crew_outline"), "Soil", h("span.wm-grow"), soil)),
		h("div.wm-field", h("div.wm-field-head", icon("tune_variant"), "Options"), h("div.wm-opts", optEls)),
		h("div.wm-field", h("div.wm-finish", icon("clock_end"), h("div.wm-when", finishV, finishS), h("span.wm-grow"), finishNow), ruler));

	// save: the star opens a name field under the head
	function openSave(open) {
		saveRow.classList.toggle("open", open);
		if (open) {
			saveName.value = `${nameOfKey(programKey())} ${W.temp === "0" ? "cold" : W.temp + "°"}`;
			setTimeout(() => {
				saveName.focus();
				saveName.select();
			}, 120);
		}
	}
	saveBtn.addEventListener("click", () => {
		const now = matchPreset();
		if (now) {
			cat = "presets";
			cats.select("presets");
			paintTiles();
			tiles.querySelector(`[data-p="${CSS.escape(now.id)}"]`)?.animate([{ transform: "scale(1.05)" }, { transform: "none" }], { duration: 500, easing: "cubic-bezier(0.34, 1.56, 0.64, 1)" });
			return;
		}
		openSave(!saveRow.classList.contains("open"));
	});
	async function doSave() {
		const name = saveName.value.trim();
		if (!name) return saveName.focus();
		const p = { id: `p${Date.now().toString(36)}`, name, ...snap() };
		fresh = p.id;
		openSave(false);
		cat = "presets";
		query = "";
		cats.select("presets");
		if (await keep([...presets, p], presets)) toast(`${name} saved`, { icon: "star" });
	}
	saveName.addEventListener("keydown", event => {
		if (event.key === "Enter") doSave();
		if (event.key === "Escape") openSave(false);
	});

	// finish at: the next 24 h, the run drags in 30 min steps (hOn's delayTime 0…1410)
	function buildRuler() {
		clear(ruler);
		const now = new Date(), m0 = now.getHours() * 60 + now.getMinutes();
		for (const start of [22 * 60 - m0, 22 * 60 - m0 + SPAN, 22 * 60 - m0 - SPAN]) {
			const a = Math.max(0, start), b = Math.min(SPAN, start + 8 * 60);
			if (b > a) ruler.appendChild(h("div.wm-night", { style: { left: `${(a / SPAN) * 100}%`, width: `${((b - a) / SPAN) * 100}%` } }, icon("weather_night")));
		}
		for (let m = 60 - (m0 % 60); m < SPAN; m += 60) {
			const hr = Math.floor((m0 + m) / 60) % 24;
			ruler.appendChild(h("div.wm-tick", { class: hr % 3 === 0 ? "h3" : "", style: { left: `${(m / SPAN) * 100}%` } },
				hr % 3 === 0 ? h("span", String(hr).padStart(2, "0")) : null));
		}
		ruler.append(h("div.wm-now"), runBlock);
	}
	let grab = null;
	ruler.addEventListener("pointerdown", event => {
		ruler.setPointerCapture(event.pointerId);
		ruler.classList.add("drag");
		const b = runBlock.getBoundingClientRect();
		grab = event.clientX >= b.left && event.clientX <= b.right ? event.clientX - b.left : b.width / 2;
		moveRuler(event);
	});
	ruler.addEventListener("pointermove", event => grab != null && moveRuler(event));
	const endDrag = () => {
		grab = null;
		ruler.classList.remove("drag");
		paint();
	};
	ruler.addEventListener("pointerup", endDrag);
	ruler.addEventListener("pointercancel", endDrag);
	function moveRuler(event) {
		const r = ruler.getBoundingClientRect();
		const m = ((event.clientX - grab - r.left) / r.width) * SPAN;
		const d = Math.max(0, Math.min(1410, Math.round(m / 30) * 30));
		if (d !== W.delay) {
			W.delay = d;
			paintRuler();
		}
	}

	// ══ RUNS ══════════════════════════════════════════════════════════════
	const runList = h("div");
	const sTotal = h("span", "0"), sAvg = h("span", "0");
	const favName = h("b", "–"), favSub = h("span", "");
	const week = h("div.wm-week");
	const runsCard = h("section.wm-card",
		h("div.wm-card-head", icon("history"), h("h2", "Runs"),
			h("div.wm-legend", PH.map(p => h("span", { style: `--c:${p.c}` }, h("i"), p.label)))),
		h("div.wm-runs-grid", runList, h("div.wm-stats",
			h("div.wm-stat", h("b", sTotal), h("span", "Programs")),
			h("div.wm-stat", h("b", sAvg, h("small", " min")), h("span", "Average")),
			h("div.wm-stat.wide", icon("trophy_outline"), favName, favSub),
			week)));

	// ══ DEVICE ════════════════════════════════════════════════════════════
	const alertToggle = toggle(false, on => {
		if (!admin) return false;
		call("input_boolean." + (on ? "turn_on" : "turn_off"), "input_boolean.notifications").catch(() => alertToggle.set(!on));
	});
	const remoteRow = h("span.v");
	const nightRow = h("span.v");
	const fetchBtn = (key, label) => {
		const i = icon("refresh");
		const b = h("button.btn.small", { type: "button", disabled: !admin }, label, i);
		b.addEventListener("click", () => {
			i.classList.remove("wm-spin-once");
			void i.offsetWidth;
			i.classList.add("wm-spin-once");
			call("button.press", key).then(() => toast("Asked the machine", { icon: "refresh" }), () => {});
		});
		return b;
	};
	const progCount = h("span", "");
	const meta = h("div.wm-meta");
	const rows = h("div.wm-rows");
	const deviceCard = h("section.wm-card.wm-device", h("div.wm-card-head", icon("cog_outline"), h("h2", "Device")), rows, meta);

	async function call(service, key, data = {}) {
		if (!admin) {
			toast("Only admins can steer it", { icon: "lock_outline", tone: "warn" });
			throw new Error("not admin");
		}
		try {
			await api.post(`/api/smarthome/nodes/${encodeURIComponent(id)}/washer/call`, { service, entity: E[key]?.id, data });
		} catch (error) {
			errorToast(error);
			throw error;
		}
	}

	// ══ START / STOP ══════════════════════════════════════════════════════
	let holdTimer = 0;
	go.addEventListener("pointerdown", () => {
		if (!go.classList.contains("stop") || !admin) return;
		go.classList.add("holding");
		holdTimer = setTimeout(() => {
			go.classList.remove("holding");
			stop();
		}, 900);
	});
	const unhold = () => {
		clearTimeout(holdTimer);
		go.classList.remove("holding");
	};
	go.addEventListener("pointerup", unhold);
	go.addEventListener("pointerleave", unhold);
	go.addEventListener("click", () => {
		if (go.classList.contains("stop")) {
			if (!admin) toast("Only admins can steer it", { icon: "lock_outline", tone: "warn" });
			return;
		}
		if (go.classList.contains("locked")) {
			go.classList.remove("shake");
			void go.offsetWidth;
			go.classList.add("shake");
			if (!admin) toast("Only admins can steer it", { icon: "lock_outline", tone: "warn" });
			else if (machine() === "off") toast("The machine is off", { icon: "washing_machine_off" });
			else {
				remoteChip.classList.remove("pulse");
				void remoteChip.offsetWidth;
				remoteChip.classList.add("pulse");
			}
			return;
		}
		start();
	});
	async function start() {
		const program = programKey();
		if (!program) return;
		const options = { temp: +W.temp, spinSpeed: +W.spin, dirtyLevel: W.soil, prewash: W.opts.prewash, hygiene: W.opts.hygiene,
			anticrease: W.opts.anticrease, acquaplus: W.opts.acquaplus, goodNight: W.opts.goodnight, delayTime: W.delay };
		for (let i = 1; i <= 3; i++) options[`extraRinse${i}`] = W.opts.rinse >= i ? 1 : 0;
		starting = Date.now();
		paintHero();
		try {
			await api.post(`/api/smarthome/nodes/${encodeURIComponent(id)}/washer/start`, { program, options });
			toast(W.delay ? `${nameOfKey(program)} starts ${clock(addMin(W.delay))}` : `${nameOfKey(program)} started`, { icon: W.delay ? "clock_start" : "play" });
		} catch (error) {
			starting = 0;
			errorToast(error);
		}
		paintHero();
		setTimeout(paintHero, 10500);
	}
	async function stop() {
		try {
			await api.post(`/api/smarthome/nodes/${encodeURIComponent(id)}/washer/stop`);
			toast("Stopped", { icon: "stop" });
		} catch (error) {
			errorToast(error);
		}
	}

	const loading = h("div.wm-loading", icon("washing_machine"));
	page.append(hero, loading);

	// ══ LOADING ═══════════════════════════════════════════════════════════
	async function load() {
		try {
			const got = await api.get(`/api/smarthome/nodes/${encodeURIComponent(id)}/washer`);
			if (gone) return;
			node = got.node;
			R = got.roles || {};
			presets = got.presets || [];
			runs = got.runs || [];
			for (const key of Object.keys(E)) delete E[key];
			for (const [key, value] of Object.entries(got.entities || {})) {
				E[key] = value;
				byId[value.id] = key;
			}
			P = families(at(R.program).options || []);
			if (!page.dataset.ready) build();
			paint();
			app.el?.top?.setTitle(view);
		} catch (error) {
			if (gone) return;
			clear(page).appendChild(h("div.empty", icon("washing_machine"), h("h3", "The washing machine did not load"), h("p", error.message),
				h("a.btn.small", { href: "/smarthome" }, icon("arrow_left"), "Smart home")));
		}
	}

	function onStates(data) {
		let touched = false, phaseMoved = false;
		for (const [entityId, value] of Object.entries(data.states || {})) {
			const key = byId[entityId];
			if (!key) continue;
			if (key === R.mode && value.s !== E[key]?.s) {
				starting = 0;
				// a run ended: its bars come with the next load
				if (E[key]?.s === "2" && value.s !== "2") phaseMoved = true;
			}
			E[key] = { ...E[key], ...value };
			touched = true;
		}
		if (touched) paint();
		if (phaseMoved) setTimeout(load, 3000);
	}

	// ══ BUILD (once the entities are known) ═══════════════════════════════
	function build() {
		page.dataset.ready = "1";
		loading.remove();
		// the next run starts out as the machine is set up now
		const k = P.keys[st(R.program)] || P.keys[Object.keys(P.keys)[0]] || {};
		Object.assign(W, { fam: k.fam || "", len: k.len || "", steam: !!k.steam });
		if (TEMPS.some(t => t[0] === st(R.temp))) W.temp = st(R.temp);
		if ((at(R.spin).options || []).includes(st(R.spin))) W.spin = st(R.spin);
		W.soil = Math.max(1, Math.min(3, num("number.dirtylevel") || 1));
		for (const o of OPTS) if (o.num) W.opts[o.k] = num(o.num) ? 1 : 0;
		W.opts.rinse = ["number.extrarinse1", "number.extrarinse2", "number.extrarinse3"].filter(k2 => num(k2)).length;
		spins.querySelectorAll("button").forEach((b, i) => (b.hidden = !(at(R.spin).options || ["0", "400", "800", "1200", "1600"]).includes(["0", "400", "800", "1200", "1600"][i])));

		const devRows = [];
		if (has("input_boolean.notifications")) devRows.push(h("div.wm-row", icon("bell_ring_outline"), "Done alert", h("span.v", alertToggle)));
		if (R.remote) devRows.push(h("div.wm-row", icon("remote"), "Remote start", remoteRow));
		if (has("binary_sensor.night_wash")) devRows.push(h("div.wm-row", icon("weather_night"), "Night wash", nightRow));
		if (has("button.get_programs_details")) devRows.push(h("div.wm-row", icon("playlist_play"), "Programs", h("span.v", progCount, fetchBtn("button.get_programs_details", ""))));
		if (has("button.get_settings_details")) devRows.push(h("div.wm-row", icon("tune_variant"), "Settings", h("span.v", fetchBtn("button.get_settings_details", "Fetch"))));
		rows.append(...devRows);

		page.append(h("div.wm-grid", progCard, setupCard), runsCard, deviceCard);
		buildRuler();
		paintTiles();
		stagger(page.querySelectorAll(":scope > :not(.wm-hero), .wm-grid > *"), { step: 60, distance: 18, from: 0.97 });
		requestAnimationFrame(drawShape);
	}

	// ══ PAINT ═════════════════════════════════════════════════════════════
	let painting = 0;
	function paint() {
		if (painting) return;
		painting = requestAnimationFrame(() => {
			painting = 0;
			if (!page.dataset.ready) return;
			paintHero();
			paintSetup();
			paintRuns();
			paintDevice();
		});
	}

	function paintHero() {
		const state = machine();
		const kind = PHASE_OF(parseInt(st(R.phase), 10));
		const ph = state === "running" ? kind : null;
		page.dataset.state = state;
		if (ph != null) page.dataset.phase = PH[ph].k;
		else delete page.dataset.phase;
		page.style.setProperty("--state", ph != null ? PH[ph].c : STATE_COLOR[state] || "var(--primary)");
		const lvl = { 0: 18, 1: 24, 2: 62 }[ph] ?? (state === "done" ? 56 : 60);
		waterFront.style.setProperty("--lvl", `${lvl + 30}px`);
		waterBack.style.setProperty("--lvl", `${lvl + 26}px`);

		const f = fam();
		const runningKey = st(R.name) && st(R.name) !== "No program" ? st(R.name) : null;
		const prog = runningKey ? nameOfKey(runningKey) : nameOfKey(programKey());
		const temp = working(state) || state === "done" ? num(R.temperature) : +W.temp;
		const spin = working(state) ? null : W.spin;
		const detail = [temp === 0 ? "Cold" : temp != null ? `${temp}°` : null, spin ? (spin === "0" ? "No spin" : `${spin} rpm`) : null,
			!working(state) && W.steam && steamOk() ? "Steam" : null].filter(Boolean).join(" · ");
		const left = num(R.remaining) ?? 0;
		const startAt = Date.parse(st("sensor.start_time"));
		const endAt = Date.parse(st("sensor.end_time"));
		const elapsed = Number.isFinite(startAt) ? Math.max(0, (Date.now() - startAt) / 60000) : 0;
		const titles = {
			off: ["Off", node?.view?.name || "Washing machine"],
			ready: [escape(f ? prog : "Ready"), detail],
			running: [`<em>${ph != null ? PH[ph].doing : "Washing"}</em>`, [escape(prog), detail].filter(Boolean).join(" · ")],
			paused: ["<em>Paused</em>", escape(prog)],
			scheduled: [`Starts <em>${Number.isFinite(startAt) ? clock(new Date(startAt)) : "later"}</em>`, [escape(prog), detail].filter(Boolean).join(" · ")],
			done: ["<em>Done</em>", escape(prog)],
			error: ["<em>Needs help</em>", escape(prog)]
		}[state];
		swap(titleBox, titles[0]);
		swap(subBox, titles[1] || "&nbsp;");

		fLeft.el.hidden = !(state === "running" || state === "paused");
		fLeft.value.textContent = hm(left);
		fLeft.unit.textContent = unitOf(left);
		const total = sum(plan());
		const ends = state === "running" || state === "paused" ? addMin(left)
			: state === "scheduled" && Number.isFinite(endAt) ? new Date(endAt)
			: state === "done" && Number.isFinite(endAt) ? new Date(endAt) : addMin(W.delay + total);
		fEnd.el.hidden = state === "off" || (state === "done" && !Number.isFinite(endAt));
		fEnd.value.textContent = clock(ends);
		fEnd.name.textContent = state === "done" ? "Finished" : "Ends";
		fRuns.el.hidden = working(state) || num("sensor.total_programs") == null;
		const runsTotal = num("sensor.total_programs") || 0;
		if (+fRuns.value.dataset.n !== runsTotal) countUp(fRuns.value, runsTotal);
		fTemp.el.hidden = fSpin.el.hidden = state !== "running";
		fTemp.value.textContent = num(R.temperature) ?? "–";
		fSpin.value.textContent = num(R.spin_speed) ?? "–";
		badgeText.textContent = state === "off" ? "–" : temp === 0 ? "Cold" : temp != null ? `${temp}°` : "–";

		// the ring and the phases: elapsed against what is left; the phase lengths from its runs or a guess
		const whole = elapsed + left;
		const frac = state === "running" || state === "paused" ? (whole ? elapsed / whole : 0) : state === "done" ? 1 : 0;
		ring.style.strokeDashoffset = 100 * (1 - frac);
		const shares = (runningKey && known_(runningKey)) || plan();
		const scale = working(state) && whole ? whole / (sum(shares) || 1) : 1;
		const parts = shares.map(m => m * scale);
		phasesEl.hidden = state === "off" || !sum(parts);
		const sigOf = parts.map(p => (p ? 1 : 0)).join("");
		if (phasesEl.dataset.sig !== sigOf) {
			phasesEl.dataset.sig = sigOf;
			clear(phasesEl);
			PH.forEach((p, i) => {
				if (!parts[i]) return;
				const el = h("div.wm-ph", { style: `--c:${p.c}`, dataset: { i } },
					h("div.wm-ph-label", icon(p.icon), p.label, h("span.t", "")), h("div.wm-ph-bar", h("i")));
				phasesEl.appendChild(el);
			});
		}
		let t = state === "done" ? 1e9 : working(state) ? elapsed : 0;
		for (const el of phasesEl.children) {
			const i = +el.dataset.i;
			el.style.flex = `${parts[i]} 1 0`;
			el.querySelector(".t").textContent = hm(parts[i]);
			let fill = Math.max(0, Math.min(1, t / parts[i]));
			t -= parts[i];
			if (ph != null) fill = i < ph ? 1 : i > ph ? 0 : Math.max(0.04, Math.min(0.96, fill));
			el.querySelector(".wm-ph-bar i").style.width = `${fill * 100}%`;
			el.classList.toggle("now", ph === i);
			el.classList.toggle("done", fill >= 1);
		}

		const waiting = starting && Date.now() - starting < 10000;
		go.classList.toggle("stop", working(state));
		go.classList.toggle("locked", !working(state) && (!admin || state === "off" || !remote()));
		go.classList.toggle("busy", !!waiting);
		go.setAttribute("aria-label", working(state) ? "Hold to stop" : "Start");
		swap(goLabel, working(state) ? "Hold to stop" : state === "done" ? "Again" : "Start");
		remoteChip.classList.toggle("hide", remote() || working(state) || state === "off" || !R.remote);
	}

	function paintSetup() {
		const f = fam();
		if (!f) return;
		const p = plan(), t = sum(p);
		setupIcon.replaceChildren(icon(f.icon));
		swap(setupName, escape(f.name));
		const now = matchPreset();
		swap(setupCat, now ? `${icon("star", "wm-star").outerHTML}${escape(now.name)}` : CATS.find(c => c.value === f.cat).label);
		durV.textContent = (isKnown(programKey()) ? "" : "≈ ") + hm(t);
		durU.textContent = unitOf(t);
		const was = saveBtn.classList.contains("saved");
		saveBtn.classList.toggle("saved", !!now);
		saveBtn.firstChild.replaceWith(icon(now ? "star" : "star_outline"));
		saveText.textContent = now ? "Saved" : "Save";
		if (now && !was) {
			saveBtn.classList.remove("pop");
			void saveBtn.offsetWidth;
			saveBtn.classList.add("pop");
		}
		if (cat === "presets") tiles.querySelectorAll(".wm-tile.preset").forEach(x => x.classList.toggle("on", !!now && x.dataset.p === now.id));

		if (f.lens.length > 1) {
			if (variants.dataset.f !== f.id) {
				variants.dataset.f = f.id;
				const seg = segmented(f.lens.map(l => ({ value: l, label: l === "xl" ? "XL" : `${l}′`, icon: l === "xl" ? "weight_kilogram" : "timer_outline" })), W.len, v => {
					W.len = v;
					paint();
				});
				seg.classList.add("small");
				variants.replaceChildren(seg);
			} else variants.firstChild.select(W.len);
		} else {
			variants.dataset.f = "";
			clear(variants);
		}
		temps.select(W.temp);
		spins.select(W.spin);
		soil.select(W.soil);
		const tc = TEMPS.find(x => x[0] === W.temp) || TEMPS[2];
		temps.style.setProperty("--thumb", tc[2]);
		tempVal.textContent = tc[1];
		tempVal.style.color = `color-mix(in srgb, ${tc[2]} 75%, var(--text))`;
		spinVal.textContent = W.spin === "0" ? "Off" : `${W.spin} rpm`;
		spinIc.classList.toggle("still", W.spin === "0");
		spinIc.style.setProperty("--spd", W.spin === "0" ? "1s" : `${(2400 / +W.spin).toFixed(2)}s`);
		optEls.forEach(b => {
			const k = b.dataset.k, v = k === "steam" ? (W.steam && steamOk() ? 1 : 0) : W.opts[k];
			b.classList.toggle("on", !!v);
			b.classList.toggle("off", k === "steam" && !steamOk());
			b.querySelectorAll(".wm-pips i").forEach((x, n) => x.classList.toggle("on", n < v));
		});
		paintRuler();
	}

	function paintRuler() {
		const t = sum(plan());
		runBlock.style.left = `${(W.delay / SPAN) * 100}%`;
		runBlock.style.width = `${(Math.max(t, 20) / SPAN) * 100}%`;
		const end = addMin(W.delay + t);
		swap(finishV, `<b>${W.delay ? clock(end) : "Now"}</b>`);
		finishS.textContent = W.delay ? `Starts ${clock(addMin(W.delay))}` : `Ends ${clock(end)}`;
		finishNow.style.visibility = W.delay ? "visible" : "hidden";
	}

	let runsSig = "";
	function paintRuns() {
		const total = num("sensor.total_programs");
		if (total != null && +sTotal.dataset.n !== total) countUp(sTotal, total);
		const sig_ = JSON.stringify(runs) + Object.keys(P.keys).length;
		if (sig_ === runsSig) return;
		runsSig = sig_;
		clear(runList);
		const max = Math.max(1, ...runs.map(r => sum(r.phases)));
		if (!runs.length) runList.appendChild(h("div.wm-empty", icon("history")));
		runs.forEach((r, n) => {
			const f = famOfKey(r.program) || { icon: "washing_machine" }, d = new Date(r.start * 1000), t = sum(r.phases);
			runList.appendChild(h("div.wm-run-row",
				h("div.when", h("b", d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })), clock(d)),
				h("span.wm-ric", icon(f.icon)),
				h("div.name", h("b", nameOfKey(r.program) || "–"), h("span", [r.temp != null ? `${r.temp}°` : null, r.spin ? `${r.spin} rpm` : null].filter(Boolean).join(" · "))),
				h("div.wm-run-bar", { style: { width: `${(t / max) * 100}%` } }, r.phases.map((m, k) => (m ? h("i", { style: `flex:${m};--c:${PH[k].c};--n:${n};--k:${k}` }) : null))),
				h("span.len", t >= 60 ? `${hm(t)} h` : `${t}′`)));
		});
		const avg = runs.length ? sum(runs.map(r => sum(r.phases))) / runs.length : 0;
		countUp(sAvg, Math.round(avg));
		const counts = {};
		runs.forEach(r => (counts[r.program] = (counts[r.program] || 0) + 1));
		const fav = Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0];
		favName.textContent = fav ? nameOfKey(fav) : "–";
		favSub.textContent = fav ? `${counts[fav]} of the last ${runs.length}` : "";
		clear(week);
		const today = new Date();
		for (let k = 13; k >= 0; k--) {
			const d = new Date(today);
			d.setDate(d.getDate() - k);
			const n = runs.filter(r => new Date(r.start * 1000).toDateString() === d.toDateString()).length;
			week.appendChild(h("div", h("i", { class: n ? "has" : "", style: `--h:${n ? 10 + n * 10 : 3};--n:${13 - k}` }),
				d.toLocaleDateString([], { weekday: "narrow" })));
		}
	}

	function paintDevice() {
		alertToggle.set(st("input_boolean.notifications") === "on");
		const dot = (ok, text, warn) => [h(`span.wm-dot${ok ? ".ok" : warn ? ".warn" : ""}`), text];
		remoteRow.replaceChildren(...dot(remote(), remote() ? "On" : "Off", true));
		nightRow.replaceChildren(...dot(st("binary_sensor.night_wash") === "on", st("binary_sensor.night_wash") === "on" ? "On" : "Off"));
		progCount.textContent = String((at(R.program).options || []).length);
		const v = node?.view || {};
		const chips = [[v.manufacturer ? v.manufacturer.charAt(0).toUpperCase() + v.manufacturer.slice(1) : null, "washing_machine"], [v.model], ["hOn"]];
		if (!meta.childElementCount) meta.append(...chips.filter(c => c[0]).map(([text, ic]) => h("span.wm-chip", ic ? icon(ic) : null, text)));
	}

	// ── life ──
	const resize = new ResizeObserver(drawShape);
	resize.observe(progCard);
	resize.observe(notch);
	const clockTimer = setInterval(() => {
		if (!page.dataset.ready) return;
		paintHero();
		if (grab == null) paintRuler();
	}, 30000);
	const offs = [
		api.on("hass", onStates),
		api.on("washer", data => {
			if (data.node !== id || grab != null) return;
			presets = data.presets || [];
			paintTiles();
			paintSetup();
		}),
		api.on("smarthome", data => {
			const next = (data.nodes || []).find(n => n.id === id);
			if (next) node = next;
		}),
		api.on("socket", data => data.open && load())
	];
	load();

	const view = {
		el: root,
		title: "Smart home",
		icon: "power_plug",
		tabTitle: () => node?.view?.name || "Washing machine",
		tabIcon: () => "washing_machine",
		crumbs: () => [{ label: "Smart home", icon: "power_plug", href: "/smarthome" }, { label: node?.view?.name || "Washing machine", icon: "washing_machine" }],
		refresh: load,
		mounted: () => setTimeout(() => (hero.style.viewTransitionName = ""), 700),
		unmount: () => {
			gone = true;
			offs.forEach(off => off());
			resize.disconnect();
			clearInterval(clockTimer);
			clearTimeout(holdTimer);
		}
	};
	return view;
}
