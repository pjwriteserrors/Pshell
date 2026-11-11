.pragma library

// What each app makes of a scheme ({background, foreground, colors[16],
// roles}), the way its theme does it – so the previews of Settings › Colours
// show the apps as they will be, not as they might be.

function parse(hex) {
	const h = String(hex || "#808080").replace("#", "");
	return { r: parseInt(h.slice(0, 2), 16) / 255, g: parseInt(h.slice(2, 4), 16) / 255, b: parseInt(h.slice(4, 6), 16) / 255 };
}

function toColor(c, a) {
	return Qt.rgba(c.r, c.g, c.b, a === undefined ? 1 : a);
}

function lin(v) {
	return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

function luminance(c) {
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

function contrast(a, b) {
	const la = luminance(a), lb = luminance(b);
	return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// over on top of base, with the given share (CSS color-mix, Qt.tint)
function mix(base, over, share) {
	return { r: base.r + (over.r - base.r) * share, g: base.g + (over.g - base.g) * share, b: base.b + (over.b - base.b) * share };
}

// Qt.lighter / darker as Theme.legible pushes them (HSV value, then whitening)
function scaled(c, factor) {
	const max = Math.max(c.r, c.g, c.b);
	if (max <= 0) return factor > 1 ? { r: 0.05, g: 0.05, b: 0.05 } : c;
	let r = c.r * factor, g = c.g * factor, b = c.b * factor;
	const over = Math.max(r, g, b) - 1;
	if (over > 0) {
		r = Math.min(1, r + over); g = Math.min(1, g + over); b = Math.min(1, b + over);
	}
	return { r: Math.min(1, r), g: Math.min(1, g), b: Math.min(1, b) };
}

function legible(c, bg, minimum) {
	const dark = luminance(bg) < 0.35;
	let out = c;
	for (let i = 0; i < 12 && contrast(out, bg) < minimum; i += 1)
		out = scaled(out, dark ? 1.12 : 1 / 1.12);
	return out;
}

// OKLab, for Floorp's oklch(from …) clamp
function toLinear(c) {
	return [lin(c.r), lin(c.g), lin(c.b)];
}

function gamma(v) {
	v = Math.max(0, Math.min(1, v));
	return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
}

function oklch(c) {
	const [r, g, b] = toLinear(c);
	const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	const L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
	const A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
	const B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
	return { L: L, C: Math.hypot(A, B), h: Math.atan2(B, A) };
}

function fromOklch(L, C, h) {
	const A = C * Math.cos(h), B = C * Math.sin(h);
	const l = Math.pow(L + 0.3963377774 * A + 0.2158037573 * B, 3);
	const m = Math.pow(L - 0.1055613458 * A - 0.0638541728 * B, 3);
	const s = Math.pow(L - 0.0894841775 * A - 1.2914855480 * B, 3);
	return {
		r: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
		g: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
		b: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
	};
}

// the shell's roles as Theme.qml (and spicetify's derive(), Discord's
// theme) take them: the engine's where it wrote them, else ranked from 1-6
function roles(scheme) {
	const bg = parse(scheme.background), fg = parse(scheme.foreground);
	const own = scheme.roles || {};
	const palette = (scheme.colors || []).map(parse);
	const ranked = palette.slice(1, 7).map(c => {
		const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b);
		const sat = max > 0 ? (max - min) / max : 0;
		return { c: c, score: sat * 1.1 + Math.min(1, Math.max(0, (contrast(c, bg) - 1.6) / 4.5)) * 1.3 };
	}).sort((a, b) => b.score - a.score).map(x => x.c);
	const pick = (name, fallback) => own[name] ? parse(own[name]) : (fallback || parse("#808080"));
	const primary = legible(pick("primary", ranked[0]), bg, 3.2);
	const out = {
		bg: bg,
		fg: fg,
		primary: primary,
		secondary: legible(pick("secondary", ranked[1]), bg, 3.0),
		tertiary: legible(pick("tertiary", ranked[2]), bg, 3.0),
		danger: legible(pick("danger", mix(parse("#e5484d"), primary, 0.12)), bg, 3.4),
		warning: legible(pick("warning", mix(parse("#f5a524"), primary, 0.1)), bg, 3.4),
		success: legible(pick("success", mix(parse("#46a758"), primary, 0.1)), bg, 3.4),
		layer1: mix(bg, fg, 0.045),
		layer2: mix(bg, fg, 0.085),
		layer3: mix(bg, fg, 0.13)
	};
	out.onPrimary = contrast(primary, bg) >= contrast(primary, fg) ? bg : fg;
	return out;
}

// libadwaita as apply_theme_selection.sh writes gtk.css, with the oomox
// accent (theme_variants.sh) for the folders
function gtk(scheme) {
	const r = roles(scheme);
	const c = i => parse(scheme.colors[i]);
	const own = !!(scheme.roles && scheme.roles.primary);
	return {
		window: r.bg,
		text: r.fg,
		headerbar: own ? mix(r.bg, r.fg, 0.06) : c(8),
		backdrop: own ? c(0) : c(14),
		sidebar: own ? mix(r.bg, r.fg, 0.06) : c(8),
		card: own ? mix(r.bg, r.fg, 0.085) : c(7),
		popover: own ? mix(r.bg, r.fg, 0.13) : c(3),
		accent: own ? parse(scheme.roles.primary) : c(4),
		accentBg: own ? parse(scheme.roles.primary) : c(6),
		accentFg: own ? parse(scheme.roles.on_primary || scheme.background) : r.fg,
		destructive: own ? parse(scheme.roles.danger) : c(1),
		folder: own ? parse(scheme.roles.primary) : c(3)
	};
}

// Floorp through Pywalfox: background color0, text color15, the accent the
// engine's primary (pshell-roles.css) or else the attention slot (13 dark,
// 5 light) clamped as dotfiles/floorp/pshell.css does
function floorp(scheme, dark) {
	const bg = parse(scheme.colors[0]);
	const fg = parse(dark ? scheme.colors[15] : scheme.colors[7]);
	const raw = parse(scheme.colors[dark ? 13 : 5]);
	const o = oklch(raw);
	const own = scheme.roles && scheme.roles.primary ? parse(scheme.roles.primary) : null;
	return {
		bg: bg,
		fg: fg,
		layer1: mix(bg, fg, 0.045),
		layer2: mix(bg, fg, 0.085),
		layer3: mix(bg, fg, 0.13),
		primary: own || fromOklch(dark ? Math.max(o.L, 0.72) : Math.min(o.L, 0.5), Math.max(o.C, 0.08), o.h)
	};
}
