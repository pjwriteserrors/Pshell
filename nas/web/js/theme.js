// The shell's colours on the web: the same derivation as style/theme/Theme.qml,
// from the palette the PC pushed (GET /api/theme = wal's colors.json). The
// roles land as CSS custom properties on :root; they are registered with
// @property in base.css, so a new palette cross-fades instead of jumping.

const FALLBACK = {
	special: { background: "#0f1218", foreground: "#e6ebf2" },
	colors: { color0: "#151a22", color1: "#e5677a", color2: "#6fc28b", color3: "#e6b45e", color4: "#5aa8ff", color5: "#b48bf0", color6: "#3fd0d8", color7: "#c9d1dc", color8: "#3a4250" },
	roles: { primary: "#4fb4ff", secondary: "#38d1d1", tertiary: "#9b8cff" }
};

// ── colour maths (QColor semantics, channels 0..1) ─────────────────────────
export function parse(hex) {
	if (typeof hex !== "string") return { r: 0.5, g: 0.5, b: 0.5, a: 1 };
	let h = hex.trim().replace(/^#/, "");
	if (h.length === 3) h = h.split("").map(c => c + c).join("");
	let a = 1;
	if (h.length === 8) {
		// Qt's #AARRGGBB
		a = parseInt(h.slice(0, 2), 16) / 255;
		h = h.slice(2);
	}
	const n = parseInt(h, 16);
	if (Number.isNaN(n)) return { r: 0.5, g: 0.5, b: 0.5, a: 1 };
	return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255, a };
}

const clamp = v => Math.max(0, Math.min(1, v));

export function hex(c) {
	const to = v => Math.round(clamp(v) * 255).toString(16).padStart(2, "0");
	return `#${to(c.r)}${to(c.g)}${to(c.b)}`;
}

export function css(c, alpha) {
	const a = alpha ?? c.a ?? 1;
	if (a >= 1) return hex(c);
	return `rgb(${Math.round(c.r * 255)} ${Math.round(c.g * 255)} ${Math.round(c.b * 255)} / ${+a.toFixed(3)})`;
}

function hsv(c) {
	const max = Math.max(c.r, c.g, c.b);
	const min = Math.min(c.r, c.g, c.b);
	const d = max - min;
	let h = -1;
	if (d > 0) {
		if (max === c.r) h = ((c.g - c.b) / d) % 6;
		else if (max === c.g) h = (c.b - c.r) / d + 2;
		else h = (c.r - c.g) / d + 4;
		h /= 6;
		if (h < 0) h += 1;
	}
	return { h, s: max === 0 ? 0 : d / max, v: max };
}

function fromHsv(h, s, v, a = 1) {
	if (h < 0) return { r: v, g: v, b: v, a };
	const i = Math.floor(h * 6);
	const f = h * 6 - i;
	const p = v * (1 - s);
	const q = v * (1 - f * s);
	const t = v * (1 - (1 - f) * s);
	const [r, g, b] = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][((i % 6) + 6) % 6];
	return { r, g, b, a };
}

// QColor::lighter / darker
function lighter(c, factor) {
	let { h, s, v } = hsv(c);
	v *= factor;
	if (v > 1) {
		s = Math.max(0, s - (v - 1));
		v = 1;
	}
	return fromHsv(h, s, v, c.a);
}

function darker(c, factor) {
	const { h, s, v } = hsv(c);
	return fromHsv(h, s, v / factor, c.a);
}

// Qt.tint(base, overlay with alpha)
export function tint(base, over, alpha) {
	const a = alpha ?? over.a ?? 1;
	return { r: base.r + (over.r - base.r) * a, g: base.g + (over.g - base.g) * a, b: base.b + (over.b - base.b) * a, a: 1 };
}

