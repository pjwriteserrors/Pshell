pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Biopunk foundations.
//
// The desktop as a specimen under glass: a dark carapace, chambers outlined in
// bone, and one luminous organ per screen that carries the colour. Nothing here
// is a rounded rectangle with a drop shadow — a chamber is a drawn membrane with
// a grown edge, and the edge is where the wallpaper's colour lives.
//
// Every colour below comes from the live Wallust palette and is corrected for
// contrast, so the same organism holds together on a light and a dark wallpaper.
// On a light palette the specimen inverts rather than washing out: ink-drawn
// bone on bleached chitin instead of luminous bone on black.
QtObject {
	id: bio

	// ---------------------------------------------------------------- palette
	property var palette: ({
		special: { background: "#0a0d0c", foreground: "#d9e2dd" },
		colors: {
			color1: "#b8453c", color2: "#5fa361", color3: "#c39a4a",
			color4: "#4d87a8", color5: "#8e6bb0", color6: "#43b3a8"
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
		const x = bio.luminance(a), y = bio.luminance(b);
		return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
	}

	function chroma(color) { return Math.max(color.r, color.g, color.b) - Math.min(color.r, color.g, color.b); }

	function parsed(value, fallback) {
		return /^#[0-9a-f]{6}$/i.test(String(value)) ? Qt.color(value) : Qt.color(fallback);
	}

	function on(surfaceColor) {
		return bio.contrast(Qt.color("#ffffff"), surfaceColor) > bio.contrast(Qt.color("#000000"), surfaceColor)
			? Qt.color("#ffffff") : Qt.color("#000000");
	}

	// Walk a colour towards black or white until it clears a contrast ratio.
	function readable(color, over, ratio) {
		const end = bio.on(over);
		if (bio.contrast(color, over) >= ratio) return color;
		let low = 0, high = 1;
		for (let step = 0; step < 16; step++) {
			const middle = (low + high) / 2;
			if (bio.contrast(bio.mix(color, end, middle), over) >= ratio) high = middle;
			else low = middle;
		}
		return bio.mix(color, end, high);
	}

	// Push a colour towards its own pure hue and up in brightness: what a
	// living edge looks like when it is lit from inside rather than painted.
	function luminous(color, amount) {
		const hue = color.hslHue < 0 ? 0 : color.hslHue;
		const saturation = Math.min(1, color.hslSaturation * (1 + amount) + amount * 0.35);
		const lightness = Math.min(0.78, Math.max(color.hslLightness, 0.46 + amount * 0.12));
		return Qt.hsla(hue, saturation, lightness, 1);
	}

	// Rank the palette by hue strength weighted with legibility on the carapace,
	// so the organ colour is whatever actually carries the wallpaper.
	function ranked() {
		const source = bio.palette.colors || {};
		const list = [];
		for (let index = 1; index <= 6; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = bio.chroma(color);
			if (tint < 0.035) continue;
			list.push({ color: color, score: tint * Math.min(1, bio.contrast(color, bio.carapace) / 3.2) });
		}
		list.sort((a, b) => b.score - a.score);
		return list.map(entry => entry.color);
	}

	// The palette entry nearest a target hue, so status colours stay in the
	// wallpaper's family instead of being three fixed hexes.
	function hued(target, spread, fallback) {
		const source = bio.palette.colors || {};
		let best = null, bestScore = -1;
		for (let index = 1; index <= 15; index++) {
			const raw = source["color" + index];
			if (!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
			const color = Qt.color(raw), tint = bio.chroma(color);
			if (tint < 0.09) continue;
			const hue = color.hslHue < 0 ? 0.5 : color.hslHue;
			const distance = Math.min(Math.abs(hue - target), 1 - Math.abs(hue - target));
			if (distance > spread) continue;
			if (tint > bestScore) { bestScore = tint; best = color; }
		}
		return best || Qt.color(fallback);
	}

	// A status colour that reads as the organ colour is not a status colour.
	function distinct(candidate, fallback) {
		const organHue = bio.organ.hslHue < 0 ? 0.5 : bio.organ.hslHue;
		const hue = candidate.hslHue < 0 ? 0.5 : candidate.hslHue;
		const gap = Math.abs(hue - organHue);
		return Math.min(gap, 1 - gap) >= 0.07 ? candidate : Qt.color(fallback);
	}

	function load(raw) {
		try {
			const next = JSON.parse(raw);
			if (!next.special
				|| !/^#[0-9a-f]{6}$/i.test(next.special.background)
				|| !/^#[0-9a-f]{6}$/i.test(next.special.foreground)) return;
			bio.palette = next;
		} catch (error) { /* keep the last valid palette while the file is replaced */ }
	}

	property FileView colorsFile: FileView {
		path: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/wal/colors.json"
		watchChanges: true
		blockLoading: true
		printErrors: false
		onLoaded: bio.load(text())
		onFileChanged: reload()
	}

	// ------------------------------------------------------------------ tissue
	// The carapace is the wallpaper's own background pushed further into its
	// corner: darker and slightly desaturated on a dark palette, bleached on a
	// light one. Every chamber is a wash of it, never a flat grey.
	readonly property color wallBackground: parsed(palette.special.background, "#0a0d0c")
	readonly property color wallForeground: parsed(palette.special.foreground, "#d9e2dd")
	readonly property bool light: luminance(wallBackground) > 0.42

	readonly property color carapace: light
		? mix(wallBackground, Qt.color("#ffffff"), 0.55)
		: mix(wallBackground, Qt.color("#000000"), 0.58)
	readonly property color depth: light ? Qt.color("#ffffff") : Qt.color("#000000")
	readonly property color lift: light ? Qt.color("#000000") : Qt.color("#ffffff")

	// Four tissue depths. A chamber sits on one of them; there is no fifth.
	readonly property color tissue0: carapace
	readonly property color tissue1: mix(carapace, lift, light ? 0.035 : 0.05)
	readonly property color tissue2: mix(carapace, lift, light ? 0.06 : 0.085)
	readonly property color tissue3: mix(carapace, lift, light ? 0.11 : 0.14)
	readonly property color cavity: mix(carapace, Qt.color("#000000"), light ? 0.10 : 0.45)
	readonly property color scrim: Qt.alpha(mix(wallBackground, Qt.color("#000000"), 0.80), 0.72)

	// The membrane wash that fills a chamber: the organ colour bled into the
	// tissue, strongest where the chamber meets its own edge.
	readonly property color membrane: mix(tissue1, organ, light ? 0.07 : 0.10)
	readonly property color membraneDeep: mix(cavity, organ, light ? 0.05 : 0.07)

	// -------------------------------------------------------------------- bone
	// Bone is the drawing colour: every frame, rib, nodule and tendon. It is
	// near-neutral with a breath of the wallpaper's foreground in it.
	readonly property color boneRaw: mix(on(carapace), wallForeground, 0.24)
	readonly property color bone: readable(boneRaw, tissue1, 7.5)
	readonly property color boneDim: Qt.alpha(bone, light ? 0.52 : 0.46)
	readonly property color boneFaint: Qt.alpha(bone, light ? 0.30 : 0.22)
	readonly property color boneGhost: Qt.alpha(bone, light ? 0.16 : 0.10)

	// -------------------------------------------------------------------- organ
	// The living colour. One entry of the palette carries the whole interface;
	// the next two are the secondary organs (progress, selection, charts).
	readonly property var organs: ranked()
	readonly property color organRaw: organs.length > 0 ? organs[0] : parsed(palette.colors?.color4, "#43b3a8")
	readonly property color organ: readable(luminous(organRaw, light ? 0.10 : 0.30), tissue1, light ? 3.6 : 3.2)
	readonly property color organAlt: readable(luminous(organs.length > 1 ? organs[1] : organRaw, light ? 0.10 : 0.26), tissue1, 3.2)
	readonly property color organThird: readable(luminous(organs.length > 2 ? organs[2] : organAlt, light ? 0.10 : 0.22), tissue1, 3.0)
	readonly property color onOrgan: on(organ)

	// Bioluminescence: the halo an edge throws onto the tissue around it. Never
	// a shadow — light leaves a living edge, it does not fall behind it.
	readonly property color glow: Qt.alpha(organ, light ? 0.16 : 0.30)
	readonly property color glowSoft: Qt.alpha(organ, light ? 0.08 : 0.15)
	readonly property color organWash: mix(tissue1, organ, light ? 0.16 : 0.22)
	readonly property color organEdge: Qt.alpha(organ, 0.62)

	// --------------------------------------------------------------- reactions
	readonly property color vital: readable(distinct(hued(0.33, 0.11, "#5fa361"), "#5fa361"), tissue1, 4.0)
	readonly property color enzyme: readable(distinct(hued(0.11, 0.07, "#c39a4a"), "#c39a4a"), tissue1, 4.0)
	// Necrosis must never be mistaken for the organ colour: a palette entry is
	// only used when its hue sits clearly apart, otherwise a fixed red is
	// corrected for contrast and used instead.
	readonly property color necrosis: readable(distinct(hued(0.0, 0.06, "#c04a42"), "#c04a42"), tissue1, 4.2)

	// -------------------------------------------------------------------- text
	readonly property color text: readable(bone, tissue1, 8)
	readonly property color textMuted: readable(mix(tissue1, bone, 0.70), tissue1, 4.8)
	readonly property color textFaint: readable(mix(tissue1, bone, 0.50), tissue1, 3.1)

	// -------------------------------------------------------------------- type
	// A humanist serif in wide small capitals for anything that names a thing —
	// the engraved-plate voice of the reference art — and a plain sans for
	// anything a person actually reads word by word.
	readonly property string serif: "P052"
	readonly property string sans: "Red Hat Text"
	readonly property string mono: "Red Hat Mono"

	readonly property real sizeSpecimen: 34
	readonly property real sizeTitle: 19
	readonly property real sizeHeading: 14
	readonly property real sizeBody: 13
	readonly property real sizeCaption: 11
	readonly property real sizeEyebrow: 10
	readonly property real sizeMono: 12
	readonly property real trackingEyebrow: 2.6
	readonly property real trackingTitle: 1.8

	// ------------------------------------------------------------------- space
	readonly property real s1: 3
	readonly property real s2: 6
	readonly property real s3: 10
	readonly property real s4: 14
	readonly property real s5: 20
	readonly property real s6: 28
	readonly property real s7: 40
	readonly property real s8: 56

	// ------------------------------------------------------------------- shape
	// Growth, not geometry: a chamber's corner is a shoulder, its line weight is
	// a bone thickness, and a nodule is the vertebra where two ribs meet.
	readonly property real rib: 1.4
	readonly property real ribThin: 1.0
	readonly property real ribHeavy: 2.0
	readonly property real nodule: 2.6
	readonly property real shoulder: 16
	readonly property real shoulderSmall: 9
	readonly property real crest: 7

	// The spine: one height the bar and everything docked to it align to.
	readonly property real spine: 36
	readonly property real nodeSize: 32

	// ------------------------------------------------------------------ motion
	// Organic: things swell open and relax shut, and a living edge never stops
	// breathing entirely.
	readonly property int twitch: 130
	readonly property int grow: 260
	readonly property int swell: 380
	readonly property int relax: 220
	readonly property int breath: 4200

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
