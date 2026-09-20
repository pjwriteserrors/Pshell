.pragma library

// What the sanctum is drawn with.
//
// Nothing here draws a border, a bevel or a box. There are four marks in this
// style and everything is made of them:
//
//   the ring    a circle that can be drawn part-way round, so it can inscribe
//               itself rather than appear
//   the rune    an angular mark cut on a stave, grown from a seed so a thing
//               always keeps its own mark
//   the ley     a hairline with a light somewhere on it, which is how two
//               things are shown to be connected and how a heading is finished
//   the mote    a point of light, which is what everything here comes apart
//               into and what it condenses out of
//
// Glass is not drawn at all. It is a fill with light caught on its upper edge,
// and that edge is the only line a pane ever gets.

// ---------------------------------------------------------------- geometry

function polyline(ctx, points, close) {
	if (!points || points.length < 2) return;
	ctx.beginPath();
	ctx.moveTo(points[0].x, points[0].y);
	for (let index = 1; index < points.length; index++)
		ctx.lineTo(points[index].x, points[index].y);
	if (close) ctx.closePath();
}

function arcPoints(cx, cy, radius, from, to, steps) {
	const count = Math.max(6, steps || Math.ceil(Math.abs(to - from) * 16));
	const points = [];
	for (let index = 0; index <= count; index++) {
		const angle = from + (to - from) * index / count;
		points.push({ x: cx + Math.cos(angle) * radius, y: cy + Math.sin(angle) * radius });
	}
	return points;
}

// ------------------------------------------------------------------ the ring

// An arc. `through` is how much of it has been inscribed, 0..1, so a ring can
// be drawn by a hand instead of switched on.
function ring(ctx, cx, cy, radius, width, color, through, from) {
	const span = Math.max(0, Math.min(1, through === undefined ? 1 : through));
	if (span <= 0.001 || radius <= 0.5) return;
	const start = from === undefined ? -Math.PI / 2 : from;
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	ctx.beginPath();
	ctx.arc(cx, cy, radius, start, start + Math.PI * 2 * span);
	ctx.stroke();
}

// Graduations round a limb: the marks that make a circle read as an instrument
// and not as a shape. Every `major`th one runs long.
function graduations(ctx, cx, cy, radius, count, minor, majorLength, major, width, color, through) {
	const span = Math.max(0, Math.min(1, through === undefined ? 1 : through));
	ctx.strokeStyle = color;
	ctx.lineCap = "butt";
	for (let index = 0; index < count; index++) {
		if (index / count > span) break;
		const angle = -Math.PI / 2 + Math.PI * 2 * index / count;
		const long = major > 0 && index % major === 0;
		const length = long ? majorLength : minor;
		ctx.lineWidth = long ? width * 1.6 : width;
		ctx.beginPath();
		ctx.moveTo(cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius);
		ctx.lineTo(cx + Math.cos(angle) * (radius - length), cy + Math.sin(angle) * (radius - length));
		ctx.stroke();
	}
}

// A plain cut: a polyline in one colour. The workhorse for a drawn glyph.
function cut(ctx, points, width, color, close) {
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	ctx.lineJoin = "round";
	polyline(ctx, points, close);
	ctx.stroke();
}

// ------------------------------------------------------------------ the rune

// A rune is cut, not written: a stave with branches struck off it at right
// angles and half angles. Deterministic from `seed`, so the same thing always
// keeps the same mark and two things never share one.
function rune(ctx, cx, cy, size, seed, width, color) {
	let state = (Math.abs(Math.round(seed)) % 2147483647) + 1;
	const random = function () {
		state = (state * 48271) % 2147483647;
		return (state - 1) / 2147483646;
	};

	const half = size / 2;
	const strokes = [[{ x: cx, y: cy - half }, { x: cx, y: cy + half }]];
	const arms = 2 + Math.floor(random() * 3);
	for (let index = 0; index < arms; index++) {
		const side = random() < 0.5 ? -1 : 1;
		const at = cy - half + size * (0.12 + random() * 0.74);
		const run = half * (0.42 + random() * 0.58);
		const drop = random() < 0.6 ? run * (random() < 0.5 ? -1 : 1) : 0;
		strokes.push([{ x: cx, y: at }, { x: cx + side * run, y: at + drop }]);
		if (random() < 0.34)
			strokes.push([{ x: cx + side * run, y: at + drop },
				{ x: cx + side * run, y: at + drop + run * 0.8 }]);
	}

	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	ctx.lineJoin = "round";
	for (const stroke of strokes) {
		ctx.beginPath();
		ctx.moveTo(stroke[0].x, stroke[0].y);
		ctx.lineTo(stroke[1].x, stroke[1].y);
		ctx.stroke();
	}
}

