/* Peek: a link in a card over the page (Settings › Browser › Navigation).
 *
 * Alt+click on a link, Shift+F in the hints, or a link from the shell (Mail,
 * WhatsApp …, when "Links from the shell" is Peek) opens it in a card that
 * grows out of the link; the page behind stays, dimmed. Escape, a click
 * beside it or another tab closes it, and it leaves nothing in the rail. A
 * peek in the peek replaces what it shows: there is never a second card.
 * Shift+Enter (or "Tab") keeps the page as a tab, Alt+Enter (or "Spur") as a
 * column in the Spur of the tab behind. A page that is open already is
 * switched to instead. */
"use strict";

(function () {
	function allowed(url) {
		return /^(https?|file):/i.test(String(url || ""));
	}

	function same(a, b) {
		const clean = url => String(url || "").replace(/#.*$/, "").replace(/\/$/, "");
		return clean(a) === clean(b);
	}

	function openTabWith(url) {
		for (const win of browserWindows()) {
			if (PrivateBrowsingUtils.isWindowPrivate(win)) continue;
			for (const tab of win.gBrowser.tabs) {
				if (same(tab.linkedBrowser?.currentURI?.spec, url)) return { win, tab };
			}
		}
		return null;
	}

	function title(W) {
		const peek = W.peek;
		if (!peek) return;
		const browser = peek.browser;
		let host = "";
		try {
			host = browser.currentURI.host || browser.currentURI.spec;
		} catch (error) {}
		peek.title.textContent = browser.contentTitle || host || "";
		peek.host.textContent = host;
		updatePage(W, browser);
	}

	function make(W, stack) {
		const doc = W.doc;
		const root = el(doc, "div", { class: "pshell-peek" });
		const card = el(doc, "div", { class: "pshell-peek-card" }, root);
		const bar = el(doc, "div", { class: "pshell-peek-bar" }, card);
		const titles = el(doc, "div", { class: "pshell-peek-titles" }, bar);
		const titleNode = el(doc, "span", { class: "pshell-peek-title" }, titles);
		const hostNode = el(doc, "span", { class: "pshell-peek-host" }, titles);
		const source = el(doc, "span", { class: "pshell-peek-source", hidden: true }, bar);
		const keepTab = el(doc, "button", { class: "pshell-peek-button", title: "Shift+Enter", text: "Tab" }, bar);
		const keepSpur = el(doc, "button", { class: "pshell-peek-button", title: "Alt+Enter", text: "Spur" }, bar);
		const close = el(doc, "button", { class: "pshell-peek-button pshell-peek-close", title: "Esc" }, bar);
		const frame = el(doc, "div", { class: "pshell-peek-frame" }, card);

		const browser = doc.createXULElement("browser");
		for (const [key, value] of Object.entries({
			type: "content",
			remote: "true",
			maychangeremoteness: "true",
			messagemanagergroup: "browsers",
			class: "pshell-peek-browser",
			flex: "1"
		})) browser.setAttribute(key, value);
		frame.appendChild(browser);
		stack.appendChild(root);

		const peek = { root, card, browser, title: titleNode, host: hostNode, source, keepSpur, stack };
		root.addEventListener("mousedown", event => {
			if (event.target === root) closePeek(W);
		});
		close.addEventListener("click", () => closePeek(W));
		keepTab.addEventListener("click", () => keep(W, "tab"));
		keepSpur.addEventListener("click", () => keep(W, "spur"));
		peek.progress = {
			QueryInterface: ChromeUtils.generateQI(["nsIWebProgressListener", "nsISupportsWeakReference"]),
			onLocationChange: () => title(W),
			onStateChange() {},
			onProgressChange() {},
			onStatusChange() {},
			onSecurityChange() {},
			onContentBlockingEvent() {}
		};
		browser.addEventListener("pagetitlechanged", () => title(W));
		return peek;
	}

	// the card grows out of the link (or the middle) into its place
	function grow(W, peek, from) {
		const win = W.win;
		const stackBox = peek.stack.getBoundingClientRect();
		const box = peek.card.getBoundingClientRect();
		const origin = from || { x: stackBox.x + stackBox.width / 2 - 60, y: stackBox.y + stackBox.height / 2 - 40, width: 120, height: 80 };
		const scaleX = Math.max(0.05, origin.width / box.width);
		const scaleY = Math.max(0.05, origin.height / box.height);
		const dx = origin.x - box.x;
		const dy = origin.y - box.y;
		peek.from = origin;
		const reduce = win.matchMedia("(prefers-reduced-motion: reduce)").matches;
		peek.card.animate([
			{ transform: `translate(${dx}px, ${dy}px) scale(${scaleX}, ${scaleY})`, opacity: 0.2 },
			{ transform: "none", opacity: 1 }
		], { duration: reduce ? 1 : 300, easing: "cubic-bezier(0.38, 1.21, 0.22, 1)" });
		peek.root.animate([{ backgroundColor: "transparent" }, {}], { duration: reduce ? 1 : 220, easing: "ease-out" });
	}

	function openPeek(W, url, options = {}) {
		if (!allowed(url) || W.private || !tabsConfig().peek.on) return false;
		const principal = options.principal || SYSTEM();
		const sourceTab = W.gBrowser.selectedTab;
		if (W.peek && W.peek.tab === sourceTab) {
			// a peek in the peek replaces what it shows
			W.peek.browser.fixupAndLoadURIString(url, { triggeringPrincipal: principal });
			setSource(W.peek, options.source);
			return true;
		}
		if (W.peek) closePeek(W, true);
		const stack = W.gBrowser.selectedBrowser.closest(".browserStack") || W.gBrowser.selectedBrowser.parentNode;
		const peek = make(W, stack);
		peek.tab = sourceTab;
		peek.sourceBrowser = options.from || W.gBrowser.selectedBrowser;
		W.peek = peek;
		W.doc.documentElement.setAttribute("pshell-peek", "");
		peek.keepSpur.hidden = !tabsConfig().spur.on;
		setSource(peek, options.source);
		peek.browser.webProgress?.addProgressListener(peek.progress, Ci.nsIWebProgress.NOTIFY_LOCATION);
		peek.browser.fixupAndLoadURIString(url, { triggeringPrincipal: principal });
		grow(W, peek, options.rect || null);
		W.win.setTimeout(() => peek.browser.focus(), 60);
		for (const browser of W.gBrowser.browsers) updatePage(W, browser);
		return true;
	}

	function setSource(peek, source) {
		peek.source.hidden = !source;
		peek.source.textContent = source || "";
	}

	function closePeek(W, now) {
		const peek = W.peek;
		if (!peek) return;
		W.peek = null;
		W.doc.documentElement.removeAttribute("pshell-peek");
		try {
			peek.browser.webProgress?.removeProgressListener(peek.progress);
		} catch (error) {}
		const done = () => {
			peek.root.remove();
			if (peek.tab === W.gBrowser.selectedTab) W.gBrowser.selectedBrowser.focus();
		};
		if (now || W.win.matchMedia("(prefers-reduced-motion: reduce)").matches) return done();
		const box = peek.card.getBoundingClientRect();
		const to = peek.from;
		const shrink = to ? `translate(${to.x - box.x}px, ${to.y - box.y}px) scale(${Math.max(0.05, to.width / box.width)}, ${Math.max(0.05, to.height / box.height)})` : "scale(0.94)";
		peek.root.style.pointerEvents = "none";
		peek.root.animate([{}, { backgroundColor: "transparent" }], { duration: 160, easing: "ease-in", fill: "forwards" });
		peek.card.animate([{ transform: "none", opacity: 1 }, { transform: shrink, opacity: 0 }], { duration: 180, easing: "cubic-bezier(0.4, 0, 1, 1)", fill: "forwards" }).finished.then(done, done);
	}

	// as a tab of its own (the page stays as it is when it can), or a column
	function keep(W, how) {
		const peek = W.peek;
		if (!peek) return;
		const url = peek.browser.currentURI?.spec || "";
		if (how === "spur") {
			const spur = PARTS.find(part => part.name === "spur");
			closePeek(W, true);
			if (allowed(url)) spur.addColumn(W, peek.tab, url, { principal: SYSTEM() });
			return;
		}
		const tab = W.gBrowser.addTrustedTab("about:blank", { relatedToCurrent: true, ownerTab: peek.tab, inBackground: false, skipAnimation: false });
		let moved = false;
		try {
			const remoteType = peek.browser.remoteType;
			if (remoteType && tab.linkedBrowser.remoteType !== remoteType) {
				W.gBrowser.updateBrowserRemoteness(tab.linkedBrowser, { remoteType });
			}
			W.gBrowser._swapBrowserDocShells(tab, peek.browser);
			moved = true;
		} catch (error) {
			console.error("[pshell] peek keep:", error);
		}
		if (!moved && allowed(url)) tab.linkedBrowser.fixupAndLoadURIString(url, { triggeringPrincipal: SYSTEM() });
		W.peek = null;
		W.doc.documentElement.removeAttribute("pshell-peek");
		peek.root.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 140, fill: "forwards" }).finished.then(() => peek.root.remove(), () => peek.root.remove());
		W.gBrowser.selectedTab = tab;
	}

	COMMANDS.peek = async args => {
		const url = String(args.url || "");
		if (!allowed(url)) throw new Error("not a page");
		const open = openTabWith(url);
		if (open) {
			open.win.gBrowser.selectedTab = open.tab;
			open.win.focus();
			return { switched: true };
		}
		const W = frontWindow();
		if (!W || W.private) throw new Error("no window");
		W.win.focus();
		return { peek: openPeek(W, url, { source: String(args.source || "") }) };
	};

	PARTS.push({
		name: "peek",
		openPeek,
		closePeek,
		pageState(W, browser, state) {
			state.peek = !!(W.peek && W.peek.browser === browser);
			state.peekOpen = !!W.peek;
		},
		attach(W) {
			on(W, W.gBrowser.tabContainer, "TabSelect", () => closePeek(W));
			on(W, W.win, "keydown", event => {
				if (!W.peek || event.defaultPrevented) return;
				if (event.key === "Escape") {
					event.preventDefault();
					closePeek(W);
				} else if (event.key === "Enter" && event.shiftKey && !event.altKey) {
					event.preventDefault();
					keep(W, "tab");
				} else if (event.key === "Enter" && event.altKey) {
					event.preventDefault();
					keep(W, "spur");
				}
			}, true);
		},
		page: {
			link(W, browser, data) {
				const url = String(data.url || "");
				if (!allowed(url)) return;
				if (data.how === "peek") {
					openPeek(W, url, { rect: chromeRect(browser, data.rect), from: browser, principal: browser.contentPrincipal });
				} else if (data.how === "bg") {
					W.gBrowser.addTab(url, { triggeringPrincipal: browser.contentPrincipal, inBackground: true, relatedToCurrent: true });
				}
			},
			peekKey(W, browser, data) {
				if (!W.peek || W.peek.browser !== browser) return;
				if (data.key === "Escape") closePeek(W);
				else if (data.key === "keepTab") keep(W, "tab");
				else if (data.key === "keepSpur") keep(W, "spur");
			}
		},
		detach(W) {
			closePeek(W, true);
		}
	});
})();
