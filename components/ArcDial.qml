pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A conjuring ring.
//
// Every round thing in the sanctum is one, from the great circle at the horizon
// down to the mark on a status sigil. It is not a stroked circle with a border:
// it is a limb of graduations, a ring of upright runes when there is room for
// them, and — where a reading is being taken — a light that has travelled round
// from the twelve and is still sitting at the value.
//
// `drawn` is the whole opening choreography: at 0 nothing has been inscribed,
// at 1 the ring is closed. Nothing here fades in.
Item {
	id: dial

	property color lineColor: Arc.goldDim
	property color liveColor: Arc.aether
	property real weight: Arc.rule
	property real intensity: 0
	property real progress: -1        // < 0: no reading taken
	property int seed: 0
	property bool beading: true       // draw the runes
	property real drawn: 1            // how much of it has been inscribed

	implicitWidth: 32
	implicitHeight: 32

	readonly property int divisions: [36, 24, 48, 30][Math.abs(seed) % 4]
	readonly property int runes: [8, 6, 10, 7][Math.abs(seed) % 4]

	onLineColorChanged: limbLayer.requestPaint()
	onWeightChanged: repaintAll()
	onSeedChanged: repaintAll()
	onBeadingChanged: repaintAll()
	onDrawnChanged: repaintAll()
	onLiveColorChanged: readingLayer.requestPaint()
	onProgressChanged: readingLayer.requestPaint()
	onIntensityChanged: readingLayer.requestPaint()

	function repaintAll() {
		limbLayer.requestPaint();
		readingLayer.requestPaint();
	}

	Canvas {
		id: limbLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 6 || height <= 6 || dial.drawn <= 0.002) return;
			const cx = width / 2, cy = height / 2;
			const outer = Math.min(width, height) / 2 - dial.weight;
			if (outer < 3) return;

			const big = outer >= 26 && dial.beading;
			const limb = big ? outer - outer * 0.20 : outer;

			Ink.ring(ctx, cx, cy, limb, dial.weight, dial.lineColor, dial.drawn);
			Ink.graduations(ctx, cx, cy, limb - dial.weight, dial.divisions,
				outer * 0.05, outer * 0.11, 3, Math.max(0.7, dial.weight * 0.55),
				Qt.alpha(dial.lineColor, 0.55), dial.drawn);

			if (big)
				Ink.runeRing(ctx, cx, cy, outer - outer * 0.05, dial.runes,
					dial.seed * 13 + 1, outer * 0.13, Math.max(0.9, dial.weight * 0.9),
					Qt.alpha(dial.lineColor, 0.7), dial.liveColor,
					Math.round(dial.runes * dial.drawn));
		}
	}

	// The reading: light that has travelled round from the twelve, with a mote
	// sitting where it stopped.
	Canvas {
		id: readingLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		visible: dial.progress >= 0 || dial.intensity > 0.004

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 6 || height <= 6) return;
			const cx = width / 2, cy = height / 2;
			const outer = Math.min(width, height) / 2 - dial.weight;
			if (outer < 3) return;
			const big = outer >= 26 && dial.beading;
			const limb = big ? outer - outer * 0.20 : outer;

			if (dial.intensity > 0.004) {
				ctx.save();
				ctx.globalAlpha = dial.intensity;
				Ink.ring(ctx, cx, cy, limb, dial.weight * 1.5, dial.liveColor, dial.drawn);
				ctx.restore();
			}

			if (dial.progress < 0) return;
			const filled = Math.max(0.004, Math.min(1, dial.progress)) * dial.drawn;
			Ink.ring(ctx, cx, cy, limb, dial.weight * 1.9, dial.liveColor, filled);
			const tip = -Math.PI / 2 + Math.PI * 2 * filled;
			Ink.mote(ctx, cx + Math.cos(tip) * limb, cy + Math.sin(tip) * limb,
				dial.weight * 1.9, dial.liveColor);
		}
	}
}
