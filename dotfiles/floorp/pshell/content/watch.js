// The picker for a watch (docs/browser.md "Watches"): put into a page on
// demand by background/bridge.js (`watchPick`), with
// window.__pshellWatchMode = "element" | "price". The element under the
// pointer is outlined; a click takes it, ↑ its parent; "Watch" (or "Price")
// sends { selector, value, attr, price, currency } to the shell, Esc or a
// right click ends it. The selector uses only what pshell-core's matcher
// reads (tag, #id, .class, [attr="v"], :nth-of-type, " " and ">"), skips
// classes and ids that look generated, and leaves out tbody (plain HTML
// rarely has one).

(() => {
	if (window.__pshellWatchPicker) {
		window.__pshellWatchPicker.mode(window.__pshellWatchMode || "element");
		return;
	}
	let mode = window.__pshellWatchMode || "element";
	let hovered = null;
	let picked = null;

	const host = document.createElement("pshell-watch");
	host.style.cssText = "all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;";
	const root = host.attachShadow({ mode: "closed" });
	const sheet = new CSSStyleSheet();
	sheet.replaceSync(`
		.box { position: fixed; pointer-events: none; border: 2px solid #7aa2f7; background: rgba(122, 162, 247, .12); border-radius: 4px; display: none; }
		.box.on { border-style: solid; border-color: #9ece6a; background: rgba(158, 206, 106, .14); }
		.bar { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); pointer-events: auto; display: flex; gap: 8px; align-items: center;
			max-width: min(640px, calc(100vw - 32px)); padding: 8px 8px 8px 14px; border-radius: 14px; background: #1a1b26; color: #c0caf5;
			font: 13px/1.3 system-ui, sans-serif; box-shadow: 0 6px 24px rgba(0, 0, 0, .35); }
		.value { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
		.value.empty { opacity: .6; }
		button { all: unset; cursor: pointer; padding: 6px 12px; border-radius: 9px; background: #24283b; color: inherit; font-weight: 600; }
		button:hover { background: #2f354d; }
		button.go { background: #7aa2f7; color: #1a1b26; }
		button[disabled] { opacity: .4; pointer-events: none; }
	`);
	root.adoptedStyleSheets = [sheet];
	const box = document.createElement("div");
	box.className = "box";
	const bar = document.createElement("div");
	bar.className = "bar";
	const value = document.createElement("div");
	value.className = "value empty";
	const up = document.createElement("button");
	up.textContent = "↑";
	up.title = "Parent";
	const go = document.createElement("button");
	go.className = "go";
	const cancel = document.createElement("button");
	cancel.textContent = "Cancel";
	bar.append(value, up, go, cancel);
	root.append(box, bar);
	document.documentElement.append(host);

	function setMode(next) {
		mode = next === "price" ? "price" : "element";
		go.textContent = mode === "price" ? "Price" : "Watch";
		show();
	}

	// ── what is shown ──────────────────────────────────────────────────────
	function textOf(el) {
		if (!el) return "";
		if (el.tagName === "META") return el.content || "";
		if (el.tagName === "INPUT") return el.value || "";
		return String(el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
	}

	function place(el) {
		if (!el) {
			box.style.display = "none";
			return;
		}
		const r = el.getBoundingClientRect();
		Object.assign(box.style, { display: "block", left: `${r.left - 2}px`, top: `${r.top - 2}px`, width: `${r.width}px`, height: `${r.height}px` });
	}

	function show() {
		const el = picked || hovered;
		place(el);
		box.classList.toggle("on", !!picked);
		const text = textOf(el).slice(0, 200);
		const price = mode === "price" ? priceOf(text) : null;
		value.textContent = picked ? (mode === "price" ? (price ? `${price.amount} ${price.currency}` : text || "–") : text || "–") : mode === "price" ? "Click the price" : "Click what to watch";
		value.classList.toggle("empty", !picked);
		go.disabled = !picked || (mode === "price" && !price);
		up.disabled = !picked || !picked.parentElement || picked.parentElement === document.body;
	}

	// ── selectors ──────────────────────────────────────────────────────────
	const css = text => String(text).replace(/(["\\])/g, "\\$1");
	const plainClass = c => /^[a-zA-Z_][\w-]{1,40}$/.test(c) && !/\d{3,}|[A-Z0-9]{6,}|^(css|sc|jsx|emotion|svelte|tw)-|__[a-zA-Z0-9]{5,}$|^(is-|has-)?(active|selected|hover|focus|open|hidden|visible|show|current)$/.test(c);
	const plainId = id => /^[a-zA-Z][\w-]{1,60}$/.test(id) && !/\d{4,}|^(ember|react|ng-|__|radix|headlessui)/i.test(id);

	function part(el, nth) {
		const tag = el.tagName.toLowerCase();
		if (el.id && plainId(el.id)) return `${tag}#${el.id}`;
		let out = tag;
		for (const name of ["itemprop", "data-testid", "data-test", "data-qa"]) {
			const v = el.getAttribute(name);
			if (v && v.length < 60) return `${out}[${name}="${css(v)}"]`;
		}
		const classes = [...el.classList].filter(plainClass).slice(0, 2);
		out += classes.map(c => `.${c}`).join("");
		if (nth) {
			const same = [...(el.parentElement?.children || [])].filter(s => s.tagName === el.tagName);
			if (same.length > 1) out += `:nth-of-type(${same.indexOf(el) + 1})`;
		}
		return out;
	}

	function unique(selector, el) {
		try {
			const all = document.querySelectorAll(selector);
			return all.length >= 1 && all[0] === el;
		} catch (error) {
			return false;
		}
	}

	function selectorOf(el) {
		// short first: the element, then ancestors in front, until it is the first match
		const parts = [part(el, false)];
		if (unique(parts[0], el) && document.querySelectorAll(parts[0]).length === 1) return parts[0];
		for (let up = el.parentElement; up && up !== document.documentElement; up = up.parentElement) {
			if (up.tagName === "TBODY") continue;
			const p = part(up, false);
			if (p === "body" || p === "div" || p === "span") continue;
			parts.unshift(p);
			const sel = parts.join(" ");
			if (unique(sel, el) && document.querySelectorAll(sel).length === 1) return sel;
			if (p.includes("#")) break;
			if (parts.length > 5) break;
		}
		// else a path with positions from the nearest plain id (or body)
		const steps = [];
		let skipped = false;
		for (let at = el; at && at !== document.body && at !== document.documentElement; at = at.parentElement) {
			if (at.tagName === "TBODY") {
				skipped = true;
				continue;
			}
			const p = part(at, true);
			if (steps.length) steps[steps.length - 1].comb = skipped ? " " : " > ";
			skipped = false;
			steps.push({ p, comb: "" });
			if (p.includes("#")) break;
		}
		steps.reverse();
		let sel = steps.map((step, i) => (i ? step.comb : "") + step.p).join("");
		if (!steps[0]?.p.includes("#")) sel = `body > ${sel}`;
		return unique(sel, el) ? sel : parts.join(" ");
	}

	// ── prices, as pshell-core reads them ─────────────────────────────────
	function priceOf(text) {
		const m = String(text).match(/(?<![\d.,])(\d{1,3}(?:[.,'\u202f\u00a0 ]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![\d])/);
		if (!m) return null;
		let raw = m[1].replace(/[\u202f\u00a0' ]/g, "");
		if (raw.includes(",") && raw.includes(".")) {
			const dec = raw.lastIndexOf(",") > raw.lastIndexOf(".") ? "," : ".";
			raw = raw.split(dec === "," ? "." : ",").join("").replace(dec, ".");
		} else if (/[.,]/.test(raw)) {
			const sep = raw.includes(",") ? "," : ".";
			const i = raw.lastIndexOf(sep);
			const tail = raw.slice(i + 1);
			raw = tail.length === 3 && (raw.split(sep).length > 2 || raw.slice(0, i).replace(/0/g, "") !== "") ? raw.split(sep).join("") : `${raw.slice(0, i).split(sep).join("")}.${tail}`;
		}
		const amount = Number(raw);
		if (!isFinite(amount)) return null;
		const low = String(text).toLowerCase();
		const currency = /€|eur/.test(low) ? "EUR" : /\$|usd/.test(low) ? "USD" : /£|gbp/.test(low) ? "GBP" : /chf/.test(low) ? "CHF" : "";
		return { amount, currency };
	}

	// ── the pointer ────────────────────────────────────────────────────────
	const ours = event => event.composedPath().includes(host);

	function onMove(event) {
		if (picked || ours(event)) return;
		const el = document.elementFromPoint(event.clientX, event.clientY);
		if (el && el !== host && el !== hovered) {
			hovered = el;
			show();
		}
	}

	function swallow(event) {
		if (ours(event)) return;
		event.preventDefault();
		event.stopImmediatePropagation();
	}

	function onClick(event) {
		if (ours(event)) return;
		swallow(event);
		if (event.button === 2) return end();
		const el = document.elementFromPoint(event.clientX, event.clientY);
		if (!el || el === host) return;
		picked = picked === el ? null : el;
		hovered = el;
		show();
	}

	function onKey(event) {
		if (event.key === "Escape") {
			swallow(event);
			end();
		} else if (event.key === "Enter" && !go.disabled) {
			swallow(event);
			send();
		} else if (event.key === "ArrowUp" && picked) {
			swallow(event);
			climb();
		}
	}

	function climb() {
		if (picked?.parentElement && picked.parentElement !== document.body) {
			picked = picked.parentElement;
			show();
		}
	}

	function send() {
		if (!picked) return;
		const text = textOf(picked).slice(0, 1000);
		const price = priceOf(text);
		const message = {
			pshell: "watchPicked",
			mode,
			url: location.href,
			title: mode === "price" ? (document.querySelector('meta[property="og:title"]')?.content || document.title) : `${document.title}`.slice(0, 120),
			selector: selectorOf(picked),
			attr: picked.tagName === "META" ? "content" : "",
			value: text,
			price: price ? price.amount : null,
			currency: price ? price.currency : ""
		};
		browser.runtime.sendMessage(message).catch(() => {});
		end();
	}

	function end() {
		window.removeEventListener("mousemove", onMove, true);
		for (const name of ["mousedown", "mouseup", "pointerdown", "pointerup", "auxclick", "dblclick"]) window.removeEventListener(name, swallowUnlessOurs, true);
		window.removeEventListener("click", onClick, true);
		window.removeEventListener("contextmenu", onContext, true);
		window.removeEventListener("keydown", onKey, true);
		window.removeEventListener("scroll", reposition, true);
		host.remove();
		delete window.__pshellWatchPicker;
	}

	function swallowUnlessOurs(event) {
		if (!ours(event)) swallow(event);
	}

	function onContext(event) {
		if (ours(event)) return;
		swallow(event);
		end();
	}

	function reposition() {
		place(picked || hovered);
	}

	up.addEventListener("click", climb);
	go.addEventListener("click", send);
	cancel.addEventListener("click", end);
	window.addEventListener("mousemove", onMove, true);
	for (const name of ["mousedown", "mouseup", "pointerdown", "pointerup", "auxclick", "dblclick"]) window.addEventListener(name, swallowUnlessOurs, true);
	window.addEventListener("click", onClick, true);
	window.addEventListener("contextmenu", onContext, true);
	window.addEventListener("keydown", onKey, true);
	window.addEventListener("scroll", reposition, true);
	window.__pshellWatchPicker = { mode: setMode, end, selectorOf, priceOf };
	setMode(mode);
})();
