import QtQuick

// Samples the colours around a region of an image file for the smart eraser.
// `sample(rect, done)` reads a few pixel rows just outside every side of
// `rect` (native pixels) and calls done(edges) with
//   { top, bottom, left, right }: arrays of [r, g, b] along each side.
// Each sample is the per-channel median of a slice of the band, so thin text
// or lines crossing the border don't streak into the fill; flat surroundings
// become exactly their colour.
// Requests are queued; the canvas is resized to the band around each one.
Canvas {
	id: root

	property string source: ""
	property real imageWidth: 0
	property real imageHeight: 0
	property var jobs: []
	property var job: null
	property string loaded: ""

	readonly property int band: 3
	readonly property int gap: 1
	readonly property int samples: 24

	width: 1
	height: 1

	function sample(rect, done) {
		root.jobs = root.jobs.concat([{ rect: Qt.rect(rect.x, rect.y, rect.width, rect.height), done: done }]);
		root.next();
	}

	function next() {
		if (root.job || root.jobs.length === 0) return;
		if (root.loaded !== root.source) {
			if (root.loaded !== "") root.unloadImage(root.loaded);
			root.loaded = root.source;
			root.loadImage(root.source);
		}
		const job = root.jobs[0];
		root.jobs = root.jobs.slice(1);
		const m = root.band + root.gap;
		const r = job.rect;
		const x = Math.max(0, Math.floor(r.x) - m);
		const y = Math.max(0, Math.floor(r.y) - m);
		const x2 = Math.min(root.imageWidth, Math.ceil(r.x + r.width) + m);
		const y2 = Math.min(root.imageHeight, Math.ceil(r.y + r.height) + m);
		job.region = { x: x, y: y, w: Math.max(1, x2 - x), h: Math.max(1, y2 - y) };
		root.job = job;
		root.width = job.region.w;
		root.height = job.region.h;
		root.requestPaint();
	}

	function median(values) {
		if (values.length === 0) return 0;
		const s = values.slice().sort((a, b) => a - b);
		return s[Math.floor(s.length / 2)];
	}

	// pixels of a band, one array of [r, g, b] per position along the side
	function bandPixels(pixel, x1, y1, x2, y2, vertical) {
		const out = [];
		if (x2 <= x1 || y2 <= y1) return out;
		const outer = vertical ? [y1, y2] : [x1, x2];
		const inner = vertical ? [x1, x2] : [y1, y2];
		for (let a = outer[0]; a < outer[1]; a += 1) {
			const px = [];
			for (let b = inner[0]; b < inner[1]; b += 1)
				px.push(vertical ? pixel(b, a) : pixel(a, b));
			out.push(px);
		}
		return out;
	}

	// median colours of `samples` slices along a side
	function profile(columns) {
		if (columns.length === 0) return null;
		const out = [];
		const n = Math.min(root.samples, columns.length);
		for (let i = 0; i < n; i += 1) {
			const from = Math.floor(i * columns.length / n);
			const to = Math.max(from + 1, Math.floor((i + 1) * columns.length / n));
			const px = [].concat(...columns.slice(from, to));
			out.push([0, 1, 2].map(c => root.median(px.map(p => p[c]))));
		}
		// a second pass over neighbours irons out slices that hit text
		return out.map((_, i) => [0, 1, 2].map(c => root.median(out.slice(Math.max(0, i - 1), i + 2).map(p => p[c]))));
	}

	function finish(sides) {
		const all = [];
		for (const key of ["top", "bottom", "left", "right"])
			if (sides[key]) for (const col of sides[key]) all.push(...col);
		if (all.length === 0) return null;
		const mid = [0, 1, 2].map(c => root.median(all.map(p => p[c])));
		const edges = {};
		for (const key of ["top", "bottom", "left", "right"])
			edges[key] = root.profile(sides[key] ?? []) ?? [mid];
		// flat surroundings (the usual UI background) give exactly that colour
		const flat = Object.values(edges).every(p => p.every(v => Math.abs(v[0] - mid[0]) <= 3 && Math.abs(v[1] - mid[1]) <= 3 && Math.abs(v[2] - mid[2]) <= 3));
		if (flat) for (const key of Object.keys(edges)) edges[key] = [mid];
		return edges;
	}

	onImageLoaded: if (root.job) root.requestPaint()

	onPaint: {
		const job = root.job;
		if (!job || root.source === "" || !root.isImageLoaded(root.source)) return;
		const g = job.region;
		// a request from inside onPaint would be dropped: ask again later
		if (Math.round(root.canvasSize.width) !== g.w || Math.round(root.canvasSize.height) !== g.h) {
			Qt.callLater(root.requestPaint);
			return;
		}
		const ctx = root.getContext("2d");
		ctx.clearRect(0, 0, g.w, g.h);
		ctx.drawImage(root.source, g.x, g.y, g.w, g.h, 0, 0, g.w, g.h);
		const data = ctx.getImageData(0, 0, g.w, g.h).data;
		// a HiDPI canvas may hand back k× the pixels
		const k = Math.max(1, Math.round(Math.sqrt(data.length / (4 * g.w * g.h))));
		const stride = g.w * k;
		const offset = (x, y) => (Math.floor(y * k) * stride + Math.floor(x * k)) * 4;
		const pixel = (x, y) => {
			const o = offset(x, y);
			return [data[o], data[o + 1], data[o + 2]];
		};
		const r = job.rect;
		// the rect inside the canvas, and how far the image reaches around it
		const rx1 = Math.floor(r.x) - g.x;
		const ry1 = Math.floor(r.y) - g.y;
		const rx2 = Math.ceil(r.x + r.width) - g.x;
		const ry2 = Math.ceil(r.y + r.height) - g.y;
		const alpha = (x, y) => data[offset(x, y) + 3];
		const has = (x, y) => x >= 0 && y >= 0 && x < g.w && y < g.h && alpha(x, y) > 0;
		const gap = root.gap;
		const band = root.band;
		const sides = {
			top: has(rx1, ry1 - gap - 1) ? root.bandPixels(pixel, Math.max(0, rx1), Math.max(0, ry1 - gap - band), Math.min(g.w, rx2), ry1 - gap, false) : null,
			bottom: has(rx1, ry2 + gap) ? root.bandPixels(pixel, Math.max(0, rx1), ry2 + gap, Math.min(g.w, rx2), Math.min(g.h, ry2 + gap + band), false) : null,
			left: has(rx1 - gap - 1, ry1) ? root.bandPixels(pixel, Math.max(0, rx1 - gap - band), Math.max(0, ry1), rx1 - gap, Math.min(g.h, ry2), true) : null,
			right: has(rx2 + gap, ry1) ? root.bandPixels(pixel, rx2 + gap, Math.max(0, ry1), Math.min(g.w, rx2 + gap + band), Math.min(g.h, ry2), true) : null
		};
		root.job = null;
		job.done(root.finish(sides));
		Qt.callLater(root.next);
	}

	Component.onDestruction: if (root.loaded !== "") root.unloadImage(root.loaded)
}
