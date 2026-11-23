// The smart home canvas: plugs and devices as nodes on a board that pans and
// zooms, devices hanging on their plug by a cable. A node is dragged the way
// a shelf card moves (ShelfCard.qml): it glides after the pointer with Qt's
// SpringAnimation (spring 4.2, damping 0.52, mass 0.7, 16 ms steps), leans
// into the pull and swings into its place on release. Around it the board is
// loose: nodes that are pushed slide aside, devices follow their plug when
// the cable is taut. Every plug is fed from the provider, which sits in a
// notch cut into the top of the board (its cables only show the flow, they
// do not pull). Where everything came to rest is saved.
import { h, icon } from "../util.js";
import { reduced, animate, EASE } from "../motion.js";

const STEP = 0.016;          // Qt's spring runs in 16 ms steps
const SPRING = 4.2;
const DAMPING = 0.52;
const MASS = 0.7;
const LEAN = 0.035;          // degrees per pixel the node trails behind
const MAX_LEAN = 4;
const SETTLE = 700;          // ms the spring still holds a node after it is let go
const GAP = 22;              // room between two nodes
const PUSH = 46;             // how hard overlapping nodes push apart
const CABLE = 170;           // length of a cable before it pulls
const PULL = 30;
const FRICTION = 0.9;        // per step for free nodes
const THRESHOLD = 6;         // px before a press becomes a drag
const REST = 2.5;            // px/s

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

function svg(tag, attrs = {}, ...children) {
	const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
	for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
	node.append(...children);
	return node;
}

// one 16 ms step of Qt's SpringAnimation (with mass) on one axis
function springStep(pos, vel, to) {
	vel += (SPRING * (to - pos) - DAMPING * vel) / MASS;
	return [pos + vel * STEP, vel];
}

// a dialog's head moves the dialog like a shelf header moves the card
export function glideDialog(dialog) {
	const box = dialog.el;
	const head = box.querySelector(".dialog-head");
	if (!head || box.classList.contains("sheet")) return;
	head.classList.add("sh-grab");
	const s = { x: 0, y: 0, vx: 0, vy: 0, tx: 0, ty: 0, held: false, until: 0, raf: 0 };
	let start = null;
	const tick = now => {
		s.raf = 0;
		for (let i = 0; i < 2; i++) {
			[s.x, s.vx] = springStep(s.x, s.vx, s.tx);
			[s.y, s.vy] = springStep(s.y, s.vy, s.ty);
		}
		const lean = clamp((s.tx - s.x) * LEAN, -MAX_LEAN, MAX_LEAN);
		box.style.translate = `${s.x}px ${s.y}px`;
		box.style.rotate = `${lean}deg`;
		if (s.held || now < s.until || Math.abs(s.tx - s.x) > 0.2 || Math.abs(s.ty - s.y) > 0.2) s.raf = requestAnimationFrame(tick);
	};
	head.addEventListener("pointerdown", event => {
		if (event.button !== 0 || event.target.closest("button, input, select, a")) return;
		start = { x: event.clientX - s.tx, y: event.clientY - s.ty };
		s.held = true;
		head.setPointerCapture(event.pointerId);
		if (!s.raf) s.raf = requestAnimationFrame(tick);
	});
	head.addEventListener("pointermove", event => {
		if (!s.held) return;
		s.tx = event.clientX - start.x;
		s.ty = event.clientY - start.y;
	});
	const end = () => {
		if (!s.held) return;
		s.held = false;
		s.until = performance.now() + SETTLE;
	};
	head.addEventListener("pointerup", end);
	head.addEventListener("pointercancel", end);
}

