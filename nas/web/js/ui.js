// Menus, dialogs, forms and snackbars: the file manager's FileMenu,
// DialogFrame, FormDialog, ConfirmDialog and Snackbar on the web. Menus and
// dialogs bloom from where they were asked for (a spring on scale + fade).
import { h, icon, clear, isMobile, glyph } from "./util.js";
import { animate, EASE, DUR, reduced } from "./motion.js";

// where the pointer last pressed: dialogs bloom from there
export const pointer = { x: innerWidth / 2, y: innerHeight / 2 };
addEventListener("pointerdown", event => {
	pointer.x = event.clientX;
	pointer.y = event.clientY;
}, { capture: true, passive: true });

const layer = () => document.getElementById("overlays") || document.body;

// ── menus ──────────────────────────────────────────────────────────────────
// entry: { label, icon, run, checked, shortcut, hint, children, danger,
// enabled, shown } | { separator: true } | { header: "…" }; children may be an
// array, a function returning one, or a function returning a promise of one.
let openMenu = null;

function cleanEntries(entries) {
	const out = [];
	for (const entry of entries || []) {
		if (!entry || entry.shown === false) continue;
		if (entry.separator && (out.length === 0 || out[out.length - 1].separator)) continue;
		out.push(entry);
	}
	while (out.length && out[out.length - 1].separator) out.pop();
	return out.filter((entry, i) => !entry.header || (out[i + 1] && !out[i + 1].header && !out[i + 1].separator));
}

async function resolveChildren(entry) {
	let children = entry.children;
	if (typeof children === "function") children = children();
	if (children && typeof children.then === "function") children = await children;
	return cleanEntries(children || []);
}

export function closeMenu() {
	openMenu?.close();
}

