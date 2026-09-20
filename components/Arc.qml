pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Arcanum: the desktop as a working instrument.
//
// The claim this style makes is that the shell is made of three materials and
// nothing else. Brass is cast, engraved and turns against a detent. Vellum is
// rolled — it comes down off a roller and goes back up onto it, it never fades
// and it never appears in the middle of the air. Flame is the only light there
// is, so it never sits still.
//
// Everything below is one of those three, or the distance between two of them.
// Colour comes entirely from the live Wallust palette: this is the only file in
// the style that reads it, and everything else takes its colour from a token
// here. A light wallpaper is not a washed-out dark one — the instrument turns
// over: real cream vellum, dark bronze fittings and brown ink, instead of a
// dark ground with pale gold on it.
QtObject {
	id: arc

	// ---------------------------------------------------------------- palette
	property var palette: ({
		special: { background: "#0f0a10", foreground: "#cfc4b4" },
		colors: {
			color1: "#9c4a3f", color2: "#6d8659", color3: "#c39a4a",
			color4: "#46688f", color5: "#6f5289", color6: "#3f8c8a"
		}
	})

	function mix(a, b, amount) {
		return Qt.rgba(a.r * (1 - amount) + b.r * amount,
			a.g * (1 - amount) + b.g * amount,
			a.b * (1 - amount) + b.b * amount, 1);
	}

	function luminance(color) {
		function channel(value) { return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4); }
		return channel(color.r) * 0.2126 + channel(color.g) * 0.7152 + channel(color.b) * 0.0722;
	}

	function contrast(a, b) {
		const x = arc.luminance(a), y = arc.luminance(b);
		return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
	}

	function chroma(color) { return Math.max(color.r, color.g, color.b) - Math.min(color.r, color.g, color.b); }

	function hueOf(color) { return color.hslHue < 0 ? 0.08 : color.hslHue; }

	function parsed(value, fallback) {
		return /^#[0-9a-f]{6}$/i.test(String(value)) ? Qt.color(value) : Qt.color(fallback);
	}

	function on(surfaceColor) {
		return arc.contrast(Qt.color("#ffffff"), surfaceColor) > arc.contrast(Qt.color("#000000"), surfaceColor)
			? Qt.color("#ffffff") : Qt.color("#000000");
	}

	// Walk a colour towards black or white until it clears a contrast ratio.
	// Nothing in this style is drawn with a colour that has not been through
	// here — thin engraved lines over a bright wallpaper are exactly where a
	// style like this normally falls apart.
	function readable(color, over, ratio) {
		const end = arc.on(over);
		if (arc.contrast(color, over) >= ratio) return color;
		let low = 0, high = 1;
		for (let step = 0; step < 16; step++) {
			const middle = (low + high) / 2;
			if (arc.contrast(arc.mix(color, end, middle), over) >= ratio) high = middle;
			else low = middle;
		}
		return arc.mix(color, end, high);
	}

	// Drive a colour towards its own pure hue and up in brightness: what a
	// pigment does when there is a flame behind it rather than in front.
	function lit(color, amount) {
		const saturation = Math.min(1, color.hslSaturation * (1 + amount) + amount * 0.36);
		const lightness = Math.min(0.76, Math.max(color.hslLightness, 0.44 + amount * 0.14));
		return Qt.hsla(arc.hueOf(color), saturation, lightness, 1);
	}

	// Rank the palette by how much hue it carries, weighted by how legible it
	// stays on the ground. color1 is not the accent; whichever entry actually
	// carries the wallpaper is.
	function ranked() {
		const source = arc.palette.colors || {};
		const list = [];
		for (let index = 1; index <= 6; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = arc.chroma(color);
			if (tint < 0.03) continue;
			list.push({ color: color, score: tint * Math.min(1, arc.contrast(color, arc.vellum) / 3.2) });
		}
		list.sort((a, b) => b.score - a.score);
		return list.map(entry => entry.color);
	}

	// The palette entry nearest a target hue, so a status colour stays in the
	// wallpaper's family instead of being a fixed hex.
	function hued(target, spread, fallback) {
		const source = arc.palette.colors || {};
		let best = null, bestScore = -1;
		for (let index = 1; index <= 15; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = arc.chroma(color);
			if (tint < 0.09) continue;
			const distance = Math.min(Math.abs(arc.hueOf(color) - target), 1 - Math.abs(arc.hueOf(color) - target));
			if (distance > spread) continue;
			if (tint > bestScore) { bestScore = tint; best = color; }
		}
		return best || Qt.color(fallback);
	}

	// A status colour that reads as the live colour is not a status colour.
	function distinct(candidate, fallback) {
		const gap = Math.abs(arc.hueOf(candidate) - arc.hueOf(arc.aether));
		return Math.min(gap, 1 - gap) >= 0.07 ? candidate : Qt.color(fallback);
	}

	function load(raw) {
		try {
			const next = JSON.parse(raw);
			if (!next.special
				|| !/^#[0-9a-f]{6}$/i.test(next.special.background)
				|| !/^#[0-9a-f]{6}$/i.test(next.special.foreground)) return;
			arc.palette = next;
		} catch (error) { /* keep the last valid palette while the file is replaced */ }
	}

	property FileView colorsFile: FileView {
		path: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/wal/colors.json"
		watchChanges: true
		blockLoading: true
		printErrors: false
		onLoaded: arc.load(text())
		onFileChanged: reload()
	}

	// ----------------------------------------------------------------- vellum
	readonly property color wallBackground: parsed(palette.special.background, "#0f0a10")
	readonly property color wallForeground: parsed(palette.special.foreground, "#cfc4b4")
	readonly property bool light: luminance(wallBackground) > 0.42

	// The page is never neutral. A dark ground is pulled a little further into
	// the wallpaper's own warmest pigment so it reads as tanned hide rather
	// than as grey; a light ground is bleached towards the same pigment so it
	// reads as cream rather than as white card.
	readonly property color tan: hued(0.08, 0.20, light ? "#8a6a42" : "#c8a061")
	readonly property color vellum: light
		? mix(mix(wallBackground, Qt.color("#ffffff"), 0.70), tan, 0.10)
		: mix(mix(wallBackground, Qt.color("#000000"), 0.56), tan, 0.05)
	readonly property color deeper: light ? Qt.color("#000000") : Qt.color("#000000")
	readonly property color raised: light ? Qt.color("#000000") : Qt.color("#ffffff")

	// Four page depths. A surface sits on one of them; there is no fifth.
	readonly property color leaf0: vellum
	readonly property color leaf1: mix(vellum, raised, light ? 0.030 : 0.055)
	readonly property color leaf2: mix(vellum, raised, light ? 0.055 : 0.090)
	readonly property color leaf3: mix(vellum, raised, light ? 0.100 : 0.150)
	// The groove: where the instrument is cut into, and where a scroll is dark
	// because it is still rolled.
	readonly property color well: mix(vellum, Qt.color("#000000"), light ? 0.12 : 0.46)
	readonly property color scrim: Qt.alpha(mix(wallBackground, Qt.color("#000000"), 0.78), 0.70)

	// The wash inside a page: the live colour bled into the vellum, so a panel
	// is tinted by the wallpaper rather than being a flat plane.
	readonly property color wash: mix(leaf1, aether, light ? 0.06 : 0.09)
	readonly property color washDeep: mix(well, aether, light ? 0.04 : 0.06)

	// ------------------------------------------------------------------ brass
	// The fittings. Deliberately low in chroma and far from the live colour in
	// lightness: on a monochrome wallpaper the accent and the metal would
	// otherwise be the same pigment, and the instrument would stop reading as
	// metal at all. Pale gold on a dark ground, dark bronze on a light one.
	readonly property color giltRaw: Qt.hsla(hueOf(tan),
		Math.min(light ? 0.34 : 0.21, tan.hslSaturation * 0.48 + 0.05),
		light ? 0.32 : 0.78, 1)
	readonly property color gilt: readable(giltRaw, leaf1, light ? 7.0 : 6.4)
	readonly property color giltDim: Qt.alpha(gilt, light ? 0.56 : 0.50)
	readonly property color giltFaint: Qt.alpha(gilt, light ? 0.32 : 0.26)
	readonly property color giltGhost: Qt.alpha(gilt, light ? 0.17 : 0.12)

	// ----------------------------------------------------------------- aether
	// The live colour: whatever the wallpaper actually carries. One entry runs
	// the whole instrument; the next two take second and third readings.
	readonly property var aethers: ranked()
	readonly property color aetherRaw: aethers.length > 0 ? aethers[0] : parsed(palette.colors?.color4, "#46688f")
	readonly property color aether: readable(lit(aetherRaw, light ? 0.12 : 0.34), leaf1, light ? 3.8 : 3.2)
	readonly property color aetherAlt: readable(lit(aethers.length > 1 ? aethers[1] : aetherRaw, light ? 0.12 : 0.28), leaf1, 3.2)
	readonly property color aetherThird: readable(lit(aethers.length > 2 ? aethers[2] : aetherAlt, light ? 0.12 : 0.24), leaf1, 3.0)
	readonly property color onAether: on(aether)

	// Candlelight. Not a shadow and never offset: the flame is in front of the
	// page, so what it does is bleed outward from whatever it is lighting.
	readonly property color glow: Qt.alpha(aether, light ? 0.15 : 0.28)
	readonly property color glowSoft: Qt.alpha(aether, light ? 0.07 : 0.14)
	readonly property color aetherWash: mix(leaf1, aether, light ? 0.15 : 0.20)
	readonly property color aetherEdge: Qt.alpha(aether, 0.60)

	// ---------------------------------------------------------------- reagents
	readonly property color ward: readable(distinct(hued(0.33, 0.11, "#6d8659"), "#6d8659"), leaf1, 4.0)
	readonly property color ember: readable(distinct(hued(0.11, 0.07, "#c39a4a"), "#c39a4a"), leaf1, 4.0)
	// Bane must never be mistaken for the live colour, or a warning reads as
	// decoration. A palette entry is used only when its hue sits clearly apart.
	readonly property color bane: readable(distinct(hued(0.0, 0.06, "#b04a42"), "#b04a42"), leaf1, 4.2)

	// -------------------------------------------------------------------- ink
	readonly property color ink: readable(mix(on(vellum), wallForeground, 0.18), leaf1, 8.5)
	readonly property color inkMuted: readable(mix(leaf1, ink, 0.68), leaf1, 4.8)
	readonly property color inkFaint: readable(mix(leaf1, ink, 0.46), leaf1, 3.1)

	// ------------------------------------------------------------------- hand
	// Two voices, and they are not interchangeable. The cut letter is what the
	// instrument has engraved on it — names of things, permanent, in small
	// capitals. The hand is what somebody wrote on the page afterwards — an
	// app's true name, a reading's aside, the oracle's line.
	readonly property string cut: "C059"
	readonly property string book: "C059"
	readonly property string hand: "Z003"
	readonly property string mono: "Red Hat Mono"

	readonly property real sizeDisplay: 34
	readonly property real sizeTitle: 19
	readonly property real sizeHeading: 15
	readonly property real sizeBody: 14
	readonly property real sizeCaption: 12
	readonly property real sizeRubric: 11
	readonly property real sizeMono: 12
	readonly property real trackingRubric: 2.4
	readonly property real trackingTitle: 1.2

	// ------------------------------------------------------------------ space
	readonly property real s1: 3
	readonly property real s2: 6
	readonly property real s3: 10
	readonly property real s4: 14
	readonly property real s5: 20
	readonly property real s6: 28
	readonly property real s7: 40
	readonly property real s8: 56

	// ------------------------------------------------------------------ shape
	readonly property real rule: 1.3
	readonly property real ruleThin: 1.0
	readonly property real ruleHeavy: 2.2
	readonly property real stud: 2.6
	readonly property real corner: 10
	readonly property real cornerSmall: 6

	// --------------------------------------------------------------- the gantry
	// The instrument hangs from the top edge of the screen as a chain: fixed at
	// both top corners, sagging to its lowest point in the middle, where the
	// horologe hangs. Everything the shell shows is seated along that curve, so
	// nothing on it is at the same height as anything else — which is the whole
	// reason it cannot be mistaken for a bar.
	readonly property real gantryDepth: 104     // the strip the chain reserves
	readonly property real gantryRise: 24       // the chain's height at the screen edges
	readonly property real gantrySag: 40        // how far it drops by the middle
	readonly property real seat: 30             // a sigil's brass seat
	readonly property real horologe: 70         // the dial hanging at the lowest point
	readonly property real dropGap: 9           // chain to the head of a hanging scroll
	readonly property real dropInset: 16        // air kept at the bottom of the screen
	readonly property real headColumn: 26

	// Where the chain sits at a fraction across the screen.
	//
	// Not a catenary. A cord carrying a single weight in the middle hangs in
	// two straight runs, and over a screen this wide a catenary's curve is too
	// slight to read as anything but a crooked line — where two straight limbs
	// meeting under the horologe read immediately as something being carried.
	function chainY(fraction) {
		const t = Math.abs(Math.max(0, Math.min(1, fraction)) * 2 - 1);
		return arc.gantryRise + arc.gantrySag * (1 - t);
	}

	// ----------------------------------------------------------------- motion
	// Three materials, three behaviours, and nothing in the shell moves in a
	// fourth way.
	//
	//   brass   turns, and stops against a detent — it overshoots the stop by a
	//           hair and settles back into it. Never slides, never fades.
	//   vellum  unrolls downward off its roller under its own weight, and is
	//           taken back up faster than it came down. Never scales.
	//   flame   kindles: up fast, then creeps, and never settles completely.
	readonly property int tick: 110
	readonly property int turn: 240
	readonly property int draw: 360
	readonly property int recoil: 190
	readonly property int unroll: 460
	readonly property int reroll: 210
	readonly property int band: 220
	readonly property int bandStep: 40
	readonly property int drift: 5200

	// Hand-cut curves. Nothing in this style uses a stock easing for anything
	// that matters: a roller has friction to overcome and a stop to arrest
	// against, and no built-in curve does both ends.
	readonly property var curveUnroll: [0.40, 0.00, 0.12, 1.00, 1, 1]
	readonly property var curveReroll: [0.56, 0.00, 0.84, 0.34, 1, 1]
	readonly property var curveDetent: [0.26, 1.44, 0.42, 0.97, 1, 1]
	readonly property var curveKindle: [0.04, 0.58, 0.26, 1.00, 1, 1]
	readonly property var curveInk: [0.62, 0.02, 0.26, 1.00, 1, 1]
	readonly property var curveSwing: [0.34, 0.00, 0.14, 1.00, 1, 1]

	// The delay before the nth band of a page is written. Capped, so a long
	// list never makes the reader wait on arithmetic.
	function stagger(index) {
		return Math.min(7, Math.max(0, index)) * bandStep;
	}

	// ------------------------------------------------------------------ flame
	// One flicker for the whole shell. Every flame in the instrument multiplies
	// its own strength by this, so the lamps all breathe together the way they
	// would in one room — and it costs exactly one timer, not one per light.
	property real flame: 1
	property real flameTarget: 1
	property real flameVelocity: 0

	property Timer flameTimer: Timer {
		running: true
		repeat: true
		interval: 50

		onTriggered: {
			// A guttering flame is not noise: it wanders towards a new target
			// and is pulled back by the wick. Integrated, so the motion has
			// weight rather than being a random walk.
			if (Math.random() < 0.16)
				arc.flameTarget = 0.80 + Math.random() * 0.24;
			arc.flameVelocity = arc.flameVelocity * 0.72 + (arc.flameTarget - arc.flame) * 0.28;
			arc.flame = Math.max(0.68, Math.min(1.06, arc.flame + arc.flameVelocity));
		}
	}

	// ------------------------------------------------------------------- hours
	// The hour has a name as well as a number. The instrument is a fantasy
	// object and the clock is the first thing anybody looks at, so it says
	// which hour of the night this is and not only what o'clock it is.
	function hourName(date) {
		const names = [
			"Hour of the Void", "Hour of Ash", "Hour of the Wolf", "Hour of the Owl",
			"Hour of the Cold", "Hour of First Light", "Hour of the Lark", "Hour of Waking",
			"Hour of the Forge", "Hour of Letters", "Hour of the Crown", "Hour of the Zenith",
			"Hour of the Bell", "Hour of Still Air", "Hour of the Long Shade", "Hour of Amber",
			"Hour of Embers", "Hour of the Hearth", "Hour of the Gate", "Hour of Dusk",
			"Hour of the Moon", "Hour of the Veil", "Hour of the Candle", "Hour of the Deep"
		];
		return names[(date ? date.getHours() : 0) % 24];
	}

	// The moon, to about a day. Enough for an instrument that is telling you
	// the season of the night, not enough to navigate by.
	function moonPhase(date) {
		const when = (date || new Date()).getTime() / 86400000;
		const age = ((when - 6.7) % 29.530588853 + 29.530588853) % 29.530588853;
		const names = ["New", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
			"Full", "Waning Gibbous", "Last Quarter", "Waning Crescent"];
		return { age: age, fraction: age / 29.530588853, name: names[Math.floor(age / 29.530588853 * 8 + 0.5) % 8] };
	}

	function icon(name, fallback) {
		const paths = {
			"view-app-grid-symbolic": "/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg",
			"audio-x-generic-symbolic": "/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg",
			"preferences-system-notifications-symbolic": "/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-notifications-symbolic.svg",
			"edit-paste-symbolic": "/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg",
			"network-wired-symbolic": "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg",
			"network-wireless-signal-excellent-symbolic": "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg",
			"bluetooth-active-symbolic": "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg",
			"system-shutdown-symbolic": "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg",
			"utilities-system-monitor-symbolic": "/usr/share/icons/Adwaita/symbolic/apps/utilities-system-monitor-symbolic.svg",
			"weather-few-clouds-symbolic": "/usr/share/icons/Adwaita/symbolic/status/weather-few-clouds-symbolic.svg",
			"preferences-system-time-symbolic": "/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-time-symbolic.svg"
		};
		return paths[name] || paths[String(name) + "-symbolic"] || String(fallback || "");
	}
}
