/* States on the icon. Loading, playing, camera and news Firefox marks itself
 * ([busy], [soundplaying], [sharing], [attention]/[titlechanged], [pending]);
 * two more come from here: pshell-count, the number a page puts before its
 * title ("(4) Inbox"), and pshell-draft, text typed into a form of the page
 * and not sent (the page script reports it; closing such a page asks first). */
"use strict";

(function () {
	const COUNT = /^\s*[([](\d{1,4})\+?[)\]]\s/;

	// what the icon shows, on its own box (a sheet reads only its own attributes)
	function badges(tab) {
		const stack = tab.querySelector(".tab-icon-stack");
		if (!stack) return;
		const spur = Number(tab.getAttribute("pshell-spur") || 0);
		const count = tab.getAttribute("pshell-count") || "";
		const badge = spur > 1 ? String(spur) : count;
		if (badge) stack.setAttribute("pshell-badge", badge);
		else stack.removeAttribute("pshell-badge");
		stack.toggleAttribute("pshell-spur", spur > 1);
		stack.toggleAttribute("pshell-draft", tab.hasAttribute("pshell-draft"));
	}

	function count(W, tab) {
		const on = tabsConfig().states;
		const match = on ? COUNT.exec(tab.label || "") : null;
		if (match && Number(match[1]) > 0) {
			const n = Number(match[1]);
			tab.setAttribute("pshell-count", n > 99 ? "99+" : String(n));
		} else {
			tab.removeAttribute("pshell-count");
		}
		badges(tab);
	}

	function setDraft(W, browser, on) {
		const tab = W.gBrowser.getTabForBrowser(browser);
		if (!tab) return;
		if (on && tabsConfig().states) tab.setAttribute("pshell-draft", "");
		else tab.removeAttribute("pshell-draft");
		badges(tab);
	}

	// tabs holding a draft, for the archive (they never age)
	COMMANDS.drafts = async () => {
		const ids = [];
		for (const win of browserWindows()) {
			for (const tab of win.gBrowser.tabs) if (tab.hasAttribute("pshell-draft")) ids.push(tabId(tab));
		}
		return ids;
	};

	PARTS.push({
		name: "marks",
		badges,
		attach(W) {
			on(W, W.gBrowser.tabContainer, "TabAttrModified", event => {
				if (event.detail?.changed?.includes("label")) count(W, event.target);
			});
			on(W, W.gBrowser.tabContainer, "TabClose", event => event.target.removeAttribute("pshell-draft"));
		},
		configure(W, tabs) {
			W.doc.documentElement.toggleAttribute("pshell-states", tabs.states);
			for (const tab of W.gBrowser.tabs) {
				count(W, tab);
				if (!tabs.states) tab.removeAttribute("pshell-draft");
			}
		},
		page: {
			draft(W, browser, data) {
				setDraft(W, browser, !!data.on);
			}
		},
		detach(W) {
			for (const tab of W.gBrowser.tabs) {
				tab.removeAttribute("pshell-count");
				tab.removeAttribute("pshell-draft");
				badges(tab);
			}
			W.doc.documentElement.removeAttribute("pshell-states");
		}
	});
})();
