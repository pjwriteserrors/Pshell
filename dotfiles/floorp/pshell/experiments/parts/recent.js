/* "Recent": at the top of the rail, tiles of the tabs used in the last
 * minutes (Settings › Browser › Tabs: Recent, Recent window). A tab comes in
 * when it is looked at and keeps its place while it is in; each tile fades
 * with the time since it was last looked at, a line under it shows what is
 * left, and when that runs out it slips away. A full row lets the oldest go.
 * A tile is a way to its tab; nothing is closed on its own, a middle click
 * takes a tile out (its tab stays open) until the tab is picked again. Pinned tabs live in the
 * dock instead, a private window has none. Alt+1…9 picks a tile by its place
 * (the number in its corner), Alt+0 the last one (keys.js). */
"use strict";

(function () {
	const TICK = 10000;

	function windowMs() {
		return tabsConfig().recent.minutes * 60000;
	}

	function usable(W, tab) {
		return tab && tab.isConnected && !tab.pinned && !tab.closing && !tab.hidden;
	}

	function touch(W, tab) {
		if (!usable(W, tab) || W.recentOut.has(tab)) return;
		const entry = W.recent.find(item => item.tab === tab);
		const now = Date.now();
		if (entry) {
			entry.at = now;
			return;
		}
		W.recent.push({ tab, at: now });
		const max = tabsConfig().recent.count;
		while (W.recent.length > max) {
			let oldest = 0;
			W.recent.forEach((item, index) => {
				if (item.at < W.recent[oldest].at) oldest = index;
			});
			W.recent.splice(oldest, 1);
		}
	}

	function iconOf(W, tab) {
		return tab.getAttribute("image") || W.gBrowser.getIcon(tab) || "chrome://global/skin/icons/defaultFavicon.svg";
	}

	function makeTile(W, tab) {
		const tile = el(W.doc, "div", { class: "pshell-rt", role: "button", entering: true });
		el(W.doc, "img", { class: "pshell-rt-icon", alt: "" }, tile);
		el(W.doc, "span", { class: "pshell-rt-label" }, tile);
		el(W.doc, "span", { class: "pshell-rt-left" }, tile);
		tile.pshellTab = tab;
		return tile;
	}

	function draw(W) {
		const box = W.recentBox;
		if (!box) return;
		const tabs = tabsConfig();
		const shown = tabs.recent.on && !W.private;
		box.hidden = !shown;
		if (!shown) return;
		const now = Date.now();
		const span = windowMs();
		const focused = Services.focus.activeWindow === W.win;
		const selected = W.gBrowser.selectedTab;
		// the tab in front is being used for as long as it is in front
		if (focused) touch(W, selected);
		W.recent = W.recent.filter(item => usable(W, item.tab) && now - item.at < span);
		const keep = new Set(W.recent.map(item => item.tab));

		const gone = [];
		for (const tile of [...box.children]) {
			if (!tile.pshellTab || keep.has(tile.pshellTab) || tile.hasAttribute("leaving")) continue;
			gone.push(tile);
		}
		for (const item of W.recent) {
			let tile = [...box.children].find(node => node.pshellTab === item.tab && !node.hasAttribute("leaving"));
			if (!tile) {
				tile = makeTile(W, item.tab);
				// a newcomer takes the place of one going, so the others stay put
				const place = gone.shift();
				if (place) place.replaceWith(tile);
				else box.appendChild(tile);
				W.win.requestAnimationFrame(() => W.win.requestAnimationFrame(() => tile.removeAttribute("entering")));
			}
			const tab = item.tab;
			const front = tab === selected;
			const share = Math.min(1, Math.max(0, (now - item.at) / span));
			tile.toggleAttribute("selected", front);
			tile.style.setProperty("--pshell-fade", front ? "1" : (1 - 0.65 * share).toFixed(3));
			tile.style.setProperty("--pshell-left", front ? "100%" : `${((1 - share) * 100).toFixed(1)}%`);
			tile.title = tab.label;
			const env = tab.getAttribute("pshell-env");
			if (env) tile.setAttribute("pshell-env", env);
			else tile.removeAttribute("pshell-env");
			tile.toggleAttribute("busy", tab.hasAttribute("busy"));
			tile.toggleAttribute("soundplaying", tab.hasAttribute("soundplaying"));
			tile.querySelector(".pshell-rt-label").textContent = tab.label;
			const icon = tile.querySelector(".pshell-rt-icon");
			const src = iconOf(W, tab);
			if (icon.getAttribute("src") !== src) icon.setAttribute("src", src);
		}
		for (const tile of gone) {
			tile.setAttribute("leaving", "");
			W.win.setTimeout(() => tile.remove(), 280);
		}
		// their numbers, for Alt+1…9
		tiles(W).forEach((tile, index) => {
			if (index < 9) tile.setAttribute("pshell-n", String(index + 1));
			else tile.removeAttribute("pshell-n");
		});
		const latest = new Set([...W.recent].sort((a, b) => b.at - a.at).slice(0, 3).map(item => item.tab));
		for (const tile of box.children) tile.toggleAttribute("recent3", latest.has(tile.pshellTab) || tile.pshellTab === selected);
		box.toggleAttribute("empty", W.recent.length === 0);
	}

	function tiles(W) {
		return W.recentBox ? [...W.recentBox.children].filter(tile => tile.pshellTab && !tile.hasAttribute("leaving")) : [];
	}

	// Alt+N: the Nth tile, 0 the last
	function pick(W, n) {
		const list = tiles(W);
		const tile = n === 0 ? list[list.length - 1] : list[n - 1];
		if (!tile || !tile.pshellTab.isConnected) return false;
		W.gBrowser.selectedTab = tile.pshellTab;
		return true;
	}

	function soon(W) {
		if (W.recentDue) return;
		W.recentDue = true;
		W.win.requestAnimationFrame(() => {
			W.recentDue = false;
			draw(W);
		});
	}

	PARTS.push({
		name: "recent",
		pick,
		attach(W) {
			W.recent = [];
			W.recentOut = new WeakSet();
			const tabsBox = W.doc.getElementById("tabbrowser-tabs");
			const holder = W.doc.getElementById("vertical-tabs");
			if (!holder || !tabsBox) return;
			W.recentBox = el(W.doc, "div", { id: "pshell-recent", hidden: true });
			holder.insertBefore(W.recentBox, tabsBox);
			// what was used in the window before: Firefox keeps when a tab was last selected
			const span = windowMs();
			const now = Date.now();
			const earlier = [...W.gBrowser.tabs]
				.filter(tab => usable(W, tab) && tab.lastAccessed && now - tab.lastAccessed < span)
				.sort((a, b) => a.lastAccessed - b.lastAccessed)
				.slice(-tabsConfig().recent.count);
			for (const tab of earlier) W.recent.push({ tab, at: tab.lastAccessed });

			on(W, W.recentBox, "click", event => {
				const tile = event.target.closest(".pshell-rt");
				if (tile && tile.pshellTab && tile.pshellTab.isConnected) W.gBrowser.selectedTab = tile.pshellTab;
			});
			// a middle click takes the tile out; its tab stays open
			on(W, W.recentBox, "mousedown", event => {
				if (event.button === 1 && event.target.closest(".pshell-rt")) event.preventDefault();
			});
			on(W, W.recentBox, "auxclick", event => {
				const tile = event.target.closest(".pshell-rt");
				if (event.button !== 1 || !tile || !tile.pshellTab?.isConnected) return;
				event.preventDefault();
				W.recentOut.add(tile.pshellTab);
				W.recent = W.recent.filter(item => item.tab !== tile.pshellTab);
				draw(W);
			});
			on(W, W.gBrowser.tabContainer, "TabSelect", () => {
				// picked again: it may come back
				W.recentOut.delete(W.gBrowser.selectedTab);
				if (!W.private) touch(W, W.gBrowser.selectedTab);
				soon(W);
			});
			for (const type of ["TabClose", "TabPinned", "TabAttrModified", "TabHide"]) {
				on(W, W.gBrowser.tabContainer, type, () => soon(W));
			}
			on(W, W.win, "focus", () => soon(W));
			every(W, TICK, () => draw(W));
			draw(W);
		},
		configure(W) {
			draw(W);
		},
		detach(W) {
			W.recentBox?.remove();
			W.recentBox = null;
		}
	});
})();