export function createCanvas({ admin, notch, renderNode, onOpen, onMenu, onWire, onCable, onEmpty, onBackground, onSave }) {
	const wires = h("svg.sh-wires", { width: 1, height: 1 });
	const world = h("div.sh-world", wires);
	// the board's outline (with the notch) carries the fill and the dots; the nodes are clipped to it
	const dots = svg("pattern", { id: `sh-dots-${Math.random().toString(36).slice(2)}`, width: 28, height: 28, patternUnits: "userSpaceOnUse" },
		svg("circle", { class: "sh-dot", cx: 14, cy: 14, r: 1.2 }));
	const shape = svg("path", { class: "sh-board" });
	const shapeDots = svg("path");
	shapeDots.setAttribute("fill", `url(#${dots.id})`);
	const board = svg("svg", { class: "sh-frame" }, svg("defs", {}, dots), shape, shapeDots);
	const clip = h("div.sh-clip", world);
	const el = h("div.sh-canvas", { tabindex: -1 }, board, clip, notch || null);
	const cut = { x0: 0, x1: 0, depth: 0 };
	const bodies = new Map();
	const paths = new Map();          // node id → {path, hit}
	const feeds = new Map();          // plug id → path from the provider in the notch
	const view = { x: 0, y: 0, k: 1, vx: 0, vy: 0 };
	let cable = null;                 // a cable pulled out of a plug's socket
	let press = null;                 // what the pointer holds
	let raf = 0;
	let last = 0;
	let fitted = false;

	// ── bodies ──
	function body(id, kind) {
		let b = bodies.get(id);
		if (b) return b;
		const node = h(`div.sh-node.${kind}`, { dataset: { id } });
		b = { id, kind, el: node, x: 0, y: 0, vx: 0, vy: 0, tx: 0, ty: 0, hw: 60, hh: 40, angle: 0,
			mass: kind === "plug" ? 2.5 : 1, held: false, until: 0, saved: null, data: null, socket: null };
		bodies.set(id, b);
		world.appendChild(node);
		return b;
	}

	function measure(b) {
		b.hw = (b.el.offsetWidth || 120) / 2;
		b.hh = (b.el.offsetHeight || 80) / 2;
		// a plug's socket sits on the bottom edge of its circle
		const circle = b.el.querySelector(".sh-plug");
		b.port = circle ? circle.offsetTop + circle.offsetHeight - b.hh : 0;
	}

	// a free place for something new: the given one, or below / beside the others
	function freeSpot(x, y) {
		for (let ring = 0; ring < 40; ring++) {
			const px = x + (ring % 2 ? 1 : -1) * Math.ceil(ring / 2) * 120 * (ring > 0);
			if (![...bodies.values()].some(b => Math.abs(b.x - px) < b.hw + 80 && Math.abs(b.y - y) < b.hh + 50)) return [px, y];
		}
		return [x, y];
	}

	function sync(plugs, nodes) {
		const seen = new Set();
		const first = !fitted;
		const place = (b, item, fallback) => {
			const has = typeof item.x === "number" && typeof item.y === "number";
			if (!b.saved) {
				[b.x, b.y] = has ? [item.x, item.y] : fallback();
				b.saved = has ? { x: item.x, y: item.y } : null;
				return true;
			}
			// someone else moved it
			if (has && !b.held && (Math.abs(item.x - b.saved.x) > 1 || Math.abs(item.y - b.saved.y) > 1)) {
				b.saved = { x: item.x, y: item.y };
				b.tx = item.x;
				b.ty = item.y;
				b.until = performance.now() + SETTLE;
			}
			return false;
		};
		plugs.forEach((plug, i) => {
			const b = body(plug.id, "plug");
			seen.add(b.id);
			b.data = plug;
			renderNode(b.el, "plug", plug);
			measure(b);
			const fresh = place(b, plug, () => freeSpot(i * 240 - (plugs.length - 1) * 120, 0));
			if (fresh && !first) pop(b);
		});
		for (const node of nodes) {
			const b = body(node.id, "dev");
			seen.add(b.id);
			b.data = node;
			b.socket = node.socket || null;
			renderNode(b.el, "dev", node);
			measure(b);
			const socket = node.socket && bodies.get(node.socket);
			const fresh = place(b, node, () => freeSpot(socket ? socket.x : 0, socket ? socket.y + CABLE : CABLE));
			if (fresh && !first) pop(b);
		}
		for (const [id, b] of bodies) {
			if (seen.has(id)) continue;
			bodies.delete(id);
			animate(b.el, [{ opacity: 1, scale: 1 }, { opacity: 0, scale: 0.6 }], { duration: 220, easing: EASE.accel }).finished.finally(() => b.el.remove());
		}
		for (const [id, wire] of paths) {
			if (bodies.get(id)?.socket && bodies.has(bodies.get(id).socket)) continue;
			wire.group.remove();
			paths.delete(id);
		}
		for (const [id, path] of feeds) {
			if (bodies.has(id) && cut.depth) continue;
			path.remove();
			feeds.delete(id);
		}
		outline();
		if (first && bodies.size && el.offsetWidth) {
			fitted = true;
			fit(false);
		}
		draw();
		kick();
	}

	function pop(b) {
		animate(b.el.firstElementChild || b.el, [{ scale: 0.4, opacity: 0 }, { scale: 1, opacity: 1 }], { duration: 620, easing: EASE.spring, fill: "none" });
	}

	// ── the simulation ──
	function kick() {
		if (raf) return;
		last = performance.now();
		raf = requestAnimationFrame(frame);
	}

	function frame(now) {
		raf = 0;
		const steps = clamp(Math.round((now - last) / 16), 1, 4);
		last = now;
		let moving = false;
		for (let i = 0; i < steps; i++) moving = step(now) || moving;
		draw();
		if (moving) raf = requestAnimationFrame(frame);
		else rested();
	}

	function step(now) {
		const list = [...bodies.values()];
		let moving = false;
		for (const b of list) {
			b.fx = 0;
			b.fy = 0;
			b.pinned = b.held || now < b.until;
		}
		// nodes that overlap push apart; one that is held does not give way
		for (let i = 0; i < list.length; i++) {
			for (let j = i + 1; j < list.length; j++) {
				const a = list[i], b = list[j];
				const dx = b.x - a.x, dy = b.y - a.y;
				const ox = a.hw + b.hw + GAP - Math.abs(dx);
				const oy = a.hh + b.hh + GAP - Math.abs(dy);
				if (ox <= 0 || oy <= 0) continue;
				const sx = dx === 0 ? (a.id < b.id ? 1 : -1) : Math.sign(dx);
				const sy = dy === 0 ? (a.id < b.id ? 1 : -1) : Math.sign(dy);
				const [fx, fy] = ox < oy ? [ox * PUSH * sx, 0] : [0, oy * PUSH * sy];
				const share = a.pinned || b.pinned ? 1 : 0.5;
				if (!a.pinned) { a.fx -= fx * share * 2; a.fy -= fy * share * 2; }
				if (!b.pinned) { b.fx += fx * share * 2; b.fy += fy * share * 2; }
			}
		}
		// a taut cable pulls the device after its plug (and a little the other way)
		for (const b of list) {
			const plug = b.socket && bodies.get(b.socket);
			if (!plug) continue;
			const dx = plug.x - b.x, dy = plug.y - b.y;
			const d = Math.hypot(dx, dy);
			const ux = dx / (d || 1), uy = dy / (d || 1);
			// the cable is long enough for both to sit apart, whichever side it comes from
			const apart = Math.min((b.hw + plug.hw + GAP) / (Math.abs(ux) || 1e-6), (b.hh + plug.hh + GAP) / (Math.abs(uy) || 1e-6));
			const length = Math.max(CABLE, apart + 30);
			if (d <= length) continue;
			const f = (d - length) * PULL;
			if (!b.pinned) { b.fx += ux * f; b.fy += uy * f; }
			if (!plug.pinned) { plug.fx -= ux * f * 0.15; plug.fy -= uy * f * 0.15; }   // a plug hardly gives way
		}
		for (const b of list) {
			let lean;
			if (b.pinned) {
				[b.x, b.vx] = springStep(b.x, b.vx, b.tx);
				[b.y, b.vy] = springStep(b.y, b.vy, b.ty);
				lean = clamp((b.tx - b.x) * LEAN, -MAX_LEAN, MAX_LEAN);
				moving = true;
			} else {
				b.vx = (b.vx + (b.fx / b.mass) * STEP) * FRICTION;
				b.vy = (b.vy + (b.fy / b.mass) * STEP) * FRICTION;
				// slower than this is rest: a cable and a neighbour may hold each other in balance
				if (Math.hypot(b.vx, b.vy) < REST) b.vx = b.vy = 0;
				b.x += b.vx * STEP;
				b.y += b.vy * STEP;
				lean = clamp(b.vx * LEAN * 0.12, -MAX_LEAN, MAX_LEAN);
				if (b.vx || b.vy) moving = true;
			}
			b.angle += (lean - b.angle) * 0.3;
			if (Math.abs(b.angle) > 0.05) moving = true;
			else if (!b.pinned) b.angle = 0;
		}
		if (cable) {
			if (cable.retract) {
				const plug = bodies.get(cable.from);
				cable.tx = plug ? plug.x : cable.x;
				cable.ty = plug ? plug.y : cable.y;
				if (Math.hypot(cable.tx - cable.x, cable.ty - cable.y) < 8) dropCable();
			}
			if (cable) {
				[cable.x, cable.vx] = springStep(cable.x, cable.vx, cable.tx);
				[cable.y, cable.vy] = springStep(cable.y, cable.vy, cable.ty);
				moving = true;
			}
		}
		if (!press?.pan && (Math.abs(view.vx) > 0.5 || Math.abs(view.vy) > 0.5)) {
			view.x += view.vx * STEP;
			view.y += view.vy * STEP;
			view.vx *= 0.9;
			view.vy *= 0.9;
			moving = true;
		}
		return moving || !!press;
	}

	// everything is still: what moved is saved
	function rested() {
		const moved = {};
		for (const b of bodies.values()) {
			if (b.saved && Math.abs(b.saved.x - b.x) < 0.5 && Math.abs(b.saved.y - b.y) < 0.5) continue;
			b.saved = { x: b.x, y: b.y };
			moved[b.id] = [Math.round(b.x * 10) / 10, Math.round(b.y * 10) / 10];
		}
		if (admin && Object.keys(moved).length) onSave(moved);
	}

	// ── drawing ──
	// a cable leaves the socket downwards and goes into the side of the device that faces it;
	// the less it is stretched, the more it hangs
	function wirePath(sx, sy, ex, ey, nx = 0, ny = -1) {
		const d = Math.hypot(ex - sx, ey - sy);
		const slack = Math.max(0, CABLE * 1.15 - d);
		const bend = Math.min(36 + slack * 0.35, d * 0.6 + 12);
		const sag = slack * 0.3;
		return `M${sx},${sy} C${sx},${sy + bend + sag} ${ex + nx * bend},${ey + ny * bend + sag} ${ex},${ey}`;
	}

	// where on the device's edge the cable from (sx, sy) goes in, and that side's outward direction
	function inlet(b, sx, sy) {
		const dx = sx - b.x, dy = sy - b.y;
		if (Math.abs(dy) / b.hh >= Math.abs(dx) / b.hw) return dy < 0 ? [b.x, b.y - b.hh, 0, -1] : [b.x, b.y + b.hh, 0, 1];
		return dx < 0 ? [b.x - b.hw, b.y, -1, 0] : [b.x + b.hw, b.y, 1, 0];
	}

	// the outline: rounded corners, and the notch the provider sits in (its top corners
	// curve outwards into the board's edge, its bottom ones inwards)
	function outline() {
		const W = el.offsetWidth, H = el.offsetHeight;
		if (!W || !H) return;
		const R = 22, r = 22, c = 16;
		const shown = notch && !notch.hidden;
		if (shown) {
			cut.depth = notch.offsetHeight;
			cut.x0 = notch.offsetLeft;
			cut.x1 = notch.offsetLeft + notch.offsetWidth;
		} else cut.depth = 0;
		const d = cut.depth
			? `M0,${R} A${R},${R} 0 0 1 ${R},0 L${cut.x0 - c},0 A${c},${c} 0 0 1 ${cut.x0},${c} L${cut.x0},${cut.depth - r} `
				+ `A${r},${r} 0 0 0 ${cut.x0 + r},${cut.depth} L${cut.x1 - r},${cut.depth} A${r},${r} 0 0 0 ${cut.x1},${cut.depth - r} `
				+ `L${cut.x1},${c} A${c},${c} 0 0 1 ${cut.x1 + c},0 L${W - R},0 A${R},${R} 0 0 1 ${W},${R} `
				+ `L${W},${H - R} A${R},${R} 0 0 1 ${W - R},${H} L${R},${H} A${R},${R} 0 0 1 0,${H - R} Z`
			: `M0,${R} A${R},${R} 0 0 1 ${R},0 L${W - R},0 A${R},${R} 0 0 1 ${W},${R} L${W},${H - R} A${R},${R} 0 0 1 ${W - R},${H} L${R},${H} A${R},${R} 0 0 1 0,${H - R} Z`;
		shape.setAttribute("d", d);
		shapeDots.setAttribute("d", d);
		clip.style.clipPath = `path("${d}")`;
	}

	function draw() {
		world.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.k})`;
		dots.setAttribute("patternTransform", `translate(${view.x} ${view.y}) scale(${view.k})`);
		for (const b of bodies.values()) {
			b.el.style.transform = `translate(${b.x - b.hw}px, ${b.y - b.hh}px) rotate(${b.angle}deg)`;
			b.el.classList.toggle("held", b.held);
		}
		// where the provider's cables leave the notch, on the board
		const source = { x: ((cut.x0 + cut.x1) / 2 - view.x) / view.k, y: (cut.depth - view.y) / view.k };
		for (const b of bodies.values()) {
			if (!cut.depth || b.kind !== "plug") continue;
			let path = feeds.get(b.id);
			if (!path) {
				path = h("path.sh-wire.feed");
				wires.prepend(path);
				feeds.set(b.id, path);
			}
			path.setAttribute("d", wirePath(source.x, source.y, b.x, b.y - b.hh));   // into the top of the plug
			const watts = b.data?.online ? b.data?.reading?.power || 0 : 0;
			path.classList.toggle("live", watts >= 2);
			path.classList.toggle("dead", !b.data?.online);
			if (watts >= 2) path.style.animationDuration = `${clamp(40 / Math.sqrt(watts), 0.35, 4).toFixed(2)}s`;
		}
		for (const b of bodies.values()) {
			const plug = b.socket && bodies.get(b.socket);
			if (!plug) continue;
			let wire = paths.get(b.id);
			if (!wire) {
				const path = h("path.sh-wire");
				const hit = h("path.sh-wire-hit");
				const group = h("g", hit, path);
				hit.addEventListener("click", event => onWire(b.id, event.clientX, event.clientY));
				hit.addEventListener("contextmenu", event => {
					event.preventDefault();
					onWire(b.id, event.clientX, event.clientY);
				});
				wires.appendChild(group);
				wire = { group, path, hit };
				paths.set(b.id, wire);
			}
			const sy = plug.y + plug.port;
			const d = wirePath(plug.x, sy, ...inlet(b, plug.x, sy));
			wire.path.setAttribute("d", d);
			wire.hit.setAttribute("d", d);
			const watts = plug.data?.online ? plug.data?.reading?.power || 0 : 0;
			wire.path.classList.toggle("live", watts >= 2);
			wire.path.classList.toggle("dead", !plug.data?.online);
			if (watts >= 2) wire.path.style.animationDuration = `${clamp(40 / Math.sqrt(watts), 0.35, 4).toFixed(2)}s`;
		}
		if (cable) {
			const plug = bodies.get(cable.from);
			if (plug) cable.path.setAttribute("d", wirePath(plug.x, plug.y + plug.port, cable.x, cable.y));
			cable.head.style.transform = `translate(${cable.x}px, ${cable.y}px)`;
		}
	}

	// ── the view ──
	function toWorld(cx, cy) {
		const r = el.getBoundingClientRect();
		return { x: (cx - r.left - view.x) / view.k, y: (cy - r.top - view.y) / view.k };
	}

	function toScreen(x, y) {
		const r = el.getBoundingClientRect();
		return { x: r.left + view.x + x * view.k, y: r.top + view.y + y * view.k };
	}

	function fit(smooth = true) {
		const list = [...bodies.values()];
		const W = el.offsetWidth, H = el.offsetHeight;
		if (!W || !H) return;
		let k = 1, cx = 0, cy = 0;
		if (list.length) {
			const x0 = Math.min(...list.map(b => b.x - b.hw)), x1 = Math.max(...list.map(b => b.x + b.hw));
			const y0 = Math.min(...list.map(b => b.y - b.hh)), y1 = Math.max(...list.map(b => b.y + b.hh));
			k = clamp(Math.min((W - 96) / (x1 - x0 || 1), (H - 96 - cut.depth) / (y1 - y0 || 1)), 0.25, 1);
			cx = (x0 + x1) / 2;
			cy = (y0 + y1) / 2;
		}
		const to = { x: W / 2 - cx * k, y: cut.depth + (H - cut.depth) / 2 - cy * k, k };
		if (!smooth || reduced()) {
			Object.assign(view, to, { vx: 0, vy: 0 });
			draw();
			return;
		}
		const from = { ...view };
		const t0 = performance.now();
		const ease = t => 1 - Math.pow(1 - t, 3);
		const run = now => {
			const t = Math.min(1, (now - t0) / 420);
			const e = ease(t);
			view.x = from.x + (to.x - from.x) * e;
			view.y = from.y + (to.y - from.y) * e;
			view.k = from.k + (to.k - from.k) * e;
			draw();
			if (t < 1) requestAnimationFrame(run);
		};
		view.vx = view.vy = 0;
		requestAnimationFrame(run);
	}

	function zoomAt(cx, cy, factor) {
		const r = el.getBoundingClientRect();
		const k = clamp(view.k * factor, 0.3, 2.2);
		const px = cx - r.left, py = cy - r.top;
		view.x = px - (px - view.x) * (k / view.k);
		view.y = py - (py - view.y) * (k / view.k);
		view.k = k;
		draw();
	}

	// ── a cable out of a socket ──
	function startCable(plug, event) {
		const at = toWorld(event.clientX, event.clientY);
		const path = h("path.sh-wire.pulling");
		const head = h("div.sh-cable-head", icon("power_plug"));
		wires.appendChild(path);
		world.appendChild(head);
		cable = { from: plug.id, x: plug.x, y: plug.y + plug.port, vx: 0, vy: 0, tx: at.x, ty: at.y, path, head, over: null };
	}

	function moveCable(event) {
		const at = toWorld(event.clientX, event.clientY);
		cable.tx = at.x;
		cable.ty = at.y;
		const under = document.elementFromPoint(event.clientX, event.clientY)?.closest(".sh-node.dev");
		const over = under && el.contains(under) ? under.dataset.id : null;
		if (over !== cable.over) {
			if (cable.over) bodies.get(cable.over)?.el.classList.remove("target");
			if (over) bodies.get(over)?.el.classList.add("target");
			cable.over = over;
		}
	}

	async function endCable() {
		const c = cable;
		if (c.over) {
			bodies.get(c.over)?.el.classList.remove("target");
			const node = c.over;
			dropCable();
			onCable(c.from, node);
			return;
		}
		const plug = bodies.get(c.from);
		if (!plug || Math.hypot(c.tx - plug.x, c.ty - plug.y) < plug.hw + 10) {
			c.retract = true;
			kick();
			return;
		}
		c.pending = true;
		const made = await onEmpty({ x: c.tx, y: c.ty }, c.from);
		if (cable !== c) return;
		if (made) dropCable();
		else {
			c.retract = true;
			kick();
		}
	}

	function dropCable() {
		if (!cable) return;
		cable.path.remove();
		cable.head.remove();
		cable = null;
	}

	// ── the pointer ──
	el.addEventListener("pointerdown", event => {
		if (event.button !== 0 || cable?.pending || event.target.closest(".sh-notch")) return;
		const nodeEl = event.target.closest(".sh-node");
		el.focus({ preventScroll: true });
		if (nodeEl) {
			const b = bodies.get(nodeEl.dataset.id);
			if (!b) return;
			const port = event.target.closest(".sh-port");
			press = { body: b, port: !!port && admin, sx: event.clientX, sy: event.clientY, dragging: false };
			if (press.port) {
				startCable(b, event);
				press.dragging = true;
			}
			const at = toWorld(event.clientX, event.clientY);
			press.grab = { x: at.x - b.x, y: at.y - b.y };
		} else if (event.target === el || event.target === world || event.target === wires || event.target === clip || board.contains(event.target)) {
			press = { pan: true, sx: event.clientX, sy: event.clientY, vx: event.clientX - view.x, vy: event.clientY - view.y, t: performance.now(), lx: event.clientX, ly: event.clientY };
			view.vx = view.vy = 0;
			el.classList.add("panning");
		} else return;
		el.setPointerCapture(event.pointerId);
		kick();
	});

	el.addEventListener("pointermove", event => {
		if (!press) return;
		if (press.pan) {
			const now = performance.now();
			const dt = Math.max(1, now - press.t) / 1000;
			view.vx = (event.clientX - press.lx) / dt * 0.6 + view.vx * 0.4;
			view.vy = (event.clientY - press.ly) / dt * 0.6 + view.vy * 0.4;
			press.t = now;
			press.lx = event.clientX;
			press.ly = event.clientY;
			view.x = event.clientX - press.vx;
			view.y = event.clientY - press.vy;
			draw();
			return;
		}
		if (press.port) {
			moveCable(event);
			return;
		}
		const b = press.body;
		if (!press.dragging) {
			if (!admin || Math.hypot(event.clientX - press.sx, event.clientY - press.sy) < THRESHOLD) return;
			press.dragging = true;
			b.held = true;
			b.tx = b.x;
			b.ty = b.y;
			b.vx = b.vy = 0;
		}
		const at = toWorld(event.clientX, event.clientY);
		b.tx = at.x - press.grab.x;
		b.ty = at.y - press.grab.y;
		kick();
	});

	const release = event => {
		if (!press) return;
		const p = press;
		press = null;
		el.classList.remove("panning");
		if (p.pan) {
			if (performance.now() - p.t > 80) view.vx = view.vy = 0;
			kick();
			return;
		}
		if (p.port) {
			if (event.type === "pointercancel") {
				cable.retract = true;
				kick();
			} else endCable();
			return;
		}
		const b = p.body;
		if (p.dragging) {
			b.held = false;
			b.until = performance.now() + SETTLE;
			kick();
		} else if (event.type === "pointerup") {
			const r = b.el.getBoundingClientRect();
			onOpen(b.id, b.kind, { x: r.left + r.width / 2, y: r.top + r.height / 2 });
		}
	};
	el.addEventListener("pointerup", release);
	el.addEventListener("pointercancel", release);

	el.addEventListener("dblclick", event => {
		if (event.target.closest(".sh-node, .sh-notch") || !admin) return;
		onEmpty(toWorld(event.clientX, event.clientY), null);
	});

	el.addEventListener("contextmenu", event => {
		if (event.target.closest(".sh-wire-hit, .sh-notch")) return;
		event.preventDefault();
		const nodeEl = event.target.closest(".sh-node");
		if (nodeEl) onMenu(nodeEl.dataset.id, nodeEl.classList.contains("plug") ? "plug" : "dev", event.clientX, event.clientY);
		else onBackground(toWorld(event.clientX, event.clientY), event.clientX, event.clientY);
	});

	el.addEventListener("wheel", event => {
		event.preventDefault();
		// a mouse wheel (whole notches) or a pinch zooms, a touchpad's two fingers move the board
		const notch = event.deltaMode !== 0 || (event.deltaX === 0 && Number.isInteger(event.deltaY) && Math.abs(event.deltaY) >= 50);
		if (event.ctrlKey || notch) {
			const amount = event.deltaMode === 1 ? event.deltaY * 33 : event.deltaY;
			zoomAt(event.clientX, event.clientY, Math.exp(-amount * (event.ctrlKey && !notch ? 0.01 : 0.0016)));
			return;
		}
		view.x -= event.deltaX;
		view.y -= event.deltaY;
		draw();
	}, { passive: false });

	const resize = new ResizeObserver(() => {
		outline();
		if (!fitted && bodies.size && el.offsetWidth) {
			fitted = true;
			fit(false);
		}
		draw();
	});
	resize.observe(el);
	if (notch) resize.observe(notch);

	return {
		el,
		sync,
		fit,
		toScreen,
		bodyOf: id => bodies.get(id),
		destroy() {
			cancelAnimationFrame(raf);
			resize.disconnect();
		}
	};
}