export function showMenu(entries, x, y, options = {}) {
	closeMenu();
	const clean = cleanEntries(entries);
	if (!clean.length) return null;
	if (isMobile() || options.sheet) return showSheetMenu(clean, options);

	const root = h("div.menu-layer");
	const panels = [];
	let closed = false;

	const close = () => {
		if (closed) return;
		closed = true;
		openMenu = null;
		document.removeEventListener("keydown", onKey, true);
		root.style.pointerEvents = "none";
		Promise.all(panels.map(p => animate(p.el, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.96)" }], { duration: DUR.short, easing: EASE.accel }).finished)).finally(() => root.remove());
		options.onClose?.();
	};

	const usable = entry => entry && !entry.separator && !entry.header && entry.enabled !== false;

	const truncate = level => {
		while (panels.length > level + 1) {
			const panel = panels.pop();
			panel.el.remove();
		}
	};

	const setCurrent = (level, index) => {
		const panel = panels[level];
		if (!panel) return;
		panel.current = index;
		panel.rows.forEach((row, i) => row?.classList.toggle("current", i === index));
		const row = panel.rows[index];
		row?.scrollIntoView({ block: "nearest" });
	};

	const activate = async (level, index) => {
		const panel = panels[level];
		const entry = panel?.entries[index];
		if (!usable(entry)) return;
		if (entry.children) {
			await openChild(level, index);
			setCurrent(level + 1, panels[level + 1]?.entries.findIndex(usable) ?? 0);
			return;
		}
		close();
		if (typeof entry.run === "function") setTimeout(() => entry.run(), 0);
	};

	let childToken = 0;
	const openChild = async (level, index) => {
		const panel = panels[level];
		const entry = panel.entries[index];
		if (!entry?.children) return;
		if (panels[level + 1]?.from === index) return;
		truncate(level);
		const token = ++childToken;
		const row = panel.rows[index];
		row.classList.add("loading");
		let children;
		try {
			children = await resolveChildren(entry);
		} finally {
			row.classList.remove("loading");
		}
		if (token !== childToken || closed || !children.length) return;
		truncate(level);
		const rect = row.getBoundingClientRect();
		const parentRect = panel.el.getBoundingClientRect();
		const child = buildPanel(children, level + 1);
		child.from = index;
		place(child, parentRect.right - 4, rect.top - 6, parentRect.left + 4, true);
	};

	const buildPanel = (list, level) => {
		const el = h("div.menu", { role: "menu" });
		const panel = { el, entries: list, rows: [], current: -1, level };
		list.forEach((entry, index) => {
			if (entry.separator) {
				panel.rows.push(null);
				el.appendChild(h("div.menu-sep"));
				return;
			}
			if (entry.header) {
				panel.rows.push(null);
				el.appendChild(h("div.menu-header", entry.header));
				return;
			}
			const iconName = entry.checked === true ? "check" : entry.icon;
			const row = h("div.menu-row", {
				role: "menuitem",
				class: [entry.danger ? "danger" : "", entry.enabled === false ? "disabled" : "", entry.checked === true ? "checked" : ""].filter(Boolean).join(" ")
			},
			iconName ? icon(iconName) : h("span.i"),
			h("span.label.ellipsis", entry.label),
			entry.children ? icon("chevron_right", "tail") : (entry.shortcut || entry.hint ? h("span.shortcut", entry.shortcut || entry.hint) : null));
			let timer = 0;
			row.addEventListener("pointerenter", () => {
				if (!usable(entry)) return;
				setCurrent(level, index);
				clearTimeout(timer);
				if (entry.children) timer = setTimeout(() => openChild(level, index), 140);
				else timer = setTimeout(() => truncate(level), 120);
			});
			row.addEventListener("pointerleave", () => clearTimeout(timer));
			row.addEventListener("click", event => {
				event.stopPropagation();
				activate(level, index);
			});
			panel.rows.push(row);
			el.appendChild(row);
		});
		root.appendChild(el);
		panels.push(panel);
		return panel;
	};

	const place = (panel, px, py, altX, sub) => {
		const el = panel.el;
		const w = el.offsetWidth;
		const hgt = Math.min(el.scrollHeight, innerHeight - 16);
		el.style.maxHeight = `${innerHeight - 16}px`;
		let left = px;
		let top = py;
		if (left + w > innerWidth - 8) left = sub ? altX - w : innerWidth - w - 8;
		left = Math.max(8, left);
		if (top + hgt > innerHeight - 8) top = Math.max(8, innerHeight - hgt - 8);
		el.style.left = `${left}px`;
		el.style.top = `${top}px`;
		// it blooms from the pointer
		const ox = Math.max(0, Math.min(w, (sub ? (left < px ? w : 0) : px - left)));
		const oy = Math.max(0, Math.min(hgt, (sub ? 14 : py - top)));
		el.style.transformOrigin = `${ox}px ${oy}px`;
		animate(el, [{ opacity: 0, transform: "scale(0.86)" }, { opacity: 1, transform: "scale(1)" }], { duration: DUR.spring, easing: EASE.spring, fill: "none" });
		animate(el, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.short, fill: "none" });
	};

	const walk = delta => {
		const level = panels.length - 1;
		const panel = panels[level];
		const count = panel.entries.length;
		let index = panel.current;
		for (let n = 0; n < count; n += 1) {
			index = (index + delta + count) % count;
			if (usable(panel.entries[index])) break;
		}
		setCurrent(level, index);
	};

	const onKey = event => {
		const level = panels.length - 1;
		const panel = panels[level];
		if (!panel) return;
		switch (event.key) {
		case "Escape":
			if (level > 0) truncate(level - 1);
			else close();
			break;
		case "ArrowDown":
			walk(1);
			break;
		case "ArrowUp":
			walk(-1);
			break;
		case "ArrowRight":
			if (panel.entries[panel.current]?.children) activate(level, panel.current);
			break;
		case "ArrowLeft":
			if (level > 0) truncate(level - 1);
			break;
		case "Enter":
		case " ":
			activate(level, panel.current);
			break;
		case "Tab":
			break;
		default:
			return;
		}
		event.preventDefault();
		event.stopPropagation();
	};

	root.addEventListener("pointerdown", event => {
		if (event.target === root) close();
	});
	root.addEventListener("contextmenu", event => {
		event.preventDefault();
		if (event.target === root) close();
	});
	root.addEventListener("wheel", event => {
		if (event.target === root) close();
	}, { passive: true });
	layer().appendChild(root);
	const first = buildPanel(clean, 0);
	place(first, x, y);
	if (options.keyboard) setCurrent(0, clean.findIndex(usable));
	document.addEventListener("keydown", onKey, true);
	openMenu = { close };
	return openMenu;
}

// on a phone the menu is a sheet from below; submenus slide in
function showSheetMenu(entries, options) {
	const stack = [{ title: options.title || "", entries }];
	const body = h("div.sheet-menu");
	let sheet;
	const render = (direction = 0) => {
		const top = stack[stack.length - 1];
		const list = h("div.sheet-list");
		if (stack.length > 1) {
			list.appendChild(h("div.menu-row.back", { onclick: () => {
				stack.pop();
				render(-1);
			} }, icon("chevron_left"), h("span.label", top.title)));
		}
		for (const entry of top.entries) {
			if (entry.separator) {
				list.appendChild(h("div.menu-sep"));
				continue;
			}
			if (entry.header) {
				list.appendChild(h("div.menu-header", entry.header));
				continue;
			}
			const row = h("div.menu-row", { class: [entry.danger ? "danger" : "", entry.enabled === false ? "disabled" : ""].join(" ") },
				icon(entry.checked === true ? "check" : entry.icon || ""),
				h("span.label", entry.label),
				entry.children ? icon("chevron_right", "tail") : null);
			row.addEventListener("click", async () => {
				if (entry.enabled === false) return;
				if (entry.children) {
					row.classList.add("loading");
					const children = await resolveChildren(entry);
					row.classList.remove("loading");
					if (!children.length) return;
					stack.push({ title: entry.label, entries: children });
					render(1);
					return;
				}
				sheet.close();
				if (typeof entry.run === "function") setTimeout(() => entry.run(), 0);
			});
			list.appendChild(row);
		}
		clear(body).appendChild(list);
		if (direction) animate(list, [{ opacity: 0, transform: `translateX(${direction * 40}px)` }, { opacity: 1, transform: "none" }], { duration: DUR.long, easing: EASE.spatial, fill: "none" });
	};
	render();
	sheet = openDialog({ body, sheet: true, className: "menu-sheet", onClose: options.onClose });
	openMenu = { close: () => sheet.close() };
	return openMenu;
}

// ── dialogs ────────────────────────────────────────────────────────────────
const dialogs = [];

export function openDialog({ title, subtitle, icon: iconName, tone, body, actions = [], wide = false, className = "", origin, sheet, dismissable = true, onClose } = {}) {
	const mobile = sheet || isMobile();
	const scrim = h("div.dialog-scrim");
	const box = h(`div.dialog${mobile ? ".sheet" : ""}${wide ? ".wide" : ""}${className ? "." + className.split(" ").join(".") : ""}`, { role: "dialog", "aria-modal": "true" });
	if (title) {
		box.appendChild(h("div.dialog-head",
			iconName ? h("div.dialog-icon", { style: tone ? { color: tone, background: `color-mix(in srgb, ${tone} 16%, transparent)` } : null }, icon(iconName)) : null,
			h("div.dialog-titles", h("h2", title), subtitle ? h("div.subtle", subtitle) : null),
			dismissable ? h("button.icon-btn.small.dialog-x", { title: "Close", onclick: () => api.close() }, icon("close")) : null));
	}
	if (mobile) box.prepend(h("div.sheet-grip"));
	const content = h("div.dialog-body");
	if (body) content.appendChild(body);
	box.appendChild(content);
	const footer = h("div.dialog-actions");
	const buttons = actions.map(action => {
		const button = h(`button.btn${action.primary ? ".primary" : ""}${action.danger ? ".danger" : ""}${action.ghost ? ".ghost" : ""}`, { type: "button" }, action.icon ? icon(action.icon) : null, action.label);
		button.addEventListener("click", async () => {
			if (button.classList.contains("busy")) return;
			if (!action.run) {
				api.close(action.value);
				return;
			}
			button.classList.add("busy");
			try {
				const result = await action.run(api);
				if (result !== false) api.close(action.value ?? result);
			} catch (error) {
				toast(error.message || String(error), { tone: "bad", icon: "alert_circle_outline" });
			} finally {
				button.classList.remove("busy");
			}
		});
		action.el = button;
		footer.appendChild(button);
		return button;
	});
	if (actions.length) box.appendChild(footer);
	const wrap = h("div.dialog-wrap", scrim, box);
	layer().appendChild(wrap);

	let resolve;
	const done = new Promise(r => (resolve = r));
	let closed = false;
	const api = {
		el: box,
		body: content,
		buttons,
		done,
		close(value) {
			if (closed) return;
			closed = true;
			const i = dialogs.indexOf(api);
			if (i >= 0) dialogs.splice(i, 1);
			wrap.style.pointerEvents = "none";
			animate(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.medium });
			const out = mobile
				? [{ transform: "none" }, { transform: "translateY(100%)" }]
				: [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.94)" }];
			animate(box, out, { duration: mobile ? DUR.long : DUR.medium, easing: EASE.accel }).finished.finally(() => wrap.remove());
			onClose?.(value);
			resolve(value);
		}
	};
	dialogs.push(api);
	scrim.addEventListener("click", () => dismissable && api.close());
	// Enter in a one-line field means the main button
	box.addEventListener("keydown", event => {
		if (event.key !== "Enter" || event.defaultPrevented || event.isComposing) return;
		if (!(event.target instanceof HTMLInputElement) || event.target.type === "checkbox") return;
		const primary = buttons.find(b => b.classList.contains("primary")) || buttons.find(b => b.classList.contains("danger"));
		if (!primary || box.querySelector("[data-own-enter]") === event.target) return;
		event.preventDefault();
		primary.click();
	});

	// bloom from where it was asked for
	const at = origin === undefined ? pointer : origin;
	animate(scrim, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.long, fill: "none" });
	if (mobile) {
		animate(box, [{ transform: "translateY(100%)" }, { transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });
		installSheetDrag(box, api);
	} else {
		const rect = box.getBoundingClientRect();
		if (at && at.x !== undefined) box.style.transformOrigin = `${at.x - rect.left}px ${at.y - rect.top}px`;
		animate(box, [{ transform: "scale(0.82)" }, { transform: "scale(1)" }], { duration: DUR.spring + 80, easing: EASE.spring, fill: "none" });
		animate(box, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.medium, fill: "none" });
	}
	setTimeout(() => {
		const focus = box.querySelector("[autofocus], input:not([type=hidden]), select, textarea, .btn.primary");
		focus?.focus?.();
		if (focus?.select && focus.dataset.selectBase !== undefined) {
			const v = focus.value;
			const dot = v.lastIndexOf(".");
			focus.setSelectionRange(0, dot > 0 ? dot : v.length);
		}
	}, 30);
	return api;
}

