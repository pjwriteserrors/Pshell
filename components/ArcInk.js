.pragma library

// The burin this style is cut with.
//
// A line engraved into brass is not a stroke of colour: the graver cuts a V
// into the plate, and one wall of that V catches the light while the other
// stays in shadow. That two-tone groove is the only reason a flat canvas reads
// as metal rather than as a drawing of metal, so it is the primitive here and
// everything — dials, plates, graduations, runes, the chain the whole shell
// hangs from — is assembled out of it.
//
// Vellum is the other material, and it is never grooved. It is drawn with a
// torn deckle edge and a curl where it leaves the roller.

// ---------------------------------------------------------------- geometry

function polyline(ctx, points, close) {
	if (!points || points.length < 2) return;
	ctx.beginPath();
	ctx.moveTo(points[0].x, points[0].y);
	for (let index = 1; index < points.length; index++)
		ctx.lineTo(points[index].x, points[index].y);
	if (close) ctx.closePath();
}

// Sample an arc into points. Everything round in this style is a segment of a
// circle sampled finely enough that nobody counts the sides.
function arcPoints(cx, cy, radius, from, to, steps) {
	const count = Math.max(6, steps || Math.ceil(Math.abs(to - from) * 14));
	const points = [];
	for (let index = 0; index <= count; index++) {
		const angle = from + (to - from) * index / count;
		points.push({ x: cx + Math.cos(angle) * radius, y: cy + Math.sin(angle) * radius });
	}
	return points;
}

// The chain the shell hangs from: a parabola between two fixed ends.
function sagPoints(x0, x1, rise, sag, steps) {
	const count = steps || 48;
	const points = [];
	for (let index = 0; index <= count; index++) {
		const fraction = index / count;
		const t = fraction * 2 - 1;
		points.push({ x: x0 + (x1 - x0) * fraction, y: rise + sag * (1 - t * t) });
	}
	return points;
}

// ------------------------------------------------------------------ the cut

// The groove. Draw the line three times: the shadow wall pushed away from the
// light, the lit wall pushed towards it, and the body of the cut between them.
// `lightAngle` is where the candle is — up and to the left, always, because an
// instrument lit from two directions stops being an object.
function groove(ctx, points, width, body, lightColor, shadowColor, close) {
	if (!points || points.length < 2) return;
	const offset = Math.max(0.5, width * 0.42);
	const lx = -0.7071 * offset, ly = -0.7071 * offset;

	ctx.lineJoin = "round";
	ctx.lineCap = "round";

	if (shadowColor) {
		ctx.strokeStyle = shadowColor;
		ctx.lineWidth = width;
		ctx.save();
		ctx.translate(-lx, -ly);
		polyline(ctx, points, close);
		ctx.stroke();
		ctx.restore();
	}

	if (lightColor) {
		ctx.strokeStyle = lightColor;
		ctx.lineWidth = width * 0.8;
		ctx.save();
		ctx.translate(lx, ly);
		polyline(ctx, points, close);
		ctx.stroke();
		ctx.restore();
	}

	ctx.strokeStyle = body;
	ctx.lineWidth = width;
	polyline(ctx, points, close);
	ctx.stroke();
}

// A plain cut, for hairlines and anything too small for a groove to read.
function cut(ctx, points, width, color, close) {
	ctx.lineJoin = "round";
	ctx.lineCap = "round";
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	polyline(ctx, points, close);
	ctx.stroke();
}

// --------------------------------------------------------------- the fittings

// Graduations along an arc: the marks on an instrument's limb. Every `major`th
// one runs longer, which is what makes a dial readable rather than hatched.
function graduations(ctx, cx, cy, radius, from, to, count, minor, majorLength, major, width, color) {
	ctx.strokeStyle = color;
	ctx.lineCap = "butt";
	for (let index = 0; index <= count; index++) {
		const angle = from + (to - from) * index / count;
		const long = major > 0 && index % major === 0;
		const length = long ? majorLength : minor;
		ctx.lineWidth = long ? width * 1.5 : width;
		ctx.beginPath();
		ctx.moveTo(cx + Math.cos(angle) * radius, cy + Math.sin(angle) * radius);
		ctx.lineTo(cx + Math.cos(angle) * (radius - length), cy + Math.sin(angle) * (radius - length));
		ctx.stroke();
	}
}

