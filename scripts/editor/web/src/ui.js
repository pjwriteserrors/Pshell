// The kit of the page, drawn and moving like style/widgets and Motion.qml:
// things bloom open with a little overshoot and snap shut.
import glyphs from "./icons.gen.js";

export const motion = {
	spatial: "cubic-bezier(.38,1.21,.22,1)",
	spatialFast: "cubic-bezier(.42,1.67,.21,.9)",
	decel: "cubic-bezier(.05,.7,.1,1)",
	accel: "cubic-bezier(.3,0,.8,.15)",
	standard: "cubic-bezier(.2,0,0,1)",
	micro: 100, short: 160, medium: 250, long: 360, extraLong: 500,
};
const calm = matchMedia("(prefers-reduced-motion: reduce)");

export function animate(element, frames, duration, easing, extra = {}) {
	if (calm.matches || !element.animate) return { finished: Promise.resolve(), cancel() {} };
	return element.animate(frames, { duration, easing, fill: "backwards", ...extra });
}

export function bloom(element, origin = "50% 0%") {
	element.style.transformOrigin = origin;
	return animate(element, [
		{ opacity: 0, transform: "scale(.94) translateY(-4px)" },
		{ opacity: 1, transform: "none" },
	], motion.medium, motion.spatial);
}

export function snapShut(element) {
	return animate(element, [
		{ opacity: 1, transform: "none" },
		{ opacity: 0, transform: "scale(.97)" },
	], motion.short, motion.accel, { fill: "forwards" });
}

// keep elements where they were, then let them travel to where they are now
export function flip(elements, mutate, duration = motion.medium) {
	const before = new Map(elements().map(each => [each, each.getBoundingClientRect()]));
	mutate();
	for (const each of elements()) {
		const old = before.get(each);
		if (!old) continue;
		const now = each.getBoundingClientRect();
		const dx = old.left - now.left;
		const dy = old.top - now.top;
		if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
		animate(each, [{ transform: `translate(${dx}px,${dy}px)` }, { transform: "none" }], duration, motion.spatial);
	}
}

export function icon(name, cls = "") {
	const span = document.createElement("span");
	span.className = `icon ${cls}`.trim();
	span.textContent = glyphs[name] ?? "";
	return span;
}

export function el(tag, cls, ...children) {
	const out = document.createElement(tag);
	if (cls) out.className = cls;
	for (const child of children) if (child !== null && child !== undefined) out.append(child);
	return out;
}

export function iconButton(name, title, onClick, cls = "") {
	const button = el("button", `icon-button ${cls}`.trim(), icon(name));
	button.title = title;
	button.addEventListener("mousedown", event => event.preventDefault());
	button.addEventListener("click", event => { event.stopPropagation(); onClick(event); });
	return button;
}

// ── a row of choices with a pill that slides (style/widgets/Segmented) ──
export function segmented(items, value, onPick) {
	const box = el("div", "segmented");
	const pill = el("div", "segmented-pill");
	box.append(pill);
	const buttons = new Map();
	const place = () => {
		const active = buttons.get(box.dataset.value);
		if (!active || !active.offsetWidth) return;
		pill.style.width = `${active.offsetWidth}px`;
		pill.style.transform = `translateX(${active.offsetLeft}px)`;
	};
	for (const item of items) {
		const button = el("button", "", item.icon ? icon(item.icon) : item.label);
		button.title = item.title ?? item.label ?? "";
		button.addEventListener("mousedown", event => event.preventDefault());
		button.addEventListener("click", () => { box.set(item.value); onPick(item.value); });
		buttons.set(String(item.value), button);
		box.append(button);
	}
	box.set = next => {
		box.dataset.value = String(next);
		for (const [key, button] of buttons) button.classList.toggle("on", key === String(next));
		requestAnimationFrame(place);
	};
	box.set(value);
	return box;
}