function installSheetDrag(box, api) {
	const grip = box.querySelector(".sheet-grip");
	if (!grip) return;
	let startY = 0;
	let dy = 0;
	let dragging = false;
	grip.addEventListener("pointerdown", event => {
		dragging = true;
		startY = event.clientY;
		grip.setPointerCapture(event.pointerId);
		box.style.transition = "none";
	});
	grip.addEventListener("pointermove", event => {
		if (!dragging) return;
		dy = Math.max(0, event.clientY - startY);
		box.style.transform = `translateY(${dy}px)`;
	});
	const end = () => {
		if (!dragging) return;
		dragging = false;
		box.style.transition = "";
		if (dy > 90) api.close();
		else box.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], { duration: DUR.long, easing: EASE.spring });
		box.style.transform = "";
		dy = 0;
	};
	grip.addEventListener("pointerup", end);
	grip.addEventListener("pointercancel", end);
}

export function closeAll() {
	closeMenu();
	[...dialogs].reverse().forEach(d => d.close());
}

export function topDialog() {
	return dialogs[dialogs.length - 1] ?? null;
}

document.addEventListener("keydown", event => {
	if (event.key !== "Escape" || openMenu) return;
	const top = topDialog();
	if (top) {
		event.preventDefault();
		event.stopPropagation();
		top.close();
	}
}, true);

