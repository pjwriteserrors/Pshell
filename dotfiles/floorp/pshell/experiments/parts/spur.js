/* Spur: pages as columns side by side in one tab, like windows in niri
 * (Settings › Browser › Navigation: Spur, Columns).
 *
 * Ctrl+Alt+click on a link, "v" in the hints, "Spur" on a peek or the
 * launcher's command starts it; while it runs every plain click on a link
 * opens on the right of its column, cutting off what was right of it. Only
 * the last few columns show, the older ones shrink and then live only in the
 * crumbs above; a crumb shows its column again. Alt+←/→ moves between
 * columns. The whole Spur is one tab, titled after its newest column; ending
 * it ("Beenden" on the crumbs, Alt+Esc) keeps the newest column as the tab's
 * page. */
"use strict";

(function () {
	const WEIGHTS = [1.55, 1, 0.78, 0.64];

	function spurOf(W, browser) {
		for (const spur of W.spurs.values()) if (spur.cols.some(col => col.browser === browser)) return spur;
		return null;
	}

	function titleOf(browser) {
		let host = "";
		try {
			host = browser.currentURI.host || browser.currentURI.spec;
		} catch (error) {}
		return { title: browser.contentTitle || host || "…", host };
	}

	function start(W, tab) {
		if (W.spurs.has(tab)) return W.spurs.get(tab);
		const own = tab.linkedBrowser;
		const stack = own.closest(".browserStack") || own.parentNode;
		const bar = el(W.doc, "div", { class: "pshell-spur-bar" });
		const crumbs = el(W.doc, "div", { class: "pshell-spur-crumbs" }, bar);
		const end = el(W.doc, "button", { class: "pshell-spur-end", title: "Alt+Esc", text: "Beenden" }, bar);
		stack.insertBefore(bar, stack.firstChild);
		stack.setAttribute("pshell-spur", "");
		const spur = { tab, stack, bar, crumbs, cols: [{ browser: own, own: true }], active: 0, start: 0 };
		W.spurs.set(tab, spur);
		crumbs.addEventListener("click", event => {
			const crumb = event.target.closest(".pshell-spur-crumb");
			if (crumb) cut(W, spur, Number(crumb.dataset.index));
		});
		end.addEventListener("click", () => finish(W, tab));
		tab.setAttribute("pshell-spur", "1");
		bar.animate([{ translate: "0 -10px", opacity: 0 }, { translate: "0 0", opacity: 1 }], { duration: 220, easing: "cubic-bezier(0.2, 0, 0, 1)" });
		layout(W, spur);
		for (const col of spur.cols) updatePage(W, col.browser);
		return spur;
	}

	function makeBrowser(W) {
		const browser = W.doc.createXULElement("browser");
		for (const [key, value] of Object.entries({
			type: "content",
			remote: "true",
			maychangeremoteness: "true",
			messagemanagergroup: "browsers",
			class: "pshell-spur-browser"
		})) browser.setAttribute(key, value);
		return browser;
	}

	function addColumn(W, tab, url, options = {}) {
		if (!tabsConfig().spur.on || W.private || !/^(https?|file):/i.test(url)) return false;
		const spur = start(W, tab);
		// a click in an older column cuts off what was right of it
		const after = options.after ? spur.cols.findIndex(col => col.browser === options.after) : spur.cols.length - 1;
		if (after >= 0 && after < spur.cols.length - 1) drop(W, spur, after + 1);
		const browser = makeBrowser(W);
		spur.stack.appendChild(browser);
		const col = { browser, own: false };
		spur.cols.push(col);
		browser.addEventListener("pagetitlechanged", () => {
			drawCrumbs(W, spur);
			retitle(W, spur);
		});
		col.progress = {
			QueryInterface: ChromeUtils.generateQI(["nsIWebProgressListener", "nsISupportsWeakReference"]),
			onLocationChange: () => {
				drawCrumbs(W, spur);
				retitle(W, spur);
			},
			onStateChange() {},
			onProgressChange() {},
			onStatusChange() {},
			onSecurityChange() {},
			onContentBlockingEvent() {}
		};
		browser.webProgress?.addProgressListener(col.progress, Ci.nsIWebProgress.NOTIFY_LOCATION);
		browser.fixupAndLoadURIString(url, { triggeringPrincipal: options.principal || SYSTEM() });
		spur.active = spur.cols.length - 1;
		spur.start = Math.max(0, spur.cols.length - tabsConfig().spur.columns);
		layout(W, spur, browser);
		W.gBrowser.selectedTab = tab;
		W.win.setTimeout(() => browser.focus(), 80);
		updatePage(W, browser);
		return true;
	}

	// columns from `index` on go away (never the tab's own)
	function drop(W, spur, index) {
		for (const col of spur.cols.splice(Math.max(1, index))) {
			try {
				col.browser.webProgress?.removeProgressListener(col.progress);
			} catch (error) {}
			col.browser.remove();
		}
		spur.active = Math.min(spur.active, spur.cols.length - 1);
		spur.start = Math.min(spur.start, Math.max(0, spur.cols.length - tabsConfig().spur.columns));
	}

	function cut(W, spur, index) {
		if (index < spur.cols.length - 1) drop(W, spur, index + 1);
		spur.active = index;
		spur.start = Math.max(0, spur.cols.length - tabsConfig().spur.columns);
		layout(W, spur);
		spur.cols[index].browser.focus();
		retitle(W, spur);
	}

	function move(W, spur, step) {
		const next = Math.max(0, Math.min(spur.cols.length - 1, spur.active + step));
		if (next === spur.active) return;
		spur.active = next;
		const shown = tabsConfig().spur.columns;
		if (next < spur.start) spur.start = next;
		if (next >= spur.start + shown) spur.start = next - shown + 1;
		layout(W, spur);
		spur.cols[next].browser.focus();
	}

	function layout(W, spur, entering) {
		const shown = tabsConfig().spur.columns;
		const end = Math.min(spur.cols.length, spur.start + shown);
		spur.cols.forEach((col, index) => {
			const visible = index >= spur.start && index < end;
			const fromRight = end - 1 - index;
			col.browser.toggleAttribute("pshell-hidden", !visible);
			col.browser.toggleAttribute("pshell-active", index === spur.active && spur.cols.length > 1);
			col.browser.style.setProperty("--pshell-grow", visible ? String(WEIGHTS[Math.min(fromRight, WEIGHTS.length - 1)]) : "0");
		});
		if (entering) {
			entering.animate([{ transform: "translateX(60px)", opacity: 0 }, { transform: "none", opacity: 1 }], { duration: 300, easing: "cubic-bezier(0.38, 1.21, 0.22, 1)" });
		}
		spur.tab.setAttribute("pshell-spur", String(spur.cols.length));
		PARTS.find(part => part.name === "marks").badges(spur.tab);
		drawCrumbs(W, spur);
	}

	// the crumbs are kept and updated; one comes in moving only when its
	// column is new (a title arriving later just changes its text)
	function drawCrumbs(W, spur) {
		const shown = tabsConfig().spur.columns;
		const nodes = [...spur.crumbs.querySelectorAll(".pshell-spur-crumb")];
		let keep = 0;
		while (keep < nodes.length && keep < spur.cols.length && nodes[keep].pshellBrowser === spur.cols[keep].browser) keep++;
		for (const node of nodes.slice(keep)) {
			const arrow = node.previousElementSibling;
			if (arrow?.classList.contains("pshell-spur-arrow")) arrow.remove();
			node.remove();
		}
		spur.cols.forEach((col, index) => {
			let crumb = nodes[index];
			if (index >= keep) {
				if (index > 0) el(W.doc, "span", { class: "pshell-spur-arrow" }, spur.crumbs);
				crumb = el(W.doc, "span", { class: "pshell-spur-crumb", role: "button", fresh: true, "data-index": index }, spur.crumbs);
				crumb.pshellBrowser = col.browser;
			}
			const { title, host } = titleOf(col.browser);
			if (crumb.textContent !== title) crumb.textContent = title;
			crumb.title = host;
			crumb.toggleAttribute("active", index === spur.active);
			crumb.toggleAttribute("older", index < spur.start || index >= spur.start + shown);
		});
	}

	function retitle(W, spur) {
		const newest = spur.cols[spur.cols.length - 1];
		if (!newest) return;
		if (newest.own) {
			W.gBrowser.setTabTitle(spur.tab);
			return;
		}
		const { title } = titleOf(newest.browser);
		if (spur.tab.getAttribute("label") === title) return;
		spur.tab.setAttribute("label", title);
		try {
			W.gBrowser._tabAttrModified(spur.tab, ["label"]);
		} catch (error) {}
	}

	function finish(W, tab) {
		const spur = W.spurs.get(tab);
		if (!spur) return;
		const newest = spur.cols[spur.cols.length - 1];
		if (!newest.own) {
			let moved = false;
			try {
				const remoteType = newest.browser.remoteType;
				if (remoteType && tab.linkedBrowser.remoteType !== remoteType) {
					W.gBrowser.updateBrowserRemoteness(tab.linkedBrowser, { remoteType });
				}
				W.gBrowser._swapBrowserDocShells(tab, newest.browser);
				moved = true;
			} catch (error) {
				console.error("[pshell] spur end:", error);
			}
			if (!moved) {
				const url = newest.browser.currentURI?.spec;
				if (url) tab.linkedBrowser.fixupAndLoadURIString(url, { triggeringPrincipal: SYSTEM() });
			}
		}
		teardown(W, spur);
		tab.linkedBrowser.focus();
		W.gBrowser.setTabTitle(tab);
	}

	function teardown(W, spur) {
		drop(W, spur, 1);
		spur.stack.removeAttribute("pshell-spur");
		spur.tab.removeAttribute("pshell-spur");
		PARTS.find(part => part.name === "marks").badges(spur.tab);
		spur.cols[0].browser.removeAttribute("pshell-active");
		spur.cols[0].browser.removeAttribute("pshell-hidden");
		spur.cols[0].browser.style.removeProperty("--pshell-grow");
		const bar = spur.bar;
		bar.animate([{ opacity: 1 }, { translate: "0 -10px", opacity: 0 }], { duration: 160, easing: "ease-in", fill: "forwards" }).finished.then(() => bar.remove(), () => bar.remove());
		W.spurs.delete(spur.tab);
		if (spur.tab.isConnected) W.gBrowser.setTabTitle(spur.tab);
		updatePage(W, spur.tab.linkedBrowser);
	}

	COMMANDS.spur = async args => {
		const tab = args.tabId >= 0 ? nativeTab(args.tabId) : frontWindow()?.gBrowser.selectedTab;
		if (!tab) throw new Error("no such tab");
		const W = windowOf(tab);
		if (W.spurs.has(tab)) finish(W, tab);
		else start(W, tab);
		return W.spurs.has(tab);
	};

	PARTS.push({
		name: "spur",
		addColumn,
		pageState(W, browser, state) {
			state.spur = !!spurOf(W, browser);
		},
		attach(W) {
			W.spurs = new Map();
			on(W, W.gBrowser.tabContainer, "TabClose", event => {
				const spur = W.spurs.get(event.target);
				if (spur) teardown(W, spur);
			});
			// Ctrl+Alt+click: Floorp keeps the chord's mousedown from the page
			// (it drags the window), the click still comes here
			on(W, W.win, "click", event => {
				if (event.button !== 0 || !event.ctrlKey || !event.altKey || event.shiftKey || event.metaKey) return;
				const browser = event.target;
				if (browser?.localName !== "browser" || !browser.messageManager) return;
				const box = browser.getBoundingClientRect();
				const zoom = browser.fullZoom || 1;
				sendPage(browser, "linkAt", { x: (event.clientX - box.x) / zoom, y: (event.clientY - box.y) / zoom });
			}, true);
			on(W, W.win, "keydown", event => {
				if (event.altKey && !event.ctrlKey && !event.shiftKey && event.key === "Escape" && W.spurs.has(W.gBrowser.selectedTab)) {
					if (W.doc.activeElement?.localName === "browser") return; // the page's script sends it
					event.preventDefault();
					finish(W, W.gBrowser.selectedTab);
					return;
				}
				if (!event.altKey || event.ctrlKey || !/^Arrow(Left|Right)$/.test(event.key)) return;
				const spur = W.spurs.get(W.gBrowser.selectedTab);
				if (!spur || W.doc.activeElement?.localName === "browser") return;
				event.preventDefault();
				move(W, spur, event.key === "ArrowLeft" ? -1 : 1);
			}, true);
		},
		configure(W) {
			for (const spur of W.spurs.values()) {
				spur.start = Math.max(0, spur.cols.length - tabsConfig().spur.columns);
				layout(W, spur);
			}
		},
		page: {
			link(W, browser, data) {
				const url = String(data.url || "");
				if (data.how === "spurRight") {
					const spur = spurOf(W, browser);
					if (spur) addColumn(W, spur.tab, url, { after: browser, principal: browser.contentPrincipal });
				} else if (data.how === "spur") {
					const spur = spurOf(W, browser);
					const tab = spur ? spur.tab : W.gBrowser.getTabForBrowser(browser) || (W.peek && W.peek.browser === browser ? W.peek.tab : null);
					if (tab) addColumn(W, tab, url, { after: spur ? browser : null, principal: browser.contentPrincipal });
				}
			},
			spurKey(W, browser, data) {
				const spur = spurOf(W, browser);
				if (!spur) return;
				if (data.key === "Escape") finish(W, spur.tab);
				else move(W, spur, data.key === "ArrowLeft" ? -1 : 1);
			},
			spurFocus(W, browser) {
				const spur = spurOf(W, browser);
				if (!spur) return;
				const index = spur.cols.findIndex(col => col.browser === browser);
				if (index >= 0 && index !== spur.active) {
					spur.active = index;
					layout(W, spur);
				}
			}
		},
		detach(W) {
			for (const spur of [...W.spurs.values()]) teardown(W, spur);
		}
	});
})();
