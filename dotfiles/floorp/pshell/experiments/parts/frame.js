/* The script inside every page of the window (tabs, the Peek card, the
 * Spur's columns): base.js loads pshellFrame() as a frame script. It talks to
 * the window over "pshell:page" (to it) and "pshell:to" (from it).
 *
 *   hints     f: every link and control in sight gets letters from the home
 *             row; typing them follows it (F: in the Peek, v: in the Spur,
 *             Ctrl+F while hinting: in a tab behind)
 *   links     Alt+click: Peek; Ctrl+Alt+click: Spur; in a Spur a plain
 *             click opens on the right
 *   keys      letters over the rail filter it; Esc, Shift+Enter, Alt+Enter
 *             in the Peek; Alt+←/→ in the Spur
 *   drafts    text typed into a form and not sent marks the tab, and closing
 *             it asks first
 *
 * The part below the function keeps what the hints need from the window: the
 * colours, and which links of a site are followed most (they get the short
 * letters). */
"use strict";

/* global sendAsyncMessage, addMessageListener, removeMessageListener, addEventListener, removeEventListener, content */
function pshellFrame() {
	let state = { hints: true, chars: "asdfghjkl", peekOn: true, spurOn: true, states: true, rail: false, filtering: false, peek: false, spur: false, colors: {}, freq: {} };
	let hint = null;
	const drafts = new Set();
	let dirty = false;
	const listeners = [];

	const send = (what, data) => {
		try {
			sendAsyncMessage("pshell:page", Object.assign({ what }, data || {}));
		} catch (error) {}
	};
	const listen = (type, fn, capture) => {
		addEventListener(type, fn, capture);
		listeners.push([type, fn, capture]);
	};

	// ── what is focused ─────────────────────────────────────────────────────
	const TEXT_TYPES = /^(text|search|email|url|tel|number|password|date|datetime-local|month|time|week)$/;
	function deepActive() {
		let node = content.document.activeElement;
		while (node && node.shadowRoot && node.shadowRoot.activeElement) node = node.shadowRoot.activeElement;
		return node;
	}
	function editable(node) {
		if (!node) return false;
		if (content.document.designMode === "on") return true;
		if (node.isContentEditable) return true;
		const name = node.localName;
		if (name === "textarea" || name === "select") return true;
		if (name === "input") return TEXT_TYPES.test(node.type || "text");
		const role = node.getAttribute && node.getAttribute("role");
		return role === "textbox" || role === "searchbox" || role === "combobox";
	}
	const mods = event => event.ctrlKey || event.altKey || event.metaKey;

	// ── drafts ──────────────────────────────────────────────────────────────
	function draftable(node) {
		if (!node) return false;
		if (node.localName === "textarea") return true;
		if (node.isContentEditable) return true;
		return node.localName === "input" && /^(text|email|url|tel)?$/.test(node.type || "") && node.type !== "search";
	}
	function textOf(node) {
		return node.isContentEditable && node.localName !== "textarea" && node.localName !== "input" ? (node.textContent || "") : (node.value || "");
	}
	function recount() {
		for (const node of [...drafts]) if (!node.isConnected || !textOf(node).trim()) drafts.delete(node);
		const now = drafts.size > 0;
		if (now !== dirty) {
			dirty = now;
			send("draft", { on: dirty });
		}
	}
	listen("input", event => {
		const node = event.composedTarget || event.originalTarget || event.target;
		if (!draftable(node)) return;
		// a search field or a box that empties itself after sending is no draft
		if (node.getAttribute && /search/i.test(`${node.getAttribute("role") || ""} ${node.getAttribute("type") || ""}`)) return;
		if (textOf(node).trim()) drafts.add(node);
		else drafts.delete(node);
		recount();
	}, true);
	listen("submit", () => content.setTimeout(() => {
		drafts.clear();
		recount();
	}, 0), true);
	listen("DOMWindowCreated", () => {
		drafts.clear();
		recount();
		content.addEventListener("beforeunload", event => {
			if (dirty && state.states) event.preventDefault();
		});
	}, true);

	// ── links ───────────────────────────────────────────────────────────────
	// (composedPath() is empty for a listener out here; walk up from the
	// target itself, through shadow roots)
	function linkOf(event) {
		return linkAbove(event.composedTarget || event.originalTarget || event.target);
	}
	function linkAbove(node) {
		while (node && node !== content.document) {
			if (node.localName === "a" && typeof node.href === "string" && node.href) return node;
			node = node.parentNode || node.host || null;
		}
		return null;
	}
	function rectOf(node) {
		const box = node.getBoundingClientRect();
		return { x: box.x, y: box.y, width: Math.max(1, box.width), height: Math.max(1, box.height) };
	}
	const followable = url => /^(https?|file):/i.test(url || "");

	listen("click", event => {
		if (event.button !== 0 || event.defaultPrevented) return;
		const link = linkOf(event);
		if (!link || !followable(link.href)) return;
		let how = "";
		if (event.altKey && (event.ctrlKey || event.metaKey) && state.spurOn) how = "spur";
		else if (event.altKey && !event.ctrlKey && !event.shiftKey && state.peekOn) how = "peek";
		else if (!mods(event) && !event.shiftKey && state.spur && link.target !== "_blank") how = "spurRight";
		if (!how) return;
		event.preventDefault();
		event.stopPropagation();
		send("link", { how, url: link.href, rect: rectOf(link) });
	}, true);
	listen("mousedown", () => {
		if (state.spur) send("spurFocus");
	}, true);

	// ── hints ───────────────────────────────────────────────────────────────
	const CLICKABLE = "a[href], button, input:not([type=hidden]), select, textarea, summary, label[for], [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [onclick], [contenteditable=''], [contenteditable=true], [tabindex]:not([tabindex='-1'])";

	function collect(onlyLinks) {
		const doc = content.document;
		const width = content.innerWidth;
		const height = content.innerHeight;
		const found = [];
		const seen = new Set();
		const walk = root => {
			for (const node of root.querySelectorAll(onlyLinks ? "a[href]" : CLICKABLE)) {
				if (seen.has(node)) continue;
				seen.add(node);
				if (onlyLinks && !followable(node.href)) continue;
				if (node.disabled) continue;
				const rects = [...node.getClientRects()].filter(r => r.width > 2 && r.height > 2 && r.bottom > 0 && r.right > 0 && r.top < height && r.left < width);
				if (!rects.length) continue;
				if (node.checkVisibility && !node.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) continue;
				const box = rects[0];
				// not under something else
				const x = Math.min(width - 1, Math.max(0, box.left + Math.min(box.width / 2, 8)));
				const y = Math.min(height - 1, Math.max(0, box.top + box.height / 2));
				let top = doc.elementFromPoint(x, y);
				while (top && top.shadowRoot) {
					const inner = top.shadowRoot.elementFromPoint(x, y);
					if (!inner || inner === top) break;
					top = inner;
				}
				if (top && top !== node && !node.contains(top) && !top.contains?.(node)) {
					const host = top.getRootNode && top.getRootNode().host;
					if (!(host && node.contains(host))) continue;
				}
				found.push({ node, box });
			}
			for (const node of root.querySelectorAll("*")) if (node.shadowRoot) walk(node.shadowRoot);
		};
		walk(doc);
		return found;
	}

	function labels(count, chars, order) {
		const letters = [...new Set(chars)];
		// as many single letters as can be; a letter that is needed as a
		// prefix gives way to its pairs (no label starts another)
		const all = [""];
		let used = 0;
		while (letters.length > 1 && (all.length - used < count || all.length === 1)) {
			const prefix = all[used++];
			for (const ch of letters) all.push(prefix + ch);
		}
		const out = all.slice(used, used + count);
		const result = new Array(count);
		order.forEach((index, rank) => {
			result[index] = out[rank];
		});
		return result;
	}

	function startHints(mode) {
		stopHints();
		if (!state.hints) return;
		const onlyLinks = mode !== "open";
		const items = collect(onlyLinks);
		if (!items.length) return;
		const freq = state.freq || {};
		// the most followed get the first letters, then top to bottom
		const order = items.map((item, index) => index).sort((a, b) => {
			const fa = items[a].node.href ? freq[items[a].node.href] || 0 : 0;
			const fb = items[b].node.href ? freq[items[b].node.href] || 0 : 0;
			return fb - fa || items[a].box.top - items[b].box.top || items[a].box.left - items[b].box.left;
		});
		const names = labels(items.length, state.chars || "asdfghjkl", order);
		const doc = content.document;
		const host = doc.createElement("pshell-hints");
		host.style.cssText = "all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;";
		const shadow = host.attachShadow({ mode: "closed" });
		const colors = state.colors || {};
		const style = doc.createElement("style");
		style.textContent = `
			.h { position: fixed; transform-origin: 0 0; font: 700 11px/1 ${colors.mono || "ui-monospace, monospace"}; letter-spacing: .04em;
				padding: 3px 5px; border-radius: 6px; background: ${colors.primary || "#efb146"}; color: ${colors.onPrimary || "#2a1600"};
				box-shadow: 0 2px 8px rgba(0,0,0,.35), 0 0 0 1px rgba(0,0,0,.15); text-transform: uppercase; white-space: nowrap;
				animation: in .16s cubic-bezier(.38,1.21,.22,1) both; transition: opacity .12s ease, transform .12s ease; }
			.h.bg { background: ${colors.secondary || "#9ab"}; }
			.h.peek { background: ${colors.tertiary || "#c9a"}; }
			.h.out { opacity: 0; transform: scale(.7); }
			.h.hit { transform: scale(1.18); }
			.h b { opacity: .45; font-weight: 700; }
			@keyframes in { from { opacity: 0; transform: scale(.5); } }
			.bar { position: fixed; left: 50%; bottom: 16px; transform: translateX(-50%); font: 600 12px/1 ${colors.font || "sans-serif"};
				padding: 7px 12px; border-radius: 999px; background: ${colors.bg || "#1b1311"}; color: ${colors.fg || "#f2e6e2"};
				box-shadow: 0 6px 20px rgba(0,0,0,.35); animation: up .2s cubic-bezier(.2,0,0,1) both; }
			@keyframes up { from { opacity: 0; transform: translate(-50%, 8px); } }
		`;
		shadow.appendChild(style);
		const nodes = items.map((item, index) => {
			const label = doc.createElement("span");
			label.className = `h ${mode === "bg" ? "bg" : mode === "peek" ? "peek" : ""}`;
			label.textContent = names[index];
			const left = Math.max(2, Math.min(content.innerWidth - 30, item.box.left - 4));
			const top = Math.max(2, Math.min(content.innerHeight - 20, item.box.top - 4));
			label.style.left = `${left}px`;
			label.style.top = `${top}px`;
			label.style.animationDelay = `${Math.min(index * 3, 90)}ms`;
			shadow.appendChild(label);
			return label;
		});
		const bar = doc.createElement("div");
		bar.className = "bar";
		shadow.appendChild(bar);
		doc.documentElement.appendChild(host);
		hint = { mode, items, names, nodes, typed: "", host, bar };
		paintBar();
	}

	function paintBar() {
		if (!hint) return;
		const words = { open: "Open", peek: "Peek", spur: "Spur", bg: "Behind" };
		hint.bar.textContent = `${words[hint.mode]}${hint.typed ? " · " + hint.typed.toUpperCase() : ""}`;
		hint.nodes.forEach((node, index) => node.classList.toggle("bg", hint.mode === "bg"));
	}

	function stopHints(after) {
		if (!hint) return;
		const host = hint.host;
		hint = null;
		if (after) content.setTimeout(() => host.remove(), after);
		else host.remove();
	}

	function follow(item, mode) {
		const node = item.node;
		const url = node.href;
		if (url) send("followed", { url });
		if (mode === "open") {
			if (node.localName === "a" && url) {
				if (node.target === "_blank" && followable(url)) return send("link", { how: "fg", url, rect: rectOf(node) });
				return node.click();
			}
			if (editable(node) || node.localName === "select") return node.focus();
			node.focus?.();
			return node.click();
		}
		if (followable(url)) send("link", { how: mode, url, rect: rectOf(node) });
	}

	function hintKey(event) {
		const key = event.key;
		if (/^(Shift|Control|Alt|Meta)$/.test(key)) return;
		event.preventDefault();
		event.stopPropagation();
		if (key === "Escape") return stopHints();
		if (event.ctrlKey && key.toLowerCase() === "f") {
			hint.mode = hint.mode === "bg" ? "open" : "bg";
			return paintBar();
		}
		if (key === "Backspace") hint.typed = hint.typed.slice(0, -1);
		else if (key.length === 1 && (state.chars || "").includes(key.toLowerCase())) hint.typed += key.toLowerCase();
		else return;
		const typed = hint.typed;
		let exact = -1;
		let alive = 0;
		hint.nodes.forEach((node, index) => {
			const name = hint.names[index];
			const ok = name.startsWith(typed);
			node.classList.toggle("out", !ok);
			if (ok) {
				alive++;
				node.innerHTML = "";
				const done = content.document.createElement("b");
				done.textContent = typed;
				node.append(done, name.slice(typed.length));
			}
			if (name === typed) exact = index;
		});
		paintBar();
		if (exact >= 0) {
			const item = hint.items[exact];
			const mode = hint.mode;
			hint.nodes[exact].classList.add("hit");
			stopHints(120);
			follow(item, mode);
		} else if (alive === 0) {
			stopHints();
		}
	}

	listen("scroll", () => stopHints(), true);
	listen("resize", () => stopHints(), true);
	listen("pagehide", () => stopHints(), true);

	// ── keys ────────────────────────────────────────────────────────────────
	listen("keydown", event => {
		if (hint) return hintKey(event);
		if (event.defaultPrevented || event.isComposing) return;
		const key = event.key;
		const active = deepActive();
		const typing = editable(active);

		if (state.peek) {
			if (key === "Escape") {
				event.preventDefault();
				event.stopPropagation();
				if (typing) return active.blur();
				return send("peekKey", { key: "Escape" });
			}
			if (key === "Enter" && !typing && event.shiftKey && !event.altKey) {
				event.preventDefault();
				return send("peekKey", { key: "keepTab" });
			}
			if (key === "Enter" && !typing && event.altKey) {
				event.preventDefault();
				return send("peekKey", { key: "keepSpur" });
			}
		}
		if (state.spur && event.altKey && !event.ctrlKey && !event.metaKey && (key === "ArrowLeft" || key === "ArrowRight" || key === "Escape")) {
			event.preventDefault();
			event.stopPropagation();
			return send("spurKey", { key });
		}
		if (typing) return;
		if (state.rail && !mods(event)) {
			const named = state.filtering && (key === "Escape" || key === "Backspace" || key === "Enter");
			if ((key.length === 1 && (key !== " " || state.filtering)) || named) {
				event.preventDefault();
				event.stopPropagation();
				return send("railKey", { key });
			}
		}
		if (!state.hints || event.ctrlKey || event.altKey || event.metaKey) return;
		if (key === "f") return (event.preventDefault(), event.stopPropagation(), startHints("open"));
		if (key === "F" && state.peekOn) return (event.preventDefault(), event.stopPropagation(), startHints("peek"));
		if (key === "v" && state.spurOn) return (event.preventDefault(), event.stopPropagation(), startHints("spur"));
	}, true);

	// ── from the window ─────────────────────────────────────────────────────
	// Ctrl+Alt+click never reaches the page (Floorp drags the window with that
	// chord), so the window asks which link is under the pointer
	function linkAt(x, y) {
		let node = content.document.elementFromPoint(x, y);
		while (node?.shadowRoot) {
			const inner = node.shadowRoot.elementFromPoint(x, y);
			if (!inner || inner === node) break;
			node = inner;
		}
		return linkAbove(node);
	}

	const onMessage = message => {
		const data = message.data || {};
		if (data.what === "state") state = Object.assign(state, data.state || {});
		else if (data.what === "linkAt") {
			const link = linkAt(data.x, data.y);
			if (link && followable(link.href) && state.spurOn) send("link", { how: "spur", url: link.href, rect: rectOf(link) });
		}
		else if (data.what === "hints") startHints(data.mode || "open");
		else if (data.what === "unload") {
			stopHints();
			for (const [type, fn, capture] of listeners) removeEventListener(type, fn, capture);
			removeMessageListener("pshell:to", onMessage);
		}
	};
	addMessageListener("pshell:to", onMessage);
	send("hello");
}

