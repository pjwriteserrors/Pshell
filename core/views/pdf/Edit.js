.pragma library

// What the PDF editor's overlays and panels share: fonts that look like the
// standard ones the helper writes, page-space geometry, the pen's smoothing
// and how words are chosen by a drag.

// the 14 standard fonts as the machine has them (URW's, metric twins)
function family(font) {
	const f = String(font || "Helvetica");
	if (/times|roman|serif/i.test(f)) return "Nimbus Roman";
	if (/courier|mono/i.test(f)) return "Nimbus Mono PS";
	return "Nimbus Sans";
}

function clamp(v, a, b) {
	return Math.max(a, Math.min(b, v));
}

function copy(value) {
	return JSON.parse(JSON.stringify(value));
}

// a rectangle from two corners; `square` keeps the sides equal (Shift)
function rectOf(a, b, square) {
	let w = b[0] - a[0], h = b[1] - a[1];
	if (square) {
		const s = Math.max(Math.abs(w), Math.abs(h));
		w = Math.sign(w || 1) * s;
		h = Math.sign(h || 1) * s;
	}
	return [Math.min(a[0], a[0] + w), Math.min(a[1], a[1] + h), Math.abs(w), Math.abs(h)];
}

// a line's end held to 45° steps (Shift)
function snapAngle(a, b) {
	const dx = b[0] - a[0], dy = b[1] - a[1];
	const len = Math.hypot(dx, dy);
	const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
	return [a[0] + Math.cos(angle) * len, a[1] + Math.sin(angle) * len];
}

function inside(r, p, pad) {
	const m = pad || 0;
	return p[0] >= r[0] - m && p[0] <= r[0] + r[2] + m && p[1] >= r[1] - m && p[1] <= r[1] + r[3] + m;
}

function overlaps(a, b) {
	return a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];
}

