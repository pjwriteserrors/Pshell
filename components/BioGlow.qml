import QtQuick

// Bioluminescence. Light leaves a living edge; it does not fall behind it, so
// this is never offset and never grey — it is the organ colour bleeding into
// the tissue around whatever it sits behind.
Canvas {
	id: halo

	property color color: Bio.organ
	property real strength: 0.4       // alpha at the centre
	property real spread: 0.5         // how far out it reaches, as a fraction
	property real falloff: 2.2

	renderStrategy: Canvas.Cooperative

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
