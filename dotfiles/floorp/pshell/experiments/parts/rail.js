/* The rail's style from Settings › Browser › Tabs: hover (icons, opens while
 * the pointer rests), open (with titles), icons (never opens) or top (tabs
 * above the page), and the open rail's width. And the rail closes when the
 * pointer leaves the window: Firefox takes the last position it saw, which is
 * inside the rail when the pointer leaves across it, so it opened again.
 * Floorp's workspace list opens in the page's corner. */
"use strict";

(function () {
	const VISIBILITY = { hover: "expand-on-hover", open: "always-show", icons: "always-show" };

	function setPref(key, value) {
		if (typeof value === "boolean") {
			if (Services.prefs.getBoolPref(key, !value) !== value) Services.prefs.setBoolPref(key, value);
		} else if (Services.prefs.getStringPref(key, "") !== value) {
			Services.prefs.setStringPref(key, value);
		}
	}

	function applyPrefs(rail) {
		if (rail.style === "top") {
			setPref("sidebar.verticalTabs", false);
			return;
		}
		setPref("sidebar.revamp", true);
		setPref("sidebar.visibility", VISIBILITY[rail.style]);
		setPref("sidebar.verticalTabs", true);
	}

	function applyWindow(W) {
		const rail = config.rail;
		if (!rail) return;
		W.doc.documentElement.setAttribute("pshell-rail", rail.style);
		const controller = W.win.SidebarController;
		const state = controller?._state;
		if (!state || rail.style === "top" || !controller.sidebarVerticalTabsEnabled) return;
		if (rail.width) state.expandedLauncherWidth = rail.width;
		if (rail.style === "open" && !state.launcherExpanded) state.launcherExpanded = true;
		if (rail.style === "icons" && state.launcherExpanded) state.launcherExpanded = false;
	}

	// the pointer left the window: away from the rail, wherever it was last seen
	function onMouseOut(event) {
		if (event.relatedTarget) return;
		const win = event.currentTarget;
		const doc = win.document;
		if (!doc.documentElement.hasAttribute("sidebar-expand-on-hover")) return;
		// a menu of the rail keeps it open; the tab's preview card does not
		if (doc.querySelector("menupopup[state='open'], panel[state='open']:not(#tab-preview-panel)")) return;
		const tracker = win.MousePosTracker;
		if (!tracker?._listeners) return;
		// after Firefox's own listener, which takes the exit point
		win.setTimeout(() => {
			tracker._x = -100000;
			tracker._y = -100000;
			for (const listener of tracker._listeners) {
				try {
					tracker._callListener(listener);
				} catch (error) {
					console.error(error);
				}
			}
		}, 0);
	}

	// Floorp's workspace list: grown into the page's upper left corner, right
	// of the rail, instead of hanging over it from its button (pshell.css
	// draws it with --ps-ws-x/--ps-ws-y as its margins)
	const GAP = 0;
	const isWorkspaces = popup => popup?.localName === "panel" && popup.getAttribute("viewId") === "workspacesToolbarButtonPanel";

	function placeWorkspaces(W, panel) {
		const page = W.doc.getElementById("tabbrowser-tabbox")?.getBoundingClientRect();
		const anchor = (panel.anchorNode || W.doc.getElementById("workspaces-toolbar-button"))?.getBoundingClientRect();
		if (!page || !anchor) return;
		panel.style.setProperty("--ps-ws-x", `${Math.round(page.left + GAP - anchor.left)}px`);
		panel.style.setProperty("--ps-ws-y", `${Math.round(page.top + GAP - anchor.bottom)}px`);
	}

	PARTS.push({
		name: "rail",
		attach(W) {
			on(W, W.win, "mouseout", onMouseOut);
			on(W, W.doc, "popupshowing", event => {
				if (isWorkspaces(event.target)) placeWorkspaces(W, event.target);
			}, true);
			applyWindow(W);
		},
		detach(W) {
			W.doc.documentElement.removeAttribute("pshell-rail");
		},
		rail(rail) {
			applyPrefs(rail);
			// the prefs' observers rebuild the rail first
			for (const win of browserWindows()) {
				if (windowOf(win)) win.setTimeout(() => windowOf(win) && applyWindow(windowOf(win)), 150);
			}
		}
	});
})();
