.pragma library

// Where each pixel of an edited picture comes from. A picture's geometry is
//   { rot: quarter turns clockwise 0..3, flip: mirrored, angle: degrees
//     clockwise (straighten), vertical, horizontal: perspective -1..1,
//     quad: null | four corners TL TR BR BL (0..1 of the turned picture),
//     crop: { x, y, w, h } 0..1 of what turn, straighten and perspective
//     made }
// and one projective map takes the result's 0..1 to the source's 0..1 (the
// shader's `geo`). Matrices are arrays of nine, row by row.

function identity() {
	return [1, 0, 0, 0, 1, 0, 0, 0, 1];
}

function mul(a, b) {
	const out = new Array(9);
	for (let r = 0; r < 3; r += 1)
		for (let c = 0; c < 3; c += 1)
			out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
	return out;
}

function inverse(m) {
	const [a, b, c, d, e, f, g, h, i] = m;
	const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
	const det = a * A + b * B + c * C;
	if (Math.abs(det) < 1e-12) return identity();
	const k = 1 / det;
	return [A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
		B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
		C * k, -(a * h - b * g) * k, (a * e - b * d) * k];
}

function apply(m, x, y) {
	const w = m[6] * x + m[7] * y + m[8];
	return [(m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w];
}

function scale(sx, sy) {
	return [sx, 0, 0, 0, sy, 0, 0, 0, 1];
}

function translate(tx, ty) {
	return [1, 0, tx, 0, 1, ty, 0, 0, 1];
}

// the unit square onto four corners TL TR BR BL (Heckbert)
function squareToQuad(q) {
	const [x0, y0] = q[0], [x1, y1] = q[1], [x2, y2] = q[2], [x3, y3] = q[3];
	const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
	const dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
	if (Math.abs(dx3) < 1e-12 && Math.abs(dy3) < 1e-12)
		return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0, 1];
	const den = dx1 * dy2 - dx2 * dy1;
	const g = (dx3 * dy2 - dx2 * dy3) / den;
	const h = (dx1 * dy3 - dx3 * dy1) / den;
	return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1];
}

function defaults() {
	return { rot: 0, flip: false, angle: 0, vertical: 0, horizontal: 0, quad: null, crop: { x: 0, y: 0, w: 1, h: 1 } };
}

function normalised(g) {
	const d = defaults();
	if (!g) return d;
	return {
		rot: ((Number(g.rot) || 0) % 4 + 4) % 4, flip: !!g.flip, angle: Number(g.angle) || 0,
		vertical: Number(g.vertical) || 0, horizontal: Number(g.horizontal) || 0,
		quad: Array.isArray(g.quad) && g.quad.length === 4 ? g.quad.map(p => [Number(p[0]), Number(p[1])]) : null,
		crop: g.crop ? { x: Number(g.crop.x) || 0, y: Number(g.crop.y) || 0, w: Number(g.crop.w) || 1, h: Number(g.crop.h) || 1 } : d.crop
	};
}

function isIdentity(g) {
	g = normalised(g);
	return g.rot === 0 && !g.flip && Math.abs(g.angle) < 1e-4 && Math.abs(g.vertical) < 1e-4 && Math.abs(g.horizontal) < 1e-4
		&& !g.quad && g.crop.x < 1e-5 && g.crop.y < 1e-5 && g.crop.w > 1 - 1e-5 && g.crop.h > 1 - 1e-5;
}

// the turned picture's size
function turnedSize(g, w, h) {
	return g.rot % 2 === 1 ? [h, w] : [w, h];
}

// the size of what turn, straighten and perspective make, before the crop
function fullSize(g, w, h) {
	const [tw, th] = turnedSize(g, w, h);
	if (!g.quad) return [tw, th];
	const q = g.quad.map(p => [p[0] * tw, p[1] * th]);
	const len = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
	return [Math.max(1, (len(q[0], q[1]) + len(q[3], q[2])) / 2), Math.max(1, (len(q[0], q[3]) + len(q[1], q[2])) / 2)];
}

function outputSize(g, w, h) {
	g = normalised(g);
	const [fw, fh] = fullSize(g, w, h);
	return [Math.max(1, Math.round(fw * g.crop.w)), Math.max(1, Math.round(fh * g.crop.h))];
}

// turned 0..1 → source 0..1
function unturn(g) {
	// forward: rotate clockwise (x, y) → (1 - y, x), then mirror x → 1 - x
	let m = identity();
	if (g.flip) m = mul([-1, 0, 1, 0, 1, 0, 0, 0, 1], m);
	let turn = identity();
	for (let i = 0; i < g.rot; i += 1) turn = mul([0, 1, 0, -1, 0, 1, 0, 0, 1], turn);
	// a point of the turned picture: undo the mirror, then the turns
	return mul(turn, m);
}

