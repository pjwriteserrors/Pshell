/* Spur: pages as columns side by side in one tab, like windows in niri
 * (Settings › Browser › Navigation: Spur, Columns).
 *
 * Ctrl+Alt+click on a link, "v" in the hints, "Spur" on a peek or the
 * launcher's command starts it; while it runs every plain click on a link
 * opens on the right of its column, cutting off what was right of it. Only
 * the last few columns show, the older ones shrink and then live only in the
 * crumbs above; a crumb shows its column again. Alt+←/→ moves between
 * columns, a middle click on a crumb closes its column. The whole Spur is one tab, titled after its newest column; ending
 * it ("Beenden" on the crumbs, Alt+Esc) keeps the newest column as the tab's
 * page.
 *
 * Breakpoints (work only, the toolbar button of parts/breakpoints.js, the
 * launcher's command): the tab's page as Mobile, Tablet and Desktop side by
 * side, each column as wide as its breakpoint for the page (zoomed out to
 * fit), scrolling together; a link clicked in one opens in all, an address
 * loaded in the tab too. A column keeps the tab's container. */
"use strict";

(function () {
	const WEIGHTS = [1.55, 1, 0.78, 0.64];
	// the tab's own page is the last, the widest
	const BREAKPOINTS = [
		{ name: "Mobile", width: 390 },
		{ name: "Tablet", width: 820 },
		{ name: "Desktop", width: 1440 }
	];
	const GAP = 6;

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
			if (!crumb) return;
			if (spur.breakpoints) focusColumn(W, spur, Number(crumb.dataset.index));
			else cut(W, spur, Number(crumb.dataset.index));
		});
		// a middle click closes a crumb's column, like a tab
		crumbs.addEventListener("mousedown", event => {
			if (event.button === 1 && event.target.closest(".pshell-spur-crumb")) event.preventDefault();
		});
		crumbs.addEventListener("auxclick", event => {
			const crumb = event.target.closest(".pshell-spur-crumb");
			if (event.button !== 1 || !crumb || spur.breakpoints) return;
			event.preventDefault();
			close(W, spur, Number(crumb.dataset.index));
		});
		end.addEventListener("click", () => finish(W, tab));
		tab.setAttribute("pshell-spur", "1");
		bar.animate([{ translate: "0 -10px", opacity: 0 }, { translate: "0 0", opacity: 1 }], { duration: 220, easing: "cubic-bezier(0.2, 0, 0, 1)" });
		layout(W, spur);
		for (const col of spur.cols) updatePage(W, col.browser);
		return spur;
	}

	function makeBrowser(W, tab) {
		const browser = W.doc.createXULElement("browser");
		// the tab's container (parts/containers.js)
		const userContextId = tab?.getAttribute("usercontextid");
		if (userContextId) browser.setAttribute("usercontextid", userContextId);
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
		if (!/^(https?|file):/i.test(url)) return false;
		const open = W.spurs.get(tab);
		if (open?.breakpoints) return navigateAll(W, open, url, options.principal);
		if (!tabsConfig().spur.on || W.private) return false;
		const spur = start(W, tab);
		// a click in an older column cuts off what was right of it
		const after = options.after ? spur.cols.findIndex(col => col.browser === options.after) : spur.cols.length - 1;
		if (after >= 0 && after < spur.cols.length - 1) drop(W, spur, after + 1);
		const browser = makeBrowser(W, tab);
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

	// one column goes; the others stay. The tab's own page cannot leave its
	// tab: the next column's page moves into it instead. One left ends the Spur.
	function close(W, spur, index) {
		if (index < 0 || index >= spur.cols.length) return;
		if (spur.cols.length === 2) {
			if (index === 0) finish(W, spur.tab); // keeps the newest
			else {
				teardown(W, spur);
				spur.tab.linkedBrowser.focus();
			}
			return;
		}
		let gone = index;
		if (index === 0) {
			// (Firefox keeps swapping a page between browsers to itself, so the
			// next column's address loads in the tab instead)
			const url = spur.cols[1].browser.currentURI?.spec;
			if (!url) return;
			spur.tab.linkedBrowser.fixupAndLoadURIString(url, { triggeringPrincipal: SYSTEM() });
			gone = 1;
		}
		const [col] = spur.cols.splice(gone, 1);
		try {
			col.browser.webProgress?.removeProgressListener(col.progress);
		} catch (error) {}
		col.browser.remove();
		if (spur.active > index || spur.active >= spur.cols.length) spur.active = Math.max(0, spur.active - 1);
		spur.start = Math.max(0, Math.min(spur.start, spur.cols.length - tabsConfig().spur.columns));
		// the crumbs from the gone one on are made anew
		const nodes = [...spur.crumbs.querySelectorAll(".pshell-spur-crumb")];
		for (const node of nodes.slice(index)) node.pshellBrowser = null;
		layout(W, spur);
		spur.cols[spur.active].browser.focus();
		retitle(W, spur);
		for (const left of spur.cols) updatePage(W, left.browser);
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
		if (spur.breakpoints) {
			// in the order they show
			const shown = spur.cols.map((col, index) => index).sort((a, b) => BREAKPOINTS.indexOf(spur.cols[a].bp) - BREAKPOINTS.indexOf(spur.cols[b].bp));
			const at = shown.indexOf(spur.active);
			const to = shown[Math.max(0, Math.min(shown.length - 1, at + step))];
			if (to !== spur.active) focusColumn(W, spur, to);
			return;
		}
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
		if (spur.breakpoints) return layoutBreakpoints(W, spur);
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
			const label = col.bp ? `${col.bp.name} ${col.bp.width}` : title;
			if (crumb.textContent !== label) crumb.textContent = label;
			if (col.bp) crumb.style.order = String(BREAKPOINTS.indexOf(col.bp));
			crumb.title = col.bp ? title : host;
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
		if (spur.breakpoints) {
			// the tab keeps its own page, the desktop one
			teardown(W, spur);
			tab.linkedBrowser.focus();
			return;
		}
		const newest = spur.cols[spur.cols.length - 1];
		if (!newest.own) {
			let moved = false;
			// the page itself moves where Firefox still lets it (older versions);
			// otherwise its address loads in the tab
			if (typeof W.gBrowser._swapBrowserDocShells === "function") {
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
		if (spur.breakpoints) {
			for (const col of spur.cols) PARTS.find(part => part.name === "breakpoints")?.unwatch(W, col.browser);
			const own = spur.cols[0].browser;
			try {
				own.webProgress?.removeProgressListener(spur.ownProgress);
			} catch (error) {}
			for (const property of ["flex", "width", "order"]) own.style.removeProperty(property);
			own.removeAttribute("pshell-bp");
			try {
				own.fullZoom = spur.ownZoom || 1;
			} catch (error) {}
			spur.stack.removeAttribute("pshell-breakpoints");
		}
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

	// ── breakpoints ──────────────────────────────────────────────────────────
	function focusColumn(W, spur, index) {
		const col = spur.cols[index];
		if (!col) return;
		spur.active = index;
		layout(W, spur);
		col.browser.focus();
	}

	function loadIn(browser, url, principal) {
		try {
			browser.fixupAndLoadURIString(url, { triggeringPrincipal: principal || SYSTEM() });
		} catch (error) {
			browser.fixupAndLoadURIString(url, { triggeringPrincipal: SYSTEM() });
		}
	}

	// a link from one column: every column shows it
	function navigateAll(W, spur, url, principal) {
		spur.synced = url;
		for (const col of spur.cols) loadIn(col.browser, url, principal);
		return true;
	}

	function layoutBreakpoints(W, spur) {
		const box = spur.stack.getBoundingClientRect();
		const room = Math.max(200, box.width - GAP * (spur.cols.length - 1) - 8);
		const total = spur.cols.reduce((sum, col) => sum + col.bp.width, 0);
		const scale = Math.min(1, room / total);
		spur.scale = scale;
		spur.cols.forEach((col, index) => {
			const browser = col.browser;
			browser.removeAttribute("pshell-hidden");
			browser.toggleAttribute("pshell-active", index === spur.active);
			browser.setAttribute("pshell-bp", col.bp.name.toLowerCase());
			browser.style.setProperty("flex", "none", "important");
			browser.style.setProperty("width", `${Math.floor(col.bp.width * scale)}px`, "important");
			browser.style.setProperty("order", String(BREAKPOINTS.indexOf(col.bp)));
			try {
				if (Math.abs((browser.fullZoom || 1) - scale) > 0.001) browser.fullZoom = scale;
			} catch (error) {}
		});
		spur.tab.setAttribute("pshell-spur", String(spur.cols.length));
		PARTS.find(part => part.name === "marks").badges(spur.tab);
		drawCrumbs(W, spur);
	}

	// the tab's page as Mobile, Tablet and Desktop; again ends it
	function breakpoints(W, tab) {
		tab = tab || W.gBrowser.selectedTab;
		const open = W.spurs.get(tab);
		if (open) {
			const was = !!open.breakpoints;
			finish(W, tab);
			if (was) return false;
		}
		if (!tabsConfig().work || W.private) return false;
		const own = tab.linkedBrowser;
		const url = own.currentURI?.spec || "";
		if (!/^(https?|file):/i.test(url)) return false;
		const spur = start(W, tab);
		spur.breakpoints = true;
		spur.ownZoom = own.fullZoom || 1;
		spur.synced = url;
		spur.stack.setAttribute("pshell-breakpoints", "");
		// the tab's own page is the desktop; the others come before it
		spur.cols[0].bp = BREAKPOINTS[BREAKPOINTS.length - 1];
		const watcher = PARTS.find(part => part.name === "breakpoints");
		for (const bp of BREAKPOINTS.slice(0, -1).reverse()) {
			const browser = makeBrowser(W, tab);
			spur.stack.appendChild(browser);
			const col = { browser, own: false, bp };
			spur.cols.push(col);
			browser.addEventListener("pagetitlechanged", () => drawCrumbs(W, spur));
			col.progress = {
				QueryInterface: ChromeUtils.generateQI(["nsIWebProgressListener", "nsISupportsWeakReference"]),
				onLocationChange: () => drawCrumbs(W, spur),
				onStateChange() {},
				onProgressChange() {},
				onStatusChange() {},
				onSecurityChange() {},
				onContentBlockingEvent() {}
			};
			browser.webProgress?.addProgressListener(col.progress, Ci.nsIWebProgress.NOTIFY_LOCATION);
			loadIn(browser, url, own.contentPrincipal);
			watcher?.watch(W, browser);
		}
		watcher?.watch(W, own);
		// an address loaded in the tab itself (the address bar, back, a
		// bookmark): the other columns follow
		spur.ownProgress = {
			QueryInterface: ChromeUtils.generateQI(["nsIWebProgressListener", "nsISupportsWeakReference"]),
			onLocationChange(webProgress, request, location, flags) {
				if (!webProgress?.isTopLevel || flags & Ci.nsIWebProgressListener.LOCATION_CHANGE_SAME_DOCUMENT) return;
				// (Firefox's zoom per site comes back with a new page)
				for (const ms of [50, 400]) W.win.setTimeout(() => W.spurs.get(spur.tab) === spur && layout(W, spur), ms);
				if (flags & Ci.nsIWebProgressListener.LOCATION_CHANGE_ERROR_PAGE) return;
				const next = location?.spec || "";
				if (!/^(https?|file):/i.test(next) || next === spur.synced) return;
				spur.synced = next;
				for (const col of spur.cols) if (!col.own) loadIn(col.browser, next, own.contentPrincipal);
			},
			onStateChange() {},
			onProgressChange() {},
			onStatusChange() {},
			onSecurityChange() {},
			onContentBlockingEvent() {}
		};
		own.webProgress?.addProgressListener(spur.ownProgress, Ci.nsIWebProgress.NOTIFY_LOCATION);
		spur.active = 0;
		layout(W, spur);
		for (const col of spur.cols) updatePage(W, col.browser);
		return true;
	}

	// the other columns of a breakpoints Spur (they scroll with this one)
	function columnsBeside(W, browser) {
		const spur = spurOf(W, browser);
		return spur?.breakpoints ? spur.cols.map(col => col.browser).filter(other => other !== browser) : [];
	}

	COMMANDS.breakpoints = async args => {
		const tab = args.tabId >= 0 ? nativeTab(args.tabId) : frontWindow()?.gBrowser.selectedTab;
		if (!tab) throw new Error("no such tab");
		return breakpoints(windowOf(tab), tab);
	};

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
		breakpoints,
		columnsBeside,
		isBreakpoints: (W, tab) => !!W.spurs?.get(tab)?.breakpoints,
		pageState(W, browser, state) {
			state.spur = !!spurOf(W, browser);
		},
		attach(W) {
			W.spurs = new Map();
			// the tab's own page got a title: its crumb follows, and the tab keeps
			// the newest column's
			on(W, W.gBrowser.tabContainer, "TabAttrModified", event => {
				const spur = W.spurs.get(event.target);
				if (!spur || !event.detail?.changed?.includes("label")) return;
				drawCrumbs(W, spur);
				retitle(W, spur);
			});
			// the breakpoints' widths follow the window's; Firefox's zoom per
			// site comes back on the tab's page when it is selected
			const relayout = () => {
				const spur = W.spurs.get(W.gBrowser.selectedTab);
				if (spur?.breakpoints) layout(W, spur);
			};
			on(W, W.win, "resize", () => W.win.requestAnimationFrame(relayout));
			on(W, W.gBrowser.tabContainer, "TabSelect", () => W.win.setTimeout(relayout, 60));
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
		configure(W, tabs) {
			for (const spur of [...W.spurs.values()]) {
				if (spur.breakpoints && !tabs.work) {
					finish(W, spur.tab);
					continue;
				}
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