// ── confirm, prompt, form ──────────────────────────────────────────────────
export function confirm({ title, body, confirmLabel = "OK", danger = false, icon: iconName, typeToConfirm, details } = {}) {
	const content = h("div.confirm-body");
	if (body) content.appendChild(typeof body === "string" ? h("p", body) : body);
	if (details?.length) content.appendChild(h("ul.confirm-list", details.slice(0, 8).map(d => h("li.ellipsis", d)), details.length > 8 ? h("li.subtle", `and ${details.length - 8} more`) : null));
	let input = null;
	if (typeToConfirm) {
		input = h("input", { placeholder: typeToConfirm, autocomplete: "off", spellcheck: false });
		content.appendChild(h("label.form-row", h("span", `Type “${typeToConfirm}” to go on`), h("div.field", input)));
	}
	return new Promise(resolve => {
		let ok = false;
		const dialog = openDialog({
			title,
			icon: iconName || (danger ? "alert_outline" : "help_circle_outline"),
			tone: danger ? "var(--danger)" : undefined,
			body: content,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: confirmLabel, primary: !danger, danger, run: () => {
					if (input && input.value.trim() !== typeToConfirm) {
						input.parentElement.classList.add("invalid");
						shake(input.parentElement);
						return false;
					}
					ok = true;
				} }
			],
			onClose: () => resolve(ok)
		});
		if (danger && input) dialog.buttons[1].classList.add("solid");
	});
}