export function luminance(c) {
	const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

export function contrast(a, b) {
	const la = luminance(a);
	const lb = luminance(b);
	return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// ── the roles ──────────────────────────────────────────────────────────────
export function derive(wal) {
	wal = wal && wal.special ? wal : FALLBACK;
	const bg = parse(wal.special?.background ?? "#141414");
	const fg = parse(wal.special?.foreground ?? "#e6e6e6");
	const palette = [];
	for (let i = 0; i < 16; i += 1) palette.push(parse(wal.colors?.[`color${i}`] ?? "#808080"));
	const dark = luminance(bg) < 0.35;

	const legible = (c, minimum) => {
		let out = c;
		for (let i = 0; i < 12 && contrast(out, bg) < minimum; i += 1) out = dark ? lighter(out, 1.12) : darker(out, 1.12);
		return out;
	};

	const ranked = [];
	for (let i = 1; i <= 6; i += 1) {
		const c = palette[i];
		const { h, s } = hsv(c);
		const score = s * 1.1 + Math.min(1, Math.max(0, (contrast(c, bg) - 1.6) / 4.5)) * 1.3;
		ranked.push({ color: c, score, hue: h });
	}
	ranked.sort((a, b) => b.score - a.score);

	const pickDistinct = (reference, offset) => {
		for (let i = offset; i < ranked.length; i += 1) {
			const hue = ranked[i].hue;
			const distance = Math.min(Math.abs(hue - reference), 1 - Math.abs(hue - reference));
			if (reference < 0 || hue < 0 || distance > 0.06) return ranked[i].color;
		}
		return ranked[Math.min(offset, ranked.length - 1)].color;
	};
	const role = name => (wal.roles?.[name] ? parse(wal.roles[name]) : null);

	const primary = legible(role("primary") ?? ranked[0].color, 3.2);
	const secondary = legible(role("secondary") ?? pickDistinct(ranked[0].hue, 1), 3.0);
	const tertiary = legible(role("tertiary") ?? pickDistinct(hsv(secondary).h, 2), 3.0);
	const onPrimary = contrast(primary, bg) >= contrast(primary, fg) ? bg : fg;
	const danger = legible(role("danger") ?? tint(parse("#e5484d"), primary, 0.12), 3.4);
	const warning = legible(role("warning") ?? tint(parse("#f5a524"), primary, 0.1), 3.4);
	const success = legible(role("success") ?? tint(parse("#46a758"), primary, 0.1), 3.4);

	const vars = {
		"--bg": hex(bg),
		"--fg": hex(fg),
		"--primary": hex(primary),
		"--secondary": hex(secondary),
		"--tertiary": hex(tertiary),
		"--on-primary": hex(onPrimary),
		"--danger": hex(danger),
		"--warning": hex(warning),
		"--success": hex(success),
		"--layer1": hex(tint(bg, fg, 0.045)),
		"--layer2": hex(tint(bg, fg, 0.085)),
		"--layer3": hex(tint(bg, fg, 0.13)),
		"--glass": css(bg, 0.8),
		"--primary-container": hex(tint(bg, primary, 0.2)),
		"--primary-soft": css(primary, 0.14),
		"--primary-glow": css(primary, 0.32),
		"--danger-container": hex(tint(bg, danger, 0.2)),
		"--danger-soft": css(danger, 0.16),
		"--warning-soft": css(warning, 0.16),
		"--success-soft": css(success, 0.16),
		"--secondary-soft": css(secondary, 0.16),
		"--tertiary-soft": css(tertiary, 0.16),
		"--scrim": `rgb(0 0 0 / ${dark ? 0.42 : 0.28})`,
		"--shadow": `rgb(0 0 0 / ${dark ? 0.55 : 0.28})`,
		"--text": hex(fg),
		"--text-muted": css(fg, 0.64),
		"--text-subtle": css(fg, 0.42),
		"--text-faint": css(fg, 0.24),
		"--outline": css(fg, 0.08),
		"--hover": css(fg, 0.06),
		"--press": css(fg, 0.1)
	};
	return { vars, dark, colors: { bg, fg, primary, secondary, tertiary, danger, warning, success } };
}

let current = null;

export function apply(wal) {
	const theme = derive(wal);
	const root = document.documentElement;
	for (const [key, value] of Object.entries(theme.vars)) root.style.setProperty(key, value);
	root.dataset.scheme = theme.dark ? "dark" : "light";
	root.style.colorScheme = theme.dark ? "dark" : "light";
	const meta = document.querySelector('meta[name="theme-color"]');
	if (meta) meta.content = theme.vars["--bg"];
	current = theme;
	try {
		localStorage.setItem("nas.theme", JSON.stringify(wal));
	} catch (error) {}
	return theme;
}

export function theme() {
	return current;
}

// the last palette worn, at once (no flash of the default before the fetch)
export function applyCached() {
	let wal = null;
	try {
		wal = JSON.parse(localStorage.getItem("nas.theme") || "null");
	} catch (error) {}
	return apply(wal || FALLBACK);
}

export async function load() {
	try {
		const response = await fetch("/api/theme", { credentials: "same-origin" });
		if (!response.ok) return current;
		const wal = await response.json();
		const before = localStorage.getItem("nas.theme");
		if (before === JSON.stringify(wal) && current) return current;
		return apply(wal);
	} catch (error) {
		return current;
	}
}
