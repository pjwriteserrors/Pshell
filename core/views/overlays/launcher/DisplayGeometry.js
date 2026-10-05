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

// the output with width/height recomputed for its transform and scale
function sized(output) {
	const scale = Number(output.scale) || 1;
	let width = output.modeWidth || output.width;
	let height = output.modeHeight || output.height;
	if (quarterTurned(output.transform)) [width, height] = [height, width];
	return Object.assign({}, output, { width: Math.round(width / scale), height: Math.round(height / scale) });
}

function overlaps(a, b) {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

// pulls the rect's edges onto nearby edges of the others (within `reach`)
function snap(rect, others, reach) {
	let bestX = null;
	let bestY = null;
	for (const other of others) {
		const xs = [other.x + other.width, other.x - rect.width, other.x, other.x + other.width - rect.width];
		const ys = [other.y + other.height, other.y - rect.height, other.y, other.y + other.height - rect.height];
		for (const x of xs)
			if (Math.abs(x - rect.x) <= reach && (bestX === null || Math.abs(x - rect.x) < Math.abs(bestX - rect.x))) bestX = x;
		for (const y of ys)
			if (Math.abs(y - rect.y) <= reach && (bestY === null || Math.abs(y - rect.y) < Math.abs(bestY - rect.y))) bestY = y;
	}
	return Object.assign({}, rect, { x: bestX === null ? rect.x : bestX, y: bestY === null ? rect.y : bestY });
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
