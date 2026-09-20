pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// The instrument's own marks: the few glyphs that mean something specific in
// this shell and have no icon anywhere on the system. Drawn rather than
// fetched, so they are cut in the same hand as everything around them.
//
//   book    the grimoire — what the launcher opens
//   star    a fixed star — an empty page, a thing with no reading yet
//   raven   the messenger — a notification, and the toast it carries
//   eye     the oracle — the weather, and anything being watched
//   phial   a measure — an empty rack, a reading that has not been taken
Item {
	id: mark

	property string glyph: "star"
	property color lineColor: Arc.gilt
	property real weight: Arc.rule

	implicitWidth: 28
	implicitHeight: 28

	onGlyphChanged: canvas.requestPaint()
	onLineColorChanged: canvas.requestPaint()
	onWeightChanged: canvas.requestPaint()

	Canvas {
		id: canvas
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const s = Math.min(width, height);
			if (s < 6) return;
			const cx = width / 2, cy = height / 2;
			const w = mark.weight;
			const c = mark.lineColor;

			if (mark.glyph === "book") {
				// An open book seen from above: the gutter down the middle, the
				// two leaves falling away from it, and the page block under
				// each.
				const half = s * 0.40, drop = s * 0.30;
				for (const side of [-1, 1]) {
					Ink.cut(ctx, [
						{ x: cx, y: cy - drop * 0.72 },
						{ x: cx + side * half * 0.55, y: cy - drop * 0.95 },
						{ x: cx + side * half, y: cy - drop * 0.62 },
						{ x: cx + side * half, y: cy + drop * 0.72 },
						{ x: cx + side * half * 0.55, y: cy + drop * 0.36 },
						{ x: cx, y: cy + drop * 0.62 }
					], w, c, false);
					// two lines of writing on each leaf
					for (const line of [0.18, 0.46]) {
						Ink.cut(ctx, [
							{ x: cx + side * half * 0.22, y: cy - drop * 0.30 + drop * line },
							{ x: cx + side * half * 0.78, y: cy - drop * 0.40 + drop * line }
						], w * 0.6, Qt.alpha(c, 0.55), false);
					}
				}
				Ink.cut(ctx, [{ x: cx, y: cy - drop * 0.72 }, { x: cx, y: cy + drop * 0.62 }], w, c, false);
				return;
			}

			if (mark.glyph === "star") {
				// A six-pointed fixed star: three strokes through one centre,
				// the vertical longest.
				const r = s * 0.42;
				for (const angle of [-Math.PI / 2, -Math.PI / 6, Math.PI / 6]) {
					const reach = angle === -Math.PI / 2 ? r : r * 0.74;
					Ink.cut(ctx, [
						{ x: cx - Math.cos(angle) * reach, y: cy - Math.sin(angle) * reach },
						{ x: cx + Math.cos(angle) * reach, y: cy + Math.sin(angle) * reach }
					], w, c, false);
				}
				ctx.fillStyle = c;
				ctx.beginPath();
				ctx.ellipse(cx - w, cy - w, w * 2, w * 2);
				ctx.fill();
				return;
			}

			if (mark.glyph === "raven") {
				// A bird in silhouette: a body with its head turned, a tail,
				// and two wings swept back. Deliberately not a species — a
				// shape at the edge of vision is all a messenger ever is.
				const u = s * 0.5;
				ctx.fillStyle = c;

				// body and tail
				ctx.beginPath();
				ctx.moveTo(cx - u * 0.18, cy - u * 0.30);
				ctx.quadraticCurveTo(cx + u * 0.22, cy - u * 0.20, cx + u * 0.26, cy + u * 0.24);
				ctx.lineTo(cx + u * 0.74, cy + u * 0.80);
				ctx.lineTo(cx + u * 0.30, cy + u * 0.66);
				ctx.quadraticCurveTo(cx - u * 0.26, cy + u * 0.46, cx - u * 0.30, cy - u * 0.10);
				ctx.closePath();
				ctx.fill();

				// head and beak
				ctx.beginPath();
				ctx.ellipse(cx - u * 0.46, cy - u * 0.62, u * 0.40, u * 0.36);
				ctx.fill();
				ctx.beginPath();
				ctx.moveTo(cx - u * 0.46, cy - u * 0.50);
				ctx.lineTo(cx - u * 0.96, cy - u * 0.36);
				ctx.lineTo(cx - u * 0.44, cy - u * 0.28);
				ctx.closePath();
				ctx.fill();

				// the two wings, the far one shorter
				ctx.beginPath();
				ctx.moveTo(cx - u * 0.14, cy - u * 0.22);
				ctx.quadraticCurveTo(cx + u * 0.10, cy - u * 0.96, cx + u * 0.86, cy - u * 0.84);
				ctx.quadraticCurveTo(cx + u * 0.40, cy - u * 0.36, cx + u * 0.12, cy + u * 0.06);
				ctx.closePath();
				ctx.fill();

				ctx.beginPath();
				ctx.moveTo(cx - u * 0.18, cy - u * 0.10);
				ctx.quadraticCurveTo(cx - u * 0.02, cy - u * 0.70, cx + u * 0.52, cy - u * 0.62);
				ctx.quadraticCurveTo(cx + u * 0.18, cy - u * 0.24, cx + u * 0.02, cy + u * 0.10);
				ctx.closePath();
				ctx.fill();
				return;
			}

			if (mark.glyph === "eye") {
				const half = s * 0.44, lid = s * 0.24;
				Ink.cut(ctx, [
					{ x: cx - half, y: cy },
					{ x: cx - half * 0.5, y: cy - lid },
					{ x: cx + half * 0.5, y: cy - lid },
					{ x: cx + half, y: cy }
				], w, c, false);
				Ink.cut(ctx, [
					{ x: cx - half, y: cy },
					{ x: cx - half * 0.5, y: cy + lid },
					{ x: cx + half * 0.5, y: cy + lid },
					{ x: cx + half, y: cy }
				], w, c, false);
				Ink.cut(ctx, Ink.arcPoints(cx, cy, lid * 0.62, 0, Math.PI * 2, 16), w, c, true);
				ctx.fillStyle = c;
				ctx.beginPath();
				ctx.ellipse(cx - w * 1.2, cy - w * 1.2, w * 2.4, w * 2.4);
				ctx.fill();
				return;
			}

			// phial
			const neck = s * 0.13, body = s * 0.30, top = cy - s * 0.40;
			Ink.cut(ctx, [
				{ x: cx - neck, y: top },
				{ x: cx - neck, y: top + s * 0.22 },
				{ x: cx - body, y: top + s * 0.44 },
				{ x: cx - body, y: cy + s * 0.32 },
				{ x: cx - body * 0.6, y: cy + s * 0.42 },
				{ x: cx + body * 0.6, y: cy + s * 0.42 },
				{ x: cx + body, y: cy + s * 0.32 },
				{ x: cx + body, y: top + s * 0.44 },
				{ x: cx + neck, y: top + s * 0.22 },
				{ x: cx + neck, y: top }
			], w, c, false);
			Ink.cut(ctx, [{ x: cx - neck * 1.5, y: top }, { x: cx + neck * 1.5, y: top }], w * 1.2, c, false);
		}
	}
}
