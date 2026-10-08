pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Single source of truth for colors, type and metrics.
//
// Colors are derived from the wallust palette (~/.cache/wal/colors.json).
// Instead of hard-wiring color4 as the accent, the most vivid palette entry
// that still reads well on the background is chosen, so every wallpaper
// produces a legible, saturated shell. Elevation is expressed with tints of
// the foreground over the background — no hairline borders.
Singleton {
	id: root

	readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || `${Quickshell.env("HOME")}/.cache`
	readonly property string walPath: `${root.cacheHome}/wal/colors.json`

	readonly property var wal: {
		try {
			return JSON.parse(walFile.text());
		} catch (error) {
			return {
				special: { background: "#141414", foreground: "#e6e6e6" },
				colors: { color1: "#c75a5a", color2: "#7fb069", color3: "#d8a657", color4: "#6f9fd8", color5: "#b58bd6", color6: "#5fb3b3", color8: "#3a3a3a" }
			};
		}
	}

	function reload() {
		walFile.reload();
	}

	FileView {
		id: walFile
		path: root.walPath
		blockLoading: true
		watchChanges: true
		onFileChanged: reload()
	}

	// corner radius of niri windows (window-rule geometry-corner-radius)
	readonly property string niriConfigPath: `${Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`}/niri/config.kdl`
	// settings.kdl (the niri-settings plugin) wins: config.kdl includes it
	readonly property int windowRadius: {
		const clean = text => String(text || "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
		for (const text of [niriSettingsFile.text(), niriFile.text()]) {
			const match = clean(text).match(/^\s*geometry-corner-radius\s+([\d.]+)/m);
			if (match) return Math.round(Number(match[1]));
		}
		return 7;
	}

	FileView {
		id: niriFile
		path: root.niriConfigPath
		blockLoading: true
		watchChanges: true
		onFileChanged: reload()
	}

	FileView {
		id: niriSettingsFile
		path: root.niriConfigPath.replace(/config\.kdl$/, "settings.kdl")
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
	}

	// ── raw palette ────────────────────────────────────────────────────────
	readonly property color bg: wal.special?.background ?? "#141414"
	readonly property color fg: wal.special?.foreground ?? "#e6e6e6"
	readonly property var palette: {
		const out = [];
		for (let i = 0; i < 16; i += 1)
			out.push(Qt.color(wal.colors?.[`color${i}`] ?? "#808080"));
		return out;
	}

	function luminance(c) {
		const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
		return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
	}

	function contrast(a, b) {
		const la = root.luminance(a);
		const lb = root.luminance(b);
		return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
	}

	readonly property bool dark: root.luminance(root.bg) < 0.35

	// push a color until it clears the given contrast against the background
	function legible(c, minimum) {
		let out = Qt.color(c);
		for (let i = 0; i < 12 && root.contrast(out, root.bg) < minimum; i += 1)
			out = root.dark ? Qt.lighter(out, 1.12) : Qt.darker(out, 1.12);
		return out;
	}

	// what an item is drawn on: the rectangles behind it composited over the
	// shell base, up to the first opaque one
	function surfaceBehind(item) {
		const layers = [];
		for (let it = item?.parent; it; it = it.parent) {
			if (it.border === undefined) continue;
			const c = it.color;
			if (!c || c.a === undefined || c.a <= 0) continue;
			layers.push(c);
			if (c.a >= 0.99) break;
		}
		let out = root.base;
		for (let i = layers.length - 1; i >= 0; i -= 1)
			out = Qt.tint(out, layers[i]);
		return out;
	}

	// failsafe for icons and text: a color that nearly vanishes into its
	// surface is lifted (lighter on dark surfaces, darker on light ones)
	// until it clearly reads; alpha is kept, so dimmed colors stay dimmed
	readonly property real vanishContrast: 2.5
	readonly property real liftContrast: 4.5
	function readableOn(c, surface) {
		const color = Qt.color(c);
		if (surface.a <= 0) return color;
		const solid = Qt.rgba(color.r, color.g, color.b, 1);
		if (root.contrast(solid, surface) >= root.vanishContrast) return color;
		const white = Qt.color("white");
		const black = Qt.color("black");
		const toward = root.contrast(white, surface) >= root.contrast(black, surface) ? white : black;
		let out = solid;
		for (let step = 1; step <= 20 && root.contrast(out, surface) < root.liftContrast; step += 1)
			out = Qt.tint(solid, Qt.alpha(toward, step / 20));
		return Qt.rgba(out.r, out.g, out.b, color.a);
	}

	readonly property var ranked: {
		const candidates = [];
		for (let i = 1; i <= 6; i += 1) {
			const c = root.palette[i];
			const score = c.hsvSaturation * 1.1
				+ Math.min(1, Math.max(0, (root.contrast(c, root.bg) - 1.6) / 4.5)) * 1.3;
			candidates.push({ color: c, score: score, hue: c.hsvHue });
		}
		candidates.sort((a, b) => b.score - a.score);
		return candidates;
	}

	function pickDistinct(reference, offset) {
		for (let i = offset; i < root.ranked.length; i += 1) {
			const hue = root.ranked[i].hue;
			const distance = Math.min(Math.abs(hue - reference), 1 - Math.abs(hue - reference));
			if (reference < 0 || hue < 0 || distance > 0.06) return root.ranked[i].color;
		}
		return root.ranked[Math.min(offset, root.ranked.length - 1)].color;
	}

	// ── semantic roles ─────────────────────────────────────────────────────
	readonly property color primary: root.legible(root.ranked[0].color, 3.2)
	readonly property color secondary: root.legible(root.pickDistinct(root.ranked[0].hue, 1), 3.0)
	readonly property color tertiary: root.legible(root.pickDistinct(root.secondary.hsvHue, 2), 3.0)
	readonly property color onPrimary: root.contrast(root.primary, root.bg) >= root.contrast(root.primary, root.fg) ? root.bg : root.fg
	readonly property color danger: root.legible(Qt.tint("#e5484d", Qt.alpha(root.primary, 0.12)), 3.4)
	readonly property color warning: root.legible(Qt.tint("#f5a524", Qt.alpha(root.primary, 0.1)), 3.4)
	readonly property color success: root.legible(Qt.tint("#46a758", Qt.alpha(root.primary, 0.1)), 3.4)

	// surfaces — the bar and every attached panel share `base`
	readonly property color base: root.bg
	// the bar is see-through; panels start at the same opacity where they
	// meet the bar and become solid further down so their text stays legible
	readonly property real barOpacity: 0.8
	readonly property color glass: Qt.alpha(root.bg, root.barOpacity)
	readonly property color layer1: Qt.tint(root.bg, Qt.alpha(root.fg, 0.045))
	readonly property color layer2: Qt.tint(root.bg, Qt.alpha(root.fg, 0.085))
	readonly property color layer3: Qt.tint(root.bg, Qt.alpha(root.fg, 0.13))
	readonly property color primaryContainer: Qt.tint(root.bg, Qt.alpha(root.primary, 0.2))
	readonly property color primarySoft: Qt.alpha(root.primary, 0.14)
	readonly property color dangerContainer: Qt.tint(root.bg, Qt.alpha(root.danger, 0.2))
	readonly property color scrim: Qt.rgba(0, 0, 0, root.dark ? 0.42 : 0.28)
	readonly property color shadow: Qt.rgba(0, 0, 0, root.dark ? 0.55 : 0.28)

	// text
	readonly property color text: root.fg
	readonly property color textMuted: Qt.alpha(root.fg, 0.64)
	readonly property color textSubtle: Qt.alpha(root.fg, 0.42)
	readonly property color textFaint: Qt.alpha(root.fg, 0.24)
	readonly property color outline: Qt.alpha(root.fg, 0.08)

	// ── type ───────────────────────────────────────────────────────────────
	readonly property string fontFamily: "Adwaita Sans"
	readonly property string monoFamily: "Adwaita Mono"
	readonly property QtObject size: QtObject {
		readonly property int tiny: 10
		readonly property int small: 11
		readonly property int body: 13
		readonly property int label: 12
		readonly property int title: 15
		readonly property int heading: 18
		readonly property int display: 28
		readonly property int hero: 44
	}

	// ── metrics ────────────────────────────────────────────────────────────
	readonly property int barHeight: 38
	readonly property int screenCorner: root.windowRadius
	readonly property int panelRadius: root.windowRadius
	readonly property int panelFillet: root.windowRadius
	readonly property int panelPadding: 18
	readonly property QtObject radius: QtObject {
		readonly property int small: 8
		readonly property int medium: 12
		readonly property int large: 16
		readonly property int huge: 22
		readonly property int full: 999
	}
	readonly property QtObject gap: QtObject {
		readonly property int xs: 4
		readonly property int sm: 8
		readonly property int md: 12
		readonly property int lg: 16
		readonly property int xl: 24
	}
}
