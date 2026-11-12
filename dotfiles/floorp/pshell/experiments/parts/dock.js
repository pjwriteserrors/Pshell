/* "Pinned": the pinned tabs as a row at the foot of the rail (Settings ›
 * Browser › Tabs: Pinned at the foot). Alt+1…9 belong to the recent tiles;
 * the shell's "slot" command still takes a place by its number.
 *
 * A pinned tab remembers the page it was pinned on; the slot command on the
 * tab already in front goes back there. A pinned tab that was closed leaves
 * its place behind, faded: a click opens it again, a middle click lets it go.
 * Unpinning lets a place go as well. */
"use strict";

(function () {
	const PREF = "pshell.tabs.dockGhosts";
	const MAX = 6;

	function ghosts() {
		try {
			const list = JSON.parse(Services.prefs.getStringPref(PREF, "[]"));
			return Array.isArray(list) ? list.filter(item => item && item.url) : [];
		} catch (error) {
			return [];
		}
	}

	function setGhosts(list) {
		Services.prefs.setStringPref(PREF, JSON.stringify(list.slice(0, MAX)));
		for (const W of attached) drawGhosts(W);
	}

	function pinned(W) {
		return W.gBrowser.tabs.filter(tab => tab.pinned && !tab.closing);
	}

	function originOf(tab) {
		try {
			return SessionStore.getCustomTabValue(tab, "pshell-origin") || "";
		} catch (error) {
			return "";
		}
	}

	const blank = url => !url || url === "about:blank";

	function remember(tab) {
		const url = PARTS.find(part => part.name === "env").urlOf(tab);
		if (!blank(url) && blank(originOf(tab))) SessionStore.setCustomTabValue(tab, "pshell-origin", url);
	}

	function reopen(W, ghost) {
		setGhosts(ghosts().filter(item => item.url !== ghost.url));
		const tab = W.gBrowser.addTrustedTab(ghost.url, { inBackground: false });
		W.gBrowser.pinTab(tab);
		SessionStore.setCustomTabValue(tab, "pshell-origin", ghost.url);
		W.gBrowser.selectedTab = tab;
	}

	function slot(W, n) {
		const tabs = pinned(W);
		const tab = tabs[n - 1];
		if (tab) {
			remember(tab);
			if (tab.selected) {
				const origin = originOf(tab);
				const now = tab.linkedBrowser.currentURI?.spec || "";
				if (!blank(origin) && origin !== now) {
					tab.linkedBrowser.fixupAndLoadURIString(origin, { triggeringPrincipal: SYSTEM() });
				}
			} else {
				W.gBrowser.selectedTab = tab;
			}
			return true;
		}
		const ghost = ghosts()[n - 1 - tabs.length];
		if (ghost) {
			reopen(W, ghost);
			return true;
		}
		return false;
	}

	function drawGhosts(W) {
		const box = W.ghostBox;
		if (!box) return;
		const list = tabsConfig().dock && !W.private ? ghosts() : [];
		box.hidden = list.length === 0;
		box.replaceChildren();
		for (const ghost of list) {
			const item = el(W.doc, "div", { class: "pshell-ghost", role: "button", title: ghost.title || ghost.url }, box);
			el(W.doc, "img", { src: ghost.icon || "chrome://global/skin/icons/defaultFavicon.svg", alt: "" }, item);
			item.pshellGhost = ghost;
		}
		number(W);
	}

	// the places carry no numbers any more (Alt+1…9 are the recent tiles')
	function number(W) {
		for (const tab of pinned(W)) tab.removeAttribute("pshell-slot");
	}

	COMMANDS.slot = async args => {
		const W = frontWindow();
		return W ? slot(W, Number(args.slot) || 1) : false;
	};

	COMMANDS.pin = async args => {
		const tab = nativeTab(args.tabId);
		if (!tab) throw new Error("no such tab");
		const W = windowOf(tab);
		if (!tab.pinned) W.gBrowser.pinTab(tab);
		remember(tab);
		const index = Math.max(0, Math.min(pinned(W).length - 1, (Number(args.slot) || 1) - 1));
		try {
			W.gBrowser.moveTabTo(tab, { tabIndex: index });
		} catch (error) {
			try {
				W.gBrowser.moveTabTo(tab, index);
			} catch (error2) {}
		}
		number(W);
		return true;
	};

	PARTS.push({
		name: "dock",
		slot,
		attach(W) {
			const container = W.doc.getElementById("pinned-tabs-container");
			if (container && container.parentNode) {
				W.ghostBox = el(W.doc, "div", { id: "pshell-ghosts", hidden: true });
				container.parentNode.insertBefore(W.ghostBox, container.nextSibling);
				on(W, W.ghostBox, "click", event => {
					const item = event.target.closest(".pshell-ghost");
					if (item) reopen(W, item.pshellGhost);
				});
				on(W, W.ghostBox, "auxclick", event => {
					const item = event.target.closest(".pshell-ghost");
					if (item && event.button === 1) setGhosts(ghosts().filter(ghost => ghost.url !== item.pshellGhost.url));
				});
			}
			const tabs = W.gBrowser.tabContainer;
			on(W, tabs, "TabPinned", event => {
				remember(event.target);
				number(W);
			});
			on(W, tabs, "TabUnpinned", event => {
				SessionStore.deleteCustomTabValue(event.target, "pshell-origin");
				event.target.removeAttribute("pshell-slot");
				number(W);
			});
			on(W, tabs, "TabMove", () => number(W));
			on(W, tabs, "TabOpen", () => number(W));
			on(W, tabs, "TabClose", event => {
				const tab = event.target;
				W.win.setTimeout(() => number(W), 0);
				if (!tab.pinned || W.private || !tabsConfig().dock || event.detail?.adoptedBy) return;
				const origin = originOf(tab);
				const url = blank(origin) ? PARTS.find(part => part.name === "env").urlOf(tab) : origin;
				if (!/^https?:/.test(url)) return;
				const list = ghosts().filter(item => item.url !== url);
				list.push({ url, title: tab.label, icon: /^(data|https?):/.test(tab.getAttribute("image") || "") && (tab.getAttribute("image") || "").length < 20000 ? tab.getAttribute("image") : "" });
				setGhosts(list);
			});
			for (const tab of pinned(W)) remember(tab);
			drawGhosts(W);
		},
		configure(W, tabs) {
			W.doc.documentElement.toggleAttribute("pshell-dock", tabs.dock && !W.private);
			drawGhosts(W);
		},
		detach(W) {
			W.ghostBox?.remove();
			for (const tab of W.gBrowser.tabs) tab.removeAttribute("pshell-slot");
			W.doc.documentElement.removeAttribute("pshell-dock");
		}
	});
})();
