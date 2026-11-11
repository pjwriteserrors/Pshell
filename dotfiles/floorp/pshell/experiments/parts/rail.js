/* The rail's style from Settings › Browser › Tabs: hover (icons, opens while
 * the pointer rests), open (with titles), icons (never opens) or top (tabs
 * above the page), and the open rail's width. And the rail closes when the
 * pointer leaves the window: Firefox takes the last position it saw, which is
 * inside the rail when the pointer leaves across it, so it opened again. */
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

	PARTS.push({
		name: "rail",
		attach(W) {
			on(W, W.win, "mouseout", onMouseOut);
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