// ── numbers roll (style/widgets/RollText) ───────────────────────────────
export function rollText() {
	const box = el("span", "roll");
	let digits = [];
	box.set = text => {
		const chars = [...String(text)].reverse();
		while (digits.length > chars.length) digits.pop().remove();
		while (digits.length < chars.length) {
			const cell = el("span", "roll-cell", el("span", "roll-char"));
			digits.push(cell);
			box.prepend(cell);
		}
		chars.forEach((char, index) => {
			const cell = digits[index];
			const old = cell.lastElementChild;
			if (old.textContent === char) return;
			const next = el("span", "roll-char", char);
			if (old.textContent !== "") {
				cell.append(next);
				animate(next, [{ transform: "translateY(90%)", opacity: 0 }, { transform: "none", opacity: 1 }], motion.medium, motion.spatial);
				const leave = animate(old, [{ transform: "none", opacity: 1 }, { transform: "translateY(-90%)", opacity: 0 }], motion.short, motion.accel, { fill: "forwards" });
				leave.finished.then(() => old.remove());
			} else {
				old.textContent = char;
			}
		});
	};
	return box;
}

// ── toast ───────────────────────────────────────────────────────────────
let toastBox;
export function toast(text, tone = "", actions = []) {
	if (!toastBox) {
		toastBox = el("div", "toasts");
		document.body.append(toastBox);
	}
	const item = el("div", `toast ${tone}`.trim(), el("span", "", text));
	const close = async () => {
		await animate(item, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(8px) scale(.96)" }], motion.short, motion.accel, { fill: "forwards" }).finished;
		item.remove();
	};
	for (const action of actions) {
		const button = el("button", "text-button", action.label);
		button.addEventListener("click", () => { close(); action.run(); });
		item.append(button);
	}
	toastBox.append(item);
	animate(item, [{ opacity: 0, transform: "translateY(16px) scale(.92)" }, { opacity: 1, transform: "none" }], motion.long, motion.spatial);
	setTimeout(close, actions.length ? 8000 : 2600);
}

// ── scrim + surface ─────────────────────────────────────────────────────
export function overlay(surface, { onClose, origin } = {}) {
	const scrim = el("div", "scrim");
	scrim.append(surface);
	document.body.append(scrim);
	animate(scrim, [{ opacity: 0 }, { opacity: 1 }], motion.short, motion.standard);
	bloom(surface, origin);
	let done = false;
	const close = async () => {
		if (done) return;
		done = true;
		onClose?.();
		animate(scrim, [{ opacity: 1 }, { opacity: 0 }], motion.short, motion.standard, { fill: "forwards" });
		await snapShut(surface).finished;
		scrim.remove();
	};
	scrim.addEventListener("mousedown", event => { if (event.target === scrim) close(); });
	return { close };
}

// ── palette: a field, a list, a pill that slides over the list ──────────
// source(query) → items or a promise of them: { title, detail, icon, keys, run }
export function palette({ placeholder, source, value = "", wide = true }) {
	return new Promise(resolve => {
		const input = el("input", "palette-input");
		input.placeholder = placeholder;
		input.value = value;
		input.spellcheck = false;
		const list = el("div", "palette-list");
		const pill = el("div", "palette-pill");
		const scroller = el("div", "palette-scroll", pill, list);
		const surface = el("div", `palette${wide ? " wide" : ""}`, el("div", "palette-head", icon("magnify"), input), scroller);
		const back = document.activeElement;
		const shell = overlay(surface, { origin: "50% 0%", onClose: () => back?.focus?.() });
		let items = [];
		let index = 0;
		let serial = 0;
		const place = (scroll = true) => {
			const row = list.children[index];
			pill.classList.toggle("off", !row);
			if (!row) return;
			pill.style.transform = `translateY(${row.offsetTop}px)`;
			pill.style.height = `${row.offsetHeight}px`;
			for (const each of list.children) each.classList.toggle("on", each === row);
			if (scroll) row.scrollIntoView({ block: "nearest" });
		};
		const finish = item => {
			shell.close();
			resolve(item ?? null);
			if (item) setTimeout(() => item.run?.(input.value), 20);
		};
		const draw = (next, fresh) => {
			items = next;
			index = Math.min(index, Math.max(0, items.length - 1));
			if (fresh) index = 0;
			list.replaceChildren(...items.slice(0, 80).map((item, position) => {
				const row = el("div", "palette-row", item.icon ? icon(item.icon) : el("span", "icon"),
					el("div", "palette-text", el("div", "palette-title", item.title), item.detail ? el("div", "palette-detail", item.detail) : null),
					item.keys ? el("kbd", "", item.keys) : null);
				row.addEventListener("mousemove", () => { if (index !== position) { index = position; place(false); } });
				row.addEventListener("mousedown", event => event.preventDefault());
				row.addEventListener("click", () => finish(item));
				if (fresh && position < 8) animate(row, [{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "none" }], motion.medium, motion.decel, { delay: position * 14 });
				return row;
			}));
			place();
		};
		const refresh = async () => {
			const ticket = ++serial;
			const found = await source(input.value);
			if (ticket === serial) draw(found ?? [], true);
		};
		input.addEventListener("input", refresh);
		input.addEventListener("keydown", event => {
			if (event.key === "ArrowDown" || (event.key === "Tab" && !event.shiftKey)) index = Math.min(index + 1, items.length - 1);
			else if (event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey)) index = Math.max(index - 1, 0);
			else if (event.key === "Enter") { event.preventDefault(); finish(items[index] ?? { run: null, typed: input.value }); return; }
			else if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); finish(null); return; }
			else return;
			event.preventDefault();
			place();
		});
		refresh();
		input.focus();
		input.select();
	});
}