function distToSegment(p, a, b) {
	const dx = b[0] - a[0], dy = b[1] - a[1];
	const len2 = dx * dx + dy * dy;
	let t = len2 > 0 ? ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2 : 0;
	t = clamp(t, 0, 1);
	return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

// does a pointer at p (radius r) touch this stroke
function touchesStroke(stroke, p, r) {
	if (stroke.length === 1) return Math.hypot(stroke[0][0] - p[0], stroke[0][1] - p[1]) <= r;
	for (let i = 1; i < stroke.length; i += 1)
		if (distToSegment(p, stroke[i - 1], stroke[i]) <= r) return true;
	return false;
}

// Ramer–Douglas–Peucker: the pen's line with the points it does not need gone
function simplify(points, epsilon) {
	if (points.length < 3) return points;
	let index = 0, best = 0;
	const last = points.length - 1;
	for (let i = 1; i < last; i += 1) {
		const d = distToSegment(points[i], points[0], points[last]);
		if (d > best) {
			best = d;
			index = i;
		}
	}
	if (best <= epsilon) return [points[0], points[last]];
	const left = simplify(points.slice(0, index + 1), epsilon);
	const right = simplify(points.slice(index), epsilon);
	return left.slice(0, -1).concat(right);
}

// a few points of a Catmull-Rom curve between each two, for a smooth line from few points
function smooth(points) {
	if (points.length < 3) return points;
	const out = [points[0]];
	for (let i = 0; i < points.length - 1; i += 1) {
		const p0 = points[Math.max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[Math.min(points.length - 1, i + 2)];
		const steps = Math.min(6, Math.max(1, Math.round(Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) / 3)));
		for (let s = 1; s <= steps; s += 1) {
			const t = s / steps, t2 = t * t, t3 = t2 * t;
			out.push([
				0.5 * (2 * p1[0] + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3),
				0.5 * (2 * p1[1] + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
			]);
		}
	}
	return out.map(p => [Math.round(p[0] * 100) / 100, Math.round(p[1] * 100) / 100]);
}

function round(v) {
	return Math.round(v * 100) / 100;
}

function roundRect(r) {
	return r.map(round);
}

// the word nearest a point: its index
function nearestWord(words, p) {
	let best = -1, dist = 1e9;
	for (let i = 0; i < words.length; i += 1) {
		const w = words[i];
		const dx = Math.max(w.x - p[0], 0, p[0] - (w.x + w.w));
		const dy = Math.max(w.y - p[1], 0, p[1] - (w.y + w.h));
		const d = dx + dy * 2.2;
		if (d < dist) {
			dist = d;
			best = i;
		}
	}
	return { index: best, dist: dist };
}

// the words from where a drag started to where it is, in reading order, as
// one box per line: { quads, text }; null when there is no text near
function flowSelect(words, a, b) {
	if (!words || words.length === 0) return null;
	const first = nearestWord(words, a), lastW = nearestWord(words, b);
	if (first.index < 0 || first.dist > 40 && lastW.dist > 40) return null;
	const i0 = Math.min(first.index, lastW.index), i1 = Math.max(first.index, lastW.index);
	const quads = [];
	const parts = [];
	let line = null;
	for (let i = i0; i <= i1; i += 1) {
		const w = words[i];
		parts.push(w.t);
		if (line && Math.abs((w.y + w.h / 2) - (line[1] + line[3] / 2)) < Math.max(w.h, line[3]) * 0.5 && w.x >= line[0] - 2) {
			const x1 = Math.max(line[0] + line[2], w.x + w.w), y0 = Math.min(line[1], w.y), y1 = Math.max(line[1] + line[3], w.y + w.h);
			line = [line[0], y0, x1 - line[0], y1 - y0];
		} else {
			if (line) quads.push(roundRect(line));
			line = [w.x, w.y, w.w, w.h];
		}
	}
	if (line) quads.push(roundRect(line));
	return { quads: quads, text: parts.join(" ") };
}

// the words a box covers (for blacking out a drawn box's text, finding a line to correct)
function wordsIn(words, r) {
	return (words || []).filter(w => overlaps(r, [w.x, w.y, w.w, w.h]));
}

// a dragged box held to page edges, its middle and other items' edges; returns { dx, dy, guides }
function snapMove(box, dx, dy, page, others, tolerance) {
	// page: the part of the page shown [x, y, w, h]
	const xs = [page[0], page[0] + page[2] / 2, page[0] + page[2]], ys = [page[1], page[1] + page[3] / 2, page[1] + page[3]];
	for (const o of others) {
		xs.push(o[0], o[0] + o[2] / 2, o[0] + o[2]);
		ys.push(o[1], o[1] + o[3] / 2, o[1] + o[3]);
	}
	const guides = [];
	let bestX = null, bestY = null;
	const edgesX = [box[0] + dx, box[0] + dx + box[2] / 2, box[0] + dx + box[2]];
	const edgesY = [box[1] + dy, box[1] + dy + box[3] / 2, box[1] + dy + box[3]];
	for (const e of edgesX) for (const x of xs) {
		const d = x - e;
		if (Math.abs(d) <= tolerance && (bestX === null || Math.abs(d) < Math.abs(bestX.d))) bestX = { d: d, at: x };
	}
	for (const e of edgesY) for (const y of ys) {
		const d = y - e;
		if (Math.abs(d) <= tolerance && (bestY === null || Math.abs(d) < Math.abs(bestY.d))) bestY = { d: d, at: y };
	}
	if (bestX) guides.push({ vertical: true, at: bestX.at });
	if (bestY) guides.push({ vertical: false, at: bestY.at });
	return { dx: dx + (bestX ? bestX.d : 0), dy: dy + (bestY ? bestY.d : 0), guides: guides };
}

// a box resized by one of its handles ("tl" "t" "tr" "r" "br" "b" "bl" "l") by dx, dy; `keep` the shape
function resize(r, handle, dx, dy, keep) {
	let x0 = r[0], y0 = r[1], x1 = r[0] + r[2], y1 = r[1] + r[3];
	if (handle.includes("l")) x0 += dx;
	if (handle.includes("r")) x1 += dx;
	if (handle.includes("t")) y0 += dy;
	if (handle.includes("b")) y1 += dy;
	if (keep && r[2] > 0 && r[3] > 0 && handle.length === 2) {
		const aspect = r[2] / r[3];
		const w = Math.abs(x1 - x0), h = Math.abs(y1 - y0);
		if (w / aspect > h) {
			const nh = w / aspect;
			if (handle.includes("t")) y0 = y1 - nh;
			else y1 = y0 + nh;
		} else {
			const nw = h * aspect;
			if (handle.includes("l")) x0 = x1 - nw;
			else x1 = x0 + nw;
		}
	}
	const out = [Math.min(x0, x1), Math.min(y0, y1), Math.max(4, Math.abs(x1 - x0)), Math.max(4, Math.abs(y1 - y0))];
	return roundRect(out);
}

// an item's points scaled from one box to another (ink, lines, marks resized)
function refit(item, from, to) {
	const sx = from[2] > 0 ? to[2] / from[2] : 1, sy = from[3] > 0 ? to[3] / from[3] : 1;
	const map = p => [round(to[0] + (p[0] - from[0]) * sx), round(to[1] + (p[1] - from[1]) * sy)];
	const out = copy(item);
	if (out.rect) out.rect = roundRect(to);
	if (out.points) out.points = out.points.map(map);
	if (out.strokes) out.strokes = out.strokes.map(s => s.map(map));
	if (out.quads) out.quads = out.quads.map(q => {
		const a = map([q[0], q[1]]), b = map([q[0] + q[2], q[1] + q[3]]);
		return [a[0], a[1], round(b[0] - a[0]), round(b[1] - a[1])];
	});
	if (out.cover) {
		const a = map([out.cover[0], out.cover[1]]), b = map([out.cover[0] + out.cover[2], out.cover[1] + out.cover[3]]);
		out.cover = [a[0], a[1], round(b[0] - a[0]), round(b[1] - a[1])];
	}
	return out;
}

// kinds drawn as a box that can be resized by its corners
const boxed = ["rect", "ellipse", "textbox", "stamp", "link", "field", "text", "whiteout", "image", "signature", "redact"];

function isBoxed(item) {
	return !!item && (boxed.includes(item.kind) && !!item.rect);
}

// what a kind is called (lists, the history)
function nameOf(item) {
	const names = { highlight: "Marked", underline: "Underlined", strike: "Struck out", squiggly: "Wavy line", ink: "Drawing", rect: "Box",
		ellipse: "Circle", line: "Line", arrow: "Arrow", note: "Note", textbox: "Text box", stamp: "Stamp", link: "Link", field: "Field",
		text: "Corrected text", whiteout: "Covered", image: "Picture", signature: "Signature", redact: "Blacked out" };
	return names[item?.kind] || "Mark";
}

function iconOf(item) {
	const icons = { highlight: "marker", underline: "format_underline", strike: "format_strikethrough_variant", squiggly: "wave", ink: "draw",
		rect: "rectangle_outline", ellipse: "circle_outline", line: "vector_line", arrow: "arrow_top_right", note: "note_text_outline",
		textbox: "form_textbox", stamp: "stamper", link: "link_variant", field: "form_textbox", text: "format_text", whiteout: "eraser",
		image: "image_outline", signature: "draw_pen", redact: "eye_off_outline" };
	return icons[item?.kind] || "shape_outline";
}

// a date as stamps write it
function today() {
	const d = new Date();
	const pad = n => (n < 10 ? "0" : "") + n;
	return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()}`;
}
