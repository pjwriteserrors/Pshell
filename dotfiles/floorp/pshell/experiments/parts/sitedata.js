/* A third button beside reload and reload without cache: clears the site in
 * front – its cookies, storage and caches (the site with its subdomains, in
 * the tab's own container only) – and reloads it, every Spur column of the
 * tab with it. */
"use strict";

(function () {
	const ID = "pshell-clear-site-button";

	function siteOf(uri) {
		try {
			return Services.eTLD.getSchemelessSite(uri);
		} catch (error) {
			try {
				return uri.host;
			} catch (error2) {
				return "";
			}
		}
	}

	async function clearSite(W, tab) {
		tab = tab || W.gBrowser.selectedTab;
		const browser = tab.linkedBrowser;
		const uri = browser.currentURI;
		if (!uri || !/^https?$/.test(uri.scheme)) return false;
		const site = siteOf(uri);
		if (!site) return false;
		const attrs = browser.contentPrincipal?.originAttributes || {};
		const pattern = { userContextId: attrs.userContextId || 0, privateBrowsingId: attrs.privateBrowsingId || 0 };
		const flags = Ci.nsIClearDataService.CLEAR_COOKIES_AND_SITE_DATA | Ci.nsIClearDataService.CLEAR_ALL_CACHES;
		await new Promise(resolve => Services.clearData.deleteDataFromSite(site, pattern, true, flags, resolve));
		const bypass = Ci.nsIWebNavigation.LOAD_FLAGS_BYPASS_CACHE | Ci.nsIWebNavigation.LOAD_FLAGS_BYPASS_PROXY;
		const spur = W.spurs?.get(tab);
		for (const each of spur ? spur.cols.map(col => col.browser) : [browser]) {
			try {
				each.reloadWithFlags(bypass);
			} catch (error) {}
		}
		return true;
	}

	COMMANDS.clearSite = async args => {
		const tab = args.tabId >= 0 ? nativeTab(args.tabId) : frontWindow()?.gBrowser.selectedTab;
		const W = tab ? windowOf(tab) : null;
		if (!W) throw new Error("no such tab");
		return await clearSite(W, tab);
	};

	PARTS.push({
		name: "sitedata",
		clearSite,
		attach(W) {
			const item = W.doc.getElementById("stop-reload-button");
			if (!item || W.doc.getElementById(ID)) return;
			const button = W.doc.createXULElement("toolbarbutton");
			button.id = ID;
			button.className = "toolbarbutton-1";
			button.setAttribute("tooltiptext", "Clear site data and reload");
			button.addEventListener("command", () => {
				button.setAttribute("busy", "");
				clearSite(W).catch(error => console.error("[pshell] clear site:", error)).finally(() => button.removeAttribute("busy"));
			});
			item.appendChild(button);
			W.cleanup.push(() => button.remove());
		}
	});
})();
