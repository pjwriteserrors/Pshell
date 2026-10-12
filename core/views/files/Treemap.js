.pragma library

// Squarified treemap: rectangles for sizes that stay close to squares,
// biggest first (Bruls, Huizing, van Wijk). Each item is { size, … };
// returns the items with x, y, w, h inside the box.

function worst(row, side, total, area) {
	if (row.length === 0) return Infinity;
	let min = Infinity;
	let max = 0;
	let sum = 0;
	for (const item of row) {
		const a = item.size / total * area;
		sum += a;
		if (a < min) min = a;
		if (a > max) max = a;
	}
	const s2 = sum * sum;
	const side2 = side * side;
	return Math.max(side2 * max / s2, s2 / (side2 * min));
}

function layout(items, x, y, w, h) {
	const list = items.filter(item => item.size > 0).sort((a, b) => b.size - a.size);
	const total = list.reduce((sum, item) => sum + item.size, 0);
	const out = [];
	if (total <= 0 || w <= 0 || h <= 0) return out;
	let box = { x: x, y: y, w: w, h: h };
	let rest = list.slice();
	let remaining = total;
	while (rest.length > 0) {
		const side = Math.min(box.w, box.h);
		const area = box.w * box.h;
		const row = [];
		while (rest.length > 0) {
			const next = row.concat([rest[0]]);
			if (row.length > 0 && worst(next, side, remaining, area) > worst(row, side, remaining, area)) break;
			row.push(rest.shift());
		}
		const rowSize = row.reduce((sum, item) => sum + item.size, 0);
		const share = rowSize / remaining;
		if (box.w >= box.h) {
			const rowW = box.w * share;
			let cy = box.y;
			for (const item of row) {
				const ih = box.h * item.size / rowSize;
				out.push(Object.assign({}, item, { x: box.x, y: cy, w: rowW, h: ih }));
				cy += ih;
			}
			box = { x: box.x + rowW, y: box.y, w: box.w - rowW, h: box.h };
		} else {
			const rowH = box.h * share;
			let cx = box.x;
			for (const item of row) {
				const iw = box.w * item.size / rowSize;
				out.push(Object.assign({}, item, { x: cx, y: box.y, w: iw, h: rowH }));
				cx += iw;
			}
			box = { x: box.x, y: box.y + rowH, w: box.w, h: box.h - rowH };
		}
		remaining -= rowSize;
	}
	return out;
}
