pragma ComponentBehavior: Bound

import QtQuick

// A quantity, as light standing in a column.
//
// Not a bar. What is being measured is a *substance* — mana, aether, charge —
// so it has a surface, and the surface is the whole point: when the reading
// jumps the substance overruns and rocks back, integrated as a real spring so
// a spike looks like something being poured and a steady load looks like
// something at rest. Motes rise off it while it is near full.
Item {
	id: phial

	property real value: 0            // 0..1
	property color trackColor: Arc.goldGhost
	property color fillColor: Arc.aether
	property real weight: Arc.rule
	property bool vertical: false

	implicitHeight: vertical ? 40 : 6
	implicitWidth: vertical ? 6 : 60

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
			phial.velocity += (phial.target - phial.level) * 0.18;
			phial.velocity *= 0.81;
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
			const filled = Math.max(0, Math.min(1.06, phial.level));
			const tip = Math.max(-1, Math.min(1, phial.velocity * 10));

			if (phial.trackColor.a > 0.004) {
				ctx.fillStyle = phial.trackColor;
				ctx.fillRect(0, 0, width, height);
			}

			if (filled <= 0.004) return;

			if (phial.vertical) {
				const floor = height;
				const top = floor - height * filled;
				const lift = height * 0.05 * tip;
				const body = ctx.createLinearGradient(0, top, 0, floor);
				body.addColorStop(0, phial.fillColor);
				body.addColorStop(1, Qt.alpha(phial.fillColor, 0.34));
				ctx.fillStyle = body;
				ctx.beginPath();
				ctx.moveTo(0, floor);
				ctx.lineTo(0, top + lift);
				ctx.quadraticCurveTo(width / 2, top - lift * 1.9, width, top + lift);
				ctx.lineTo(width, floor);
				ctx.closePath();
				ctx.fill();
				return;
			}

			const head = width * filled;
			const lean = width * 0.04 * tip;
			const body = ctx.createLinearGradient(0, 0, head, 0);
			body.addColorStop(0, Qt.alpha(phial.fillColor, 0.34));
			body.addColorStop(1, phial.fillColor);
			ctx.fillStyle = body;
			ctx.beginPath();
			ctx.moveTo(0, 0);
			ctx.lineTo(head + lean, 0);
			ctx.quadraticCurveTo(head - lean * 1.9, height / 2, head + lean, height);
			ctx.lineTo(0, height);
			ctx.closePath();
			ctx.fill();
		}
	}
}
