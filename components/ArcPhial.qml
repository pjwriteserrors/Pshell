pragma ComponentBehavior: Bound

import QtQuick

// A reading, drawn as what is in the vessel.
//
// Not a progress bar: a quantity of liquid with a surface on it. The surface is
// the whole point — when a reading jumps, the liquid overruns and rocks back,
// integrated as a real damped spring rather than eased, so a load spike looks
// like something being poured and a steady load looks like something at rest.
Item {
	id: phial

	property real value: 0            // 0..1
	property color trackColor: Arc.giltGhost
	property color fillColor: Arc.aether
	property real weight: Arc.rule
	property bool vertical: false

	implicitHeight: vertical ? 40 : 6
	implicitWidth: vertical ? 6 : 60

	// Where the liquid actually stands, which is not where the reading is
	// until it has stopped moving.
	property real level: 0
	property real velocity: 0
	readonly property real target: Math.max(0, Math.min(1, phial.value))

	onValueChanged: slosh.running = true

	Component.onCompleted: {
		phial.level = phial.target;
		canvas.requestPaint();
	}

	Timer {
		id: slosh
		interval: 16
		repeat: true

		onTriggered: {
			// Stiffness and damping chosen so a full-scale change overruns by
			// about six percent and is still inside two rocks.
			phial.velocity += (phial.target - phial.level) * 0.19;
			phial.velocity *= 0.80;
			phial.level += phial.velocity;
			canvas.requestPaint();
			if (Math.abs(phial.target - phial.level) < 0.0015 && Math.abs(phial.velocity) < 0.0015) {
				phial.level = phial.target;
				phial.velocity = 0;
				canvas.requestPaint();
				slosh.running = false;
			}
		}
	}

	onFillColorChanged: canvas.requestPaint()
	onTrackColorChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 2 || height <= 2) return;
			const inset = phial.weight * 0.5;
			const filled = Math.max(0, Math.min(1.06, phial.level));
			// How far past level the surface is tipped, so the liquid reads as
			// having been thrown rather than having grown.
			const tip = Math.max(-1, Math.min(1, phial.velocity * 9));

			if (phial.trackColor.a > 0.004) {
				ctx.fillStyle = phial.trackColor;
				ctx.fillRect(inset, inset, width - inset * 2, height - inset * 2);
			}

			if (filled <= 0.004) return;
			ctx.fillStyle = phial.fillColor;

			if (phial.vertical) {
				const floor = height - inset;
				const top = floor - (height - inset * 2) * filled;
				const lift = (height - inset * 2) * 0.06 * tip;
				ctx.beginPath();
				ctx.moveTo(inset, floor);
				ctx.lineTo(inset, top + lift);
				ctx.quadraticCurveTo(width / 2, top - lift * 1.8, width - inset, top + lift);
				ctx.lineTo(width - inset, floor);
				ctx.closePath();
				ctx.fill();
				return;
			}

			const left = inset;
			const head = left + (width - inset * 2) * filled;
			const lean = (width - inset * 2) * 0.05 * tip;
			ctx.beginPath();
			ctx.moveTo(left, inset);
			ctx.lineTo(head + lean, inset);
			ctx.quadraticCurveTo(head - lean * 1.8, height / 2, head + lean, height - inset);
			ctx.lineTo(left, height - inset);
			ctx.closePath();
			ctx.fill();
		}
	}
}
