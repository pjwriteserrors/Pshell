pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// How the panels that hang from the bar open and close (style/widgets/
// Drawer.qml), and the same motion for the tiles on the Desktop page. One
// progress value runs from 0 to 1 (overshooting with the springy ones) and
// shape() turns it into the panel's size, its content's way in and the
// effects over it, so every style is the same panel moving differently.
// Kept in popups.json.
Singleton {
	id: root

	// classic | button | liquid | curtain | glass | pop
	property string style: "classic"
	// 0.6 slow … 1.6 fast
	property real speed: 1

	readonly property var styles: [
		{ id: "classic", label: "Classic", about: "Extrudes from the bar, the neck widening as it comes" },
		{ id: "button", label: "From the button", about: "A thin tongue out of the button you pressed, then it unrolls" },
		{ id: "liquid", label: "Liquid", about: "Drips out of the bar and wobbles into shape; the content comes into focus" },
		{ id: "curtain", label: "Curtain", about: "Unrolls downwards, the content fading in behind a soft edge" },
		{ id: "glass", label: "Glass", about: "Settles out of a blur with a light sweeping across it" },
		{ id: "pop", label: "Pop", about: "Springs out of the bar with a little bounce" }
	]

	// the open motion of a style; closing is quick and plain for every one
	function opening(style) {
		const base = Motion.long / Math.max(0.3, root.speed);
		switch (style) {
		case "liquid": return { duration: base * 2.1, type: Easing.OutElastic, amplitude: 1, period: 0.55, curve: Motion.spatial };
		case "pop": return { duration: base * 1.15, type: Easing.OutBack, overshoot: 2.2, curve: Motion.spatial };
		case "curtain": return { duration: base * 1.35, type: Easing.BezierSpline, curve: Motion.decel };
		case "glass": return { duration: base * 1.4, type: Easing.BezierSpline, curve: Motion.decel };
		case "button": return { duration: base * 1.3, type: Easing.BezierSpline, curve: Motion.emphasized };
		default: return { duration: base, type: Easing.BezierSpline, curve: Motion.spatial };
		}
	}

	function closing(style) {
		return { duration: (Motion.medium - 60) / Math.max(0.3, root.speed), type: Easing.BezierSpline, curve: Motion.accel };
	}

	function clamp(v) {
		return Math.max(0, Math.min(1, v));
	}

	// the panel at progress r: body width/height, its scale and opacity,
	// where its content is (y offset, opacity, scale), how blurred it is,
	// how far a curtain has uncovered it and where the light is
	function shape(style, r, width, height, buttonWidth, opening) {
		const c = root.clamp(r);
		const out = { w: width, h: height * r, scale: 1, opacity: 1, y: -14 * (1 - c), co: root.clamp((c - 0.35) / 0.65), cs: 1, blur: 0, wipe: 1, sheen: -1 };
		switch (style) {
		case "button": {
			// a tongue as wide as the button drops first, then unrolls sideways
			const k = root.clamp((r - 0.22) / 0.6);
			const widen = k * k * (3 - 2 * k);
			out.w = buttonWidth + (width - buttonWidth) * widen;
			out.h = height * Math.min(1.04, Math.max(0, r * 1.5));
			out.y = -8 * (1 - c);
			out.co = root.clamp((c - 0.5) / 0.5);
			out.cs = 0.95 + 0.05 * c;
			break;
		}
		case "liquid":
			// the overshoot bulges it sideways and lets it hang a little long
			out.w = width * (0.5 + 0.5 * Math.min(1.08, r));
			out.h = height * Math.min(1.08, Math.max(0, r));
			out.y = -22 * (1 - c);
			out.co = root.clamp((c - 0.25) / 0.6);
			out.blur = opening ? 1 - c : 0;
			break;
		case "curtain":
			out.h = height * c;
			out.y = 0;
			out.co = 1;
			out.wipe = opening ? c : 1;
			break;
		case "glass":
			out.h = height;
			out.scale = 0.92 + 0.08 * c;
			out.opacity = c;
			out.y = 0;
			out.co = root.clamp(c * 1.3);
			out.blur = opening ? (1 - c) * 0.9 : 0;
			out.sheen = opening && c < 1 ? c : -1;
			break;
		case "pop":
			out.h = height;
			out.scale = 0.55 + 0.45 * r;
			out.opacity = root.clamp(c * 2.5);
			out.y = 0;
			out.co = root.clamp((c - 0.15) / 0.6);
			break;
		default:
			out.w = width * (0.62 + 0.38 * Math.min(1.04, r));
		}
		return out;
	}

	function set(name, value) {
		if (root[name] === value) return;
		root[name] = value;
		file.setText(JSON.stringify({ style: root.style, speed: root.speed }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("popups.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			try {
				const saved = JSON.parse(String(text() || "{}"));
				if (root.styles.some(entry => entry.id === saved.style)) root.style = saved.style;
				if (Number(saved.speed) >= 0.5 && Number(saved.speed) <= 2) root.speed = Number(saved.speed);
			} catch (error) {}
		}
	}
}
