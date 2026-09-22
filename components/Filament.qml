pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The one place that knows what the shell is made of.
//
// Filament is a lit thread. Wallust decides what the light is: the accent
// with the most chroma that still reads on the background becomes the
// charge, the two after it are the supporting charges, and the reddest
// saturated entry is the alert. Everything else — the cold thread, the
// planes the lanterns are made of, the four ink tones — is mixed from the
// palette's background and foreground, so a light wallpaper produces a dark
// thread across a light plane instead of a washed-out dark shell.
//
// This is the only file that reads colors.json. Nothing else is allowed to.
QtObject {
	id: filament

	// ---------------------------------------------------------------- palette
	readonly property string cachePath: {
		const xdg = String(Quickshell.env("XDG_CACHE_HOME") || "");
		const home = String(Quickshell.env("HOME") || "");
		return (xdg !== "" ? xdg : `${home}/.cache`) + "/wal/colors.json";
	}

	property var wal: fallbackWal
	readonly property var fallbackWal: ({
		special: { background: "#161a1c", foreground: "#c9d1cb" },
		colors: {
			color0: "#161a1c", color1: "#8a4a3c", color2: "#5f7a58", color3: "#b5893e",
			color4: "#5b7b9a", color5: "#8c6a9c", color6: "#4f8c8a", color7: "#c9d1cb",
			color8: "#2c3236", color9: "#c4614d", color10: "#7fa374", color11: "#e0aa4c",
			color12: "#7aa3c9", color13: "#b58ccb", color14: "#6fb6b3", color15: "#e6ebe6"
		}
	})

	readonly property FileView walFile: FileView {
		path: filament.cachePath
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: filament.adopt(text())
		onLoadFailed: {}
	}

	function adopt(raw) {
		try {
			const parsed = JSON.parse(String(raw || ""));
			if (!parsed?.special?.background || !parsed?.special?.foreground || !parsed?.colors?.color1)
				return;
			filament.wal = parsed;
		} catch (error) {
			// A half-written file keeps the last palette that was whole.
		}
	}

	function reload() {
		walFile.reload();
		adopt(walFile.text());
	}

	// ------------------------------------------------------------ colour maths
	function lum(c) {
		const col = Qt.color(c);
		const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
		return 0.2126 * lin(col.r) + 0.7152 * lin(col.g) + 0.0722 * lin(col.b);
	}

	function contrast(a, b) {
		const la = lum(a), lb = lum(b);
		return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
	}

	function chroma(c) {
		const col = Qt.color(c);
		return Math.max(col.r, col.g, col.b) - Math.min(col.r, col.g, col.b);
	}

	function mix(a, b, t) {
		const ca = Qt.color(a), cb = Qt.color(b);
		return Qt.rgba(ca.r + (cb.r - ca.r) * t, ca.g + (cb.g - ca.g) * t, ca.b + (cb.b - ca.b) * t, 1);
	}

	// Push a colour away from the background until it reads, without changing
	// what hue it is. Dark shells lift, light shells sink.
	function legible(c, against, minimum) {
		let col = Qt.color(c);
		const lighten = lum(against) < 0.5;
		for (let i = 0; i < 8 && contrast(col, against) < minimum; i += 1)
			col = lighten ? Qt.lighter(col, 1.18) : Qt.darker(col, 1.18);
		return col;
	}

	function hueOf(c) {
		return Qt.color(c).hslHue;
	}

	// -------------------------------------------------------------- the light
	readonly property color bg: wal.special.background
	readonly property color fg: legible(wal.special.foreground, wal.special.background, 4.5)
	readonly property bool light: lum(bg) > 0.5

	readonly property var ranked: {
		const entries = [];
		for (let i = 1; i <= 6; i += 1) {
			const c = wal.colors[`color${i}`];
			if (!c) continue;
			const col = legible(c, bg, 2.6);
			const score = chroma(col) * Math.min(contrast(col, bg), 7);
			entries.push({ color: col, score: score, hue: hueOf(col), sat: Qt.color(col).hslSaturation });
		}
		entries.sort((a, b) => b.score - a.score);
		return entries;
	}

	readonly property color charge: ranked.length > 0 ? ranked[0].color : "#d99a4c"
	readonly property color charge2: ranked.length > 1 ? ranked[1].color : charge
	readonly property color charge3: ranked.length > 2 ? ranked[2].color : charge2
	readonly property color onCharge: lum(charge) > 0.42 ? "#111417" : "#f4f6f4"

	readonly property color alert: {
		let best = null;
		for (const entry of ranked) {
			const h = entry.hue;
			const reddish = h < 0.07 || h > 0.92;
			if (reddish && (best === null || entry.sat > best.sat)) best = entry;
		}
		return best ? best.color : legible("#d95c5c", bg, 2.6);
	}
	readonly property color onAlert: lum(alert) > 0.42 ? "#111417" : "#f4f6f4"

	// --------------------------------------------------------------- the dark
	readonly property color planeSolid: light ? Qt.darker(bg, 1.02) : mix(bg, charge, 0.05)
	readonly property color plane: Qt.alpha(planeSolid, 0.985)
	readonly property color planeRaised: light ? Qt.darker(bg, 1.06) : mix(bg, fg, 0.06)
	readonly property color well: Qt.alpha(fg, light ? 0.10 : 0.09)
	readonly property color wellDeep: Qt.alpha(fg, 0.16)
	readonly property color scrim: Qt.alpha(light ? "#ffffff" : "#000000", light ? 0.42 : 0.5)

	// ------------------------------------------------------------- the thread
	readonly property color wire: mix(bg, fg, light ? 0.62 : 0.5)
	readonly property color wireDim: mix(bg, fg, 0.22)
	readonly property color wireBright: mix(bg, fg, 0.85)

	// ---------------------------------------------------------------- the ink
	readonly property color ink: fg
	readonly property color inkSoft: Qt.alpha(fg, 0.72)
	readonly property color inkMute: Qt.alpha(fg, 0.5)
	readonly property color inkFaint: Qt.alpha(fg, 0.3)

	// Names the Studio contract still speaks. The pages get these handed over
	// and are free to read them as what they are here.
	readonly property color secondaryBoxColor: well
	readonly property color secondaryBoxStrongColor: wellDeep
	readonly property color secondaryInsetColor: Qt.alpha(fg, 0.06)

	// ------------------------------------------------------------------- type
	readonly property string fontUi: "Red Hat Display"
	readonly property string fontMono: "CaskaydiaCove Nerd Font Mono"
	readonly property int textXs: 10
	readonly property int textSm: 12
	readonly property int textMd: 13
	readonly property int textLg: 15
	readonly property int textXl: 20
	readonly property int textDisplay: 30

	// --------------------------------------------------------------- geometry
	readonly property int barHeight: 36
	readonly property int wireY: 18
	readonly property int wireWidth: 2
	readonly property int beadHeight: 24
	readonly property int stemLength: 12
	readonly property int radius: 10
	readonly property int radiusSmall: 6
	readonly property int gap: 8
	readonly property int pad: 14

	// ----------------------------------------------------------------- motion
	// The thread is under tension: it gives quickly and settles in two swings.
	// Light travels; it has a speed, not a duration.
	readonly property int quick: 140
	readonly property int settle: 260
	readonly property int unfold: 380
	readonly property int fold: 190
	readonly property int breathe: 2600

	readonly property var easeSettle: [0.16, 1, 0.3, 1, 1, 1]
	readonly property var easeUnfold: [0.18, 0.9, 0.22, 1.06, 1, 1]
	readonly property var easeFold: [0.5, 0, 0.75, 0.3, 1, 1]
	readonly property var easeTravel: [0.5, 0, 0.12, 1, 1, 1]
	readonly property var easeGrow: [0.3, 0, 0.1, 1, 1, 1]

	function travelTime(distance) {
		return Math.round(Math.max(220, Math.min(760, 160 + Math.abs(distance) * 0.5)));
	}

	function stagger(index) {
		return Math.min(Math.max(0, index), 9) * 32;
	}

	// A band's own reveal, 0..1, from the parent's reveal and its order.
	function band(reveal, order) {
		const start = Math.min(0.55, order * 0.09);
		return Math.max(0, Math.min(1, (reveal - start) / (1 - start)));
	}
}
