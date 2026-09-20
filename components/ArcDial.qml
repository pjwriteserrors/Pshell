pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// The dial: a graduated brass limb.
//
// Every round thing in the instrument is one — a sigil's seat, a status lamp,
// the ring a reading is taken on. It is not a stroked circle: the rim is cut as
// a groove, the limb is graduated, and a reading is an arc laid over the
// graduations from the twelve, the way it would be on a real instrument.
//
// `seed` picks how the limb is divided, so a row of dials is a set of
// instruments rather than one instrument repeated.
Item {
	id: dial

	property color lineColor: Arc.giltDim
	property color liveColor: Arc.aether
	property real weight: Arc.rule
	property real intensity: 0
	property real progress: -1        // < 0: no reading taken
	property int seed: 0
	property bool beading: true

	implicitWidth: 32
	implicitHeight: 32

	readonly property int divisions: [12, 8, 16, 10][Math.abs(seed) % 4]

	onLineColorChanged: brassLayer.requestPaint()
	onWeightChanged: repaintAll()
	onSeedChanged: repaintAll()
	onBeadingChanged: repaintAll()
	onLiveColorChanged: liveLayer.requestPaint()
	onProgressChanged: readingLayer.requestPaint()

	function repaintAll() {
		brassLayer.requestPaint();
		liveLayer.requestPaint();
		readingLayer.requestPaint();
	}

	function paintLimb(ctx, w, h, color, weight) {
		const cx = w / 2, cy = h / 2;
		const radius = Math.min(w, h) / 2 - weight * 1.8;
		if (radius <= 1) return;
		const shadow = Qt.alpha(Qt.darker(color, 2.2), 0.55);
		const highlight = Qt.alpha(Qt.lighter(color, 1.7), 0.5);

		Ink.groove(ctx, Ink.arcPoints(cx, cy, radius, 0, Math.PI * 2, 34),
			weight, color, highlight, shadow, true);

		if (!dial.beading || radius < 9) return;
		Ink.graduations(ctx, cx, cy, radius - weight * 1.2, -Math.PI / 2, Math.PI * 1.5,
			dial.divisions, radius * 0.13, radius * 0.24, 3, Math.max(0.7, weight * 0.62),
			Qt.alpha(color, 0.72));
	}

	Canvas {
		id: brassLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width > 4 && height > 4) dial.paintLimb(ctx, width, height, dial.lineColor, dial.weight);
		}
	}

	Canvas {
		id: liveLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		opacity: dial.intensity
		visible: opacity > 0.004

		Behavior on opacity {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width > 4 && height > 4) dial.paintLimb(ctx, width, height, dial.liveColor, dial.weight * 1.12);
		}
	}

	// The reading: an arc taken from the twelve, with an index mark at its head
	// so the value can be read off the limb rather than guessed from a length.
	Canvas {
		id: readingLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		visible: dial.progress >= 0

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (dial.progress < 0 || width <= 4 || height <= 4) return;
			const cx = width / 2, cy = height / 2;
			const radius = Math.min(width, height) / 2 - dial.weight * 1.8;
			if (radius <= 1) return;
			const filled = Math.max(0.005, Math.min(1, dial.progress));
			const tip = -Math.PI / 2 + Math.PI * 2 * filled;

			Ink.cut(ctx, Ink.arcPoints(cx, cy, radius, -Math.PI / 2, tip, 30),
				dial.weight * 2.1, dial.liveColor, false);

			// The index: the pointer the reading is taken against.
			ctx.strokeStyle = dial.liveColor;
			ctx.lineWidth = Math.max(1, dial.weight);
			ctx.lineCap = "round";
			ctx.beginPath();
			ctx.moveTo(cx + Math.cos(tip) * (radius - dial.weight * 3.4), cy + Math.sin(tip) * (radius - dial.weight * 3.4));
			ctx.lineTo(cx + Math.cos(tip) * (radius + dial.weight * 1.6), cy + Math.sin(tip) * (radius + dial.weight * 1.6));
			ctx.stroke();
		}
	}
}
