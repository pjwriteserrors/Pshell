pragma ComponentBehavior: Bound

import QtQuick
import "BioInk.js" as Ink

// A sigil: the round bioform that stands in for a thing when there is no icon
// for it — the launcher, a locked session, an empty list, a specimen with no
// artwork. Grown from `seed`, so the same thing always gets the same creature
// and two different things never get the same one.
Item {
	id: sigil

	property color lineColor: Bio.bone
	property int seed: 1
	property real weight: Bio.rib
	property real detail: 1.0

	implicitWidth: 48
	implicitHeight: 48

	onLineColorChanged: canvas.requestPaint()
	onSeedChanged: canvas.requestPaint()
	onWeightChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		// A small deterministic generator: the same seed has to grow the same
		// creature across restarts, so Math.random is out.
		function makeRandom(seed) {
			let state = (Math.abs(seed) % 2147483647) + 1;
			return function () {
				state = (state * 48271) % 2147483647;
				return (state - 1) / 2147483646;
			};
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const size = Math.min(width, height);
			if (size <= 8) return;
			const random = makeRandom(sigil.seed * 7919 + 13);
			const cx = width / 2, cy = height / 2;
			const w = sigil.weight;
			ctx.fillStyle = sigil.lineColor;

			const loops = 2 + Math.floor(random() * 2 * sigil.detail);
			for (let loop = 0; loop < loops; loop++) {
				const radius = size * (0.44 - loop * 0.11) * (0.82 + random() * 0.3);
				const drift = size * 0.06 * loop;
				const ox = cx + (random() - 0.5) * drift * 2;
				const oy = cy + (random() - 0.5) * drift * 2;
				const points = 5 + Math.floor(random() * 3);
				const start = random() * Math.PI * 2;
				// A closed loop whose radius wanders: the shape reads as grown
				// because no two of its quarters are the same size.
				const nodes = [];
				for (let step = 0; step <= points; step++) {
					const angle = start + Math.PI * 2 * step / points;
					const next = start + Math.PI * 2 * (step + 1) / points;
					const r0 = radius * (0.72 + random() * 0.5);
					const r1 = radius * (0.72 + random() * 0.5);
					const p0 = { x: ox + Math.cos(angle) * r0, y: oy + Math.sin(angle) * r0 };
					const p3 = { x: ox + Math.cos(next) * r1, y: oy + Math.sin(next) * r1 };
					const handle = radius * 0.62;
					const p1 = { x: p0.x - Math.sin(angle) * handle, y: p0.y + Math.cos(angle) * handle };
					const p2 = { x: p3.x + Math.sin(next) * handle, y: p3.y - Math.cos(next) * handle };
					if (step === 0) nodes.push(p0);
					nodes.push(p1, p2, p3);
					if (step === points - 1) break;
				}
				Ink.chain(ctx, nodes, Ink.taper(w * (2.6 - loop * 0.5), 0.1, 0.1, 0.35 + random() * 0.3), 12);

				// A run of vertebrae down one flank of the loop.
				if (sigil.detail > 0.5) {
					const from = random() * Math.PI * 2;
					const span = Math.PI * (0.5 + random() * 0.8);
					const count = 4 + Math.floor(random() * 4);
					for (let index = 0; index < count; index++) {
						const angle = from + span * index / Math.max(1, count - 1);
						const r = radius * (1.02 + random() * 0.12);
						Ink.bead(ctx, ox + Math.cos(angle) * r, oy + Math.sin(angle) * r,
							w * (1.2 - index * 0.06), 1.2, angle);
					}
				}
			}
		}
	}
}