// a question in a line; resolves to the text or null
export function ask(placeholder, value = "") {
	return new Promise(resolve => {
		const input = el("input", "palette-input");
		input.placeholder = placeholder;
		input.value = value;
		input.spellcheck = false;
		const surface = el("div", "palette", el("div", "palette-head", input));
		const back = document.activeElement;
		const shell = overlay(surface, { onClose: () => back?.focus?.() });
		input.addEventListener("keydown", event => {
			if (event.key === "Enter") { event.preventDefault(); shell.close(); resolve(input.value); }
			if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); shell.close(); resolve(null); }
		});
		input.focus();
		input.select();
	});
}

export function confirmDialog(title, buttons) {
	return new Promise(resolve => {
		const row = el("div", "dialog-buttons");
		const surface = el("div", "dialog", el("div", "dialog-title", title), row);
		const back = document.activeElement;
		const shell = overlay(surface, { origin: "50% 50%", onClose: () => back?.focus?.() });
		buttons.forEach((button, index) => {
			const each = el("button", `text-button ${button.tone ?? ""}`, button.label);
			each.addEventListener("click", () => { shell.close(); resolve(button.value); });
			row.append(each);
			if (index === buttons.length - 1) setTimeout(() => each.focus());
		});
		surface.addEventListener("keydown", event => {
			if (event.key === "Escape") { event.stopPropagation(); shell.close(); resolve(null); }
		});
	});
}

// ── context menu ────────────────────────────────────────────────────────
let openMenu = null;
export function menu(x, y, items) {
	openMenu?.();
	const box = el("div", "menu");
	for (const item of items) {
		if (item === "-") { box.append(el("div", "menu-line")); continue; }
		const row = el("button", "menu-row", item.icon ? icon(item.icon) : el("span", "icon"), el("span", "menu-title", item.title), item.keys ? el("kbd", "", item.keys) : null);
		row.addEventListener("mousedown", event => event.preventDefault());
		row.addEventListener("click", () => { close(); item.run(); });
		box.append(row);
	}
	document.body.append(box);
	const rect = box.getBoundingClientRect();
	const left = Math.min(x, innerWidth - rect.width - 8);
	const top = Math.min(y, innerHeight - rect.height - 8);
	box.style.left = `${left}px`;
	box.style.top = `${top}px`;
	bloom(box, `${x - left}px ${y - top}px`);
	const away = event => { if (!box.contains(event.target)) close(); };
	const key = event => { if (event.key === "Escape") { event.stopPropagation(); close(); } };
	function close() {
		openMenu = null;
		document.removeEventListener("mousedown", away, true);
		document.removeEventListener("keydown", key, true);
		snapShut(box).finished.then(() => box.remove());
	}
	document.addEventListener("mousedown", away, true);
	document.addEventListener("keydown", key, true);
	openMenu = close;
}

export function fuzzy(query, text) {
	if (!query) return 1;
	const q = query.toLowerCase();
	const t = text.toLowerCase();
	const whole = t.indexOf(q);
	if (whole >= 0) return 1000 - whole + (whole === 0 || /[/\s_-]/.test(t[whole - 1]) ? 200 : 0) - t.length * 0.1;
	let at = 0;
	let score = 0;
	let last = -2;
	for (const char of q) {
		const found = t.indexOf(char, at);
		if (found < 0) return -1;
		score += found === last + 1 ? 6 : 1;
		last = found;
		at = found + 1;
	}
	return score - t.length * 0.05;
}
