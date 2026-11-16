// Time charts drawn by hand in SVG (no library): lines or a stacked area,
// recessive grid, dashed limits, a legend for two or more series, and a
// crosshair with a tooltip under the pointer or the arrow keys.
import { h } from "./util.js";
import { reduced } from "./motion.js";

const NS = "http://www.w3.org/2000/svg";
const svgEl = (tag, attrs = {}) => {
	const el = document.createElementNS(NS, tag);
	for (const [k, v] of Object.entries(attrs)) {
		if (v === undefined || v === null) continue;
		// colours as style: var() and color-mix() do not work in attributes
		if ((k === "stroke" || k === "fill" || k === "stop-color") && /var\(|color-mix/.test(v)) el.style.setProperty(k, v);
		else el.setAttribute(k, v);
	}
	return el;
};

// 3–5 round steps between lo and hi
function ticks(lo, hi, count = 4) {
	if (hi <= lo) hi = lo + 1;
	const raw = (hi - lo) / count;
	const mag = 10 ** Math.floor(Math.log10(raw));
	const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => s >= raw) || raw;
	const out = [];
	for (let v = Math.floor(lo / step) * step; v <= hi + step * 0.001; v += step) out.push(+v.toFixed(10));
	return out;
}

const hourFmt = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit" });
const dayFmt = new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric" });
const fullFmt = new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

