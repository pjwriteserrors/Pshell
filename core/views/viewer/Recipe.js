.pragma library
.import "Geometry.js" as Geo

// What was done to a picture, as plain data: kept beside nothing (in the
// shell's state, see Viewer.qml), so the copy can be made again and every
// step taken back.
//   { adjust: { exposure … grain: -1..1 }, curves: { rgb, r, g, b: [[x, y] 0..1] },
//     tones: { shadow: "#rrggbb", shadowAmount, highlight, highlightAmount },
//     look: "" | look id, geometry: Geometry.js, cutout: "" | mask file,
//     markup: { items: [annotations in result pixels], geometry } }

const SLIDERS = [
	{ group: "Light", id: "exposure", label: "Exposure", icon: "brightness_6" },
	{ group: "Light", id: "brightness", label: "Brightness", icon: "brightness_5" },
	{ group: "Light", id: "contrast", label: "Contrast", icon: "contrast_box" },
	{ group: "Light", id: "highlights", label: "Highlights", icon: "white_balance_sunny" },
	{ group: "Light", id: "shadows", label: "Shadows", icon: "weather_night" },
	{ group: "Colour", id: "temperature", label: "Warmth", icon: "thermometer" },
	{ group: "Colour", id: "tint", label: "Tint", icon: "eyedropper_variant" },
	{ group: "Colour", id: "saturation", label: "Saturation", icon: "palette_outline" },
	{ group: "Colour", id: "vibrance", label: "Vibrance", icon: "creation" },
	{ group: "Effects", id: "sharpen", label: "Sharpen", icon: "details", min: 0 },
	{ group: "Effects", id: "vignette", label: "Vignette", icon: "circle_half_full" },
	{ group: "Effects", id: "grain", label: "Grain", icon: "grain", min: 0 },
	{ group: "Effects", id: "fade", label: "Fade", icon: "blur_linear", min: 0 }
];

const ADJUST_IDS = SLIDERS.map(s => s.id);

// looks: a few sliders, curves and tones each
const LOOKS = [
	{ id: "vivid", label: "Vivid", adjust: { contrast: 0.18, vibrance: 0.45, saturation: 0.08 } },
	{ id: "warm", label: "Golden", adjust: { temperature: 0.35, vibrance: 0.15, highlights: -0.1 }, tones: { highlight: "#ffcf8a", highlightAmount: 0.35 } },
	{ id: "cool", label: "Nordic", adjust: { temperature: -0.3, saturation: -0.12, contrast: 0.08 }, tones: { shadow: "#4a7aa8", shadowAmount: 0.4 } },
	{ id: "matte", label: "Matte", adjust: { fade: 0.5, contrast: -0.12, saturation: -0.1 } },
	{ id: "film", label: "Film", adjust: { fade: 0.25, grain: 0.35, vibrance: -0.1, temperature: 0.08 }, curves: { rgb: [[0, 0.04], [0.25, 0.22], [0.75, 0.8], [1, 0.96]] }, tones: { shadow: "#2f6f73", shadowAmount: 0.3, highlight: "#f2c38f", highlightAmount: 0.3 } },
	{ id: "drama", label: "Drama", adjust: { contrast: 0.4, shadows: -0.15, highlights: -0.25, vignette: -0.45, saturation: -0.15 } },
	{ id: "noir", label: "Noir", adjust: { saturation: -1, contrast: 0.35, vignette: -0.35, grain: 0.2 } },
	{ id: "silver", label: "Silver", adjust: { saturation: -1, contrast: 0.05, fade: 0.2, brightness: 0.1 } },
	{ id: "sepia", label: "Sepia", adjust: { saturation: -0.85, fade: 0.15 }, tones: { shadow: "#6b4a2a", shadowAmount: 0.6, highlight: "#f5d9a8", highlightAmount: 0.5 } },
	{ id: "teal", label: "Teal & orange", adjust: { contrast: 0.12, vibrance: 0.2 }, tones: { shadow: "#1f8a8a", shadowAmount: 0.55, highlight: "#ff9a4d", highlightAmount: 0.45 } },
	{ id: "fade", label: "Faded", adjust: { fade: 0.35, saturation: -0.3, brightness: 0.12 }, curves: { rgb: [[0, 0.12], [1, 0.94]] } },
	{ id: "punch", label: "Punch", adjust: { contrast: 0.3, saturation: 0.25, sharpen: 0.35, vignette: -0.2 } }
];

function lookById(id) {
	return LOOKS.find(l => l.id === id) ?? null;
}

function blank() {
	return { adjust: {}, curves: {}, tones: {}, look: "", geometry: Geo.defaults(), cutout: "", markup: { items: [] } };
}

function normalised(r) {
	const b = blank();
	if (!r) return b;
	return {
		adjust: Object.assign({}, r.adjust || {}),
		curves: Object.assign({}, r.curves || {}),
		tones: Object.assign({}, r.tones || {}),
		look: String(r.look || ""),
		geometry: Geo.normalised(r.geometry),
		cutout: String(r.cutout || ""),
		markup: { items: (r.markup?.items || []).slice() }
	};
}