// ── the window's side of the hints ─────────────────────────────────────────
(function () {
	const PREF = "pshell.tabs.hintFrequency";
	let freq = null;

	function load() {
		if (freq) return freq;
		try {
			freq = JSON.parse(Services.prefs.getStringPref(PREF, "{}")) || {};
		} catch (error) {
			freq = {};
		}
		return freq;
	}

	function hostOf(url) {
		try {
			return Services.io.newURI(url).host;
		} catch (error) {
			return "";
		}
	}

	let saveDue = null;
	function save() {
		if (saveDue) return;
		saveDue = true;
		Services.tm.dispatchToMainThread(() => {
			saveDue = null;
			const hosts = Object.keys(freq);
			// a few sites, a few links each
			for (const host of hosts.slice(0, Math.max(0, hosts.length - 150))) delete freq[host];
			Services.prefs.setStringPref(PREF, JSON.stringify(freq));
		});
	}

	function colors(W) {
		const style = W.win.getComputedStyle(W.doc.body || W.doc.documentElement);
		const read = (name, fallback) => style.getPropertyValue(name).trim() || fallback;
		return {
			primary: read("--ps-primary", "#efb146"),
			onPrimary: read("--ps-on-primary", "#2a1600"),
			secondary: read("--ps-secondary", "#9ab7d0"),
			tertiary: read("--ps-tertiary", "#d4a5c9"),
			bg: read("--ps-bg", "#1b1311"),
			fg: read("--ps-text", "#f2e6e2"),
			font: read("--ps-font", "sans-serif"),
			mono: read("--ps-font-mono", "monospace")
		};
	}

	COMMANDS.hints = async args => {
		const W = frontWindow();
		if (!W) throw new Error("no window");
		// the top layer: the Peek, else the Spur's column in use, else the page
		let browser = W.gBrowser.selectedBrowser;
		if (W.peek) browser = W.peek.browser;
		else {
			const spur = W.spurs?.get(W.gBrowser.selectedTab);
			if (spur) browser = spur.cols[spur.active].browser;
		}
		W.win.focus();
		browser.focus();
		sendPage(browser, "hints", { mode: ["open", "peek", "spur", "bg"].includes(args.mode) ? args.mode : "open" });
		return true;
	};

	PARTS.push({
		name: "hints",
		pageState(W, browser, state) {
			const host = (() => {
				try {
					return browser.currentURI.host;
				} catch (error) {
					return "";
				}
			})();
			state.freq = (host && load()[host]) || {};
			state.colors = colors(W);
		},
		page: {
			followed(W, browser, data) {
				const host = hostOf(data.url);
				if (!host || W.private) return;
				const all = load();
				const links = (all[host] = all[host] || {});
				links[data.url] = (links[data.url] || 0) + 1;
				const keys = Object.keys(links);
				if (keys.length > 40) {
					keys.sort((a, b) => links[a] - links[b]);
					for (const key of keys.slice(0, keys.length - 40)) delete links[key];
				}
				// the latest host goes last, so the oldest are dropped first
				delete all[host];
				all[host] = links;
				save();
			},
			link(W, browser, data) {
				if (data.how !== "fg" || !/^(https?|file):/i.test(data.url || "")) return;
				const tab = W.gBrowser.addTab(data.url, { triggeringPrincipal: browser.contentPrincipal, relatedToCurrent: true });
				W.gBrowser.selectedTab = tab;
			}
		}
	});
})();