export function prompt({ title, label, value = "", placeholder = "", confirmLabel = "OK", icon: iconName, selectBase = false, hint } = {}) {
	const input = h("input", { value, placeholder, autocomplete: "off", spellcheck: false });
	if (selectBase) input.dataset.selectBase = "";
	const content = h("div.form", h("label.form-row", label ? h("span", label) : null, h("div.field", input), hint ? h("span.form-hint", hint) : null));
	return new Promise(resolve => {
		let out = null;
		const dialog = openDialog({
			title,
			icon: iconName,
			body: content,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: confirmLabel, primary: true, run: () => {
					if (!input.value.trim()) {
						shake(input.parentElement);
						return false;
					}
					out = input.value.trim();
				} }
			],
			onClose: () => resolve(out)
		});
	});
}

// fields: [{ key, label, type: choice|text|number|bool|password|textarea|info, choices, default, hint, min, max, placeholder, shown(values) }]
export function buildForm(fields, values = {}) {
	const state = {};
	const rows = [];
	const form = h("div.form");
	const refresh = () => {
		for (const row of rows) if (row.field.shown) row.el.hidden = !row.field.shown(state);
	};
	for (const field of fields) {
		const initial = values[field.key] ?? field.default ?? (field.type === "bool" ? false : field.type === "choice" ? choiceValue(field.choices?.[0]) : "");
		state[field.key] = initial;
		let control;
		const set = v => {
			state[field.key] = v;
			refresh();
			field.onChange?.(v, state);
		};
		switch (field.type) {
		case "bool": {
			const toggle = h("button.toggle", { type: "button", class: initial ? "on" : "", role: "switch", "aria-checked": String(!!initial) });
			toggle.addEventListener("click", () => {
				const on = !toggle.classList.contains("on");
				toggle.classList.toggle("on", on);
				toggle.setAttribute("aria-checked", String(on));
				set(on);
			});
			const row = h("div.form-switch", h("div", h("div.form-switch-label", field.label), field.hint ? h("div.form-hint", field.hint) : null), toggle);
			rows.push({ field, el: row });
			form.appendChild(row);
			continue;
		}
		case "choice": {
			const choices = (field.choices || []).map(c => ({ value: choiceValue(c), label: choiceLabel(c) }));
			if (choices.length <= 4 && choices.every(c => String(c.label).length < 14) && !field.select) {
				control = segmented(choices, initial, set);
			} else {
				const select = h("select", choices.map(c => h("option", { value: c.value, selected: String(c.value) === String(initial) }, c.label)));
				select.addEventListener("change", () => set(choices.find(c => String(c.value) === select.value)?.value ?? select.value));
				control = h("div.field", select, icon("chevron_down"));
			}
			break;
		}
		case "textarea": {
			const area = h("textarea", { placeholder: field.placeholder || "", rows: 4 });
			area.value = initial ?? "";
			area.addEventListener("input", () => set(area.value));
			control = h("div.field.area", area);
			break;
		}
		case "info":
			control = h("div.form-info", field.text || "");
			break;
		default: {
			const input = h("input", {
				type: field.type === "number" ? "number" : field.type === "password" ? "password" : "text",
				placeholder: field.placeholder || "",
				min: field.min,
				max: field.max,
				step: field.step,
				autocomplete: field.type === "password" ? "new-password" : "off",
				spellcheck: false
			});
			input.value = initial ?? "";
			input.addEventListener("input", () => set(field.type === "number" ? (input.value === "" ? "" : Number(input.value)) : input.value));
			control = h("div.field", field.icon ? icon(field.icon) : null, input, field.suffix ? h("span.subtle", field.suffix) : null);
		}
		}
		const row = h("label.form-row", field.label ? h("span", field.label) : null, control, field.hint && field.type !== "bool" ? h("span.form-hint", field.hint) : null);
		rows.push({ field, el: row });
		form.appendChild(row);
	}
	refresh();
	return { el: form, values: state };
}

