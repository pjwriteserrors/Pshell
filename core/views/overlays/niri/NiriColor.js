.pragma library

// Colors as niri writes them (CSS: "#rrggbbaa", "red", "rgb(…)") and the
// gradients it draws, so previews look like niri will: a gradient is mixed in
// the color space it names (srgb, srgb-linear, oklab, oklch … hue).

const NAMED = {
	transparent: [0, 0, 0, 0], black: [0, 0, 0, 1], white: [1, 1, 1, 1], red: [1, 0, 0, 1], green: [0, 128 / 255, 0, 1],
	blue: [0, 0, 1, 1], gray: [128 / 255, 128 / 255, 128 / 255, 1], grey: [128 / 255, 128 / 255, 128 / 255, 1],
	yellow: [1, 1, 0, 1], orange: [1, 165 / 255, 0, 1], purple: [128 / 255, 0, 128 / 255, 1], cyan: [0, 1, 1, 1],
	magenta: [1, 0, 1, 1], pink: [1, 192 / 255, 203 / 255, 1], lime: [0, 1, 0, 1], navy: [0, 0, 128 / 255, 1],
	teal: [0, 128 / 255, 128 / 255, 1], silver: [192 / 255, 192 / 255, 192 / 255, 1], maroon: [128 / 255, 0, 0, 1]
};

function clamp(v, lo, hi) {
	return Math.max(lo, Math.min(hi, v));
}

// "#rgb" "#rgba" "#rrggbb" "#rrggbbaa" "rgb(…)" "rgba(…)" "hsl(…)" names → [r, g, b, a] in 0…1
function parse(text) {
	const s = String(text || "").trim().toLowerCase();
	if (NAMED[s]) return NAMED[s].slice();
	let m = /^#([0-9a-f]{3,8})$/.exec(s);
	if (m) {
		let hex = m[1];
		if (hex.length === 3 || hex.length === 4) hex = hex.split("").map(c => c + c).join("");
		if (hex.length !== 6 && hex.length !== 8) return null;
		const n = i => parseInt(hex.slice(i, i + 2), 16) / 255;
		return [n(0), n(2), n(4), hex.length === 8 ? n(6) : 1];
	}
	m = /^rgba?\(([^)]*)\)$/.exec(s);
	if (m) {
		const parts = m[1].split(/[\s,/]+/).filter(p => p !== "");
		const channel = p => p.endsWith("%") ? parseFloat(p) / 100 : parseFloat(p) / 255;
		const alpha = p => p === undefined ? 1 : (p.endsWith("%") ? parseFloat(p) / 100 : parseFloat(p));
		return [channel(parts[0]), channel(parts[1]), channel(parts[2]), alpha(parts[3])].map(v => clamp(isNaN(v) ? 0 : v, 0, 1));
	}
	m = /^hsla?\(([^)]*)\)$/.exec(s);
	if (m) {
		const parts = m[1].split(/[\s,/]+/).filter(p => p !== "");
		const h = parseFloat(parts[0]) / 360;
		const sat = parseFloat(parts[1]) / 100;
		const l = parseFloat(parts[2]) / 100;
		const a = parts[3] === undefined ? 1 : (parts[3].endsWith("%") ? parseFloat(parts[3]) / 100 : parseFloat(parts[3]));
		const k = n => (n + h * 12) % 12;
		const f = n => l - sat * Math.min(l, 1 - l) * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
		return [f(0), f(8), f(4), a];
	}
	return null;
}

function valid(text) {
	return parse(text) !== null;
}

function hex2(v) {
	const n = Math.round(clamp(v, 0, 1) * 255);
	return (n < 16 ? "0" : "") + n.toString(16);
}

// [r, g, b, a] → "#rrggbb" or "#rrggbbaa"
function format(rgba) {
	const base = `#${hex2(rgba[0])}${hex2(rgba[1])}${hex2(rgba[2])}`;
	return rgba[3] >= 0.999 ? base : base + hex2(rgba[3]);
}

// a Qt color from a CSS one (Qt reads #aarrggbb, CSS #rrggbbaa)
function qt(text, fallback) {
	const c = parse(text);
	if (!c) return fallback === undefined ? Qt.rgba(0.5, 0.5, 0.5, 1) : fallback;
	return Qt.rgba(c[0], c[1], c[2], c[3]);
}

function fromQt(color) {
	return format([color.r, color.g, color.b, color.a]);
}

