pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// The ring: a circle grown rather than stroked.
//
// The reference sheet's circles are never one even line — the bone thickens
// through one arc, thins to nothing at the top, and a run of vertebrae fills
// the gap where it broke. Every round thing in this style is this: bar nodes,
// status lamps, the ring around a progress reading.
//
// `progress` fills part of the circumference in the organ colour, which is how
// a reading is shown here; a bar under a number would belong to another style.
Item {
	id: ring

	property color lineColor: Bio.boneDim
	property color liveColor: Bio.organ
	property real weight: Bio.rib
	property real intensity: 0
	property real progress: -1        // < 0: no reading drawn
	property int seed: 0              // which of the grown variants to draw
	property bool beading: true

	implicitWidth: 32
	implicitHeight: 32

	onLineColorChanged: boneLayer.requestPaint()
	onWeightChanged: repaintAll()
	onSeedChanged: repaintAll()
	onBeadingChanged: repaintAll()
	onLiveColorChanged: liveLayer.requestPaint()
	onProgressChanged: readingLayer.requestPaint()

	function repaintAll() {
		boneLayer.requestPaint();
		liveLayer.requestPaint();
		readingLayer.requestPaint();
	}

	// An arc of the ring as a tapered ribbon. Four control points on a circle
	// approximate a quarter turn closely enough that nobody counts.
	function arc(ctx, cx, cy, radius, from, to, widthAt) {
		const steps = Math.max(1, Math.ceil(Math.abs(to - from) / (Math.PI / 2)));
		const nodes = [];
		for (let step = 0; step < steps; step++) {
			const a0 = from + (to - from) * step / steps;
			const a1 = from + (to - from) * (step + 1) / steps;
			const handle = 4 / 3 * Math.tan((a1 - a0) / 4) * radius;
			const p0 = { x: cx + Math.cos(a0) * radius, y: cy + Math.sin(a0) * radius };
			const p3 = { x: cx + Math.cos(a1) * radius, y: cy + Math.sin(a1) * radius };
			const p1 = { x: p0.x - Math.sin(a0) * handle, y: p0.y + Math.cos(a0) * handle };
			const p2 = { x: p3.x + Math.sin(a1) * handle, y: p3.y - Math.cos(a1) * handle };
			if (step === 0) nodes.push(p0);
			nodes.push(p1, p2, p3);
		}
		Ink.chain(ctx, nodes, widthAt, 14);
	}

	function beadsAlong(ctx, cx, cy, radius, from, to, count, size) {
		for (let index = 0; index < count; index++) {
			const t = count === 1 ? 0.5 : index / (count - 1);
			const angle = from + (to - from) * t;
			Ink.bead(ctx, cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius,
				size, 1.25, angle + Math.PI / 2);
		}
	}

	function paintRing(ctx, w, h, color, weight) {
		const cx = w / 2, cy = h / 2;
		const radius = Math.min(w, h) / 2 - weight * 2.2;
		if (radius <= 1) return;
		ctx.fillStyle = color;

		// Where the bone breaks. Four grown variants, picked by seed, so a row
		// of nodes is a colony and not a repeat pattern.
		const cut = [-Math.PI / 2, -Math.PI / 6, Math.PI / 2, Math.PI * 0.85][Math.abs(ring.seed) % 4];
		const openness = [0.30, 0.22, 0.34, 0.26][Math.abs(ring.seed) % 4];
		const from = cut + openness;
		const to = cut + Math.PI * 2 - openness;

		ring.arc(ctx, cx, cy, radius, from, to, Ink.taper(weight * 2.4, 0.08, 0.08, 0.42));
		if (!ring.beading) return;
		ring.beadsAlong(ctx, cx, cy, radius, to + 0.10, to + openness * 1.7, 3, weight * 1.05);
		ring.beadsAlong(ctx, cx, cy, radius, from - openness * 1.7, from - 0.10, 3, weight * 1.05);
	}

	Canvas {
		id: boneLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width > 4 && height > 4) ring.paintRing(ctx, width, height, ring.lineColor, ring.weight);
		}
	}

	Canvas {
		id: liveLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		opacity: ring.intensity
		visible: opacity > 0.004

		Behavior on opacity {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width > 4 && height > 4) ring.paintRing(ctx, width, height, ring.liveColor, ring.weight * 1.15);
		}
	}

	// The reading: a second, heavier arc laid over the bone from the top.
	Canvas {
		id: readingLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		visible: ring.progress >= 0

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (ring.progress < 0 || width <= 4 || height <= 4) return;
			const cx = width / 2, cy = height / 2;
			const radius = Math.min(width, height) / 2 - ring.weight * 2.2;
			if (radius <= 1) return;
			const filled = Math.max(0.02, Math.min(1, ring.progress));
			ctx.fillStyle = ring.liveColor;
			ring.arc(ctx, cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * filled,
				Ink.taper(ring.weight * 2.9, 0.55, 0.14, 0.7));
			const tip = -Math.PI / 2 + Math.PI * 2 * filled;
			Ink.bead(ctx, cx + Math.cos(tip) * radius, cy + Math.sin(tip) * radius,
				ring.weight * 1.25, 1.0, 0);
		}
	}
}
