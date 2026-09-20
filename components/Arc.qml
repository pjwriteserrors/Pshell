pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// ARCANUM.
//
// The desktop is a sanctum, and the things in it are conjured rather than
// built. That is a claim about material, and everything below follows from it:
//
//   the void     the ground is not a surface. It is depth — the wallpaper
//                pushed towards its own coldest pigment until it reads as
//                distance rather than as a plane to put widgets on.
//   glass        a panel is a pane of dark glass hanging in that depth. It has
//                no frame. Light catches its upper edge and nothing else; the
//                rest of its outline is where the glass stops being dark.
//   light        the only bright things are conjured: rings that draw
//                themselves, runes that ignite, motes that drift. Gold is the
//                colour of writing, never of a border.
//
// There is no ornament here that encloses anything. A box drawn round a thing
// is a thing that was manufactured, and nothing in this shell was.
//
// Colour comes entirely from the live Wallust palette; this is the only file in
// the style that reads it. A light wallpaper is not a washed-out dark one — the
// sanctum turns over into daylight: a pale astral ground, glass that is bright
// rather than dark, and ink for writing instead of gold.
QtObject {
	id: arc

	// ---------------------------------------------------------------- palette
	property var palette: ({
		special: { background: "#0b0a14", foreground: "#cdc6dc" },
		colors: {
			color1: "#8f3f4c", color2: "#4a7a5e", color3: "#c0913f",
			color4: "#3f5f9c", color5: "#6b4d99", color6: "#3f8f9c"
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

	function hueOf(color) { return color.hslHue < 0 ? 0.66 : color.hslHue; }

	function parsed(value, fallback) {
		return /^#[0-9a-f]{6}$/i.test(String(value)) ? Qt.color(value) : Qt.color(fallback);
	}

	function on(surfaceColor) {
		return arc.contrast(Qt.color("#ffffff"), surfaceColor) > arc.contrast(Qt.color("#000000"), surfaceColor)
			? Qt.color("#ffffff") : Qt.color("#000000");
	}

	// Nothing is drawn with a colour that has not been through here. Fine light
	// over an arbitrary wallpaper is exactly where a style like this falls
	// apart, and the answer is a contrast floor, not a heavier line.
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

	// What a pigment looks like when it is being *emitted* rather than lit.
	function kindled(color, amount) {
		const saturation = Math.min(1, color.hslSaturation * (1 + amount) + amount * 0.40);
		const lightness = Math.min(0.78, Math.max(color.hslLightness, 0.46 + amount * 0.14));
		return Qt.hsla(arc.hueOf(color), saturation, lightness, 1);
	}

	// Rank the palette by how much hue it carries, weighted by how legible it
	// stays against the void. color1 is not the accent; whichever entry
	// actually carries the wallpaper is.
	function ranked() {
		const source = arc.palette.colors || {};
		const list = [];
		for (let index = 1; index <= 6; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = arc.chroma(color);
			if (tint < 0.03) continue;
			list.push({ color: color, score: tint * Math.min(1, arc.contrast(color, arc.abyss) / 3.2) });
		}
		list.sort((a, b) => b.score - a.score);
		return list.map(entry => entry.color);
	}

	// The palette entry nearest a target hue.
	function hued(target, spread, fallback) {
		const source = arc.palette.colors || {};
		let best = null, bestScore = -1;
		for (let index = 1; index <= 15; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = arc.chroma(color);
			if (tint < 0.08) continue;
			const distance = Math.min(Math.abs(arc.hueOf(color) - target), 1 - Math.abs(arc.hueOf(color) - target));
			if (distance > spread) continue;
			if (tint > bestScore) { bestScore = tint; best = color; }
		}
		return best || Qt.color(fallback);
	}

	// The coldest pigment the wallpaper has, which is what the void is pulled
	// towards. Deep blue and violet are what make a dark ground read as depth
	// instead of as black card, and a neutral fallback would lose that.
	readonly property color cold: {
		const source = arc.palette.colors || {};
		let best = null, bestScore = -1;
		for (let index = 1; index <= 15; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), hue = arc.hueOf(color);
			// how far into the blue-violet arc, times how much colour it has
			const cool = hue > 0.5 && hue < 0.82 ? 1 - Math.abs(hue - 0.68) * 3 : 0.0;
			const score = cool * (0.25 + arc.chroma(color));
			if (score > bestScore) { bestScore = score; best = color; }
		}
		return bestScore > 0.04 ? best : Qt.color("#2a2350");
	}

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

	// ------------------------------------------------------------------ void
	readonly property color wallBackground: parsed(palette.special.background, "#0b0a14")
	readonly property color wallForeground: parsed(palette.special.foreground, "#cdc6dc")
	readonly property bool light: luminance(wallBackground) > 0.42

	// The ground. Taken down towards black and pulled into the wallpaper's own
	// coldest pigment, so it reads as distance rather than as a dark plane.
	readonly property color abyss: light
		? mix(mix(wallBackground, Qt.color("#ffffff"), 0.62), cold, 0.07)
		: mix(mix(wallBackground, Qt.color("#000000"), 0.62), cold, 0.16)
	readonly property color raised: light ? Qt.color("#000000") : Qt.color("#ffffff")

	// Four depths of glass. A pane sits at one of them; there is no fifth.
	// They are *translucent*: a pane is something you look into, and a stack of
	// opaque rectangles would be a stack of cards.
	readonly property real paneAlpha: light ? 0.97 : 0.955
	readonly property color veil0: Qt.alpha(abyss, paneAlpha)
	readonly property color veil1: Qt.alpha(mix(abyss, cold, light ? 0.05 : 0.12), paneAlpha)
	readonly property color veil2: Qt.alpha(mix(abyss, raised, light ? 0.05 : 0.07), paneAlpha)
	readonly property color veil3: Qt.alpha(mix(abyss, raised, light ? 0.09 : 0.13), paneAlpha)
	// Where the glass is deepest, and where a conjuring has not reached yet.
	readonly property color depth: Qt.alpha(mix(abyss, Qt.color("#000000"), light ? 0.10 : 0.45), light ? 0.94 : 0.90)
	readonly property color scrim: Qt.alpha(mix(mix(wallBackground, Qt.color("#000000"), 0.35), cold, 0.22), light ? 0.80 : 0.94)

	// The haze inside a pane: the live colour bled into the glass, strongest
	// where the conjuring came through.
	readonly property color haze: Qt.alpha(mix(abyss, aether, light ? 0.07 : 0.13), paneAlpha)
	readonly property color hazeDeep: Qt.alpha(mix(abyss, cold, light ? 0.06 : 0.22), paneAlpha)

	// ------------------------------------------------------------------ gold
	// The colour of writing and of runes. Warm, because everything else in the
	// sanctum is cold, and that is the whole reason it reads at all.
	readonly property color warm: hued(0.10, 0.16, light ? "#7a5a20" : "#d8ab52")
	readonly property color goldRaw: Qt.hsla(hueOf(warm),
		Math.min(light ? 0.62 : 0.46, warm.hslSaturation * 0.82 + 0.10),
		light ? 0.30 : 0.72, 1)
	readonly property color gold: readable(goldRaw, veil1, light ? 6.4 : 5.6)
	readonly property color goldDim: Qt.alpha(gold, light ? 0.58 : 0.52)
	readonly property color goldFaint: Qt.alpha(gold, light ? 0.34 : 0.28)
	readonly property color goldGhost: Qt.alpha(gold, light ? 0.18 : 0.13)

	// ---------------------------------------------------------------- aether
	// The live light. One pigment runs the whole sanctum; the next two take
	// second and third readings.
	readonly property var aethers: ranked()
	readonly property color aetherRaw: aethers.length > 0 ? aethers[0] : cold
	readonly property color aether: readable(kindled(aetherRaw, light ? 0.14 : 0.38), veil1, light ? 3.8 : 3.0)
	readonly property color aetherAlt: readable(kindled(aethers.length > 1 ? aethers[1] : cold, light ? 0.14 : 0.32), veil1, 3.0)
	readonly property color aetherThird: readable(kindled(aethers.length > 2 ? aethers[2] : aetherAlt, light ? 0.14 : 0.26), veil1, 2.8)
	readonly property color onAether: on(aether)

	readonly property color glow: Qt.alpha(aether, light ? 0.16 : 0.34)
	readonly property color glowSoft: Qt.alpha(aether, light ? 0.08 : 0.17)

	// --------------------------------------------------------------- reagents
	readonly property color ward: readable(distinct(hued(0.33, 0.11, "#4a7a5e"), "#4a7a5e"), veil1, 4.0)
	readonly property color ember: readable(distinct(hued(0.11, 0.07, "#c0913f"), "#c0913f"), veil1, 4.0)
	// Bane must never be mistaken for the live colour, or a warning reads as
	// decoration.
	readonly property color bane: readable(distinct(hued(0.0, 0.06, "#b4444f"), "#b4444f"), veil1, 4.2)

	// -------------------------------------------------------------------- ink
	readonly property color ink: readable(mix(on(abyss), wallForeground, 0.16), veil1, 9.0)
	readonly property color inkMuted: readable(mix(abyss, ink, 0.66), veil1, 4.6)
	readonly property color inkFaint: readable(mix(abyss, ink, 0.44), veil1, 3.0)

	// ------------------------------------------------------------------- hand
	// Two voices. The cut letter is what is inscribed on a thing — names,
	// small capitals, permanent. The hand is what a person wrote: an app's true
	// name, the oracle's line, the name of the hour.
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
	readonly property real trackingRubric: 2.6
	readonly property real trackingTitle: 1.4

	// ------------------------------------------------------------------ space
	// Wider than a normal shell's, on purpose: the reference this style is
	// drawn from is mostly empty space with a few bright things in it.
	readonly property real s1: 4
	readonly property real s2: 8
	readonly property real s3: 13
	readonly property real s4: 20
	readonly property real s5: 28
	readonly property real s6: 40
	readonly property real s7: 56
	readonly property real s8: 76

	// ------------------------------------------------------------------ shape
	readonly property real rule: 1.2
	readonly property real ruleThin: 1.0
	readonly property real ruleHeavy: 2.0
	readonly property real mote: 2.4

	// -------------------------------------------------------------- the scene
	// The shell reserves a band at the foot of the screen, and there is exactly
	// one permanent object in it: the chronomancer, a great rune circle half
	// sunk below the edge like a moon at the horizon. Everything else in the
	// band is a small light placed in the space around it, and everything the
	// shell opens rises out of that band.
	readonly property real horizon: 146      // the band the sanctum reserves
	readonly property real chronoRadius: 146 // the great circle, mostly below
	readonly property real chronoSunk: 34    // how far its centre is off-screen
	readonly property real sigilSize: 30
	readonly property real riseGap: 18       // horizon to the foot of a panel
	readonly property real riseInset: 22     // air kept at the top of the screen

	// ----------------------------------------------------------------- motion
	// Three things happen in this shell and nothing else does:
	//
	//   draw      a ring inscribes itself, once round, at the speed a hand
	//             moves. Every conjuring starts with one.
	//   settle    light that has been called takes a moment to stop moving; it
	//             overshoots a little and comes back. Never a linear fade.
	//   disperse  what was conjured comes apart into motes and falls.
	//
	// Nothing slides in from off-screen, nothing scales from a corner, and
	// nothing unrolls.
	readonly property int tick: 120
	readonly property int turn: 260
	readonly property int draw: 420
	readonly property int recoil: 200
	readonly property int conjure: 620
	readonly property int dispel: 260
	readonly property int band: 200
	readonly property int bandStep: 46
	readonly property int drift: 6000

	// Hand-cut curves. A conjuring is slow to start (the ring has to be drawn)
	// and then arrives all at once; a dispelling goes the other way.
	readonly property var curveRise: [0.46, 0.00, 0.10, 1.00, 1, 1]
	readonly property var curveSink: [0.58, 0.00, 0.86, 0.36, 1, 1]
	readonly property var curveSnap: [0.24, 1.48, 0.42, 0.98, 1, 1]
	readonly property var curveKindle: [0.04, 0.62, 0.24, 1.00, 1, 1]
	readonly property var curveInk: [0.62, 0.02, 0.26, 1.00, 1, 1]
	readonly property var curveDraw: [0.32, 0.00, 0.12, 1.00, 1, 1]

	// The delay before the nth thing in a conjuring arrives. Capped, so a long
	// list never makes the reader wait on arithmetic.
	function stagger(index) {
		return Math.min(7, Math.max(0, index)) * bandStep;
	}

	// ------------------------------------------------------------------ flame
	// One guttering value for the whole sanctum. Every light multiplies its own
	// strength by it, so the room breathes together for the cost of one timer
	// and no repaints anywhere.
	property real flame: 1
	property real flameTarget: 1
	property real flameVelocity: 0

	property Timer flameTimer: Timer {
		running: true
		repeat: true
		interval: 50

		onTriggered: {
			if (Math.random() < 0.14)
				arc.flameTarget = 0.82 + Math.random() * 0.22;
			arc.flameVelocity = arc.flameVelocity * 0.74 + (arc.flameTarget - arc.flame) * 0.26;
			arc.flame = Math.max(0.70, Math.min(1.06, arc.flame + arc.flameVelocity));
		}
	}

	// ------------------------------------------------------------------ hours
	// The hour has a name as well as a number, and the runes on the great
	// circle are cut from that name's own index, so they change as the night
	// turns.
	readonly property var hourNames: [
		"Hour of the Void", "Hour of Ash", "Hour of the Wolf", "Hour of the Owl",
		"Hour of the Cold", "Hour of First Light", "Hour of the Lark", "Hour of Waking",
		"Hour of the Forge", "Hour of Letters", "Hour of the Crown", "Hour of the Zenith",
		"Hour of the Bell", "Hour of Still Air", "Hour of the Long Shade", "Hour of Amber",
		"Hour of Embers", "Hour of the Hearth", "Hour of the Gate", "Hour of Dusk",
		"Hour of the Moon", "Hour of the Veil", "Hour of the Candle", "Hour of the Deep"
	]

	function hourName(date) {
		return arc.hourNames[(date ? date.getHours() : 0) % 24];
	}

	// The moon, to about a day. Enough for an instrument telling you which part
	// of the night this is; not enough to navigate by.
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