// ── color spaces ─────────────────────────────────────────────────────────
function toLinear(c) {
	return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function fromLinear(c) {
	return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function toOklab(rgb) {
	const r = toLinear(rgb[0]), g = toLinear(rgb[1]), b = toLinear(rgb[2]);
	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	return [
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	];
}

function fromOklab(lab) {
	const l = Math.pow(lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2], 3);
	const m = Math.pow(lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2], 3);
	const s = Math.pow(lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2], 3);
	return [
		clamp(fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), 0, 1),
		clamp(fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), 0, 1),
		clamp(fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), 0, 1)
	];
}

function hueLerp(a, b, t, mode) {
	let d = b - a;
	if (mode === "shorter hue") {
		if (d > 180) d -= 360;
		else if (d < -180) d += 360;
	} else if (mode === "longer hue") {
		if (d > 0 && d < 180) d -= 360;
		else if (d > -180 && d <= 0) d += 360;
	} else if (mode === "increasing hue") {
		if (d < 0) d += 360;
	} else if (mode === "decreasing hue") {
		if (d > 0) d -= 360;
	}
	return a + d * t;
}

// mixes two [r, g, b, a] in a CSS color space ("srgb", "srgb-linear", "oklab", "oklch longer hue" …)
function mix(c1, c2, t, space) {
	const s = String(space || "srgb");
	const alpha = c1[3] + (c2[3] - c1[3]) * t;
	const lerp = (a, b) => a + (b - a) * t;
	if (s === "srgb-linear") {
		return [0, 1, 2].map(i => fromLinear(lerp(toLinear(c1[i]), toLinear(c2[i])))).concat([alpha]);
	}
	if (s.startsWith("oklab")) {
		const a = toOklab(c1), b = toOklab(c2);
		return fromOklab([lerp(a[0], b[0]), lerp(a[1], b[1]), lerp(a[2], b[2])]).concat([alpha]);
	}
	if (s.startsWith("oklch")) {
		const a = toOklab(c1), b = toOklab(c2);
		const ca = Math.hypot(a[1], a[2]), cb = Math.hypot(b[1], b[2]);
		let ha = Math.atan2(a[2], a[1]) * 180 / Math.PI, hb = Math.atan2(b[2], b[1]) * 180 / Math.PI;
		// a grey has no hue: it takes the other one's
		if (ca < 0.002) ha = hb;
		if (cb < 0.002) hb = ha;
		const mode = s.replace(/^oklch\s*/, "") || "shorter hue";
		const h = hueLerp(ha, hb, t, mode) * Math.PI / 180;
		const c = lerp(ca, cb);
		return fromOklab([lerp(a[0], b[0]), c * Math.cos(h), c * Math.sin(h)]).concat([alpha]);
	}
	return [lerp(c1[0], c2[0]), lerp(c1[1], c2[1]), lerp(c1[2], c2[2]), alpha];
}

// gradient stops for a ShapePath/Rectangle gradient: [{ position, color }]
function stops(from, to, space, count) {
	const a = parse(from) || [0.5, 0.5, 0.5, 1];
	const b = parse(to) || [0.5, 0.5, 0.5, 1];
	const n = Math.max(2, count || 14);
	const out = [];
	for (let i = 0; i < n; i++) {
		const t = i / (n - 1);
		const c = mix(a, b, t, space);
		out.push({ position: t, color: Qt.rgba(c[0], c[1], c[2], c[3]) });
	}
	return out;
}

// CSS linear-gradient angle (0 = to top, 90 = to right) → start and end points in a w×h box
function line(angle, w, h) {
	const rad = (Number(angle) || 0) * Math.PI / 180;
	const dx = Math.sin(rad), dy = -Math.cos(rad);
	const half = Math.abs(w / 2 * dx) + Math.abs(h / 2 * dy);
	return { x1: w / 2 - dx * half, y1: h / 2 - dy * half, x2: w / 2 + dx * half, y2: h / 2 + dy * half };
}

// HSV helpers for the picker
function toHsv(rgba) {
	const r = rgba[0], g = rgba[1], b = rgba[2];
	const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
	let h = 0;
	if (d > 0) {
		if (max === r) h = ((g - b) / d) % 6;
		else if (max === g) h = (b - r) / d + 2;
		else h = (r - g) / d + 4;
		h /= 6;
		if (h < 0) h += 1;
	}
	return [h, max === 0 ? 0 : d / max, max, rgba[3]];
}

function fromHsv(h, s, v, a) {
	const f = n => {
		const k = (n + h * 6) % 6;
		return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
	};
	return [f(5), f(3), f(1), a === undefined ? 1 : a];
}

function luminance(rgba) {
	return 0.2126 * toLinear(rgba[0]) + 0.7152 * toLinear(rgba[1]) + 0.0722 * toLinear(rgba[2]);
}
