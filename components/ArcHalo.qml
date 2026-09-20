import QtQuick

// Candlelight. It is in front of the page, not behind it, so it never offsets
// and is never grey — it is the aether colour bleeding outward from whatever it
// is lighting.
//
// The bloom is painted once. `flicker` puts the shell's one shared flame on its
// opacity instead of its paint, so a room full of lamps guttering together
// costs one timer and no repaints at all.
Canvas {
	id: halo

	property color color: Arc.aether
	property real strength: 0.4       // alpha at the centre
	property real spread: 0.5         // how far out it reaches, as a fraction
	property real falloff: 2.2
	property bool flicker: false

	renderStrategy: Canvas.Cooperative
	opacity: halo.flicker ? Arc.flame : 1

	onColorChanged: requestPaint()
	onStrengthChanged: requestPaint()
	onSpreadChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		if (width <= 2 || height <= 2) return;
		const cx = width / 2, cy = height / 2;
		const radius = Math.max(width, height) * Math.max(0.05, halo.spread);
		const bloom = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
		const steps = 6;
		for (let step = 0; step <= steps; step++) {
			const t = step / steps;
			bloom.addColorStop(t, Qt.alpha(halo.color, halo.strength * Math.pow(1 - t, halo.falloff)));
		}
		ctx.fillStyle = bloom;
		ctx.fillRect(0, 0, width, height);
	}
}
