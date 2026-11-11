/* Tabs of one site in a group of their own (Settings › Browser › Tabs, "Group
 * by site").
 *
 * Two or more tabs outside any group with the same site (its registrable
 * domain: docs.github.com and github.com are one) become a tab group named
 * after it; a further tab of the site joins it. A tab that goes to another
 * site leaves the group, a group down to one tab dissolves. Tabs in a group
 * of the user's own, pinned tabs and those an environment groups (env.js) stay
 * where they are, and so does a tab the user took out of a site's group – as
 * long as it shows that site.
 *
 * Which groups are the site groups (a group may be renamed) is kept in the
 * session: SessionStore's global value "pshell-site-groups", { id: site }. */
"use strict";

(function () {
	const COLORS = ["purple", "cyan", "orange", "yellow", "pink", "gray"];
	const KEY = "pshell-site-groups";
	const LEFT = "pshell-site-left";

	let busy = 0;

	function siteOf(url) {
		let uri;
		try {
			uri = Services.io.newURI(url);
		} catch (error) {
			return "";
		}
		if (!/^https?$/.test(uri.scheme)) return "";
		try {
			return Services.eTLD.getBaseDomain(uri).toLowerCase();
		} catch (error) {
			try {
				return uri.host.toLowerCase().replace(/^www\./, "");
			} catch (error2) {
				return "";
			}
		}
	}

	function colorOf(site) {
		let hash = 0;
		for (const ch of site) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
		return COLORS[hash % COLORS.length];
	}

	function urlOf(tab) {
		const env = PARTS.find(part => part.name === "env");
		return env ? env.urlOf(tab) : tab.linkedBrowser?.currentURI?.spec || "";
	}

	function load() {
		try {
			return JSON.parse(SessionStore.getCustomGlobalValue(KEY) || "{}") || {};
		} catch (error) {
			return {};
		}
	}

	function save(groups) {
		try {
			SessionStore.setCustomGlobalValue(KEY, JSON.stringify(groups));
		} catch (error) {}
	}

	function left(tab) {
		try {
			return SessionStore.getCustomTabValue(tab, LEFT) || "";
		} catch (error) {
			return "";
		}
	}

	function setLeft(tab, site) {
		try {
			if (site) SessionStore.setCustomTabValue(tab, LEFT, site);
			else SessionStore.deleteCustomTabValue(tab, LEFT);
		} catch (error) {}
	}

	function enabled(W) {
		return tabsConfig().bySite && !W.private;
	}

	// an environment's group takes the tab (env.js)
	function envTakes(tab) {
		const tabs = tabsConfig();
		return tab.hasAttribute("pshell-env") && tabs.envs.on && tabs.envs.group;
	}

	function ours(W, groups) {
		const out = new Map();
		for (const group of W.gBrowser.tabGroups) {
			if (groups[group.id]) out.set(group, groups[group.id]);
		}
		return out;
	}

	function sweep(W) {
		W.siteTimer = 0;
		if (!enabled(W) || !W.gBrowser) return;
		const stored = load();
		const groups = ours(W, stored);
		busy++;
		try {
			// tabs that went elsewhere leave (to an environment's group, if one
			// takes them); a group of one dissolves
			const toEnv = [];
			for (const [group, site] of groups) {
				for (const tab of [...group.tabs]) {
					if (envTakes(tab)) toEnv.push(tab);
					else if (siteOf(urlOf(tab)) === site) continue;
					W.gBrowser.ungroupTab(tab);
				}
			}
			const env = PARTS.find(part => part.name === "env");
			for (const tab of toEnv) env?.regroup(W, tab);
			const dissolved = new Set();
			for (const [group] of groups) {
				if (group.isConnected && group.tabs.length === 1) {
					dissolved.add(group);
					W.gBrowser.ungroupTab(group.tabs[0]);
				}
			}

			const buckets = new Map();
			for (const tab of W.gBrowser.tabs) {
				if (tab.pinned || tab.closing || tab.group || envTakes(tab)) continue;
				const site = siteOf(urlOf(tab));
				if (!site) continue;
				const out = left(tab);
				if (out) {
					if (out === site) continue;
					setLeft(tab, "");
				}
				if (!buckets.has(site)) buckets.set(site, []);
				buckets.get(site).push(tab);
			}

			// (a dissolved group may still be in the document a moment)
			const live = ours(W, stored);
			for (const group of dissolved) live.delete(group);
			for (const [site, tabs] of buckets) {
				const group = [...live].find(([, s]) => s === site)?.[0];
				if (group) {
					for (const tab of tabs) W.gBrowser.moveTabToExistingGroup(tab, group);
				} else if (tabs.length >= 2) {
					const created = W.gBrowser.addTabGroup(tabs, { label: site, color: colorOf(site), insertBefore: tabs[0] });
					if (created) {
						live.set(created, site);
						created.setAttribute("pshell-site", site);
					}
				}
			}

			const next = {};
			for (const [group, site] of live) {
				if (group.isConnected && group.tabs.length && !dissolved.has(group)) {
					next[group.id] = site;
					group.setAttribute("pshell-site", site);
				}
			}
			save(next);
		} catch (error) {
			console.error("[pshell] sites:", error);
		} finally {
			busy--;
		}
	}

	function soon(W) {
		if (!enabled(W) || W.siteTimer) return;
		W.siteTimer = W.win.setTimeout(() => sweep(W), 150);
	}

	function ungroupAll(W) {
		const groups = ours(W, load());
		busy++;
		try {
			for (const [group] of groups) {
				for (const tab of [...group.tabs]) W.gBrowser.ungroupTab(tab);
			}
		} finally {
			busy--;
		}
		save({});
	}

	PARTS.push({
		name: "domains",
		attach(W) {
			W.siteProgress = {
				onLocationChange(browser, webProgress) {
					if (webProgress.isTopLevel) soon(W);
				}
			};
			W.gBrowser.addTabsProgressListener(W.siteProgress);
			const box = W.gBrowser.tabContainer;
			for (const type of ["TabOpen", "TabClose", "TabPinned", "TabUnpinned", "TabGroupRemoved"]) on(W, box, type, () => soon(W));
			// taken out by hand: left alone while it shows that site
			on(W, box, "TabUngrouped", event => {
				if (!enabled(W)) return;
				// (the event is the group's, the tab in its detail)
				const tab = event.detail;
				if (!busy && tab?.localName === "tab" && !tab.closing) {
					const site = siteOf(urlOf(tab));
					if (site) setLeft(tab, site);
				}
				soon(W);
			});
		},
		configure(W, tabs) {
			if (W.bySite && !tabs.bySite) ungroupAll(W);
			W.bySite = tabs.bySite;
			soon(W);
		},
		detach(W) {
			W.gBrowser.removeTabsProgressListener(W.siteProgress);
			if (W.siteTimer) W.win.clearTimeout(W.siteTimer);
		}
	});
})();