function copy(r) {
	return JSON.parse(JSON.stringify(normalised(r)));
}

function value(r, id) {
	return Number(r?.adjust?.[id] ?? 0) || 0;
}

function curveIsFlat(points) {
	return !points || points.length === 0 || points.every(p => Math.abs(p[0] - p[1]) < 1e-4);
}

function curvesFlat(r) {
	const c = r?.curves || {};
	return ["rgb", "r", "g", "b"].every(k => curveIsFlat(c[k]));
}

function tonesOn(r) {
	return (Number(r?.tones?.shadowAmount) || 0) > 0 || (Number(r?.tones?.highlightAmount) || 0) > 0;
}

function colourIsPlain(r) {
	return ADJUST_IDS.every(id => Math.abs(value(r, id)) < 1e-4) && curvesFlat(r) && !tonesOn(r);
}

function isPlain(r) {
	r = normalised(r);
	return colourIsPlain(r) && Geo.isIdentity(r.geometry) && !r.cutout && r.markup.items.length === 0;
}

function same(a, b) {
	return JSON.stringify(normalised(a)) === JSON.stringify(normalised(b));
}

// a look laid over the sliders the user set (their own values win where
// they moved one the look does not touch)
function withLook(r, id) {
	const out = copy(r);
	const previous = lookById(out.look);
	if (previous) {
		for (const key in previous.adjust || {}) if (Math.abs(value(out, key) - previous.adjust[key]) < 1e-4) delete out.adjust[key];
		if (previous.curves) out.curves = {};
		if (previous.tones) out.tones = {};
	}
	const look = lookById(id);
	out.look = look ? look.id : "";
	if (look) {
		Object.assign(out.adjust, look.adjust || {});
		if (look.curves) out.curves = JSON.parse(JSON.stringify(look.curves));
		if (look.tones) out.tones = Object.assign({}, look.tones);
	}
	return out;
}

// what the shader is given for the colours of a recipe
function uniforms(r) {
	const out = {};
	for (const id of ADJUST_IDS) out[id] = value(r, id);
	const t = r?.tones || {};
	out.shadowTone = Qt.rgba(...toneRgb(t.shadow || "#808080"), Number(t.shadowAmount) || 0);
	out.highlightTone = Qt.rgba(...toneRgb(t.highlight || "#808080"), Number(t.highlightAmount) || 0);
	out.curves = curvesFlat(r) ? 0 : 1;
	return out;
}

function toneRgb(hex) {
	const c = Qt.color(hex);
	return [c.r, c.g, c.b];
}

// ── curves ─────────────────────────────────────────────────────────────────
// a monotone cubic through the points (Fritsch–Carlson), 256 values 0..1
function sampleCurve(points) {
	if (curveIsFlat(points)) {
		const out = new Array(256);
		for (let i = 0; i < 256; i += 1) out[i] = i / 255;
		return out;
	}
	const p = points.slice().sort((a, b) => a[0] - b[0]);
	if (p[0][0] > 0) p.unshift([0, p[0][1]]);
	if (p[p.length - 1][0] < 1) p.push([1, p[p.length - 1][1]]);
	const n = p.length;
	const d = [], m = new Array(n);
	for (let i = 0; i < n - 1; i += 1) d.push((p[i + 1][1] - p[i][1]) / Math.max(1e-6, p[i + 1][0] - p[i][0]));
	m[0] = d[0];
	m[n - 1] = d[n - 2];
	for (let i = 1; i < n - 1; i += 1) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
	for (let i = 0; i < n - 1; i += 1) {
		if (Math.abs(d[i]) < 1e-9) {
			m[i] = 0;
			m[i + 1] = 0;
			continue;
		}
		const a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b;
		if (s > 9) {
			const t = 3 / Math.sqrt(s);
			m[i] = t * a * d[i];
			m[i + 1] = t * b * d[i];
		}
	}
	const out = new Array(256);
	let k = 0;
	for (let i = 0; i < 256; i += 1) {
		const x = i / 255;
		while (k < n - 2 && x > p[k + 1][0]) k += 1;
		const h = Math.max(1e-6, p[k + 1][0] - p[k][0]);
		const t = Math.max(0, Math.min(1, (x - p[k][0]) / h));
		const t2 = t * t, t3 = t2 * t;
		const y = (2 * t3 - 3 * t2 + 1) * p[k][1] + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * p[k + 1][1] + (t3 - t2) * h * m[k + 1];
		out[i] = Math.max(0, Math.min(1, y));
	}
	return out;
}

// rows r, g, b of the lookup texture: the channel's curve after the master
function lut(r) {
	const c = r?.curves || {};
	const master = sampleCurve(c.rgb);
	const rows = ["r", "g", "b"].map(k => {
		const own = sampleCurve(c[k]);
		return master.map(v => own[Math.round(v * 255)]);
	});
	return rows;
}
