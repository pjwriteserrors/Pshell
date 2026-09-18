.pragma library

// The pen this style is drawn with.
//
// A stroke of constant width reads as a border; the reference art is bone, and
// bone swells at the joint and runs out to a point. So nothing here is stroked:
// every line is a filled ribbon built by sampling a curve, walking its normal
// out by a width that changes along its length, and closing the two sides into
// one polygon. Everything else — frames, rings, tendons, sigils — is assembled
// out of ribbons and beads.

function point(p0, p1, p2, p3, t) {
	const u = 1 - t;
	const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
	return {
		x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
		y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
	};
}

function tangent(p0, p1, p2, p3, t) {
	const u = 1 - t;
	const x = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x);
	const y = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y);
	const length = Math.sqrt(x * x + y * y) || 1;
	return { x: x / length, y: y / length };
}

// A width profile along a ribbon: thin ends, a belly wherever `peak` sits.
// `head` and `tail` are the widths the ribbon starts and finishes at, as a
// fraction of `width` — 0 makes a point, 1 makes a blunt end.
function taper(width, head, tail, peak) {
	return function (t) {
		const belly = Math.sin(Math.pow(t, Math.log(0.5) / Math.log(peak)) * Math.PI);
		const ends = head * (1 - t) + tail * t;
		return width * Math.max(ends, belly * 0.5 + ends * 0.5);
	};
}

// One cubic segment as a filled ribbon. `widthAt` is called with t in 0..1.
function ribbon(ctx, p0, p1, p2, p3, widthAt, samples) {
	const count = samples || 26;
	const left = [], right = [];
	for (let index = 0; index <= count; index++) {
		const t = index / count;
		const at = point(p0, p1, p2, p3, t);
		const dir = tangent(p0, p1, p2, p3, t);
		const half = Math.max(0.16, widthAt(t) / 2);
		left.push({ x: at.x - dir.y * half, y: at.y + dir.x * half });
		right.push({ x: at.x + dir.y * half, y: at.y - dir.x * half });
	}
	ctx.beginPath();
	ctx.moveTo(left[0].x, left[0].y);
	for (let index = 1; index < left.length; index++) ctx.lineTo(left[index].x, left[index].y);
	for (let index = right.length - 1; index >= 0; index--) ctx.lineTo(right[index].x, right[index].y);
	ctx.closePath();
	ctx.fill();
}

// A chain of cubic segments drawn as one continuous ribbon, so the width runs
// across the joins instead of restarting at every corner.
function chain(ctx, nodes, widthAt, samples) {
	const perSegment = samples || 22;
	const left = [], right = [];
	for (let segment = 0; segment + 3 < nodes.length; segment += 3) {
		const p0 = nodes[segment], p1 = nodes[segment + 1];
		const p2 = nodes[segment + 2], p3 = nodes[segment + 3];
		const segments = (nodes.length - 1) / 3;
		for (let index = 0; index <= perSegment; index++) {
			const local = index / perSegment;
			const t = (segment / 3 + local) / segments;
			const at = point(p0, p1, p2, p3, local);
			const dir = tangent(p0, p1, p2, p3, local);
			const half = Math.max(0.16, widthAt(t) / 2);
			left.push({ x: at.x - dir.y * half, y: at.y + dir.x * half });
			right.push({ x: at.x + dir.y * half, y: at.y - dir.x * half });
		}
	}
	if (left.length === 0) return;
	ctx.beginPath();
	ctx.moveTo(left[0].x, left[0].y);
	for (let index = 1; index < left.length; index++) ctx.lineTo(left[index].x, left[index].y);
	for (let index = right.length - 1; index >= 0; index--) ctx.lineTo(right[index].x, right[index].y);
	ctx.closePath();
	ctx.fill();
}

// A vertebra. Slightly oval and rotated along the bone it sits on, because a
// row of perfect circles reads as a dotted border and not as a spine.
function bead(ctx, x, y, radius, stretch, angle) {
	const rx = radius, ry = radius * (stretch === undefined ? 1.35 : stretch);
	ctx.save();
	ctx.translate(x, y);
	ctx.rotate(angle || 0);
	ctx.beginPath();
	ctx.ellipse(-rx, -ry, rx * 2, ry * 2);
	ctx.fill();
	ctx.restore();
}

// A run of vertebrae along a cubic, shrinking towards the far end. This is the
// motif that carries the whole style: a joint is never a corner, it is a place
// where the bone breaks into beads.
function beadRun(ctx, p0, p1, p2, p3, count, radius, decay, offset) {
	for (let index = 0; index < count; index++) {
		const t = count === 1 ? 0.5 : (index + (offset || 0)) / Math.max(1, count - 1 + (offset || 0) * 2);
		const clamped = Math.min(1, Math.max(0, t));
		const at = point(p0, p1, p2, p3, clamped);
		const dir = tangent(p0, p1, p2, p3, clamped);
		const size = radius * Math.pow(decay === undefined ? 0.82 : decay, index);
		bead(ctx, at.x, at.y, size, 1.3, Math.atan2(dir.y, dir.x));
	}
}

// A hooked spur: the claw that finishes a corner or the tip of a tendon.
function spur(ctx, x, y, dx, dy, length, width) {
	ribbon(ctx,
		{ x: x, y: y },
		{ x: x + dx * length * 0.45, y: y + dy * length * 0.1 },
		{ x: x + dx * length * 0.82, y: y + dy * length * 0.55 },
		{ x: x + dx * length, y: y + dy * length },
		taper(width, 0.9, 0.0, 0.35), 18);
}