export function choiceValue(c) {
	return c && typeof c === "object" ? (c.value ?? c.key ?? c.id) : c;
}

const LANGS = { en: "English", de: "German", fr: "French", es: "Spanish", it: "Italian", nl: "Dutch", pl: "Polish", pt: "Portuguese", ru: "Russian", uk: "Ukrainian", tr: "Turkish", ja: "Japanese", zh: "Chinese", ko: "Korean", ar: "Arabic", sv: "Swedish", da: "Danish", cs: "Czech" };
const WORDS = { pc_or_pi: "PC or Pi", pdfa: "PDF/A", ocr: "OCR", totext: "To text", toimages: "To pictures", tooffice: "To Word", imagesout: "Pictures out", fromimages: "From pictures", officetopdf: "Office to PDF", htmltopdf: "HTML to PDF", pagenumbers: "Page numbers", "tar.gz": "tar.gz", "7z": "7z", zip: "ZIP" };

export function choiceLabel(c) {
	if (c && typeof c === "object") return c.label ?? c.name ?? String(c.value);
	const text = String(c);
	if (LANGS[text]) return LANGS[text];
	if (WORDS[text]) return WORDS[text];
	if (/^\d+$/.test(text)) return text;
	if (/^[a-z0-9]{2,5}$/.test(text) && /^(mp4|webm|mkv|gif|mp3|m4a|ogg|opus|flac|wav|jpg|png|webp|avif|heic|jxl|bmp|tiff|ico|pdf)$/.test(text)) return text.toUpperCase();
	return text.charAt(0).toUpperCase() + text.slice(1).replace(/_/g, " ");
}

export function formDialog({ title, subtitle, icon: iconName, fields, values, confirmLabel = "Start", intro, wide } = {}) {
	const form = buildForm(fields, values);
	const body = h("div", intro ? h("p.dialog-intro", intro) : null, form.el);
	return new Promise(resolve => {
		let out = null;
		openDialog({
			title,
			subtitle,
			icon: iconName,
			body,
			wide,
			actions: [
				{ label: "Cancel", ghost: true },
				{ label: confirmLabel, primary: true, run: () => {
					out = { ...form.values };
				} }
			],
			onClose: () => resolve(out)
		});
	});
}

// ── segmented control with a sliding thumb ─────────────────────────────────
export function segmented(choices, value, onChange, { icons = false } = {}) {
	const el = h("div.segmented", { role: "tablist" });
	const thumb = h("span.thumb");
	el.appendChild(thumb);
	const buttons = choices.map(choice => {
		const b = h("button", { type: "button", role: "tab", title: choice.title || "" }, choice.icon ? icon(choice.icon) : null, icons && choice.icon ? null : choice.label);
		b.addEventListener("click", () => {
			select(choice.value);
			onChange?.(choice.value);
		});
		el.appendChild(b);
		return b;
	});
	const select = v => {
		el.dataset.value = v;
		buttons.forEach((b, i) => b.classList.toggle("on", String(choices[i].value) === String(v)));
		requestAnimationFrame(() => {
			const on = buttons.find(b => b.classList.contains("on"));
			if (!on) {
				thumb.style.width = "0";
				return;
			}
			thumb.style.width = `${on.offsetWidth}px`;
			thumb.style.transform = `translateX(${on.offsetLeft - 3}px)`;
			thumb.style.left = "3px";
		});
	};
	el.select = select;
	select(value);
	// a first layout after fonts load
	document.fonts?.ready.then(() => select(el.dataset.value));
	new ResizeObserver(() => select(el.dataset.value)).observe(el);
	return el;
}

export function toggle(on, onChange) {
	const el = h("button.toggle", { type: "button", role: "switch", class: on ? "on" : "", "aria-checked": String(!!on) });
	el.addEventListener("click", event => {
		event.stopPropagation();
		const next = !el.classList.contains("on");
		const result = onChange?.(next);
		if (result === false) return;
		el.classList.toggle("on", next);
		el.setAttribute("aria-checked", String(next));
	});
	el.set = v => {
		el.classList.toggle("on", !!v);
		el.setAttribute("aria-checked", String(!!v));
	};
	return el;
}

export function shake(el) {
	animate(el, [
		{ transform: "translateX(0)" },
		{ transform: "translateX(-8px)" },
		{ transform: "translateX(7px)" },
		{ transform: "translateX(-5px)" },
		{ transform: "translateX(3px)" },
		{ transform: "translateX(0)" }
	], { duration: 380, easing: "ease-out", fill: "none" });
}