// Runes set round a circle, upright rather than radial, because a ring of
// rotated marks reads as a pattern and a ring of upright ones reads as writing.
// `lit` is how many of them are alight, counted from the twelve.
function runeRing(ctx, cx, cy, radius, count, seed, size, width, dim, litColor, lit) {
	const alight = lit === undefined ? -1 : lit;
	for (let index = 0; index < count; index++) {
		const angle = -Math.PI / 2 + Math.PI * 2 * index / count;
		rune(ctx, cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius,
			size, seed + index * 7, width,
			alight >= 0 && index < alight ? litColor : dim);
	}
}

// ------------------------------------------------------------------- the ley

// A hairline with a light riding it. `at` places the light along the line;
// leave it out and the line is dark.
function ley(ctx, x0, y0, x1, y1, width, color, lightColor, at) {
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	ctx.beginPath();
	ctx.moveTo(x0, y0);
	ctx.lineTo(x1, y1);
	ctx.stroke();
	if (at === undefined || at < 0 || !lightColor) return;
	const t = Math.max(0, Math.min(1, at));
	mote(ctx, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, width * 2.0, lightColor);
}

// A run of ley line between two points, bowed, with nodes on it. This is what
// connects two things in the realm map.
function leyCurve(ctx, x0, y0, x1, y1, bow, width, color) {
	const mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
	const nx = -(y1 - y0), ny = x1 - x0;
	const length = Math.sqrt(nx * nx + ny * ny) || 1;
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.beginPath();
	ctx.moveTo(x0, y0);
	ctx.quadraticCurveTo(mx + nx / length * bow, my + ny / length * bow, x1, y1);
	ctx.stroke();
}

// ------------------------------------------------------------------ the mote

function mote(ctx, x, y, radius, color) {
	ctx.fillStyle = color;
	ctx.beginPath();
	ctx.ellipse(x - radius, y - radius, radius * 2, radius * 2);
	ctx.fill();
}

// A scatter of motes on a ring, used where something is coming apart or coming
// together. `spread` pushes them off the ring as the conjuring progresses.
function moteRing(ctx, cx, cy, radius, count, seed, spread, radiusOf, color) {
	let state = (Math.abs(Math.round(seed)) % 2147483647) + 1;
	const random = function () {
		state = (state * 48271) % 2147483647;
		return (state - 1) / 2147483646;
	};
	for (let index = 0; index < count; index++) {
		const angle = random() * Math.PI * 2;
		const off = radius + (random() - 0.35) * spread;
		mote(ctx, cx + Math.cos(angle) * off, cy + Math.sin(angle) * off,
			radiusOf * (0.4 + random() * 0.8), color);
	}
}

// ----------------------------------------------------------------- the glass

// The only line a pane gets: light caught along its upper edge, brightest in
// the middle and running out at both ends. Anything more is a border.
function paneEdge(ctx, x, y, width, color, transparent, strength) {
	const light = ctx.createLinearGradient(x, y, x + width, y);
	light.addColorStop(0.0, transparent);
	light.addColorStop(0.26, color);
	light.addColorStop(0.5, color);
	light.addColorStop(0.74, color);
	light.addColorStop(1.0, transparent);
	ctx.save();
	ctx.globalAlpha = strength === undefined ? 1 : strength;
	ctx.fillStyle = light;
	ctx.fillRect(x, y, width, 1.2);
	ctx.restore();
}

// The corner marks a conjuring leaves on a pane: two short strokes that do not
// meet. They are not a frame — there is nothing along the edges between them.
function corners(ctx, x, y, w, h, reach, width, color) {
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	for (const c of [
		{ x: x, y: y, dx: 1, dy: 1 }, { x: x + w, y: y, dx: -1, dy: 1 },
		{ x: x + w, y: y + h, dx: -1, dy: -1 }, { x: x, y: y + h, dx: 1, dy: -1 }
	]) {
		ctx.beginPath();
		ctx.moveTo(c.x + c.dx * reach, c.y);
		ctx.lineTo(c.x, c.y);
		ctx.lineTo(c.x, c.y + c.dy * reach);
		ctx.stroke();
	}
}
