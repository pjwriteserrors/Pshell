import QtQuick

// Light, bleeding into the void around whatever it is coming from. Never
// offset, never grey: it is in front of the thing, not behind it.
//
// The bloom is painted once. `flicker` puts the sanctum's single guttering
// value on its opacity rather than its paint, so a room full of conjured
// lights breathes together for one timer and no repaints.
Canvas {
	id: halo

	property color color: Arc.aether
	property real strength: 0.4
	property real spread: 0.5
	property real falloff: 2.2
	// How much of the radius stays at full strength before it starts to fall
	// off. A plain power curve leaves nothing flat in the middle, which is
	// wrong when the light is standing in for a *place* — a pool of night, say
	// — rather than for a glow.
	property real core: 0
	property bool flicker: false

	renderStrategy: Canvas.Cooperative
	opacity: halo.flicker ? Arc.flame : 1

	onColorChanged: requestPaint()
	onStrengthChanged: requestPaint()
	onSpreadChanged: requestPaint()
	onCoreChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		if (width <= 2 || height <= 2) return;
		const cx = width / 2, cy = height / 2;
		const radius = Math.max(width, height) * Math.max(0.05, halo.spread);
		const bloom = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
		const steps = 10;
		const core = Math.max(0, Math.min(0.9, halo.core));
		for (let step = 0; step <= steps; step++) {
			const t = step / steps;
			const fade = t <= core ? 1 : Math.pow((1 - t) / (1 - core), halo.falloff);
			bloom.addColorStop(t, Qt.alpha(halo.color, halo.strength * fade));
		}
		ctx.fillStyle = bloom;
		ctx.fillRect(0, 0, width, height);
	}
}
