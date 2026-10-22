.pragma library

// Where the window switcher puts its cards. Every layout is a function of
// the windows, the picked one and the room it has, and gives every card a
// place – so changing the pick or the layout is the same card moving to a
// new place, never a new picture.
//
//   cards  [{ x, y, w, h, z, rotation, yaw, scale, opacity, row }]
//   groups [{ x, y, w, h, label }]   frames drawn behind (workspaces)
//   hero   { x, y, w, h } | null     the picked window big (list)

const GAP = 22;

function aspect(item) {
	const a = Number(item.width) / Math.max(1, Number(item.height));
	return Math.max(0.45, Math.min(2.4, a || 1.6));
}

function card(x, y, w, h, extra) {
	return Object.assign({ x, y, w, h, z: 1, rotation: 0, yaw: 0, scale: 1, opacity: 1, row: false }, extra || {});
}

function fit(a, maxW, maxH) {
	let w = maxW;
	let h = w / a;
	if (h > maxH) {
		h = maxH;
		w = h * a;
	}
	return { w, h };
}

function strip(items, index, W, H, size) {
	let h = Math.min(H * 0.26, 300) * size;
	const widths = () => items.map(item => h * aspect(item));
	let total = widths().reduce((s, w) => s + w, 0) + GAP * (items.length - 1);
	const room = W * 0.92;
	if (total > room) {
		h *= Math.max(0.55, room / total);
		total = widths().reduce((s, w) => s + w, 0) + GAP * (items.length - 1);
	}
	const ws = widths();
	let offset = (W - total) / 2;
	if (total > room) {
		// too many: the strip slides so the picked one stays in the middle
		let before = 0;
		for (let i = 0; i < index; i++) before += ws[i] + GAP;
		const centre = before + ws[index] / 2;
		offset = Math.max(W - W * 0.04 - total, Math.min(W * 0.04, W / 2 - centre));
	}
	const y = (H - h) / 2;
	let x = offset;
	return { cards: items.map((item, i) => {
		const c = card(x, y, ws[i], h, { z: i === index ? 50 : 1 });
		x += ws[i] + GAP;
		return c;
	}), groups: [], hero: null };
}

function grid(items, index, W, H, size) {
	const n = items.length;
	const ratio = 1.6;
	const maxCell = 420 * size;
	let best = null;
	// widest cells win; of equal ones the squarer arrangement (more columns)
	for (let cols = n; cols >= 1; cols--) {
		const rows = Math.ceil(n / cols);
		let cw = Math.min(maxCell, (W * 0.86 - GAP * (cols - 1)) / cols);
		let ch = cw / ratio;
		const tall = H * 0.78;
		if (rows * ch + GAP * (rows - 1) > tall) {
			ch = (tall - GAP * (rows - 1)) / rows;
			cw = ch * ratio;
		}
		if (!best || cw > best.cw + 0.5) best = { cols, rows, cw, ch };
	}
	const { cols, rows, cw, ch } = best;
	const top = (H - (rows * ch + GAP * (rows - 1))) / 2;
	return { cards: items.map((item, i) => {
		const row = Math.floor(i / cols);
		const inRow = row === rows - 1 ? n - row * cols : cols;
		const left = (W - (inRow * cw + GAP * (inRow - 1))) / 2;
		const col = i - row * cols;
		const f = fit(aspect(item), cw, ch);
		return card(left + col * (cw + GAP) + (cw - f.w) / 2, top + row * (ch + GAP) + (ch - f.h) / 2, f.w, f.h, { z: i === index ? 50 : 1 });
	}), groups: [], hero: null, columns: cols };
}

function carousel(items, index, W, H, size) {
	const front = Math.min(W * 0.4, H * 0.55 * 1.6) * size;
	const base = front / 1.6;
	return { cards: items.map((item, i) => {
		const d = i - index;
		const a = Math.abs(d);
		const w = Math.min(base * aspect(item), front * 1.3);
		const h = w / aspect(item);
		const side = Math.sign(d);
		const shift = a === 0 ? 0 : side * (front * 0.5 + base * 0.35 + (a - 1) * front * 0.2);
		return card(W / 2 + shift - w / 2, H / 2 - h / 2, w, h, {
			z: 100 - a,
			yaw: a === 0 ? 0 : -side * 52,
			scale: a === 0 ? 1 : 0.74 * Math.pow(0.9, a - 1),
			opacity: a > 5 ? 0 : 1 - Math.max(0, a - 1) * 0.14
		});
	}), groups: [], hero: null };
}

function fan(items, index, W, H, size) {
	const n = items.length;
	const h = Math.min(H * 0.3, 320) * size;
	const spread = Math.min(70, 10 * (n - 1));
	const step = n > 1 ? spread / (n - 1) : 0;
	const R = H * 0.8;
	return { cards: items.map((item, i) => {
		const w = Math.min(h * aspect(item), h * 1.8);
		const theta = (-spread / 2 + i * step) * Math.PI / 180;
		const lift = i === index ? h * 0.22 : 0;
		const cx = W / 2 + (R + lift) * Math.sin(theta);
		const cy = H / 2 - h * 0.05 + R - (R + lift) * Math.cos(theta);
		return card(cx - w / 2, cy - h / 2, w, h, {
			z: i === index ? 1000 : i,
			rotation: theta * 180 / Math.PI,
			scale: i === index ? 1.1 : 0.94
		});
	}), groups: [], hero: null };
}