// points: [{t: ms, v: {key: number|null}}]; series: [{key, label, tone}]
export function timeChart({ series, points = [], format = v => String(Math.round(v)), axisFormat, min, max, thresholds = [], stacked = false, height = 180, empty = "No samples yet" }) {
	const legend = series.length > 1 ? h("div.chart-legend", series.map(s => h("span.legend-item", h("i", { style: { background: s.tone } }), s.label))) : null;
	const tip = h("div.chart-tip", { role: "status", hidden: true });
	const box = h("div.chart-box", { tabindex: 0, role: "img" });
	const wrap = h("div.chart", legend, box, tip);
	let svg = null;
	let geom = null;
	let index = -1;

	const label = () => {
		const last = points[points.length - 1];
		if (!last) return empty;
		return `${series.map(s => `${s.label} ${last.v[s.key] === null || last.v[s.key] === undefined ? "–" : format(last.v[s.key])}`).join(", ")} now`;
	};

	function draw() {
		const width = Math.round(box.clientWidth);
		if (!width) return;
		box.textContent = "";
		box.setAttribute("aria-label", label());
		if (points.length < 2) {
			box.appendChild(h("div.chart-empty", { style: { height: `${height}px` } }, empty));
			geom = null;
			return;
		}
		const pad = { l: 44, r: 10, t: 10, b: 22 };
		const W = width;
		const H = height;
		const t0 = points[0].t;
		const t1 = points[points.length - 1].t;
		// the values per point (stacked: running sums)
		const rows = points.map(p => {
			let acc = 0;
			return series.map(s => {
				const v = p.v[s.key];
				if (v === null || v === undefined || Number.isNaN(v)) return stacked ? acc : null;
				if (stacked) {
					acc += v;
					return acc;
				}
				return v;
			});
		});
		const all = rows.flat().filter(v => v !== null);
		thresholds.forEach(th => all.push(th.value));
		let lo = min ?? Math.min(...all);
		let hi = max ?? Math.max(...all);
		if (min === undefined) lo -= (hi - lo) * 0.08;
		if (max === undefined) hi += (hi - lo) * 0.08 || 1;
		const yt = ticks(lo, hi);
		lo = min ?? Math.min(lo, yt[0]);
		hi = max ?? Math.max(hi, yt[yt.length - 1]);
		const x = t => pad.l + ((t - t0) / Math.max(1, t1 - t0)) * (W - pad.l - pad.r);
		const y = v => pad.t + (1 - (v - lo) / (hi - lo || 1)) * (H - pad.t - pad.b);
		svg = svgEl("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, class: "chart-svg" });

		// grid and y labels
		const grid = svgEl("g", { class: "chart-axes" });
		for (const v of yt) {
			if (v < lo - 1e-9 || v > hi + 1e-9) continue;
			grid.appendChild(svgEl("line", { x1: pad.l, x2: W - pad.r, y1: y(v), y2: y(v) }));
			const text = svgEl("text", { x: pad.l - 8, y: y(v) + 3.5, "text-anchor": "end" });
			text.textContent = (axisFormat || format)(v);
			grid.appendChild(text);
		}
		// x labels: hours over a day, days over a week
		const span = t1 - t0;
		const dayLong = span > 36 * 3600e3;
		const step = dayLong ? 24 * 3600e3 : span > 12 * 3600e3 ? 4 * 3600e3 : span > 3 * 3600e3 ? 3600e3 : 15 * 60e3;
		const startAt = new Date(t0);
		if (dayLong) startAt.setHours(24, 0, 0, 0);
		else startAt.setTime(Math.ceil(t0 / step) * step);
		let lastX = -100;
		for (let t = startAt.getTime(); t <= t1; t += step) {
			const px = x(t);
			if (px - lastX < 56 || px > W - pad.r - 16) continue;
			lastX = px;
			grid.appendChild(svgEl("line", { class: "chart-xtick", x1: px, x2: px, y1: H - pad.b, y2: H - pad.b + 4 }));
			const text = svgEl("text", { x: px, y: H - 6, "text-anchor": "middle" });
			text.textContent = dayLong ? dayFmt.format(t) : hourFmt.format(t);
			grid.appendChild(text);
		}
		svg.appendChild(grid);

		// a gap of more than three usual steps breaks the line
		const steps = points.slice(1).map((p, i) => p.t - points[i].t).sort((a, b) => a - b);
		const usual = steps[Math.floor(steps.length / 2)] || 60e3;
		const broken = i => i > 0 && points[i].t - points[i - 1].t > usual * 3.5;

		const paths = [];
		series.forEach((s, k) => {
			let d = "";
			let area = "";
			let open = false;
			let segStart = 0;
			const base = i => (stacked && k > 0 ? rows[i][k - 1] : lo);
			const closeArea = (from, to) => {
				if (!stacked && series.length > 1) return;
				let back = "";
				for (let j = to; j >= from; j -= 1) back += `L${x(points[j].t).toFixed(1)} ${y(stacked && k > 0 ? rows[j][k - 1] : Math.max(lo, 0 > lo ? 0 : lo)).toFixed(1)}`;
				area += `${back}Z`;
			};
			rows.forEach((row, i) => {
				const v = row[k];
				if (v === null || broken(i)) {
					if (open) closeArea(segStart, i - 1);
					open = false;
					if (v === null) return;
				}
				const px = x(points[i].t).toFixed(1);
				const py = y(v).toFixed(1);
				if (!open) {
					d += `M${px} ${py}`;
					area += `M${px} ${py}`;
					segStart = i;
					open = true;
				} else {
					d += `L${px} ${py}`;
					area += `L${px} ${py}`;
				}
				void base;
			});
			if (open) closeArea(segStart, rows.length - 1);
			paths.push({ s, d, area });
		});
		// stacked: draw the top band first so lower ones stay visible
		const order = stacked ? [...paths].reverse() : paths;
		const id = `g${Math.random().toString(36).slice(2, 8)}`;
		order.forEach(({ s, d, area }, n) => {
			if (stacked || series.length === 1) {
				if (!stacked) {
					const grad = svgEl("linearGradient", { id: `${id}${n}`, x1: 0, y1: 0, x2: 0, y2: 1 });
					grad.append(svgEl("stop", { offset: 0, "stop-color": s.tone, "stop-opacity": 0.28 }), svgEl("stop", { offset: 1, "stop-color": s.tone, "stop-opacity": 0 }));
					svg.appendChild(svgEl("defs")).appendChild(grad);
				}
				svg.appendChild(svgEl("path", { d: area, class: "chart-area", fill: stacked ? s.tone : `url(#${id}${n})`, "fill-opacity": stacked ? 0.55 : 1 }));
			}
			const line = svgEl("path", { d, class: "chart-line", stroke: s.tone });
			svg.appendChild(line);
			if (!reduced() && !wrap.dataset.drawn) {
				const length = line.getTotalLength?.() || 0;
				if (length) line.animate([{ strokeDasharray: `${length}`, strokeDashoffset: length }, { strokeDasharray: `${length}`, strokeDashoffset: 0 }], { duration: 900, easing: "cubic-bezier(0.33, 1, 0.68, 1)" });
			}
		});
		wrap.dataset.drawn = "1";

		// limits, dashed, labelled at the right
		for (const th of thresholds) {
			if (th.value < lo || th.value > hi) continue;
			svg.appendChild(svgEl("line", { class: "chart-limit", x1: pad.l, x2: W - pad.r, y1: y(th.value), y2: y(th.value), stroke: th.tone }));
			const text = svgEl("text", { class: "chart-limit-label", x: W - pad.r - 2, y: y(th.value) - 4, "text-anchor": "end" });
			text.textContent = th.label;
			svg.appendChild(text);
		}

		const cross = svgEl("line", { class: "chart-cross", y1: pad.t, y2: H - pad.b, x1: 0, x2: 0, visibility: "hidden" });
		const dots = series.map(s => svgEl("circle", { class: "chart-dot", r: 4, cx: 0, cy: 0, fill: s.tone, visibility: "hidden" }));
		svg.append(cross, ...dots);
		box.appendChild(svg);
		geom = { x, y, rows, cross, dots, W, pad };
		if (index >= 0) show(index);
	}

	function show(i) {
		if (!geom || !points[i]) return;
		index = i;
		const p = points[i];
		const px = geom.x(p.t);
		geom.cross.setAttribute("x1", px);
		geom.cross.setAttribute("x2", px);
		geom.cross.setAttribute("visibility", "visible");
		series.forEach((s, k) => {
			const v = geom.rows[i][k];
			const has = p.v[s.key] !== null && p.v[s.key] !== undefined;
			geom.dots[k].setAttribute("visibility", has ? "visible" : "hidden");
			if (has) {
				geom.dots[k].setAttribute("cx", px);
				geom.dots[k].setAttribute("cy", geom.y(v));
			}
		});
		tip.replaceChildren(h("div.tip-time", fullFmt.format(p.t)), ...series.map(s => h("div.tip-row", h("i", { style: { background: s.tone } }), h("span", s.label), h("strong", p.v[s.key] === null || p.v[s.key] === undefined ? "–" : format(p.v[s.key])))));
		tip.hidden = false;
		const tw = tip.offsetWidth;
		const left = px + 14 + tw > geom.W ? px - 14 - tw : px + 14;
		tip.style.transform = `translate(${Math.max(0, left)}px, ${(legend?.offsetHeight || 0) + 6}px)`;
	}

	function hide() {
		index = -1;
		tip.hidden = true;
		if (!geom) return;
		geom.cross.setAttribute("visibility", "hidden");
		geom.dots.forEach(d => d.setAttribute("visibility", "hidden"));
	}

	const nearest = clientX => {
		const rect = box.getBoundingClientRect();
		const px = clientX - rect.left;
		let best = 0;
		let bestD = Infinity;
		points.forEach((p, i) => {
			const d = Math.abs(geom.x(p.t) - px);
			if (d < bestD) {
				bestD = d;
				best = i;
			}
		});
		return best;
	};
	box.addEventListener("pointermove", event => geom && show(nearest(event.clientX)));
	box.addEventListener("pointerleave", hide);
	box.addEventListener("blur", hide);
	box.addEventListener("keydown", event => {
		if (!geom) return;
		const stepN = event.shiftKey ? 10 : 1;
		if (event.key === "ArrowLeft") show(Math.max(0, (index < 0 ? points.length : index) - stepN));
		else if (event.key === "ArrowRight") show(Math.min(points.length - 1, (index < 0 ? points.length - 2 : index) + stepN));
		else if (event.key === "Home") show(0);
		else if (event.key === "End") show(points.length - 1);
		else if (event.key === "Escape") hide();
		else return;
		event.preventDefault();
	});

	let frame = 0;
	const ro = new ResizeObserver(() => {
		cancelAnimationFrame(frame);
		frame = requestAnimationFrame(draw);
	});
	ro.observe(box);
	wrap.update = next => {
		points = next;
		draw();
	};
	wrap.destroy = () => ro.disconnect();
	return wrap;
}