// A rivet: the brass pin that holds one plate onto another. Two arcs, one lit
// and one shadowed, which is the whole trick for anything round and metal.
function rivet(ctx, x, y, radius, body, lightColor, shadowColor) {
	ctx.beginPath();
	ctx.ellipse(x - radius, y - radius, radius * 2, radius * 2);
	ctx.fillStyle = body;
	ctx.fill();
	ctx.lineWidth = Math.max(0.6, radius * 0.34);
	ctx.strokeStyle = shadowColor;
	ctx.beginPath();
	ctx.arc(x, y, radius * 0.82, -Math.PI * 0.25, Math.PI * 0.75);
	ctx.stroke();
	ctx.strokeStyle = lightColor;
	ctx.beginPath();
	ctx.arc(x, y, radius * 0.82, Math.PI * 0.75, Math.PI * 1.75);
	ctx.stroke();
}

// Guilloche: the engine-turned rosette on an instrument's face. A single sine
// riding a circle, which from any normal distance is indistinguishable from the
// real lathe pattern and costs one pass.
function guilloche(ctx, cx, cy, radius, lobes, depth, turns, width, color) {
	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineJoin = "round";
	for (let turn = 0; turn < turns; turn++) {
		const base = radius * (1 - turn * 0.17);
		const phase = turn * Math.PI / lobes;
		ctx.beginPath();
		for (let step = 0; step <= 180; step++) {
			const angle = step / 180 * Math.PI * 2;
			const r = base + Math.sin(angle * lobes + phase) * depth;
			const x = cx + Math.cos(angle) * r, y = cy + Math.sin(angle) * r;
			if (step === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
		}
		ctx.closePath();
		ctx.stroke();
	}
}

// ------------------------------------------------------------------- the runes

// A rune is cut, not written: straight strokes on a lattice, at right angles
// and half angles only. Grown from a seed, so the same thing is always given
// the same mark and two different things never share one.
function rune(ctx, cx, cy, size, seed, width, color) {
	let state = (Math.abs(seed) % 2147483647) + 1;
	const random = function () {
		state = (state * 48271) % 2147483647;
		return (state - 1) / 2147483646;
	};

	const half = size / 2;
	// A stave down the middle is what makes a mark read as a rune rather than
	// as a scribble; everything else hangs off it.
	const strokes = [[{ x: cx, y: cy - half }, { x: cx, y: cy + half }]];
	const arms = 2 + Math.floor(random() * 3);
	for (let index = 0; index < arms; index++) {
		const side = random() < 0.5 ? -1 : 1;
		const at = cy - half + size * (0.15 + random() * 0.7);
		const run = half * (0.45 + random() * 0.55);
		const drop = random() < 0.55 ? run * (random() < 0.5 ? -1 : 1) : 0;
		strokes.push([{ x: cx, y: at }, { x: cx + side * run, y: at + drop }]);
		if (random() < 0.3)
			strokes.push([{ x: cx + side * run, y: at + drop },
				{ x: cx + side * run, y: at + drop + run * 0.7 }]);
	}

	ctx.strokeStyle = color;
	ctx.lineWidth = width;
	ctx.lineCap = "round";
	for (const stroke of strokes) {
		ctx.beginPath();
		ctx.moveTo(stroke[0].x, stroke[0].y);
		ctx.lineTo(stroke[1].x, stroke[1].y);
		ctx.stroke();
	}
}

// ------------------------------------------------------------------ the vellum

// The deckle: a sheet's torn edge. Deterministic from a seed so a page does not
// re-tear itself every time it is repainted.
function deckle(ctx, x0, y0, x1, y1, amplitude, seed) {
	let state = (Math.abs(seed || 1) % 2147483647) + 1;
	const random = function () {
		state = (state * 48271) % 2147483647;
		return (state - 1) / 2147483646;
	};
	const length = Math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
	const steps = Math.max(4, Math.round(length / 7));
	const nx = -(y1 - y0) / (length || 1), ny = (x1 - x0) / (length || 1);
	const points = [];
	for (let index = 0; index <= steps; index++) {
		const t = index / steps;
		const wobble = (random() - 0.5) * 2 * amplitude * (index === 0 || index === steps ? 0 : 1);
		points.push({ x: x0 + (x1 - x0) * t + nx * wobble, y: y0 + (y1 - y0) * t + ny * wobble });
	}
	return points;
}

// The curl at the leading edge of a sheet coming off its roller: a band that
// darkens into the turn and catches the light just before it.
function curl(ctx, x, y, width, depth, sheet, shade, lightColor) {
	const band = ctx.createLinearGradient(0, y - depth, 0, y + depth * 0.3);
	band.addColorStop(0.0, sheet);
	band.addColorStop(0.55, lightColor);
	band.addColorStop(0.82, shade);
	band.addColorStop(1.0, sheet);
	ctx.fillStyle = band;
	ctx.fillRect(x, y - depth, width, depth * 1.3);
}
