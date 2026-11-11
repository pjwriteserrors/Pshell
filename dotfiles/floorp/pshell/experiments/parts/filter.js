/* Typing over the rail filters it (Settings › Browser › Tabs: Typing filters
 * the rail): with the pointer on the rail and no text field focused, letters
 * go to the rail instead of the page. Matching tabs stay, the others fade,
 * nothing moves; closed groups with a match open for as long as it lasts.
 * Enter takes the first match, Escape or leaving the rail clears it. */
"use strict";

(function () {
	function hostOf(tab) {
		try {
			return tab.linkedBrowser.currentURI.host || "";
		} catch (error) {
			return "";
		}
	}

	// letters of the query in order (any gaps), or the query as one piece
	function matches(text, query) {
		const low = text.toLowerCase();
		if (low.includes(query)) return 2;
		let at = 0;
		for (const ch of low) {
			if (ch === query[at]) at++;
			if (at === query.length) return 1;
		}
		return 0;
	}

	function apply(W) {
		const query = (W.filter || "").toLowerCase();
		const root = W.doc.documentElement;
		root.toggleAttribute("pshell-filtering", !!query);
		if (W.filterBox) {
			W.filterBox.querySelector(".pshell-filter-text").textContent = W.filter || "";
			W.filterBox.toggleAttribute("open", !!query);
		}
		let first = null;
		let best = 0;
		const groups = new Set();
		for (const tab of W.gBrowser.tabs) {
			tab.removeAttribute("pshell-first");
			if (!query) {
				tab.removeAttribute("pshell-miss");
				continue;
			}
			const score = matches(`${tab.label} ${hostOf(tab)}`, query);
			tab.toggleAttribute("pshell-miss", score === 0);
			if (score && tab.group) groups.add(tab.group);
			if (score > best) {
				best = score;
				first = tab;
			}
		}
		if (first) first.setAttribute("pshell-first", "");
		W.filterFirst = first;
		for (const group of W.gBrowser.tabGroups) group.toggleAttribute("pshell-miss", !!query && !groups.has(group));
		// closed groups open while they hold a match, and close again after
		for (const group of W.gBrowser.tabGroups) {
			if (groups.has(group) && group.collapsed) {
				W.filterOpened.add(group);
				group.collapsed = false;
			}
		}
		if (!query) {
			for (const group of W.filterOpened) if (group.isConnected) group.collapsed = true;
			W.filterOpened.clear();
		}
		// the best match comes into view (after a group it is in has opened)
		if (first && !first.pinned) {
			W.win.requestAnimationFrame(() => {
				try {
					W.gBrowser.tabContainer.arrowScrollbox.ensureElementIsVisible(first);
				} catch (error) {}
			});
		}
		updatePage(W, W.gBrowser.selectedBrowser);
	}

	function key(W, name) {
		if (name === "Escape") W.filter = "";
		else if (name === "Backspace") W.filter = (W.filter || "").slice(0, -1);
		else if (name === "Enter") {
			const tab = W.filterFirst;
			W.filter = "";
			apply(W);
			if (tab) W.gBrowser.selectedTab = tab;
			return;
		} else if (name.length === 1) W.filter = (W.filter || "") + name;
		else return;
		apply(W);
	}

	function editable(node) {
		if (!node) return false;
		if (node.localName === "browser") return true; // the page handles its own keys
		return node.isContentEditable || /^(input|textarea|select|moz-input-box)$/.test(node.localName) || !!node.closest?.("#urlbar, .urlbar, searchbar");
	}

	function setOver(W, over) {
		if (W.overRail === over) return;
		W.overRail = over;
		W.win.clearTimeout(W.filterLeave);
		if (!over && W.filter) {
			W.filterLeave = W.win.setTimeout(() => {
				W.filter = "";
				apply(W);
			}, 600);
		}
		updatePage(W, W.gBrowser.selectedBrowser);
	}

	PARTS.push({
		name: "filter",
		pageState(W, browser, state) {
			const on = tabsConfig().filter && browser === W.gBrowser.selectedBrowser;
			state.rail = !!(on && W.overRail);
			state.filtering = !!(on && W.filter);
		},
		attach(W) {
			W.filter = "";
			W.filterOpened = new Set();
			const rail = W.doc.querySelector("sidebar-main");
			const holder = W.doc.getElementById("vertical-tabs");
			const tabsBox = W.doc.getElementById("tabbrowser-tabs");
			if (holder && tabsBox) {
				W.filterBox = el(W.doc, "div", { id: "pshell-filter" });
				el(W.doc, "span", { class: "pshell-filter-icon" }, W.filterBox);
				el(W.doc, "span", { class: "pshell-filter-text" }, W.filterBox);
				holder.insertBefore(W.filterBox, tabsBox);
			}
			if (rail) {
				on(W, rail, "mouseenter", () => setOver(W, tabsConfig().filter));
				on(W, rail, "mouseleave", () => setOver(W, false));
			}
			// with the window's own controls focused (not a page)
			on(W, W.win, "keydown", event => {
				if (!W.overRail || event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey) return;
				if (editable(W.doc.activeElement)) return;
				const name = event.key;
				if (name.length !== 1 && !(W.filter && ["Escape", "Backspace", "Enter"].includes(name))) return;
				if (name === " " && !W.filter) return;
				event.preventDefault();
				event.stopPropagation();
				key(W, name);
			}, true);
			on(W, W.gBrowser.tabContainer, "TabSelect", event => {
				if (W.filter) {
					W.filter = "";
					apply(W);
				}
				// only the page in front takes letters for the rail
				const before = event.detail?.previousTab?.linkedBrowser;
				if (before) updatePage(W, before);
				updatePage(W, W.gBrowser.selectedBrowser);
			});
		},
		page: {
			railKey(W, browser, data) {
				if (browser === W.gBrowser.selectedBrowser && W.overRail) key(W, String(data.key || ""));
			}
		},
		configure(W, tabs) {
			if (!tabs.filter && W.filter) {
				W.filter = "";
				apply(W);
			}
		},
		detach(W) {
			W.filter = "";
			apply(W);
			W.filterBox?.remove();
			W.doc.documentElement.removeAttribute("pshell-filtering");
		}
	});
})();