function list(items, index, W, H, size) {
	const rowW = Math.min(420, W * 0.3);
	const rowH = 58;
	const gap = 6;
	const sel = items[index] || items[0];
	const hero = fit(aspect(sel), Math.min(W * 0.52, 1100 * size), H * 0.66 * Math.min(1.2, size));
	const total = rowW + 44 + hero.w;
	const left = (W - total) / 2;
	const listH = items.length * (rowH + gap) - gap;
	let top = (H - listH) / 2;
	if (listH > H * 0.86) {
		const centre = index * (rowH + gap) + rowH / 2;
		top = Math.max(H * 0.93 - listH, Math.min(H * 0.07, H / 2 - centre));
	}
	return {
		cards: items.map((item, i) => card(left, top + i * (rowH + gap), rowW, rowH, { row: true, z: i === index ? 50 : 1 })),
		groups: [],
		hero: { x: left + rowW + 44, y: (H - hero.h) / 2, w: hero.w, h: hero.h }
	};
}

function workspaces(items, index, W, H, size, order) {
	// workspaces left to right like the screens, then by number
	const byWs = {};
	const keys = [];
	items.forEach((item, i) => {
		if (!byWs[item.workspaceId]) {
			byWs[item.workspaceId] = { item, members: [] };
			keys.push(item.workspaceId);
		}
		byWs[item.workspaceId].members.push(i);
	});
	keys.sort((a, b) => {
		const A = byWs[a].item, B = byWs[b].item;
		const oa = order(A.output), ob = order(B.output);
		return oa !== ob ? oa - ob : A.workspaceIdx - B.workspaceIdx;
	});
	const pad = 14;
	const head = 30;
	const gap = 14;
	const place = ch => {
		const groups = keys.map(key => {
			const g = byWs[key];
			const widths = g.members.map(i => Math.min(ch * aspect(items[i]), ch * 2));
			return { key, g, widths, w: widths.reduce((s, w) => s + w, 0) + gap * (widths.length - 1) + pad * 2, h: ch + pad * 2 + head };
		});
		const rows = [];
		let row = null;
		for (const group of groups) {
			if (!row || row.w + GAP + group.w > W * 0.92) {
				row = { groups: [], w: -GAP, h: 0 };
				rows.push(row);
			}
			row.groups.push(group);
			row.w += GAP + group.w;
			row.h = Math.max(row.h, group.h);
		}
		return { rows, height: rows.reduce((s, r) => s + r.h, 0) + GAP * (rows.length - 1) };
	};
	let ch = Math.min(170, H * 0.18) * size;
	let laid = place(ch);
	while (laid.height > H * 0.88 && ch > 60) {
		ch *= 0.9;
		laid = place(ch);
	}
	const cards = new Array(items.length);
	const groups = [];
	let y = (H - laid.height) / 2;
	for (const row of laid.rows) {
		let x = (W - row.w) / 2;
		for (const group of row.groups) {
			const first = group.g.item;
			groups.push({ x, y, w: group.w, h: group.h, label: `${first.output} · ${first.workspaceName || first.workspaceIdx}`, active: first.workspaceActive });
			let cx = x + pad;
			group.g.members.forEach((i, k) => {
				const w = group.widths[k];
				const h = Math.min(ch, w / aspect(items[i]));
				cards[i] = card(cx, y + head + pad + (ch - h) / 2, w, h, { z: i === index ? 50 : 1 });
				cx += w + gap;
			});
			x += group.w + GAP;
		}
		y += row.h + GAP;
	}
	return { cards, groups, hero: null };
}

function compute(name, items, index, W, H, size, order) {
	if (items.length === 0 || W <= 0 || H <= 0) return { cards: [], groups: [], hero: null };
	switch (name) {
	case "grid": return grid(items, index, W, H, size);
	case "carousel": return carousel(items, index, W, H, size);
	case "fan": return fan(items, index, W, H, size);
	case "list": return list(items, index, W, H, size);
	case "workspaces": return workspaces(items, index, W, H, size, order);
	default: return strip(items, index, W, H, size);
	}
}

// the card a direction key leads to from `index`
function neighbour(name, result, index, key) {
	const cards = result.cards;
	const n = cards.length;
	if (n === 0) return index;
	const linear = { strip: ["left", "right"], carousel: ["left", "right"], fan: ["left", "right"], list: ["up", "down"] }[name];
	if (linear) {
		if (key === linear[0]) return (index - 1 + n) % n;
		if (key === linear[1]) return (index + 1) % n;
		// the other axis moves along as well
		return key === "up" || key === "left" ? (index - 1 + n) % n : (index + 1) % n;
	}
	// grid and workspaces: the nearest card that way
	const from = cards[index];
	const fx = from.x + from.w / 2, fy = from.y + from.h / 2;
	let best = -1, bestScore = Infinity;
	cards.forEach((c, i) => {
		if (i === index) return;
		const dx = c.x + c.w / 2 - fx, dy = c.y + c.h / 2 - fy;
		const along = { left: -dx, right: dx, up: -dy, down: dy }[key];
		const across = key === "left" || key === "right" ? Math.abs(dy) : Math.abs(dx);
		if (along <= 4) return;
		const score = along + across * 2.5;
		if (score < bestScore) {
			bestScore = score;
			best = i;
		}
	});
	return best >= 0 ? best : index;
}