// before the crop (0..1 of fullSize) → turned 0..1
function straighten(g, w, h) {
	if (g.quad) return squareToQuad(g.quad);
	const [tw, th] = turnedSize(g, w, h);
	const a = (g.angle || 0) * Math.PI / 180;
	// what is shown turned clockwise by a samples at R(-a)
	const cos = Math.cos(-a), sin = Math.sin(-a);
	let rot = mul(translate(0.5, 0.5), mul(scale(1 / tw, 1 / th), mul([cos, -sin, 0, sin, cos, 0, 0, 0, 1], mul(scale(tw, th), translate(-0.5, -0.5)))));
	const v = Math.max(-1, Math.min(1, g.vertical || 0)) * 0.3;
	const hz = Math.max(-1, Math.min(1, g.horizontal || 0)) * 0.3;
	if (Math.abs(v) < 1e-5 && Math.abs(hz) < 1e-5) return rot;
	const tl = [0, 0], tr = [1, 0], br = [1, 1], bl = [0, 1];
	if (v > 0) { tl[0] += v; tr[0] -= v; } else { bl[0] -= v; br[0] += v; }
	if (hz > 0) { tl[1] += hz; bl[1] -= hz; } else { tr[1] -= hz; br[1] += hz; }
	return mul(rot, squareToQuad([tl, tr, br, bl]));
}

function cropMatrix(c) {
	return [c.w, 0, c.x, 0, c.h, c.y, 0, 0, 1];
}

// the result's 0..1 → the source's 0..1
function matrix(g, w, h, withoutCrop) {
	g = normalised(g);
	const c = withoutCrop ? { x: 0, y: 0, w: 1, h: 1 } : g.crop;
	return mul(unturn(g), mul(straighten(g, w, h), cropMatrix(c)));
}

// before the crop 0..1 → inside the turned picture?
function covered(g, w, h, x, y) {
	const p = apply(straighten(g, w, h), x, y);
	return p[0] >= -1e-4 && p[0] <= 1 + 1e-4 && p[1] >= -1e-4 && p[1] <= 1 + 1e-4;
}

// the crop made smaller around its middle until no corner leaves the picture
function fitCrop(g, w, h) {
	g = normalised(g);
	const c = g.crop;
	const inside = s => {
		const cw = c.w * s, ch = c.h * s;
		const x = c.x + (c.w - cw) / 2, y = c.y + (c.h - ch) / 2;
		return covered(g, w, h, x, y) && covered(g, w, h, x + cw, y) && covered(g, w, h, x, y + ch) && covered(g, w, h, x + cw, y + ch);
	};
	if (inside(1)) return c;
	let lo = 0, hi = 1;
	for (let i = 0; i < 24; i += 1) {
		const mid = (lo + hi) / 2;
		if (inside(mid)) lo = mid;
		else hi = mid;
	}
	const cw = c.w * lo, ch = c.h * lo;
	return { x: c.x + (c.w - cw) / 2, y: c.y + (c.h - ch) / 2, w: cw, h: ch };
}

// the largest crop of a shape (width / height in pixels, 0 = as the picture)
// around the middle that the picture covers
function cropForAspect(g, w, h, aspect) {
	g = normalised(g);
	const [fw, fh] = fullSize(g, w, h);
	let cw = 1, ch = 1;
	if (aspect > 0) {
		if (fw / fh > aspect) cw = aspect * fh / fw;
		else ch = fw / aspect / fh;
	}
	const centre = [g.crop.x + g.crop.w / 2, g.crop.y + g.crop.h / 2];
	let x = Math.max(0, Math.min(1 - cw, centre[0] - cw / 2)), y = Math.max(0, Math.min(1 - ch, centre[1] - ch / 2));
	return fitCrop(Object.assign({}, g, { crop: { x: x, y: y, w: cw, h: ch } }), w, h);
}

// a point of the result in pixels from one geometry to another (what is
// drawn on the picture stays on the same spot of it)
function remapPoint(from, to, w, h, x, y) {
	const [fw, fh] = outputSize(from, w, h);
	const [tw, th] = outputSize(to, w, h);
	const src = apply(matrix(from, w, h), x / fw, y / fh);
	const back = apply(inverse(matrix(to, w, h)), src[0], src[1]);
	return [back[0] * tw, back[1] * th];
}

function remapItems(items, from, to, w, h) {
	if (!items || items.length === 0) return items;
	const map = (x, y) => remapPoint(from, to, w, h, x, y);
	return items.map(a => {
		const b = Object.assign({}, a);
		if (Array.isArray(a.points)) b.points = a.points.map(p => map(p[0], p[1]));
		if (a.x1 !== undefined) {
			const p1 = map(a.x1, a.y1), p2 = map(a.x2, a.y2);
			b.x1 = p1[0]; b.y1 = p1[1]; b.x2 = p2[0]; b.y2 = p2[1];
		}
		if (a.x !== undefined && a.y !== undefined) {
			const p = map(a.x, a.y);
			b.x = p[0]; b.y = p[1];
		}
		return b;
	});
}

// the shader's matrix4x4 arguments
function uniform(m) {
	return [m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0, 0, 0, 0, 1];
}