// ── snackbars (Snackbar.qml): slide in from below, stack, leave by themselves
export function toast(text, { icon: iconName, tone, action, timeout = 4200, body, progress } = {}) {
	const host = document.getElementById("toasts") || document.body;
	const el = h(`div.toast${tone ? "." + tone : ""}`, { role: "status" },
		iconName ? icon(iconName) : null,
		h("div.toast-text", h("div.toast-title", text), body ? h("div.toast-body", body) : null),
		action ? h("button.btn.small.ghost.toast-action", { onclick: () => {
			action.run();
			dismiss();
		} }, action.label) : null,
		h("button.icon-btn.small", { onclick: () => dismiss(), title: "Close" }, icon("close")));
	const bar = progress !== undefined ? h("div.toast-progress", h("i")) : null;
	if (bar) el.appendChild(bar);
	host.appendChild(el);
	animate(el, [{ opacity: 0, transform: "translateY(24px) scale(0.96)" }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });
	let timer = timeout ? setTimeout(() => dismiss(), timeout) : 0;
	el.addEventListener("pointerenter", () => clearTimeout(timer));
	el.addEventListener("pointerleave", () => {
		if (timeout) timer = setTimeout(() => dismiss(), 1800);
	});
	let gone = false;
	function dismiss() {
		if (gone) return;
		gone = true;
		clearTimeout(timer);
		const height = el.offsetHeight;
		animate(el, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(40px) scale(0.96)" }], { duration: DUR.medium, easing: EASE.accel }).finished.then(() => {
			el.style.overflow = "hidden";
			animate(el, [{ height: `${height}px`, marginTop: getComputedStyle(el).marginTop }, { height: "0px", marginTop: "0px", paddingTop: "0px", paddingBottom: "0px" }], { duration: DUR.short }).finished.then(() => el.remove());
		});
	}
	return {
		el,
		dismiss,
		update(next) {
			if (next.text) el.querySelector(".toast-title").textContent = next.text;
			if (next.progress !== undefined && bar) bar.firstChild.style.width = `${Math.round(next.progress * 100)}%`;
		}
	};
}

export function errorToast(error, prefix) {
	if (error?.name === "AbortError") return;
	toast(prefix ? `${prefix}: ${error.message || error}` : error.message || String(error), { tone: "bad", icon: "alert_circle_outline", timeout: 6500 });
}

// a small popover anchored to an element (view options, the jobs tray)
export function popover(anchor, content, { align = "end", className = "", onClose } = {}) {
	const root = h("div.menu-layer");
	const box = h(`div.popover${className ? "." + className : ""}`, content);
	root.appendChild(box);
	layer().appendChild(root);
	const rect = anchor.getBoundingClientRect();
	const w = box.offsetWidth;
	let left = align === "end" ? rect.right - w : rect.left;
	left = Math.max(8, Math.min(innerWidth - w - 8, left));
	let top = rect.bottom + 8;
	if (top + box.offsetHeight > innerHeight - 8) top = Math.max(8, rect.top - box.offsetHeight - 8);
	box.style.left = `${left}px`;
	box.style.top = `${top}px`;
	box.style.maxHeight = `${innerHeight - top - 12}px`;
	box.style.transformOrigin = `${rect.left + rect.width / 2 - left}px ${top > rect.top ? 0 : box.offsetHeight}px`;
	animate(box, [{ opacity: 0, transform: "scale(0.9) translateY(-6px)" }, { opacity: 1, transform: "none" }], { duration: DUR.spring, easing: EASE.spring, fill: "none" });
	let closed = false;
	const close = () => {
		if (closed) return;
		closed = true;
		document.removeEventListener("keydown", onKey, true);
		animate(box, [{ opacity: 1 }, { opacity: 0, transform: "scale(0.96)" }], { duration: DUR.short, easing: EASE.accel }).finished.then(() => root.remove());
		onClose?.();
	};
	const onKey = event => {
		if (event.key === "Escape") {
			event.stopPropagation();
			close();
		}
	};
	document.addEventListener("keydown", onKey, true);
	root.addEventListener("pointerdown", event => event.target === root && close());
	return { close, el: box };
}

export function tooltip(el, text) {
	el.setAttribute("title", text);
	return el;
}

export { glyph, reduced };
