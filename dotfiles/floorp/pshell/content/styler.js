// The page style editor (docs/browser.md, "Page styles"), put into a page by
// background/styles.js when asked for (Restyle page, Alt+Shift+S); a second
// time closes it.
//
// Pick an element, see the page's rules for it and change any value, give
// its text, background, border or fill one of the shell's colours, or let
// Auto map the colours of a simple page onto the shell's. Every change is
// written into the style of this site as plain CSS with the shell's colours
// as var(--pshell-…), so the page follows the shell's colours from then on.

(() => {
	if (window.pshellStyler) {
		if (window.pshellFollowOnly) {
			window.pshellFollowOnly = false;
			window.pshellStyler.follow();
		} else window.pshellStyler.toggle();
		return;
	}

	const send = (op, data) => browser.runtime.sendMessage(Object.assign({ pshell: "styles", op }, data || {}));

	// ── CSS text: blocks found without losing the author's comments ─────────
	// parse(text) → [{ prelude, start, open, close, children }] (open/close:
	// the braces' positions); declarations of a block without nested blocks
	function parse(text) {
		const top = [];
		const stack = [{ children: top }];
		let preludeStart = 0;
		let quote = "";
		for (let i = 0; i < text.length; i++) {
			const c = text[i];
			if (quote) {
				if (c === "\\") i++;
				else if (c === quote) quote = "";
				continue;
			}
			if (c === "/" && text[i + 1] === "*") {
				const end = text.indexOf("*/", i + 2);
				i = end < 0 ? text.length : end + 1;
				continue;
			}
			if (c === "\"" || c === "'") quote = c;
			else if (c === "{") {
				const block = { prelude: clean(text.slice(preludeStart, i)), start: preludeStart, open: i, close: -1, children: [] };
				stack[stack.length - 1].children.push(block);
				stack.push(block);
				preludeStart = i + 1;
			} else if (c === "}") {
				if (stack.length > 1) stack.pop().close = i;
				preludeStart = i + 1;
			} else if (c === ";") preludeStart = i + 1;
		}
		return top;
	}

	function clean(prelude) {
		return prelude.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\s+/g, " ").trim();
	}

	function sameSelector(a, b) {
		const norm = s => clean(s).split(",").map(part => part.trim().replace(/\s*([>+~])\s*/g, "$1")).join(",");
		return norm(a) === norm(b);
	}

	function declarationsOf(body) {
		const out = [];
		let depth = 0;
		let quote = "";
		let start = 0;
		for (let i = 0; i <= body.length; i++) {
			const c = body[i];
			if (i < body.length) {
				if (quote) {
					if (c === "\\") i++;
					else if (c === quote) quote = "";
					continue;
				}
				if (c === "/" && body[i + 1] === "*") {
					const end = body.indexOf("*/", i + 2);
					i = end < 0 ? body.length - 1 : end + 1;
					continue;
				}
				if (c === "\"" || c === "'") quote = c;
				else if (c === "(") depth++;
				else if (c === ")") depth--;
			}
			if (i === body.length || (c === ";" && depth === 0)) {
				const raw = body.slice(start, i);
				const text = clean(raw);
				const colon = text.indexOf(":");
				if (colon > 0) {
					const value = text.slice(colon + 1).trim();
					out.push({
						prop: text.slice(0, colon).trim().toLowerCase(),
						value: value.replace(/\s*!\s*important$/i, ""),
						start,
						end: Math.min(i + 1, body.length)
					});
				}
				start = i + 1;
			}
		}
		return out;
	}

	// the style rule for `selector` under `path` (at-rule preludes), made when missing
	function findRule(text, path, selector) {
		let blocks = parse(text);
		let parent = null;
		for (const prelude of path) {
			parent = blocks.find(block => block.close >= 0 && clean(block.prelude) === clean(prelude));
			if (!parent) return null;
			blocks = parent.children;
		}
		return blocks.find(block => block.close >= 0 && block.children.length === 0 && sameSelector(block.prelude, selector)) || null;
	}

	function setDeclaration(text, path, selector, prop, value) {
		const rule = findRule(text, path, selector);
		if (!rule) {
			if (value === null) return text;
			let block = `${selector} {\n\t${prop}: ${value};\n}`;
			for (const prelude of [...path].reverse()) block = `${prelude} {\n${block.replace(/^/gm, "\t")}\n}`;
			return `${text.replace(/\s*$/, "")}${text.trim() ? "\n\n" : ""}${block}\n`;
		}
		const bodyStart = rule.open + 1;
		const body = text.slice(bodyStart, rule.close);
		const found = declarationsOf(body).filter(declaration => declaration.prop === prop);
		let next = body;
		if (value === null) {
			for (const declaration of found.reverse()) {
				next = next.slice(0, declaration.start).replace(/[ \t]*$/, "") + next.slice(declaration.end).replace(/^[ \t]*\n?/, "");
			}
			if (!declarationsOf(next).length) {
				const end = text[rule.close + 1] === "\n" ? rule.close + 2 : rule.close + 1;
				return (text.slice(0, rule.start).replace(/\s*$/, "") + "\n" + text.slice(end)).replace(/^\n+/, "");
			}
		} else if (found.length) {
			const last = found[found.length - 1];
			const indent = (body.slice(last.start).match(/^\s*/) || [""])[0];
			next = `${body.slice(0, last.start)}${indent}${prop}: ${value};${body.slice(last.end).startsWith("\n") || last.end >= body.length ? "" : " "}${body.slice(last.end)}`;
		} else {
			const indent = path.length ? "\t".repeat(path.length + 1) : "\t";
			const trimmed = body.replace(/\s*$/, "");
			const glue = trimmed.trim() && !/;\s*$/.test(trimmed) ? ";" : "";
			next = `${trimmed}${glue}\n${indent}${prop}: ${value};\n${"\t".repeat(path.length)}`;
		}
		return text.slice(0, bodyStart) + next + text.slice(rule.close);
	}

	// every style rule of a style's text with its at-rule path
	function rulesOf(text) {
		const out = [];
		const walk = (blocks, path) => {
			for (const block of blocks) {
				if (block.close < 0) continue;
				if (block.prelude.startsWith("@")) walk(block.children, [...path, block.prelude]);
				else if (block.children.length === 0) {
					out.push({ selector: block.prelude, path, at: block.open, declarations: declarationsOf(text.slice(block.open + 1, block.close)) });
				}
			}
		};
		walk(parse(text), []);
		return out;
	}

	// ── colours ─────────────────────────────────────────────────────────────
	function rgbOf(value) {
		const m = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)/.exec(value || "");
		if (!m) return null;
		let a = m[4] === undefined ? 1 : parseFloat(m[4]);
		if (m[4] && m[4].endsWith("%")) a /= 100;
		return { r: +m[1], g: +m[2], b: +m[3], a };
	}

	function lightness(c) {
		const lin = v => {
			v /= 255;
			return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
		};
		const y = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
		return Math.cbrt(y); // close to OKLab's L
	}

	function chroma(c) {
		return (Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b)) / 255;
	}

	function hue(c) {
		const r = c.r / 255, g = c.g / 255, b = c.b / 255;
		const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
		if (d === 0) return 0;
		let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
		h *= 60;
		return h < 0 ? h + 360 : h;
	}

	function isColour(value) {
		const v = String(value || "").trim();
		return !!v && !/^(inherit|initial|unset|revert|revert-layer|none|auto)$/i.test(v) && CSS.supports("color", v);
	}

	// ── state ───────────────────────────────────────────────────────────────
	let palette = [];
	let dark = true;
	let allStyles = [];
	let current = null; // the style being edited
	let picked = null;
	let group = []; // Ctrl+click: several elements, the selector what they share
	let selector = "";
	let picking = false;
	let cornering = false; // the corner tool: rounded corners placed with the mouse
	let tab = "element";
	let side = "right";
	let saveDue = null;
	let learnDue = null;
	let model = {}; // what was learned: kind → prop → role (background/styles.js learnedModel)
	let learnedCount = 0;
	let open = true;

	const host = document.createElement("pshell-styler");
	const root = host.attachShadow({ mode: "closed" });
	host.style.cssText = "all: initial !important; position: fixed !important; inset: 0 !important; z-index: 2147483647 !important; pointer-events: none !important; display: block !important;";

	// a constructed sheet: a page's CSP does not reach it (a <style> it would)
	const sheet = new CSSStyleSheet();
	sheet.replaceSync(`
		:host { all: initial; }
		* { box-sizing: border-box; scrollbar-color: var(--layer3) transparent; scrollbar-width: thin; }
		.panel { position: fixed; top: 10px; bottom: 10px; width: 380px; display: flex; flex-direction: column; pointer-events: auto;
			background: var(--bg); color: var(--fg); border-radius: 16px; font: 12.5px/1.4 system-ui, sans-serif;
			box-shadow: 0 0 0 1px var(--outline), 0 18px 50px rgba(0,0,0,.45); overflow: hidden; }
		.panel.right { right: 10px; } .panel.left { left: 10px; }
		.head { display: flex; align-items: center; gap: 4px; padding: 8px; background: var(--layer1); }
		.head select { flex: 1; min-width: 0; }
		button, select, input, textarea { font: inherit; color: inherit; }
		button { all: unset; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 5px;
			height: 28px; padding: 0 10px; border-radius: 9px; font-weight: 600; white-space: nowrap; }
		button:hover { background: var(--layer2); }
		button.on { background: var(--primary); color: var(--onprimary); }
		button.icon { width: 28px; padding: 0; }
		svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
		select, input, textarea { background: var(--layer2); border: 1px solid transparent; border-radius: 8px; padding: 5px 8px; outline: none; }
		select:focus, input:focus, textarea:focus { border-color: var(--primary); }
		.tabs { display: flex; gap: 2px; padding: 0 8px 8px; background: var(--layer1); }
		.tabs button { flex: 1; height: 26px; }
		.body { flex: 1; overflow: auto; padding: 10px; display: flex; flex-direction: column; gap: 12px; }
		.empty { flex: 1; display: grid; place-items: center; }
		.crumbs { display: flex; flex-wrap: wrap; gap: 3px; }
		.crumbs button { height: 22px; padding: 0 7px; font: 500 11px ui-monospace, monospace; background: var(--layer1); border-radius: 6px; }
		.crumbs button.on { background: var(--primary-soft); color: var(--fg); }
		.row { display: flex; align-items: center; gap: 6px; }
		.row input { flex: 1; min-width: 0; font-family: ui-monospace, monospace; font-size: 11.5px; }
		.row input.bad { border-color: var(--danger); }
		.count { font-variant-numeric: tabular-nums; opacity: .6; min-width: 28px; text-align: right; }
		h4 { margin: 0; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; opacity: .55; font-weight: 700; }
		.prop { display: grid; grid-template-columns: 82px 22px 1fr auto; align-items: center; gap: 6px; }
		.prop .name { opacity: .7; }
		.prop .value { font: 11.5px ui-monospace, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
		.chip { width: 22px; height: 22px; border-radius: 7px; box-shadow: inset 0 0 0 1px var(--outline-strong); cursor: pointer;
			background-image: linear-gradient(45deg, #8884 25%, transparent 25% 75%, #8884 75%), linear-gradient(45deg, #8884 25%, transparent 25% 75%, #8884 75%);
			background-size: 8px 8px; background-position: 0 0, 4px 4px; position: relative; }
		.chip > i { position: absolute; inset: 0; border-radius: inherit; }
		.roles { display: grid; grid-template-columns: repeat(9, 1fr); gap: 4px; padding: 6px; background: var(--layer1); border-radius: 10px; }
		.roles .chip { width: 100%; height: 26px; }
		.roles .chip.on { box-shadow: 0 0 0 2px var(--fg); }
		.roles .wide { grid-column: span 9; display: flex; gap: 4px; }
		.roles .wide input { flex: 1; min-width: 0; font: 11.5px ui-monospace, monospace; }
		.rule { background: var(--layer1); border-radius: 10px; padding: 7px 8px; display: flex; flex-direction: column; gap: 2px; }
		.rule.mine { box-shadow: inset 0 0 0 1px var(--primary); }
		.sel { font: 600 11.5px ui-monospace, monospace; color: var(--primary); word-break: break-all; }
		.at { font: 11px ui-monospace, monospace; opacity: .55; }
		.decl { display: flex; align-items: center; gap: 5px; font: 11.5px ui-monospace, monospace; min-height: 20px; }
		.decl .p { opacity: .75; white-space: nowrap; }
		.decl input { flex: 1; min-width: 0; padding: 1px 5px; background: transparent; border-radius: 5px; font: inherit; }
		.decl input:hover { background: var(--layer2); }
		.decl .chip { width: 14px; height: 14px; border-radius: 4px; flex: none; }
		.decl button { height: 18px; width: 18px; padding: 0; border-radius: 5px; opacity: .5; }
		.decl button:hover { opacity: 1; }
		.decl.add input { opacity: .8; }
		.note { opacity: .55; font-size: 11.5px; }
		textarea { flex: 1; min-height: 240px; resize: none; font: 12px/1.5 ui-monospace, monospace; tab-size: 4; white-space: pre; }
		.code { display: flex; flex-direction: column; gap: 8px; flex: 1; }
		.strip { display: flex; gap: 3px; flex-wrap: wrap; }
		.strip .chip { width: 20px; height: 20px; }
		.style { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border-radius: 10px; background: var(--layer1); }
		.style.cur { box-shadow: inset 0 0 0 1px var(--primary); }
		.style .names { flex: 1; min-width: 0; cursor: pointer; }
		.style .names b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
		.style .names span { font-size: 11px; opacity: .55; display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
		.style.off .names { opacity: .45; }
		.toggle { width: 30px; height: 18px; border-radius: 9px; background: var(--layer3); position: relative; padding: 0; flex: none; }
		.toggle::after { content: ""; position: absolute; top: 3px; left: 3px; width: 12px; height: 12px; border-radius: 50%; background: var(--fg); transition: left .12s; }
		.toggle.on { background: var(--primary); }
		.toggle.on::after { left: 15px; background: var(--onprimary); }
		.foot { display: flex; gap: 4px; flex-wrap: wrap; }
		.box { position: fixed; pointer-events: none; border: 1.5px solid var(--primary); background: color-mix(in srgb, var(--primary) 12%, transparent); border-radius: 3px; }
		.box.match { border: 1px dashed var(--primary); background: color-mix(in srgb, var(--primary) 6%, transparent); }
		.box.picked { border-width: 2px; background: color-mix(in srgb, var(--primary) 16%, transparent); }
		.catch { position: fixed; inset: 0; pointer-events: auto; cursor: crosshair; display: none; }
		.catch.on { display: block; }
		.catch.corners { cursor: default; }
		.handle { position: fixed; pointer-events: none; width: 12px; height: 12px; margin: -6px 0 0 -6px; border-radius: 50%;
			border: 2px solid var(--primary); background: var(--bg); }
		.handle.set { background: var(--primary); }
		.handle.near { width: 18px; height: 18px; margin: -9px 0 0 -9px; box-shadow: 0 0 0 3px color-mix(in srgb, var(--primary) 30%, transparent); }
		.alts { display: flex; flex-wrap: wrap; gap: 4px; }
		.alts button { height: 22px; padding: 0 8px; border-radius: 6px; background: var(--layer1); font: 500 11px ui-monospace, monospace; max-width: 100%; overflow: hidden; text-overflow: ellipsis; display: inline-block; line-height: 22px; }
		.alts button.on { background: var(--primary-soft); color: var(--fg); }
		.alts b { opacity: .55; font-weight: 500; margin-left: 5px; }
		.states button { font-family: inherit; font-weight: 600; }
		.field { display: grid; grid-template-columns: 82px minmax(0, 1fr); align-items: center; gap: 4px 6px; }
		.field .name { opacity: .7; }
		.field.set .name { opacity: 1; color: var(--primary); font-weight: 600; }
		.field input { min-width: 0; padding: 3px 7px; font: 11.5px ui-monospace, monospace; }
		.field input::placeholder { color: var(--fg); opacity: .35; }
		.presets { grid-column: 2; display: flex; flex-wrap: wrap; gap: 3px; }
		.presets button { height: 20px; padding: 0 6px; border-radius: 6px; font: 500 10.5px ui-monospace, monospace; background: var(--layer1); }
		.presets button.on { background: var(--primary-soft); color: var(--fg); }
		.tag { position: fixed; pointer-events: none; background: var(--primary); color: var(--onprimary); font: 600 11px ui-monospace, monospace;
			padding: 2px 6px; border-radius: 5px; white-space: nowrap; max-width: 60vw; overflow: hidden; text-overflow: ellipsis; }
		.toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: var(--layer2); padding: 8px 14px; border-radius: 10px; pointer-events: none; }
	`);
	root.adoptedStyleSheets = [sheet];
	root.innerHTML = `<div class="boxes"></div><div class="catch"></div><div class="panel"></div>`;

	const boxes = root.querySelector(".boxes");
	const panel = root.querySelector(".panel");
	const catcher = root.querySelector(".catch");

	const ICONS = {
		pick: "<path d='M4 4l6.5 15 2.2-6.3L19 10.5z'/><path d='M13 13l5 5'/>",
		auto: "<path d='M5 19l9-9'/><path d='M14 4v3M18.5 5.5l-2 2M20 10h-3M12 8l2 2'/>",
		eye: "<path d='M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z'/><circle cx='12' cy='12' r='2.8'/>",
		side: "<rect x='3.5' y='4.5' width='17' height='15' rx='2.5'/><path d='M10 4.5v15'/>",
		close: "<path d='M6 6l12 12M18 6L6 18'/>",
		x: "<path d='M7 7l10 10M17 7L7 17'/>",
		up: "<path d='M12 19V5M6 11l6-6 6 6'/>",
		frame: "<path d='M3.5 4.5h17v15h-17z'/><path d='M3.5 9h4.5a3 3 0 0 0-3 3v7.5M20.5 9H8'/>",
		corner: "<path d='M4 20v-7a9 9 0 0 1 9-9h7'/><circle cx='4' cy='20' r='0.6'/><circle cx='20' cy='4' r='0.6'/>",
		pages: "<path d='M8 3.5h8.5l3 3V17H8z'/><path d='M16.5 3.5v3h3'/><path d='M8 7H4.5v13.5H15V17'/>"
	};
	const icon = name => `<svg viewBox="0 0 24 24">${ICONS[name]}</svg>`;

	function el(tag, props, parent) {
		const node = document.createElement(tag);
		for (const [key, value] of Object.entries(props || {})) {
			if (key === "text") node.textContent = value;
			else if (key === "html") node.innerHTML = value;
			else if (key === "class") node.className = value;
			else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
			else node.setAttribute(key, value);
		}
		if (parent) parent.appendChild(node);
		return node;
	}

	function themePanel() {
		const value = name => (palette.find(role => role.name === name) || {}).value || "";
		const vars = palette.map(role => `--${role.name === "on-primary" ? "onprimary" : role.name}: ${role.value.replace(/var\(--pshell-/g, "var(--")};`).join(" ");
		panel.style.cssText = `${vars} --outline-strong: color-mix(in srgb, ${value("fg")} 22%, transparent); color-scheme: ${dark ? "dark" : "light"};`;
		boxes.style.cssText = vars;
	}

	function toast(text) {
		const node = el("div", { class: "toast", text }, root);
		node.style.cssText = panel.style.cssText;
		setTimeout(() => node.remove(), 1800);
	}

	// ── styles ──────────────────────────────────────────────────────────────
	const pageHost = location.hostname.replace(/^www\./, "");

	async function load() {
		const state = await send("state");
		palette = state.palette;
		dark = state.dark;
		allStyles = state.styles;
		model = state.learned || {};
		learnedCount = state.learnedCount || 0;
		if (!current || !allStyles.some(style => style.id === current.id)) {
			current = allStyles.find(style => style.matches && (style.sites || []).length) || null;
		} else current = allStyles.find(style => style.id === current.id);
		themePanel();
	}

	function draftStyle() {
		return { id: crypto.randomUUID(), name: pageHost || location.href, on: true, sites: pageHost ? [pageHost] : [location.href], css: "", matches: true };
	}

	// every edit goes in at once (the page shows it) and is kept shortly after
	function change(css) {
		if (!current) {
			current = draftStyle();
			allStyles.push(current);
		}
		current.css = css;
		clearTimeout(saveDue);
		saveDue = setTimeout(save, 120);
	}

	async function save() {
		clearTimeout(saveDue);
		if (!current) return;
		const saved = await send("save", { style: current });
		if (saved && saved.gone) {
			allStyles = allStyles.filter(style => style !== current);
			current = null;
			return;
		}
		const index = allStyles.findIndex(style => style.id === saved.id);
		if (index >= 0) allStyles[index] = Object.assign(allStyles[index], { matches: saved.matches });
		if (open) {
			clearTimeout(learnDue);
			learnDue = setTimeout(learn, 1500);
		}
	}

	function cssOf() {
		return current ? current.css : "";
	}

	// ── picking ─────────────────────────────────────────────────────────────
	function stableClass(name) {
		return /^[a-zA-Z_-][\w-]*$/.test(name) && name.length < 40 &&
			!/\d{3,}|^(css|sc|jsx|svelte|emotion|tw|styled)-|^_|__[a-z0-9]{5,}$|[a-z][A-Z].*\d|^(?=[a-z]*\d)[a-z0-9]{6,8}$/.test(name) || /^[a-z]+(-[a-z]+)+$/.test(name);
	}

	function stableId(id) {
		return /^[a-zA-Z][\w-]*$/.test(id) && !/\d{3,}|^(ember|react|radix|headlessui|mui|:)/i.test(id);
	}

	function keyOf(node) {
		const tag = node.localName;
		if (node.id && stableId(node.id)) return `#${CSS.escape(node.id)}`;
		const classes = [...node.classList].filter(stableClass).slice(0, 3);
		if (classes.length) return tag + classes.map(name => `.${CSS.escape(name)}`).join("");
		// no class worth keeping: an attribute that says what it is
		for (const attr of ["data-testid", "data-test", "role", "aria-label", "name", "type"]) {
			const value = node.getAttribute(attr);
			if (value && value.length < 40 && !/\d{4,}/.test(value)) return `${tag}[${attr}="${value.replace(/["\\]/g, "\\$&")}"]`;
		}
		return tag;
	}

	function countOf(sel) {
		const nodes = matchesOf(sel);
		return nodes ? nodes.length : Infinity;
	}

	// exactly this element: up to an ancestor with an id, by position
	function exactFor(node) {
		const parts = [];
		for (let cur = node; cur && cur !== document.documentElement; cur = cur.parentElement) {
			const key = keyOf(cur);
			if (key.startsWith("#") || cur === document.body) {
				parts.unshift(key.startsWith("#") ? key : "body");
				break;
			}
			const same = cur.parentElement ? [...cur.parentElement.children].filter(other => other.localName === cur.localName) : [cur];
			const plain = [key, ...parts].join(" > ");
			parts.unshift(same.length > 1 && countOf(plain) !== 1 ? `${key}:nth-of-type(${same.indexOf(cur) + 1})` : key);
			if (countOf(parts.join(" > ")) === 1) break;
		}
		return parts.join(" > ");
	}

	// what to offer for an element: its kind as narrow as needed to stay
	// near it, the same kind everywhere, and exactly this one
	function choicesFor(node) {
		if (node === document.documentElement || node === document.body) return [node.localName];
		const key = keyOf(node);
		if (key.startsWith("#")) return [key];
		const out = [];
		const plain = key === node.localName;
		if (!plain && countOf(key) <= 25) out.push(key);
		else {
			let chain = key;
			let depth = 0;
			for (let parent = node.parentElement; parent && parent !== document.body && parent !== document.documentElement && depth < 6; parent = parent.parentElement) {
				const parentKey = keyOf(parent);
				if (parentKey === parent.localName) continue;
				depth++;
				chain = `${parentKey} ${chain}`;
				if (countOf(chain) <= (plain ? 8 : 25) || parentKey.startsWith("#")) break;
			}
			if (chain !== key && countOf(chain) <= (plain ? 8 : 25)) out.push(chain);
			if (!plain) out.push(key);
		}
		out.push(exactFor(node));
		return [...new Set(out)].filter(sel => countOf(sel) !== Infinity && (matchesOf(sel) || []).includes(node));
	}

	function selectorFor(node) {
		return choicesFor(node)[0] || node.localName;
	}

	function matchesOf(sel) {
		try {
			return [...document.querySelectorAll(sel)].filter(node => node !== host);
		} catch (error) {
			return null;
		}
	}

	function under(x, y) {
		for (const node of document.elementsFromPoint(x, y)) {
			if (node !== host && !host.contains(node)) return node;
		}
		return null;
	}

	let hovered = null;
	function hover(x, y) {
		const node = under(x, y);
		if (node === hovered) return;
		hovered = node;
		drawBoxes();
	}

	catcher.addEventListener("mousemove", event => {
		if (cornering) cornerMove(event);
		else hover(event.clientX, event.clientY);
	});
	catcher.addEventListener("pointerdown", event => {
		event.preventDefault();
		if (cornering) cornerDown(event);
	});
	catcher.addEventListener("pointerup", event => {
		if (cornering) cornerUp(event);
	});
	catcher.addEventListener("click", event => {
		event.preventDefault();
		if (cornering) return;
		const node = under(event.clientX, event.clientY);
		if (node && (event.ctrlKey || event.metaKey)) {
			addToGroup(node);
			return;
		}
		stopPicking();
		if (node) choose(node);
	});
	catcher.addEventListener("contextmenu", event => {
		event.preventDefault();
		if (cornering) stopCorners();
		else stopPicking();
	});
	// the wheel still scrolls what is under the pointer
	catcher.addEventListener("wheel", event => {
		event.preventDefault();
		// over a corner the wheel goes through the elements that have one there
		if (cornering && corner && corner.list.length > 1) {
			corner.index = (corner.index + (event.deltaY > 0 ? 1 : -1) + corner.list.length) % corner.list.length;
			drawBoxes();
			return;
		}
		let node = under(event.clientX, event.clientY);
		while (node && node !== document.body && node !== document.documentElement) {
			const style = getComputedStyle(node);
			if ((/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight) ||
				(/(auto|scroll)/.test(style.overflowX) && node.scrollWidth > node.clientWidth)) break;
			node = node.parentElement;
		}
		const target = node && node !== document.body && node !== document.documentElement ? node : document.scrollingElement || document.documentElement;
		const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1;
		target.scrollBy(event.deltaX * unit, event.deltaY * unit);
		requestAnimationFrame(() => {
			hovered = null;
			hover(event.clientX, event.clientY);
		});
	}, { passive: false });

	function onKey(event) {
		if (event.key !== "Escape") return;
		event.preventDefault();
		event.stopImmediatePropagation();
		if (cornering) stopCorners();
		else stopPicking();
	}

	function startPicking() {
		if (cornering) stopCorners();
		picking = true;
		catcher.classList.add("on");
		window.addEventListener("keydown", onKey, true);
		render();
	}

	function stopPicking() {
		picking = false;
		hovered = null;
		catcher.classList.remove("on");
		window.removeEventListener("keydown", onKey, true);
		drawBoxes();
		render();
	}

	function choose(node, keepSelector) {
		picked = node;
		group = [];
		if (!keepSelector) selector = selectorFor(node);
		tab = "element";
		render();
		drawBoxes();
	}

	// ── corners ─────────────────────────────────────────────────────────────
	// Pointed at, the elements with a corner near the pointer (the innermost
	// one that shows a surface first; the wheel goes through the others);
	// a click rounds that corner with the shell's radius or takes it away
	// again, dragging inward sets its size (near a shell radius it snaps to it)
	const CORNERS = [["top-left", 1, 1], ["top-right", -1, 1], ["bottom-right", -1, -1], ["bottom-left", 1, -1]];
	const REACH = 18;
	let corner = null; // { list: [{ node, which }], index, x, y }
	let drag = null;

	function startCorners() {
		if (picking) stopPicking();
		cornering = true;
		catcher.classList.add("on", "corners");
		window.addEventListener("keydown", onKey, true);
		render();
	}

	function stopCorners() {
		cornering = false;
		corner = null;
		drag = null;
		catcher.classList.remove("on", "corners");
		window.removeEventListener("keydown", onKey, true);
		drawBoxes();
		render();
	}

	const radiusKey = name => `border${name.replace(/(^|-)(\w)/g, (_, __, c) => c.toUpperCase())}Radius`;

	function cornerPoint(rect, which) {
		const [, sx, sy] = CORNERS[which];
		return [sx > 0 ? rect.left : rect.right, sy > 0 ? rect.top : rect.bottom];
	}

	function shows(node) {
		const style = getComputedStyle(node);
		const bg = rgbOf(style.backgroundColor);
		return (bg && bg.a > 0.1) || style.backgroundImage !== "none" || parseFloat(style.borderTopWidth) > 0 || style.boxShadow !== "none";
	}

	function cornersAt(x, y) {
		const nodes = new Set();
		for (const [dx, dy] of [[0, 0], [-REACH, -REACH], [REACH, -REACH], [-REACH, REACH], [REACH, REACH]]) {
			for (const start of document.elementsFromPoint(x + dx, y + dy)) {
				for (let node = start; node && node !== document.documentElement; node = node.parentElement) {
					if (node === host || host.contains(node)) break;
					nodes.add(node);
				}
			}
		}
		const found = [];
		for (const node of nodes) {
			const rect = node.getBoundingClientRect();
			if (rect.width < 24 || rect.height < 24) continue;
			let best = null;
			CORNERS.forEach((_, which) => {
				const [cx, cy] = cornerPoint(rect, which);
				const d = Math.hypot(x - cx, y - cy);
				if (d <= REACH && (!best || d < best.d)) best = { node, which, d, area: rect.width * rect.height, shows: shows(node) };
			});
			if (best) found.push(best);
		}
		if (!found.length) return [];
		const nearest = Math.min(...found.map(entry => entry.d));
		const list = found.filter(entry => entry.d <= nearest + 3).sort((a, b) => a.area - b.area);
		const first = list.findIndex(entry => entry.shows);
		return first > 0 ? [...list.slice(first), ...list.slice(0, first)] : list;
	}

	function cornerMove(event) {
		if (drag) {
			const [, sx, sy] = CORNERS[drag.which];
			const inward = Math.max((event.clientX - drag.cx) * sx, (event.clientY - drag.cy) * sy, 0);
			if (!drag.moved && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) > 4) {
				drag.moved = true;
				// this style's own value would win over the preview
				const sel = cornerSelector(drag.node);
				const prop = `border-${CORNERS[drag.which][0]}-radius`;
				const mine = mineFor(sel, []);
				if (mine && mine.declarations.some(d => d.prop === prop || d.prop === "border-radius")) {
					const computed = getComputedStyle(drag.node);
					let css = setDeclaration(cssOf(), [], sel, "border-radius", null);
					for (const [name] of CORNERS) css = setDeclaration(css, [], sel, `border-${name}-radius`, name === CORNERS[drag.which][0] ? null : computed[radiusKey(name)]);
					change(css);
				}
			}
			if (!drag.moved) return;
			drag.value = snapRadius(Math.round(inward));
			drag.node.style.setProperty(`border-${CORNERS[drag.which][0]}-radius`, resolveRadius(drag.value), "important");
			drawBoxes();
			return;
		}
		if (corner && Math.hypot(event.clientX - corner.x, event.clientY - corner.y) < 3) return;
		const list = cornersAt(event.clientX, event.clientY);
		corner = list.length ? { list, index: 0, x: event.clientX, y: event.clientY } : null;
		drawBoxes();
	}

	function shellRadii() {
		const root = getComputedStyle(document.documentElement);
		const read = (name, fallback) => parseFloat(root.getPropertyValue(name)) || fallback;
		return [
			["var(--pshell-radius-small)", read("--pshell-radius-small", 6)],
			["var(--pshell-radius-medium)", read("--pshell-radius-medium", 10)],
			["var(--pshell-radius)", read("--pshell-radius", 14)],
			["var(--pshell-radius-large)", read("--pshell-radius-large", 16)]
		];
	}

	function snapRadius(px) {
		if (px < 2) return "0";
		const near = shellRadii().find(([, value]) => Math.abs(value - px) <= 2);
		return near ? near[0] : `${px}px`;
	}

	function resolveRadius(value) {
		const shell = shellRadii().find(([name]) => name === value);
		return shell ? `${shell[1]}px` : value;
	}

	function cornerDown(event) {
		if (!corner) return;
		const { node, which } = corner.list[corner.index];
		const [cx, cy] = cornerPoint(node.getBoundingClientRect(), which);
		drag = { node, which, cx, cy, x: event.clientX, y: event.clientY, moved: false, value: null };
		try {
			catcher.setPointerCapture(event.pointerId);
		} catch (error) {}
	}

	function cornerUp() {
		if (!drag) return;
		const { node, which, moved, value } = drag;
		drag = null;
		node.style.removeProperty(`border-${CORNERS[which][0]}-radius`);
		// a click: the shell's corner, or (set by this style already) none
		const mine = mineFor(cornerSelector(node), []);
		const own = mine && [...mine.declarations].reverse().find(d => d.prop === `border-${CORNERS[which][0]}-radius` || d.prop === "border-radius");
		const set = own && (own.prop === "border-radius" ? parseFloat(getComputedStyle(node)[radiusKey(CORNERS[which][0])]) > 0 : !/^0(px)?$/.test(own.value));
		setCorner(node, which, moved ? value : set ? "0" : "var(--pshell-radius)");
	}

	// big things (a page, a bar) by themselves, smaller ones with their kind
	function cornerSelector(node) {
		const rect = node.getBoundingClientRect();
		return rect.width * rect.height > innerWidth * innerHeight * 0.15 ? exactSelector(node) : selectorFor(node);
	}

	function setCorner(node, which, value) {
		const sel = cornerSelector(node);
		let css = cssOf();
		const mine = mineFor(sel, []);
		// a shorthand of this style's own becomes the four corners
		if (mine && mine.declarations.some(d => d.prop === "border-radius")) {
			const computed = getComputedStyle(node);
			css = setDeclaration(css, [], sel, "border-radius", null);
			for (const [name] of CORNERS) {
				const key = radiusKey(name);
				css = setDeclaration(css, [], sel, `border-${name}-radius`, computed[key]);
			}
		}
		css = setDeclaration(css, [], sel, `border-${CORNERS[which][0]}-radius`, value);
		// what lies inside follows the corner
		const rounded = CORNERS.some(([name], index) => index === which ? value !== "0" : parseFloat(getComputedStyle(node)[radiusKey(name)]) > 0);
		const own = rulesOf(css).find(rule => sameSelector(rule.selector, sel) && !rule.path.length);
		const ownOverflow = own && own.declarations.find(d => d.prop === "overflow");
		if (rounded && !ownOverflow && getComputedStyle(node).overflow === "visible") css = setDeclaration(css, [], sel, "overflow", "clip");
		else if (!rounded && ownOverflow && ownOverflow.value === "clip") css = setDeclaration(css, [], sel, "overflow", null);
		change(css);
		picked = node;
		group = [];
		selector = sel;
		render();
		setTimeout(drawBoxes, 200);
	}

	// Ctrl+click adds an element (again: takes it out); the selector becomes
	// the narrowest one all of them share
	function addToGroup(node) {
		if (!picked || !picked.isConnected) {
			choose(node);
			return;
		}
		if (!group.length) group = [picked];
		if (group.includes(node)) {
			if (group.length > 1) group = group.filter(other => other !== node);
		} else group.push(node);
		picked = group[group.length - 1];
		selector = group.length > 1 ? groupChoices(group)[0] : selectorFor(picked);
		tab = "element";
		render();
		drawBoxes();
	}

	// what an element is made of: its tag, classes worth keeping, attributes
	// (values only when they look like names, not ids)
	const SKIP_ATTRS = /^(class|id|style|href|src|srcset|d|alt|title|value|tabindex|width|height|viewbox|xmlns|loading|decoding|on\w+|aria-(describedby|labelledby|controls|owns|activedescendant|label))$/i;
	function featuresOf(node) {
		const values = {};
		const names = [];
		for (const attr of node.attributes) {
			if (SKIP_ATTRS.test(attr.name) || !/^[\w-]+$/.test(attr.name)) continue;
			names.push(attr.name);
			if (attr.value.length < 40 && !/\d{3,}|[0-9a-f]{8}-/.test(attr.value)) values[attr.name] = attr.value;
		}
		return { tag: node.localName, classes: [...node.classList].filter(stableClass), values, names };
	}

	// one compound selector for what every node has; "" when nothing
	function commonPart(nodes, withTag) {
		const fs = nodes.map(featuresOf);
		const [first] = fs;
		const tag = fs.every(f => f.tag === first.tag) ? first.tag : "";
		const classes = first.classes.filter(name => fs.every(f => f.classes.includes(name))).slice(0, 4);
		const same = Object.keys(first.values).filter(name => fs.every(f => f.values[name] === first.values[name])).slice(0, 3);
		const present = first.names.filter(name => !same.includes(name) && fs.every(f => f.names.includes(name))).slice(0, 2);
		const quote = value => value.replace(/["\\]/g, "\\$&");
		const rest = classes.map(name => `.${CSS.escape(name)}`).join("") +
			same.map(name => `[${name}="${quote(first.values[name])}"]`).join("") +
			present.map(name => `[${name}]`).join("");
		if (!rest && !withTag) return tag;
		return (tag || (rest ? "" : "*")) + rest;
	}

	function groupChoices(nodes) {
		const all = sel => {
			const found = matchesOf(sel);
			return found && nodes.every(node => found.includes(node));
		};
		const out = [];
		const self = commonPart(nodes);
		const specific = self && self !== nodes[0].localName;
		// the nearest ancestor of all of them
		let lca = nodes[0].parentElement;
		while (lca && !nodes.every(node => lca.contains(node))) lca = lca.parentElement;
		// near them: inside the closest ancestor kind they all sit in
		let near = "";
		for (let anc = lca; anc && anc !== document.documentElement; anc = anc.parentElement) {
			const key = anc === document.body ? "" : keyOf(anc);
			if (!key || key === anc.localName) continue;
			near = `${key} ${self || "*"}`;
			break;
		}
		// the same way down from that ancestor, level by level
		let path = "";
		if (lca) {
			const ways = nodes.map(node => {
				const way = [];
				for (let cur = node; cur && cur !== lca; cur = cur.parentElement) way.unshift(cur);
				return way;
			});
			if (ways.every(way => way.length === ways[0].length) && ways[0].length <= 6) {
				const levels = ways[0].map((_, i) => commonPart(ways.map(way => way[i]), true));
				const anchor = lca === document.body ? "body" : (keyOf(lca) !== lca.localName && countOf(keyOf(lca)) <= 3 ? keyOf(lca) : exactSelector(lca));
				path = `${anchor} > ${levels.join(" > ")}`;
			}
		}
		if (near) out.push(near);
		if (specific && countOf(self) <= 80) out.push(self);
		if (path) out.push(path);
		if (self) out.push(self);
		out.push(nodes.map(exactSelector).join(", "));
		return [...new Set(out)].filter(all);
	}

	// ── outlines over the page ──────────────────────────────────────────────
	let boxesDue = 0;
	function drawBoxes() {
		cancelAnimationFrame(boxesDue);
		boxesDue = requestAnimationFrame(() => {
			boxes.textContent = "";
			if (!open) return;
			const add = (node, cls, label) => {
				const r = node.getBoundingClientRect();
				if (r.width === 0 && r.height === 0) return;
				const box = el("div", { class: `box ${cls}` }, boxes);
				box.style.cssText = `left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px`;
				if (label) {
					const tag = el("div", { class: "tag", text: label }, boxes);
					const top = r.top > 22 ? r.top - 20 : r.bottom + 22 < innerHeight ? r.bottom + 2 : Math.max(0, r.top) + 4;
					tag.style.cssText = `left:${Math.max(0, r.left) + (r.top > 22 || r.bottom + 22 < innerHeight ? 0 : 4)}px;top:${top}px`;
				}
			};
			if (cornering) {
				const target = drag ? { node: drag.node, which: drag.which } : corner && corner.list[corner.index];
				if (!target) return;
				const rect = target.node.getBoundingClientRect();
				const many = !drag && corner.list.length > 1 ? `  ${corner.index + 1}/${corner.list.length}` : "";
				add(target.node, "match", drag && drag.moved ? drag.value : `${cornerSelector(target.node)}${many}`);
				const computed = getComputedStyle(target.node);
				CORNERS.forEach(([name], which) => {
					const [x, y] = cornerPoint(rect, which);
					const radius = parseFloat(computed[radiusKey(name)]) || 0;
					const handle = el("div", { class: `handle${radius > 0 ? " set" : ""}${which === target.which ? " near" : ""}` }, boxes);
					handle.style.cssText = `left:${x}px;top:${y}px`;
				});
				return;
			}
			if (picking && hovered && !group.length) add(hovered, "picked", keyOf(hovered));
			else if (picked) {
				const own = group.length ? group : [picked];
				const nodes = (matchesOf(selector) || []).filter(node => !own.includes(node));
				const view = node => {
					const r = node.getBoundingClientRect();
					return r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
				};
				nodes.filter(view).slice(0, 150).forEach(node => add(node, "match", ""));
				for (const node of own) if (node.isConnected) add(node, "picked", "");
				if (picking && hovered && !own.includes(hovered)) add(hovered, "picked", keyOf(hovered));
			}
		});
	}

	window.addEventListener("scroll", drawBoxes, true);
	window.addEventListener("resize", drawBoxes);

	// ── the page's rules for an element ─────────────────────────────────────
	function pageRules(node) {
		const out = [];
		let unreadable = 0;
		const walk = (rules, path) => {
			for (const rule of rules) {
				if (rule.selectorText !== undefined) {
					let hit = false;
					try {
						hit = node.matches(rule.selectorText);
					} catch (error) {}
					if (hit) out.push({ selector: rule.selectorText, path, declarations: declarationsOf(rule.style.cssText) });
					if (rule.cssRules && rule.cssRules.length) walk(rule.cssRules, path);
				} else if (rule.media && rule.cssRules) {
					if (matchMedia(rule.media.mediaText).matches) walk(rule.cssRules, [...path, `@media ${rule.media.mediaText}`]);
				} else if (rule.conditionText !== undefined && rule.cssRules) {
					if (CSS.supports(rule.conditionText)) walk(rule.cssRules, [...path, `@supports ${rule.conditionText}`]);
				} else if (rule.cssRules) walk(rule.cssRules, path);
			}
		};
		for (const sheet of [...document.styleSheets, ...(document.adoptedStyleSheets || [])]) {
			if (sheet.disabled) continue;
			if (sheet.media && sheet.media.mediaText && !matchMedia(sheet.media.mediaText).matches) continue;
			let rules;
			try {
				rules = sheet.cssRules;
			} catch (error) {
				unreadable++;
				continue;
			}
			walk(rules, []);
		}
		out.reverse(); // the later rule first, as it wins
		const inline = node.getAttribute("style");
		if (inline) out.unshift({ selector: "", inline: true, path: [], declarations: declarationsOf(inline) });
		return { rules: out.slice(0, 60), unreadable };
	}

	// ── panel ───────────────────────────────────────────────────────────────
	function render() {
		const scroll = panel.querySelector(".body")?.scrollTop || 0;
		panel.textContent = "";
		panel.className = `panel ${side}`;
		const head = el("div", { class: "head" }, panel);
		const select = el("select", { title: "Style" }, head);
		const here = allStyles.filter(style => style.matches);
		if (!current) el("option", { value: "", text: `New: ${pageHost || "this page"}` }, select);
		for (const style of here) el("option", { value: style.id, text: style.name + (style.on === false ? " (off)" : "") }, select);
		if (current && !here.includes(current)) el("option", { value: current.id, text: current.name }, select);
		select.value = current ? current.id : "";
		select.addEventListener("change", () => {
			current = allStyles.find(style => style.id === select.value) || null;
			render();
		});
		el("button", { class: `icon${picking ? " on" : ""}`, title: "Pick element", html: icon("pick"), onclick: () => (picking ? stopPicking() : startPicking()) }, head);
		el("button", { class: `icon${cornering ? " on" : ""}`, title: "Corners", html: icon("corner"), onclick: () => (cornering ? stopCorners() : startCorners()) }, head);
		el("button", { title: "Map the page's colours onto the shell's", html: `${icon("auto")}Auto`, onclick: auto }, head);
		el("button", {
			class: `icon${current && current.look ? " on" : ""}`,
			title: "Shell look: bars in the frame's colour, the page beside them with the shell's corners",
			html: icon("frame"),
			onclick: () => {
				if (!current) {
					current = draftStyle();
					allStyles.push(current);
				}
				current.look = !current.look;
				// what Auto made follows at once; without it Auto runs now
				auto();
			}
		}, head);
		el("button", {
			class: `icon${current && current.follow ? " on" : ""}`,
			title: "Colour the site's other pages too",
			html: icon("pages"),
			onclick: async () => {
				if (!current) {
					current = draftStyle();
					allStyles.push(current);
				}
				current.follow = !current.follow;
				if (current.follow && !(current.autoMap && current.css.includes(AUTO_START))) await auto();
				else {
					await save();
					render();
				}
			}
		}, head);
		const compare = el("button", { class: "icon", title: "Hold: page without its styles", html: icon("eye") }, head);
		compare.addEventListener("pointerdown", () => send("suspend", { on: true }));
		for (const name of ["pointerup", "pointerleave"]) compare.addEventListener(name, () => send("suspend", { on: false }));
		el("button", { class: "icon", title: "Other side", html: icon("side"), onclick: () => { side = side === "right" ? "left" : "right"; render(); } }, head);
		el("button", { class: "icon", title: "Close (Alt+Shift+S)", html: icon("close"), onclick: close }, head);

		const tabs = el("div", { class: "tabs" }, panel);
		for (const [key, label] of [["element", "Element"], ["code", "Code"], ["styles", "Styles"]]) {
			el("button", { class: tab === key ? "on" : "", text: label, onclick: () => { tab = key; render(); } }, tabs);
		}
		const body = el("div", { class: "body" }, panel);
		if (tab === "element") renderElement(body);
		else if (tab === "code") renderCode(body);
		else renderStyles(body);
		body.scrollTop = scroll;
	}

	function rolesPicker(parent, currentValue, apply) {
		const grid = el("div", { class: "roles" }, parent);
		for (const role of palette) {
			const chip = el("div", { class: `chip${currentValue === `var(${role.variable})` ? " on" : ""}`, title: role.label }, grid);
			el("i", {}, chip).style.background = `var(${role.variable})`;
			chip.style.cssText = palette.map(r => `${r.variable}: ${r.value};`).join("");
			chip.addEventListener("click", () => apply(`var(${role.variable})`));
		}
		const wide = el("div", { class: "wide" }, grid);
		const custom = el("input", { value: currentValue || "", spellcheck: "false" }, wide);
		custom.addEventListener("keydown", event => {
			if (event.key === "Enter") apply(custom.value.trim() || null);
		});
		el("button", { text: "Set", onclick: () => apply(custom.value.trim() || null) }, wide);
		el("button", { text: "Reset", onclick: () => apply(null) }, wide);
		return grid;
	}

	function swatch(parent, value, cls) {
		const chip = el("div", { class: `chip ${cls || ""}` }, parent);
		const inner = el("i", {}, chip);
		inner.style.cssText = palette.map(role => `${role.variable}: ${role.value};`).join("") + `background: ${value}`;
		return chip;
	}

	const COLOUR_PROPS = [
		["color", "Text"],
		["background-color", "Background"],
		["border-color", "Border"],
		["outline-color", "Outline"],
		["fill", "Fill"],
		["stroke", "Stroke"]
	];
	let openRole = "";

	function mineFor(sel, path) {
		return rulesOf(cssOf()).find(rule => sameSelector(rule.selector, sel) && rule.path.join("|") === path.join("|"));
	}

	// the state edits go to: the selector as it is, or each part of it with
	// :hover, :focus-visible, :active … appended
	const STATES = [["", "Normal"], [":hover", "Hover"], [":focus-visible", "Focus"], [":active", "Active"], ["::placeholder", "Placeholder"]];
	const STATE_RE = /:(hover|focus|focus-visible|focus-within|active|visited)\b|::placeholder/g;
	let state = "";

	function splitSelectors(sel) {
		const out = [];
		let depth = 0;
		let start = 0;
		for (let i = 0; i < sel.length; i++) {
			const c = sel[i];
			if (c === "(" || c === "[") depth++;
			else if (c === ")" || c === "]") depth--;
			else if (c === "," && depth === 0) {
				out.push(sel.slice(start, i).trim());
				start = i + 1;
			}
		}
		out.push(sel.slice(start).trim());
		return out.filter(Boolean);
	}

	function withState(sel) {
		return state ? splitSelectors(sel).map(part => part + state).join(", ") : sel;
	}

	function stateless(sel) {
		return sel.replace(STATE_RE, "");
	}

	// ↑/↓ in a value: the number under the caret by 1 (Shift 10, Alt 0.1)
	function bump(input, event) {
		const text = input.value;
		const caret = input.selectionStart ?? text.length;
		const numbers = [...text.matchAll(/-?\d*\.?\d+/g)];
		if (!numbers.length) return false;
		const hit = numbers.find(m => caret >= m.index && caret <= m.index + m[0].length) || numbers[0];
		const step = (event.shiftKey ? 10 : event.altKey ? 0.1 : 1) * (event.key === "ArrowUp" ? 1 : -1);
		const next = String(Math.round((parseFloat(hit[0]) + step) * 100) / 100);
		input.value = text.slice(0, hit.index) + next + text.slice(hit.index + hit[0].length);
		input.setSelectionRange(hit.index + next.length, hit.index + next.length);
		return true;
	}

	const PROPS = [
		["Spacing", [
			["padding", "Padding", ["0", "4px", "8px", "12px 16px"]],
			["margin", "Margin", ["0", "8px", "16px", "auto"]],
			["gap", "Gap", ["0", "4px", "8px", "16px"], computed => /flex|grid/.test(computed.display)],
			["width", "Width", ["auto", "100%", "max-content"]],
			["max-width", "Max width", ["none", "100%", "1200px"]]
		]],
		["Border", [
			["border-width", "Width", ["0", "1px", "2px"]],
			["border-style", "Style", ["none", "solid", "dashed", "dotted"]],
			["border-radius", "Radius", ["0", ["var(--pshell-radius-small)", "small"], ["var(--pshell-radius-medium)", "medium"], ["var(--pshell-radius)", "window"], ["999px", "pill"]]]
		]],
		["Text", [
			["font-size", "Size", ["12px", "14px", "16px", "20px"]],
			["font-weight", "Weight", ["400", "500", "600", "700"]],
			["line-height", "Line", ["1.2", "1.4", "1.6"]],
			["text-decoration", "Decoration", ["none", "underline"]],
			["font-family", "Font", ["inherit", "system-ui", "monospace"]]
		]],
		["Effects", [
			["opacity", "Opacity", ["1", "0.8", "0.6", "0.4"]],
			["box-shadow", "Shadow", ["none", ["0 1px 3px rgb(0 0 0 / .25)", "soft"], ["0 8px 24px rgb(0 0 0 / .35)", "strong"]]],
			["transition", "Transition", ["none", ["all .15s ease", "smooth"]]],
			["cursor", "Cursor", ["pointer", "default"]],
			["display", "Display", ["none", "block", "flex", "inline-block"]]
		]]
	];

	function renderProps(body, computed, target, mine) {
		const own = prop => mine && [...mine.declarations].reverse().find(declaration => declaration.prop === prop);
		for (const [group, props] of PROPS) {
			el("h4", { text: group }, body);
			for (const [prop, label, presets, when] of props) {
				if (when && !when(computed)) continue;
				const mineValue = own(prop);
				const line = el("div", { class: `field${mineValue ? " set" : ""}` }, body);
				el("span", { class: "name", text: label }, line);
				const input = el("input", { value: mineValue ? mineValue.value : "", placeholder: state ? "" : computed.getPropertyValue(prop), spellcheck: "false" }, line);
				const write = value => {
					let css = setDeclaration(cssOf(), [], target, prop, value);
					// a border width shows only with a style
					if (prop === "border-width" && value && value !== "0" && computed.borderTopStyle === "none" && !own("border-style")) {
						css = setDeclaration(css, [], target, "border-style", "solid");
					}
					change(css);
				};
				input.addEventListener("keydown", event => {
					if ((event.key === "ArrowUp" || event.key === "ArrowDown") && bump(input, event)) {
						event.preventDefault();
						write(input.value);
					} else if (event.key === "Enter") input.blur();
					else if (event.key === "Escape") {
						input.value = mineValue ? mineValue.value : "";
						input.blur();
					}
				});
				input.addEventListener("change", () => {
					write(input.value.trim() || null);
					render();
				});
				const chips = el("div", { class: "presets" }, line);
				for (const entry of presets) {
					const [preset, name] = Array.isArray(entry) ? entry : [entry, entry];
					el("button", {
						class: mineValue && mineValue.value === preset ? "on" : "",
						text: name,
						title: preset,
						onclick: () => {
							write(mineValue && mineValue.value === preset ? null : preset);
							render();
						}
					}, chips);
				}
			}
		}
	}

	function renderElement(body) {
		if (!picked || !picked.isConnected) {
			picked = null;
			const empty = el("div", { class: "empty" }, body);
			el("button", { class: picking ? "on" : "", html: `${icon("pick")}Pick element`, onclick: () => (picking ? stopPicking() : startPicking()) }, empty);
			return;
		}
		// the path down to it
		const crumbs = el("div", { class: "crumbs" }, body);
		const chain = [];
		for (let node = picked; node && node.nodeType === 1; node = node.parentElement) chain.unshift(node);
		const chosen = matchesOf(selector) || [];
		for (const node of chain.slice(-6)) {
			el("button", {
				class: chosen.includes(node) ? "on" : "",
				text: keyOf(node),
				title: selectorFor(node),
				onclick: () => { selector = selectorFor(node); picked = node; group = []; render(); drawBoxes(); }
			}, crumbs);
		}

		const row = el("div", { class: "row" }, body);
		const input = el("input", { value: selector, spellcheck: "false", title: "Selector" }, row);
		const count = el("span", { class: "count" }, row);
		const showCount = () => {
			const nodes = matchesOf(input.value);
			input.classList.toggle("bad", nodes === null);
			count.textContent = nodes === null ? "–" : String(nodes.length);
		};
		showCount();
		input.addEventListener("input", () => {
			showCount();
			if (matchesOf(input.value) !== null) {
				selector = input.value;
				drawBoxes();
			}
		});
		input.addEventListener("change", () => render());

		if (group.length > 1 && !group.every(node => node.isConnected)) group = group.filter(node => node.isConnected);
		const choices = group.length > 1 ? groupChoices(group) : choicesFor(picked);
		if (choices.length > 1) {
			const alts = el("div", { class: "alts" }, body);
			for (const choice of choices) {
				const button = el("button", { class: choice === selector ? "on" : "", title: choice, text: choice }, alts);
				el("b", { text: String(countOf(choice)) }, button);
				button.addEventListener("click", () => {
					selector = choice;
					render();
					drawBoxes();
				});
			}
		}

		const states = el("div", { class: "alts states" }, body);
		for (const [suffix, label] of STATES) {
			if (suffix === "::placeholder" && !/^(input|textarea)$/.test(picked.localName)) continue;
			el("button", { class: state === suffix ? "on" : "", text: label, onclick: () => { state = suffix; render(); } }, states);
		}
		const target = withState(selector);

		// colours: the computed value, a shell colour with one click
		el("h4", { text: "Colours" }, body);
		const computed = getComputedStyle(picked, state === "::placeholder" ? "::placeholder" : null);
		const mine = mineFor(target, []);
		const isSvg = picked instanceof SVGElement;
		for (const [prop, label] of COLOUR_PROPS) {
			if ((prop === "fill" || prop === "stroke") && !isSvg) continue;
			const ownWidth = mine && mine.declarations.some(d => /^border(-width)?$/.test(d.prop));
			if (prop === "outline-color" && computed.outlineStyle === "none" && !state) continue;
			if (prop === "border-color" && !ownWidth && !["Top", "Right", "Bottom", "Left"].some(edge => parseFloat(computed[`border${edge}Width`]) > 0)) continue;
			const own = mine && [...mine.declarations].reverse().find(declaration => declaration.prop === prop);
			const shown = own ? own.value : state ? "transparent" : prop === "border-color" ? computed.borderTopColor : computed.getPropertyValue(prop);
			const line = el("div", { class: "prop" }, body);
			el("span", { class: "name", text: label }, line);
			const chip = swatch(line, shown);
			const role = own && palette.find(r => own.value === `var(${r.variable})`);
			el("span", { class: "value", text: role ? role.label : own || !state ? shown : "–", title: shown }, line);
			el("span", {}, line);
			const toggle = () => {
				openRole = openRole === prop ? "" : prop;
				render();
			};
			chip.addEventListener("click", toggle);
			line.querySelector(".value").addEventListener("click", toggle);
			if (openRole === prop) {
				rolesPicker(body, own ? own.value : "", value => {
					openRole = "";
					change(setDeclaration(cssOf(), [], target, prop, value));
					render();
				});
			}
		}

		renderProps(body, computed, target, mine);

		// this style's rules for it, then the page's
		el("h4", { text: "Rules" }, body);
		for (const rule of rulesOf(cssOf())) {
			let hit = false;
			try {
				hit = picked.matches(rule.selector) || picked.matches(stateless(rule.selector));
			} catch (error) {}
			if (hit) ruleCard(body, rule, true);
		}
		const { rules, unreadable } = pageRules(picked);
		for (const rule of rules) ruleCard(body, rule, false);
		if (!rules.length) el("div", { class: "note", text: "No rules" }, body);
		if (unreadable) el("div", { class: "note", text: `${unreadable} sheet${unreadable > 1 ? "s" : ""} not readable` }, body);
	}

	// a rule; a value changed in a page's rule goes into this style under the
	// same selector (inline styles: under the selector above)
	let openDecl = "";
	function ruleCard(body, rule, mine) {
		const card = el("div", { class: `rule${mine ? " mine" : ""}` }, body);
		const target = rule.inline ? selector : rule.selector;
		const path = rule.inline ? [] : rule.path;
		for (const at of path) el("div", { class: "at", text: at }, card);
		el("div", { class: "sel", text: rule.inline ? "style=\"…\"" : rule.selector }, card);
		const own = mine ? rule : mineFor(target, path);
		const write = (prop, value) => change(setDeclaration(cssOf(), path, target, prop, value));
		rule.declarations.forEach((declaration, index) => {
			const id = `${mine}|${path.join("|")}|${target}|${declaration.prop}|${index}`;
			const overridden = !mine && own && own.declarations.some(other => other.prop === declaration.prop);
			const line = el("div", { class: "decl" }, card);
			el("span", { class: "p", text: `${declaration.prop}:` }, line);
			if (isColour(declaration.value) || /var\(/.test(declaration.value) && /colou?r|background|border|fill|stroke|shadow|outline/.test(declaration.prop)) {
				const chip = swatch(line, declaration.value);
				chip.addEventListener("click", () => {
					openDecl = openDecl === id ? "" : id;
					render();
				});
			}
			const value = el("input", { value: declaration.value, spellcheck: "false" }, line);
			if (overridden) value.style.textDecoration = "line-through";
			value.addEventListener("keydown", event => {
				if (event.key === "Enter") value.blur();
				if (event.key === "Escape") {
					value.value = declaration.value;
					value.blur();
				}
			});
			value.addEventListener("change", () => {
				const next = value.value.trim();
				if (next === declaration.value) return;
				write(declaration.prop, next || null);
				render();
			});
			if (mine) {
				el("button", { title: "Remove", html: icon("x"), onclick: () => { write(declaration.prop, null); render(); } }, line);
			}
			if (openDecl === id) {
				rolesPicker(card, mine ? declaration.value : "", next => {
					openDecl = "";
					write(declaration.prop, next);
					render();
				});
			}
		});
		if (mine) {
			const add = el("div", { class: "decl add" }, card);
			const input = el("input", { placeholder: "property: value", spellcheck: "false" }, add);
			input.addEventListener("keydown", event => {
				if (event.key !== "Enter") return;
				const m = /^\s*([-\w]+)\s*:\s*(.+?)\s*;?\s*$/.exec(input.value);
				if (!m) return;
				write(m[1].toLowerCase(), m[2]);
				render();
			});
		}
	}

	function renderCode(body) {
		const box = el("div", { class: "code" }, body);
		const style = current || draftStyle();
		const name = el("input", { value: style.name, placeholder: "Name", spellcheck: "false" }, box);
		const sites = el("input", { value: (style.sites || []).join(", "), placeholder: "Every page", title: "Sites", spellcheck: "false" }, box);
		const strip = el("div", { class: "strip" }, box);
		const area = el("textarea", { spellcheck: "false" }, box);
		area.value = style.css;
		for (const role of palette) {
			const chip = swatch(strip, `var(${role.variable})`);
			chip.title = `${role.label}: var(${role.variable})`;
			chip.addEventListener("mousedown", event => event.preventDefault());
			chip.addEventListener("click", () => {
				area.setRangeText(`var(${role.variable})`, area.selectionStart, area.selectionEnd, "end");
				area.dispatchEvent(new Event("input"));
				area.focus();
			});
		}
		const meta = () => {
			if (!current) {
				current = Object.assign(style, { css: area.value });
				allStyles.push(current);
			}
			current.name = name.value.trim() || pageHost;
			current.sites = sites.value.split(",").map(site => site.trim()).filter(Boolean);
			clearTimeout(saveDue);
			saveDue = setTimeout(save, 200);
		};
		name.addEventListener("input", meta);
		sites.addEventListener("input", meta);
		area.addEventListener("input", () => change(area.value));
		area.addEventListener("keydown", event => {
			if (event.key === "Tab") {
				event.preventDefault();
				area.setRangeText("\t", area.selectionStart, area.selectionEnd, "end");
				change(area.value);
			}
		});
	}

	function renderStyles(body) {
		const sorted = [...allStyles].sort((a, b) => (b.matches - a.matches) || a.name.localeCompare(b.name));
		for (const style of sorted) {
			const row = el("div", { class: `style${style === current ? " cur" : ""}${style.on === false ? " off" : ""}` }, body);
			const toggle = el("button", { class: `toggle${style.on !== false ? " on" : ""}`, title: style.on !== false ? "On" : "Off" }, row);
			toggle.addEventListener("click", async () => {
				style.on = style.on === false;
				await send("save", { style });
				render();
			});
			const names = el("div", { class: "names" }, row);
			el("b", { text: style.name }, names);
			el("span", { text: (style.sites || []).join(", ") || "Every page" }, names);
			names.addEventListener("click", () => {
				current = style;
				tab = "code";
				render();
			});
			el("button", {
				class: "icon",
				title: "Delete",
				html: icon("x"),
				onclick: async () => {
					if (!confirm(`Delete "${style.name}"?`)) return;
					if (current && current.id === style.id) clearTimeout(saveDue);
					await send("remove", { id: style.id });
					if (current && current.id === style.id) current = null;
					await load();
					render();
				}
			}, row);
		}
		const foot = el("div", { class: "foot" }, body);
		el("button", { text: "New", onclick: () => { current = draftStyle(); allStyles.push(current); tab = "code"; render(); } }, foot);
		const file = el("input", { type: "file", accept: ".json,application/json" }, foot);
		file.style.display = "none";
		file.addEventListener("change", async () => {
			const chosen = file.files && file.files[0];
			if (!chosen) return;
			const result = await send("import", { text: await chosen.text() });
			if (result.error) toast(result.error);
			else toast(`${result.count} imported`);
			await load();
			render();
		});
		el("button", { text: "Import from Stylus", onclick: () => file.click() }, foot);
		if (learnedCount) {
			el("button", {
				text: "Forget learned",
				onclick: async () => {
					if (!confirm("Forget what Auto learned from your styles?")) return;
					await send("forget");
					await load();
					render();
				}
			}, foot);
		}
		el("button", {
			text: "Export",
			onclick: async () => {
				const data = await send("export");
				const link = el("a", { href: URL.createObjectURL(new Blob([JSON.stringify(data, null, "\t")], { type: "application/json" })), download: "pshell-styles.json" });
				link.click();
				setTimeout(() => URL.revokeObjectURL(link.href), 4000);
			}
		}, foot);
	}

	// ── Auto: the page's colours onto the shell's ───────────────────────────
	// The page is read without its styles: every surface, text and border
	// colour gets a role (neutral surfaces by their distance from the page's
	// background → bg, layer 1–3; the most used hue → primary, then
	// secondary and tertiary, reds, greens and ambers → danger, success,
	// warning; text by its contrast → text, muted, subtle), written per
	// selector (the role most of its area has). The result goes between
	// /* pshell:auto */ markers; running Auto again replaces only that.
	const AUTO_START = "/* pshell:auto */";
	const AUTO_END = "/* /pshell:auto */";

	async function auto() {
		if (picking) stopPicking();
		if (cornering) stopCorners();
		await send("suspend", { on: true });
		await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
		const text = cssOf();
		const start = text.indexOf(AUTO_START);
		const end = text.indexOf(AUTO_END);
		// what the user changed in Auto's rules stays
		const edits = start >= 0 && end > start ? editsOf(text.slice(start, end), current && current.autoMap && current.autoMap.made) : [];
		let css = "";
		try {
			const result = analyse(null);
			css = result.lines.map(line => `${line.text}\n`).join("");
			if (!current) {
				current = draftStyle();
				allStyles.push(current);
			}
			current.autoMap = Object.assign(result.map, { made: madeOf(css) });
		} finally {
			await send("suspend", { on: false });
		}
		const block = `${AUTO_START}\n${css}${AUTO_END}`;
		let next = start >= 0 && end > start
			? text.slice(0, start) + block + text.slice(end + AUTO_END.length)
			: `${block}\n${text ? `\n${text}` : ""}`;
		for (const edit of edits) next = setDeclaration(next, edit.path, edit.selector, edit.prop, edit.value);
		change(next);
		await save();
		render();
	}

	// Auto's rules as it wrote them: selector → prop → value
	function madeOf(text) {
		const made = {};
		for (const rule of rulesOf(text)) {
			if (rule.path.length) continue;
			const props = made[rule.selector] = made[rule.selector] || {};
			for (const declaration of rule.declarations) props[declaration.prop] = declaration.value;
		}
		return made;
	}

	// the user's changes to them (null: a declaration taken out)
	function editsOf(block, made) {
		const out = [];
		if (!made) return out;
		for (const rule of rulesOf(block)) {
			const was = made[rule.selector];
			if (!was || rule.path.length) continue;
			const now = {};
			for (const declaration of rule.declarations) now[declaration.prop] = declaration.value;
			for (const [prop, value] of Object.entries(now)) if (was[prop] !== value) out.push({ path: [], selector: rule.selector, prop, value });
			for (const prop of Object.keys(was)) if (!(prop in now)) out.push({ path: [], selector: rule.selector, prop, value: null });
		}
		return out;
	}

	// ── learning: what kind of thing an element is ──────────────────────────
	// Read from its tag, role and the words of its classes and id, never from
	// how it looks (Auto reads a page without its styles, learning with them):
	// a region ("sidebar", "header", …) or a leaf in one ("sidebar/item",
	// "page/button", "chat/message"), ".on" when selected or current.
	const REGION_WORDS = {
		sidebar: ["sidebar", "sidenav", "drawer", "rail", "aside", "sidepanel", "leftnav", "complementary"],
		header: ["header", "topbar", "navbar", "appbar", "toolbar", "masthead", "banner"],
		footer: ["footer", "contentinfo"],
		menu: ["menu", "dropdown", "popover", "popup", "listbox", "contextmenu"],
		dialog: ["dialog", "modal", "alertdialog"],
		chat: ["chat", "conversation", "messages", "thread"],
		nav: ["nav", "navigation"]
	};
	const REGION_TAGS = { aside: "sidebar", header: "header", footer: "footer", nav: "nav", dialog: "dialog", menu: "menu" };
	const LEAF_WORDS = [
		["button", ["button", "btn"]],
		["input", ["input", "textbox", "searchbox", "combobox", "textarea"]],
		["tab", ["tab"]],
		["badge", ["badge", "tag", "chip", "pill", "counter"]],
		["message", ["message", "msg", "bubble", "comment", "reply"]],
		["card", ["card", "tile", "widget"]],
		["item", ["item", "entry", "row", "option", "listitem", "menuitem", "treeitem"]],
		["heading", ["title", "heading", "headline"]],
		["code", ["code", "pre", "kbd"]],
		["avatar", ["avatar"]],
		["icon", ["icon"]]
	];
	const LEAF_TAGS = { button: "button", input: "input", textarea: "input", select: "input", a: "link", li: "item", h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading", h6: "heading", pre: "code", code: "code", kbd: "code", th: "cell", td: "cell", svg: "icon", img: "image" };
	const NEUTRAL = ["bg", "layer1", "layer2", "layer3", "primary-container", "primary-soft", "outline"];
	const kindCache = new Map();
	const regionCache = new Map();

	function wordsOf(node) {
		const text = [node.id, node.getAttribute("class"), node.getAttribute("role"), node.getAttribute("data-testid")].filter(Boolean).join(" ");
		return new Set(text.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().split(/[^a-z]+/).filter(Boolean));
	}

	function ownRegion(node, words) {
		for (const [region, list] of Object.entries(REGION_WORDS)) if (list.some(word => words.has(word))) return region;
		return REGION_TAGS[node.localName] || "";
	}

	function regionOf(node) {
		if (!node || node === document.body || node === document.documentElement) return "";
		if (regionCache.has(node)) return regionCache.get(node);
		const region = ownRegion(node, wordsOf(node)) || regionOf(node.parentElement);
		regionCache.set(node, region);
		return region;
	}

	function kindOf(node) {
		if (kindCache.has(node)) return kindCache.get(node);
		const words = wordsOf(node);
		let leaf = "";
		for (const [name, list] of LEAF_WORDS) if (list.some(word => words.has(word))) { leaf = name; break; }
		if (!leaf) leaf = LEAF_TAGS[node.localName] || "";
		if (leaf === "input" && node.localName === "input" && /^(button|submit|reset)$/.test(node.type)) leaf = "button";
		if (leaf === "link" && words.has("button")) leaf = "button";
		const own = ownRegion(node, words);
		let kind;
		if (!leaf && own) kind = own;
		else {
			const region = own || regionOf(node.parentElement) || "page";
			const text = [...node.childNodes].some(child => child.nodeType === 3 && child.textContent.trim());
			kind = `${region}/${leaf || (text ? "text" : "box")}`;
		}
		if (onMark(node)) kind += ".on";
		kindCache.set(node, kind);
		return kind;
	}

	// what makes an element the selected or current one: a class or an attribute
	const ON_WORDS = ["active", "selected", "current", "checked"];
	const ON_ATTRS = ["aria-selected", "aria-current", "aria-pressed", "aria-checked"];
	function onMark(node) {
		for (const name of node.classList) {
			const words = name.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase().split(/[^a-z]+/);
			if (ON_WORDS.some(word => words.includes(word))) return `.${CSS.escape(name)}`;
		}
		for (const attr of ON_ATTRS) {
			const value = node.getAttribute(attr);
			if (value && value !== "false") return `[${attr}]:not([${attr}="false"])`;
		}
		return "";
	}

	// a role learned for a kind (exactly, else the leaf in any region)
	function learnt(kind, prop) {
		const own = model[kind];
		if (own && own[prop]) return own[prop];
		const slash = kind.indexOf("/");
		const any = slash > 0 ? model[`*${kind.slice(slash)}`] : null;
		return any && any[prop] ? any[prop] : null;
	}

	// the user's own rules of the style being edited (outside Auto's block,
	// or changed in it): each rule's role per prop and the kind of what it reaches
	async function learn() {
		learnDue = null;
		if (!current || !current.css && !current.autoMap) return;
		const text = cssOf();
		const start = text.indexOf(AUTO_START);
		const end = text.indexOf(AUTO_END);
		const made = current.autoMap && current.autoMap.made;
		kindCache.clear();
		regionCache.clear();
		const entries = {};
		const keep = [];
		for (const rule of rulesOf(text)) {
			const ruleKey = `${rule.path.join("|")}|${rule.selector}`;
			keep.push(ruleKey);
			const inAuto = start >= 0 && rule.at > start && rule.at < end;
			const was = inAuto ? made && made[rule.selector] : null;
			if (inAuto && !was) continue;
			const props = {};
			for (const { prop, value } of rule.declarations) {
				const m = /^var\(--pshell-([a-z0-9-]+)\)$/.exec(value.replace(/\s*!important\s*$/, "").trim());
				if (!m || (was && was[prop] === value)) continue;
				props[prop] = m[1];
			}
			if (!Object.keys(props).length) {
				entries[ruleKey] = null;
				continue;
			}
			const nodes = (matchesOf(stateless(rule.selector)) || []).slice(0, 30);
			if (!nodes.length) continue; // not on this page: what was learned stays
			const counts = new Map();
			for (const node of nodes) counts.set(kindOf(node), (counts.get(kindOf(node)) || 0) + 1);
			const [kind] = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
			const state = (/:(hover|focus-visible|active)\b/.exec(rule.selector) || [""])[0];
			entries[ruleKey] = { key: kind + state, props };
		}
		try {
			await send("learn", { id: current.id, entries, keep });
			const state = await send("state");
			model = state.learned || {};
			learnedCount = state.learnedCount || 0;
		} catch (error) {}
	}

	// follow: null for Auto on a page shown without its styles; for a subpage
	// { map, covered }: the mapping Auto kept and the elements its rules
	// already reach (read with the styles on: only the uncovered are the page's own)
	function analyse(follow) {
		const opaque = c => c && c.a > 0.5;
		const rootBg = rgbOf(getComputedStyle(document.documentElement).backgroundColor);
		const bodyBg = document.body ? rgbOf(getComputedStyle(document.body).backgroundColor) : null;
		const base = follow ? Object.assign({ a: 1 }, follow.map.base) : opaque(bodyBg) ? bodyBg : opaque(rootBg) ? rootBg : { r: 255, g: 255, b: 255, a: 1 };
		const baseL = lightness(base);

		const nodes = [];
		const all = document.body ? document.body.getElementsByTagName("*") : [];
		for (let i = 0; i < all.length && nodes.length < 5000; i++) {
			const node = all[i];
			if (node === host || /^(script|style|link|meta|noscript|template|img|video|canvas|iframe|picture|source|br|head)$/.test(node.localName)) continue;
			if (node instanceof SVGElement && node.localName !== "svg") continue;
			const rect = node.getBoundingClientRect();
			if (rect.width < 1 || rect.height < 1) continue;
			nodes.push({ node, area: Math.min(rect.width * rect.height, 4e6), style: getComputedStyle(node) });
		}

		// the hues in use, by area of surfaces and by text
		const hueArea = new Map();
		const bin = c => Math.round(hue(c) / 30) % 12;
		const vivid = c => chroma(c) > 0.22 && lightness(c) > 0.25;
		for (const { style, area } of follow ? [] : nodes) {
			const bg = rgbOf(style.backgroundColor);
			if (opaque(bg) && vivid(bg)) hueArea.set(bin(bg), (hueArea.get(bin(bg)) || 0) + area);
			const fg = rgbOf(style.color);
			if (fg && vivid(fg)) hueArea.set(bin(fg), (hueArea.get(bin(fg)) || 0) + 2000);
		}
		const accents = follow ? follow.map.accents || [] : [...hueArea.entries()].sort((a, b) => b[1] - a[1]).map(entry => entry[0]);
		const semantic = h => (h >= 345 || h < 18) ? "danger" : (h >= 90 && h < 165) ? "success" : (h >= 30 && h < 65) ? "warning" : null;
		const vividRole = c => {
			const b = bin(c);
			if (b === accents[0]) return "primary";
			const meaning = semantic(hue(c));
			if (meaning) return meaning;
			const rank = accents.indexOf(b);
			return rank === 1 ? "secondary" : rank === 2 ? "tertiary" : "primary";
		};
		const surfaceRole = c => {
			if (vivid(c)) return vividRole(c);
			const d = Math.abs(lightness(c) - baseL);
			return d < 0.006 ? "bg" : d < 0.05 ? "layer1" : d < 0.11 ? "layer2" : "layer3";
		};
		const onRole = role => role === "primary" ? "on-primary" : "bg";
		// what was learned from the user's styles goes before what the page says
		kindCache.clear();
		regionCache.clear();

		// the shell look: the bar on top, a rail at the side and the page beside them
		const look = follow ? !!follow.map.look : !!(current && current.look);
		let frame = null;
		let frameNew = false;
		if (look && follow && follow.map.frame) {
			const kept = {};
			for (const key of ["bar", "left", "right", "main"]) {
				try {
					kept[key] = follow.map.frame[key] ? document.querySelector(follow.map.frame[key]) : null;
				} catch (error) {
					kept[key] = null;
				}
			}
			if (kept.bar || kept.left || kept.right) frame = kept;
		}
		if (look && !frame) {
			frame = findFrame(nodes);
			frameNew = !!frame;
		}
		const NEXT = { bg: "layer1", layer1: "layer2", layer2: "layer3", layer3: "layer3" };

		// per selector: votes of area for each property's role
		const votes = new Map(); // selector → prop → role → weight
		const vote = (sel, prop, role, weight) => {
			if (!votes.has(sel)) votes.set(sel, new Map());
			const props = votes.get(sel);
			if (!props.has(prop)) props.set(prop, new Map());
			props.get(prop).set(role, (props.get(prop).get(role) || 0) + weight);
		};
		const surfaceOf = new Map(); // node → role of the surface it sits on
		const colourOf = new Map(); // node → the page's own colour under it
		const frameEdges = frame ? [frame.bar, frame.left, frame.right].filter(Boolean) : [];
		const inEdge = node => frameEdges.some(edge => edge.contains(node));
		let links = 0;
		const paletteRgb = palette.map(role => [role.name, rgbOf(role.value)]).filter(entry => entry[1]);
		const worn = value => {
			const c = rgbOf(value);
			if (!c || c.a < 0.5) return null;
			const hit = paletteRgb.find(([, p]) => Math.abs(p.r - c.r) + Math.abs(p.g - c.g) + Math.abs(p.b - c.b) < 4);
			return hit ? hit[0] : null;
		};
		for (const { node, style, area } of nodes) {
			if (follow && follow.covered.has(node)) {
				const role = worn(style.backgroundColor);
				surfaceOf.set(node, role || surfaceOf.get(node.parentElement) || "bg");
				colourOf.set(node, base);
				continue;
			}
			const kind = kindOf(node);
			// the selected one apart from the others like it
			let sel = selectorFor(node);
			const mark = kind.endsWith(".on") ? onMark(node) : "";
			if (mark && !splitSelectors(sel).every(part => part.endsWith(mark))) sel = splitSelectors(sel).map(part => part + mark).join(", ");
			let surface = surfaceOf.get(node.parentElement) || (frame && frame.main && frame.main.contains(node) ? "layer1" : "bg");
			let ownSurface = false;
			let below = colourOf.get(node.parentElement) || base;
			const bg = rgbOf(style.backgroundColor);
			const gradient = /gradient\(/.test(style.backgroundImage) && !/url\(/.test(style.backgroundImage);
			const field = /^(input|textarea|select)$/.test(node.localName);
			if ((opaque(bg) || gradient) && !field) {
				let colour = bg;
				if (!opaque(colour)) {
					const first = rgbOf(style.backgroundImage);
					colour = first || base;
				}
				surface = surfaceRole(colour);
				// inside the page the frame's colour is taken: everything one layer up
				if (frame && frame.main && frame.main.contains(node) && NEXT[surface]) surface = NEXT[surface];
				surface = (kind && learnt(kind, "background-color")) || surface;
				ownSurface = true;
				below = opaque(bg) ? bg : colour;
				if (!frameEdges.includes(node)) {
					vote(sel, "background-color", surface, area);
					if (gradient) vote(sel, "background-image", "none", area);
				}
			} else if (kind && !field && !frameEdges.includes(node)) {
				// a region (its outermost element), a message or a card without a
				// background of its own on this page still gets the learned one
				const want = learnt(kind, "background-color");
				const bare = kind.replace(/\.on$/, "");
				const region = !bare.includes("/") && regionOf(node.parentElement) !== bare;
				if (want && (region || /\/(message|card)$/.test(bare))) {
					surface = want;
					ownSurface = true;
					vote(sel, "background-color", want, area);
				}
			}
			// a bar or rail takes the frame's colour (frameRules): what is in it is read against that
			if (frameEdges.includes(node)) {
				surface = "bg";
				ownSurface = true;
			}
			surfaceOf.set(node, surface);
			colourOf.set(node, below);
			// rounded things take the shell's radii
			if (frame && !frameEdges.includes(node) && node !== frame.main && parseFloat(style.borderTopLeftRadius) > 0 && parseFloat(style.borderTopLeftRadius) < 100) {
				const small = /^(button|input|select|textarea|a)$/.test(node.localName) || node.getBoundingClientRect().height < 48;
				vote(sel, "border-radius", small ? "radius-small" : "radius-medium", area);
			}
			const vividSurface = !NEUTRAL.includes(surface);
			const radius = kind && learnt(kind, "border-radius");
			if (radius) vote(sel, "border-radius", radius, area * 4);

			const hasText = [...node.childNodes].some(child => child.nodeType === 3 && child.textContent.trim());
			const fg = rgbOf(style.color);
			const inherited = follow && node.parentElement && getComputedStyle(node.parentElement).color === style.color;
			if (fg && !inherited && (hasText || ownSurface || node.localName === "a" || node.localName === "svg")) {
				let role;
				if (vividSurface) role = onRole(surface);
				else if (vivid(fg)) role = vividRole(fg);
				else {
					const contrast = Math.abs(lightness(fg) - lightness(below));
					// a bar that was coloured: its text was measured against the colour
					if (inEdge(node) && vivid(below)) role = contrast > 0.3 ? "fg" : "muted";
					else role = contrast > 0.6 ? "fg" : contrast > 0.3 ? "muted" : "subtle";
				}
				role = (kind && learnt(kind, "color")) || role;
				if (node.localName === "a" && role === "primary") links++;
				vote(sel, "color", role, hasText ? Math.max(area, 400) : 200);
			}

			if (node.localName === "svg" || node instanceof SVGElement) {
				const fill = rgbOf(style.fill);
				if (fill && fill.a > 0 && style.fill !== style.color) vote(sel, "fill", vivid(fill) ? vividRole(fill) : vividSurface ? onRole(surface) : "fg", area);
			}

			const edges = ["Top", "Right", "Bottom", "Left"].filter(edge => parseFloat(style[`border${edge}Width`]) > 0 && style[`border${edge}Style`] !== "none");
			if (edges.length) {
				const border = rgbOf(style[`border${edges[0]}Color`]);
				if (border && border.a > 0) {
					const role = (kind && learnt(kind, "border-color")) || (vivid(border) ? vividRole(border) : "outline");
					if (edges.length === 4) vote(sel, "border-color", role, area);
					else for (const edge of edges) vote(sel, `border-${edge.toLowerCase()}-color`, role, area);
				}
			}

			// hover, focus, pressed: as learned for this kind
			if (kind) {
				for (const suffix of [":hover", ":focus-visible", ":active"]) {
					for (const prop of ["background-color", "color", "border-color"]) {
						const role = learnt(kind + suffix, prop);
						if (role) vote(splitSelectors(sel).map(part => part + suffix).join(", "), prop, role, area);
					}
				}
			}
		}

		// the rules, page wide ones first (not again on a subpage)
		const lines = follow ? [] : [
			`html { color-scheme: ${dark ? "dark" : "light"}; scrollbar-color: var(--pshell-layer3) var(--pshell-bg); }`,
			"html, body { background-color: var(--pshell-bg); color: var(--pshell-fg); }",
			"::selection { background-color: var(--pshell-primary); color: var(--pshell-on-primary); }",
			"input, textarea, select { background-color: var(--pshell-layer1); color: var(--pshell-fg); border-color: var(--pshell-outline); }",
			"::placeholder { color: var(--pshell-subtle); }"
		];
		if (links && !follow) lines.push("a { color: var(--pshell-primary); }");
		let count = 0;
		for (const [sel, props] of votes) {
			if (sel === "html" || sel === "body") continue;
			const declarations = [];
			for (const [prop, roles] of props) {
				const [role] = [...roles.entries()].sort((a, b) => b[1] - a[1])[0];
				declarations.push(role === "none" ? `${prop}: none;` : `${prop}: var(--pshell-${role});`);
			}
			if (!declarations.length) continue;
			lines.push(`${sel} { ${declarations.join(" ")} }`);
			if (++count >= 400) break;
		}
		const out = lines.map(text => ({ text }));
		let frameKept = follow ? follow.map.frame || null : null;
		if (frame && (!follow || frameNew)) {
			const rules = frameRules(frame);
			out.push(...rules.lines.map(text => ({ text, force: true })));
			frameKept = rules.selectors;
		} else if (look && !frame && !follow) toast("No bar or side bar found");
		const map = follow
			? (frameNew ? { frame: frameKept } : null)
			: { base: { r: base.r, g: base.g, b: base.b }, accents, look, frame: frameKept };
		return { lines: out, map };
	}

	// a page of the site: what the style's Auto rules do not reach yet
	async function followPage() {
		if (open) return; // the editor is at work here
		let state;
		try {
			state = await send("state");
		} catch (error) {
			return;
		}
		palette = state.palette;
		dark = state.dark;
		model = state.learned || {};
		const style = state.styles.find(other => other.matches && other.on !== false && other.follow && other.autoMap);
		if (!style) return;
		const start = style.css.indexOf(AUTO_START);
		const end = style.css.indexOf(AUTO_END);
		if (start < 0 || end < start) return;
		const covered = new Set();
		for (const rule of rulesOf(style.css.slice(start, end))) {
			for (const node of matchesOf(stateless(rule.selector)) || []) covered.add(node);
		}
		const { lines, map } = analyse({ map: style.autoMap, covered });
		if (lines.length || map) await send("extend", { id: style.id, lines, map });
	}

	function exactSelector(node) {
		const sel = selectorFor(node);
		return countOf(sel) === 1 ? sel : exactFor(node);
	}

	// a bar: at the top, (nearly) as wide as the window, not tall; a rail: at
	// a side, narrow and (nearly) as tall; the page: what lies right beside
	// them and is large. The outermost of each wins.
	function findFrame(nodes) {
		const vw = innerWidth;
		const vh = innerHeight;
		const boxes = nodes.map(entry => ({ node: entry.node, r: entry.node.getBoundingClientRect() }));
		const outermost = list => list.find(a => !list.some(b => b !== a && b.node.contains(a.node))) || null;
		const bar = outermost(boxes.filter(({ r }) => r.top <= 4 && r.width >= vw * 0.9 && r.height >= 28 && r.height <= 140));
		const top = bar ? bar.r.bottom : 0;
		const rails = boxes.filter(({ node, r }) => (!bar || !bar.node.contains(node)) && r.width >= 40 && r.width <= vw * 0.35 &&
			r.height >= (vh - top) * 0.6 && r.top <= top + 8 && (r.left <= 4 || r.right >= vw - 4));
		const left = outermost(rails.filter(({ r }) => r.left <= 4));
		const right = outermost(rails.filter(({ r }) => r.right >= vw - 4 && r.left > vw / 2));
		if (!bar && !left && !right) return null;
		const startX = left ? left.r.right : 0;
		const endX = right ? right.r.left : vw;
		const main = outermost(boxes.filter(({ node, r }) => [bar, left, right].every(edge => !edge || (!node.contains(edge.node) && !edge.node.contains(node))) &&
			Math.abs(r.top - top) <= 12 && Math.abs(r.left - startX) <= 12 && r.right >= endX - 12 && r.height >= vh * 0.4));
		return { bar: bar && bar.node, left: left && left.node, right: right && right.node, main: main && main.node };
	}

	function frameRules(frame) {
		const out = [];
		const selectors = {};
		for (const key of ["bar", "left", "right"]) {
			const edge = frame[key];
			if (!edge) continue;
			selectors[key] = exactSelector(edge);
			out.push(`${selectors[key]} { background-color: var(--pshell-bg); background-image: none; border-color: transparent; box-shadow: none; }`);
		}
		if (frame.main) {
			const r = "var(--pshell-radius)";
			const touchesTop = !!frame.bar;
			const corners = [
				touchesTop || frame.left ? r : "0",
				touchesTop || frame.right ? r : "0",
				frame.right ? r : "0",
				frame.left ? r : "0"
			].join(" ");
			const clip = getComputedStyle(frame.main).overflow === "visible" ? " overflow: clip;" : "";
			selectors.main = exactSelector(frame.main);
			out.push(`${selectors.main} { background-color: var(--pshell-layer1); border-radius: ${corners};${clip} }`);
		}
		return { lines: out, selectors };
	}

	// ── open and close ──────────────────────────────────────────────────────
	function close() {
		if (picking) stopPicking();
		if (cornering) stopCorners();
		clearTimeout(saveDue);
		if (current && current.css !== undefined) save().then(() => {
			clearTimeout(learnDue);
			learn();
		});
		open = false;
		host.remove();
	}

	async function show() {
		open = true;
		(document.documentElement || document).appendChild(host);
		await load();
		render();
		drawBoxes();
	}

	browser.runtime.onMessage.addListener(message => {
		if (!message || !message.pshellStyler || !open) return;
		if (message.op === "palette") {
			palette = message.palette;
			dark = message.dark;
			themePanel();
			render();
		}
	});

	// a page that replaces its whole document drops the panel: put it back
	new MutationObserver(() => {
		if (open && !host.isConnected) (document.documentElement || document).appendChild(host);
	}).observe(document, { childList: true, subtree: false });

	window.pshellStyler = { toggle: () => (open ? close() : show()), follow: () => followPage() };
	if (window.pshellFollowOnly) {
		window.pshellFollowOnly = false;
		open = false;
		followPage();
	} else show();
})();
