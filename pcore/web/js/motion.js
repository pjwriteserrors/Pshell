// Motion: the shell's curves for the things the web animates by hand –
// staggered entrances, FLIP (shared element) moves, view transitions,
// ripples, rolling digits and rings. Only transform and opacity move.
import { h } from "./util.js";

export const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export const EASE = {
	spatial: "cubic-bezier(0.33, 1, 0.68, 1)",
	fast: "cubic-bezier(0.25, 1, 0.5, 1)",
	accel: "cubic-bezier(0.4, 0, 0.2, 1)",
	standard: "cubic-bezier(0.2, 0, 0, 1)",
	spring: "linear(0, 0.046, 0.159, 0.307, 0.465, 0.618, 0.752, 0.863, 0.95, 1.012, 1.052, 1.074, 1.083, 1.082, 1.074, 1.062, 1.049, 1.036, 1.024, 1.014, 1.006, 1, 0.997, 0.994, 0.993, 0.993, 0.994, 0.994, 0.996, 0.997, 0.998, 0.999, 0.999, 1)"
};

export const DUR = { micro: 100, short: 160, medium: 220, long: 300, xlong: 500, spring: 520 };

export function animate(el, keyframes, options) {
	if (!el?.animate) return { finished: Promise.resolve(), cancel() {} };
	if (reduced()) options = { ...options, duration: 1, delay: 0 };
	return el.animate(keyframes, { fill: "both", ...options });
}

// cards that come with a new folder rise in one after another (FileCard.qml)
export function stagger(elements, { step = 18, max = 28, distance = 14, from = 0.92 } = {}) {
	if (reduced()) return;
	[...elements].forEach((el, i) => {
		const anim = el.animate(
			[
				{ opacity: 0, transform: `translateY(${distance}px) scale(${from})` },
				{ opacity: 1, transform: "none" }
			],
			{ duration: DUR.long + 60, delay: Math.min(i, max) * step, easing: EASE.spatial, fill: "backwards" }
		);
		anim.onfinish = () => anim.cancel();
	});
}

// FLIP: el is drawn where it ends; it starts where `from` (a DOMRect) is
export function flipFrom(el, from, { duration = 420, easing = EASE.spring, radius } = {}) {
	if (!from || reduced()) return Promise.resolve();
	const to = el.getBoundingClientRect();
	if (!to.width || !to.height) return Promise.resolve();
	const sx = from.width / to.width;
	const sy = from.height / to.height;
	const dx = from.left - to.left;
	const dy = from.top - to.top;
	const frames = [
		{ transformOrigin: "top left", transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`, borderRadius: radius ?? "16px" },
		{ transformOrigin: "top left", transform: "none" }
	];
	return el.animate(frames, { duration, easing }).finished.catch(() => {});
}

export function flipTo(el, to, { duration = 300, easing = EASE.accel } = {}) {
	if (!to || reduced()) return Promise.resolve();
	const from = el.getBoundingClientRect();
	if (!from.width || !from.height) return Promise.resolve();
	const sx = to.width / from.width;
	const sy = to.height / from.height;
	const dx = to.left - from.left;
	const dy = to.top - from.top;
	return el.animate(
		[{ transformOrigin: "top left", transform: "none" }, { transformOrigin: "top left", transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` }],
		{ duration, easing, fill: "forwards" }
	).finished.catch(() => {});
}

// a page change through the View Transitions API, else a soft cross-fade
export async function viewTransition(update, direction = "forward") {
	document.documentElement.dataset.direction = direction;
	if (document.startViewTransition && !reduced()) {
		try {
			const transition = document.startViewTransition(() => update());
			// a newer page change skips this one: not an error
			transition.ready.catch(() => {});
			transition.finished.catch(() => {});
			await transition.updateCallbackDone;
			return;
		} catch (error) {
			// fall through: update already ran or failed
			return;
		}
	}
	await update();
}

// a press leaves a ripple where it landed
export function installRipples() {
	document.addEventListener("pointerdown", event => {
		if (event.button !== 0) return;
		const target = event.target.closest(".btn, .icon-btn, .ripple, .side-item, .nav-item, .menu-row, .chip.ripple");
		if (!target || target.disabled || reduced()) return;
		const rect = target.getBoundingClientRect();
		const radius = Math.hypot(Math.max(event.clientX - rect.left, rect.right - event.clientX), Math.max(event.clientY - rect.top, rect.bottom - event.clientY));
		const wave = h("span.ripple-wave", {
			style: {
				width: `${radius * 2}px`,
				height: `${radius * 2}px`,
				left: `${event.clientX - rect.left - radius}px`,
				top: `${event.clientY - rect.top - radius}px`
			}
		});
		if (getComputedStyle(target).position === "static") target.style.position = "relative";
		target.appendChild(wave);
		setTimeout(() => wave.remove(), 600);
	}, { passive: true });
}

