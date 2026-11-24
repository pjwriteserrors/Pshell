import QtQuick
import qs.style.theme

// A wish's prices over time: a step line (a price holds until the next
// one), a soft area under it, the lowest and the highest as small marks,
// the price now as a dot at the right end, drawn up to today.
Canvas {
	id: root

	// [{ at (epoch s), price }]
	property var points: []
	property color color: Theme.primary
	property color low: Theme.success
	property color high: Theme.textSubtle

	implicitHeight: 44
	antialiasing: true
	renderStrategy: Canvas.Cooperative

	onPointsChanged: requestPaint()
	onColorChanged: requestPaint()
	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.reset();
		const pts = (root.points || []).map(p => ({ at: Number(p.at), price: Number(p.price) })).filter(p => isFinite(p.at) && isFinite(p.price));
		if (pts.length === 0)
			return;
		const pad = 5;
		const w = root.width - pad * 2;
		const h = root.height - pad * 2;
		const now = Math.max(Date.now() / 1000, pts[pts.length - 1].at);
		const t0 = pts[0].at;
		const span = Math.max(1, now - t0);
		const prices = pts.map(p => p.price);
		const lo = Math.min(...prices);
		const hi = Math.max(...prices);
		const range = hi - lo || Math.max(1, hi * 0.1);
		const x = at => pad + (at - t0) / span * w;
		const y = price => pad + h - (hi === lo ? 0.5 : (price - lo) / range) * h;

		// the steps, to today
		const line = [];
		for (let i = 0; i < pts.length; i += 1) {
			if (i > 0) line.push([x(pts[i].at), y(pts[i - 1].price)]);
			line.push([x(pts[i].at), y(pts[i].price)]);
		}
		line.push([x(now), y(pts[pts.length - 1].price)]);

		ctx.beginPath();
		ctx.moveTo(line[0][0], pad + h);
		for (const [px, py] of line) ctx.lineTo(px, py);
		ctx.lineTo(line[line.length - 1][0], pad + h);
		ctx.closePath();
		ctx.fillStyle = Qt.alpha(root.color, 0.12);
		ctx.fill();

		ctx.beginPath();
		ctx.moveTo(line[0][0], line[0][1]);
		for (const [px, py] of line) ctx.lineTo(px, py);
		ctx.lineWidth = 2;
		ctx.lineJoin = "round";
		ctx.strokeStyle = root.color;
		ctx.stroke();

		const mark = (px, py, r, color) => {
			ctx.beginPath();
			ctx.arc(px, py, r, 0, Math.PI * 2);
			ctx.fillStyle = color;
			ctx.fill();
		};
		if (hi !== lo) {
			const lowAt = pts.find(p => p.price === lo);
			const highAt = pts.find(p => p.price === hi);
			mark(x(highAt.at), y(hi), 3, root.high);
			mark(x(lowAt.at), y(lo), 3, root.low);
		}
		const last = line[line.length - 1];
		mark(last[0], last[1], 5, Qt.alpha(root.color, 0.3));
		mark(last[0], last[1], 3, root.color);
	}
}
