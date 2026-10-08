.pragma library

// Layout maths of the display setup editor. Outputs are
// { name, x, y, width, height, modeWidth, modeHeight, scale, transform, off }
// in niri's logical pixels; width/height already account for rotation.

const ANGLES = ["normal", "90", "180", "270"];

function shown(outputs) {
	const on = (outputs || []).filter(output => !output.off);
	return on.length > 0 ? on : (outputs || []);
}

function bounds(outputs) {
	const list = shown(outputs);
	if (list.length === 0) return { x: 0, y: 0, width: 1920, height: 1080 };
	const left = Math.min(...list.map(o => o.x));
	const top = Math.min(...list.map(o => o.y));
	const right = Math.max(...list.map(o => o.x + o.width));
	const bottom = Math.max(...list.map(o => o.y + o.height));
	return { x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
}

// screen pixels per logical pixel so `box` fits into width × height
function fit(box, width, height) {
	if (width <= 0 || height <= 0) return 0;
	return Math.min(width / box.width, height / box.height);
}

// niri (wayland) counts transforms counter-clockwise; clockwise = +1
function rotate(transform, clockwise) {
	const value = String(transform || "normal");
	const flipped = value.startsWith("flipped");
	const angle = flipped ? (value === "flipped" ? "normal" : value.slice(8)) : value;
	const index = (ANGLES.indexOf(angle) + (clockwise ? 3 : 1)) % 4;
	const next = ANGLES[Math.max(0, index)];
	if (!flipped) return next;
	return next === "normal" ? "flipped" : `flipped-${next}`;
}

function quarterTurned(transform) {
	return /(90|270)$/.test(String(transform || ""));
}

// the output with width/height recomputed for its transform and scale, the
// way niri lays it out: scales are 120ths, a part of a pixel counts as one
function sized(output) {
	const scale = Math.round((Number(output.scale) || 1) * 120) / 120;
	let width = output.modeWidth || output.width;
	let height = output.modeHeight || output.height;
	if (quarterTurned(output.transform)) [width, height] = [height, width];
	return Object.assign({}, output, { width: Math.ceil(width / scale), height: Math.ceil(height / scale) });
}

function overlaps(a, b) {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

// pushes the rect out of any monitor it overlaps, the shortest way
function separate(rect, others) {
	let result = Object.assign({}, rect);
	for (let round = 0; round < 8; round += 1) {
		const other = others.find(o => overlaps(result, o));
		if (!other) break;
		const moves = [
			{ x: other.x - result.width, y: result.y },
			{ x: other.x + other.width, y: result.y },
			{ x: result.x, y: other.y - result.height },
			{ x: result.x, y: other.y + other.height }
		];
		moves.sort((a, b) => (Math.abs(a.x - result.x) + Math.abs(a.y - result.y)) - (Math.abs(b.x - result.x) + Math.abs(b.y - result.y)));
		result = Object.assign(result, moves[0]);
	}
	return result;
}

// how far two rects are apart, 0 when they touch
function distance(a, b) {
	return Math.max(0, a.x - b.x - b.width, b.x - a.x - a.width) + Math.max(0, a.y - b.y - b.height, b.y - a.y - a.height);
}

// the names of what stands right of the rect (or below it, `down`), next to
// it or next to something that does; a pixel into it still counts, older
// arrangements were rounded down
function behind(rect, others, down) {
	const pos = down ? "y" : "x", size = down ? "height" : "width";
	const side = down ? "x" : "y", span = down ? "width" : "height";
	const chain = [rect];
	for (let grown = true; grown;) {
		grown = false;
		for (const o of others) {
			if (chain.includes(o)) continue;
			if (!chain.some(m => o[pos] >= m[pos] + m[size] - 1 && o[side] < m[side] + m[span] && m[side] < o[side] + o[span])) continue;
			chain.push(o);
			grown = true;
		}
	}
	return chain.slice(1).map(o => o.name);
}

// the outputs with `name` replaced by `next`, which has another size at the
// same corner: what stands right of it or below moves along, and nothing
// ends up overlapping
function resized(outputs, name, next) {
	const old = outputs.find(o => o.name === name);
	if (!old || old.off || next.off) return outputs.map(o => o.name === name ? next : o);
	const others = outputs.filter(o => o.name !== name && !o.off);
	const right = behind(old, others, false);
	const below = behind(old, others, true);
	const moved = others.map(o => Object.assign({}, o, {
		x: o.x + (right.includes(o.name) ? next.width - old.width : 0),
		y: o.y + (below.includes(o.name) ? next.height - old.height : 0)
	})).sort((a, b) => distance(a, next) - distance(b, next));
	const settled = [next];
	for (const o of moved) settled.push(separate(o, settled));
	return outputs.map(o => settled.find(placed => placed.name === o.name) || o);
}

// shifts everything so the arrangement starts at 0,0
function normalized(outputs) {
	const box = bounds(outputs);
	return outputs.map(output => output.off
		? Object.assign({}, output)
		: Object.assign({}, output, { x: Math.round(output.x - box.x), y: Math.round(output.y - box.y) }));
}

function signature(outputs) {
	return JSON.stringify(normalized(outputs || [])
		.map(o => [o.name, o.off ? "off" : `${o.x},${o.y}`, o.transform, Number(o.scale) || 1, o.mode || ""])
		.sort());
}