// ── rolling digits (RollText.qml): each digit a strip that rolls to its value
export function rollText(el, text) {
	text = String(text);
	if (!el.classList.contains("roll")) el.classList.add("roll");
	if (el.dataset.value === text) return el;
	const previous = el.dataset.value ?? "";
	el.dataset.value = text;
	el.setAttribute("aria-label", text);
	const chars = [...text];
	// rebuild when the shape changes (the digits stay where they are)
	const shape = chars.map(c => (/\d/.test(c) ? "d" : c)).join("");
	if (el.dataset.shape !== shape) {
		el.dataset.shape = shape;
		el.textContent = "";
		chars.forEach((c, index) => {
			if (/\d/.test(c)) {
				const strip = h("span.strip", { "aria-hidden": "true" });
				for (let n = 0; n <= 9; n += 1) strip.appendChild(h("span", String(n)));
				const col = h("span.col", strip);
				el.appendChild(col);
				// a fresh number rolls in from 0
				strip.style.transform = "translateY(0)";
				if (!reduced()) strip.style.transitionDelay = `${index * 40}ms`;
			} else {
				el.appendChild(h("span.static", c === " " ? " " : c));
			}
		});
		void el.offsetWidth;
		if (previous === "") {
			// first show: roll up from zero after a frame
		}
	}
	let digit = 0;
	[...el.children].forEach(child => {
		if (!child.classList.contains("col")) return;
		const strip = child.firstChild;
		while (digit < chars.length && !/\d/.test(chars[digit])) digit += 1;
		const n = Number(chars[digit]);
		digit += 1;
		requestAnimationFrame(() => {
			strip.style.transform = `translateY(${-n * 1.2}em)`;
		});
	});
	return el;
}

export function roll(text, cls = "") {
	const el = h(`span.roll${cls ? "." + cls : ""}`);
	rollText(el, text);
	return el;
}

// ── a progress ring (Ring.qml): value 0..1, or null for indeterminate
export function ring(value, { size = 40, stroke = 4, tone = "var(--primary)", track = "var(--layer3)" } = {}) {
	const r = (size - stroke) / 2;
	const c = 2 * Math.PI * r;
	const svgNs = "http://www.w3.org/2000/svg";
	const svg = document.createElementNS(svgNs, "svg");
	svg.setAttribute("width", size);
	svg.setAttribute("height", size);
	svg.setAttribute("viewBox", `0 0 ${size} ${size}`);
	svg.style.transform = "rotate(-90deg)";
	const back = document.createElementNS(svgNs, "circle");
	const front = document.createElementNS(svgNs, "circle");
	for (const circle of [back, front]) {
		circle.setAttribute("cx", size / 2);
		circle.setAttribute("cy", size / 2);
		circle.setAttribute("r", r);
		circle.setAttribute("stroke-width", stroke);
	}
	back.setAttribute("class", "track");
	back.style.stroke = track;
	front.setAttribute("class", "value");
	front.style.stroke = tone;
	front.setAttribute("stroke-dasharray", c);
	front.setAttribute("stroke-dashoffset", c);
	svg.append(back, front);
	const wrap = h("span.ring", svg);
	wrap.set = (v, nextTone, instant) => {
		if (nextTone) front.style.stroke = nextTone;
		if (v === null || v === undefined) {
			wrap.classList.add("indeterminate");
			front.setAttribute("stroke-dashoffset", c * 0.72);
			return;
		}
		wrap.classList.remove("indeterminate");
		const clamped = Math.max(0, Math.min(1, v));
		if (instant) front.setAttribute("stroke-dashoffset", c * (1 - clamped));
		else requestAnimationFrame(() => front.setAttribute("stroke-dashoffset", c * (1 - clamped)));
	};
	// a ring made for a value that is already under way shows it at once
	wrap.set(value, null, !!value);
	return wrap;
}

// a number counted up (for big figures that appear)
export function countUp(el, to, format = n => String(Math.round(n)), duration = 900) {
	if (reduced()) {
		el.textContent = format(to);
		return;
	}
	const from = Number(el.dataset.n || 0);
	el.dataset.n = to;
	const start = performance.now();
	const step = now => {
		const t = Math.min(1, (now - start) / duration);
		const eased = 1 - Math.pow(1 - t, 3);
		el.textContent = format(from + (to - from) * eased);
		if (t < 1) requestAnimationFrame(step);
	};
	requestAnimationFrame(step);
}
