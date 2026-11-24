/* Separate logins per environment (Settings › Browser › Environments,
 * envs.containers): every group of env.js has a container of its own, so
 * Live, Stage and Dev each keep their own cookies and storage and one can be
 * signed in as different users at once.
 *
 * Only while working (a qtrack timer runs: envs.on is false otherwise, see
 * base.js) and never in a private window. The containers are Firefox's
 * internal ones (not public): they appear in no menu, Firefox's container
 * settings or the extension API, and are not cleared with the public ones.
 * Named "pshell-env:<id>", kept in containers.json; nothing is ever removed.
 *
 * A page of a group asked for in a tab of another container is not loaded
 * there (the request is cancelled before it leaves) but in a tab of the
 * group's container: in place of a tab that had nothing else (a new tab, a
 * tab not loaded yet) or showed that page already, else beside it. POST requests, pages outside a tab
 * (Peek, Spur columns: they follow their tab) and pages of no group stay
 * where they are. */
"use strict";

(function () {
	const PREFIX = "pshell-env:";
	let CIS = null;
	let observing = false;
	// browser → { url, at }: one move per page and moment
	const moving = new WeakMap();

	function service() {
		if (CIS) return CIS;
		for (const url of ["moz-src:///toolkit/components/contextualidentity/ContextualIdentityService.sys.mjs", "resource://gre/modules/ContextualIdentityService.sys.mjs"]) {
			try {
				CIS = ChromeUtils.importESModule(url).ContextualIdentityService;
				if (CIS) return CIS;
			} catch (error) {}
		}
		return null;
	}

	// the userContextId of a group's container, made the first time
	function containerOf(env) {
		const cis = service();
		if (!cis) return 0;
		const name = PREFIX + env;
		try {
			const known = cis.getPrivateIdentity(name);
			if (known && known.userContextId) return known.userContextId;
		} catch (error) {}
		try {
			cis.ensureDataReady();
			const userContextId = ++cis._lastUserContextId;
			cis._identities.push({ userContextId, public: false, name });
			cis.saveSoon();
			return userContextId;
		} catch (error) {
			console.error("[pshell] containers:", error);
			return 0;
		}
	}

	function envId(userContextId) {
		const cis = service();
		if (!cis || !userContextId) return "";
		try {
			const identity = cis._identities.find(info => info.userContextId === userContextId && !info.public);
			return identity && identity.name.startsWith(PREFIX) ? identity.name.slice(PREFIX.length) : "";
		} catch (error) {
			return "";
		}
	}

	function active() {
		const tabs = tabsConfig();
		return tabs.work && tabs.envs.on && tabs.envs.containers;
	}

	const env = () => PARTS.find(part => part.name === "env");

	function blankish(tab, browser) {
		if (!tab.linkedPanel || tab.hasAttribute("pending")) return true;
		const spec = browser.currentURI?.spec || "";
		if (/^about:(blank|newtab|home|privatebrowsing)$/.test(spec)) return true;
		return false;
	}

	function move(W, tab, url, userContextId) {
		const browser = tab.linkedBrowser;
		// (the same page again, a reload: it moves rather than doubles)
		const replace = blankish(tab, browser) || browser.currentURI?.spec === url;
		const added = W.gBrowser.addTab(url, {
			userContextId,
			triggeringPrincipal: SYSTEM(),
			index: tab._tPos + 1,
			ownerTab: tab,
			skipAnimation: true
		});
		if (tab.selected) W.gBrowser.selectedTab = added;
		if (replace) {
			if (tab.pinned) W.gBrowser.pinTab(added);
			W.gBrowser.removeTab(tab, { animate: false, skipPermitUnload: true });
		}
	}

	const observer = {
		observe(subject, topic) {
			if (topic !== "http-on-modify-request" || !active()) return;
			let channel;
			try {
				channel = subject.QueryInterface(Ci.nsIHttpChannel);
			} catch (error) {
				return;
			}
			const info = channel.loadInfo;
			if (!info || info.externalContentPolicyType !== Ci.nsIContentPolicy.TYPE_DOCUMENT) return;
			if (channel.requestMethod !== "GET") return;
			const attrs = info.originAttributes || {};
			if (attrs.privateBrowsingId) return;
			const context = info.browsingContext;
			if (!context || context.parent) return;
			const browser = context.top?.embedderElement;
			if (!browser) return;
			const W = windowOf(browser);
			if (!W || W.private) return;
			const tab = W.gBrowser.getTabForBrowser(browser);
			if (!tab) return; // Peek, Spur columns: they follow their tab
			const match = env()?.envOf(channel.URI);
			const current = attrs.userContextId || 0;
			if (!match) return;
			const target = containerOf(match.env);
			if (!target || target === current) return;
			const url = channel.URI.spec;
			const last = moving.get(browser);
			if (last && last.url === url && Date.now() - last.at < 3000) return;
			moving.set(browser, { url, at: Date.now() });
			channel.cancel(0x804b0002); // NS_BINDING_ABORTED
			W.win.setTimeout(() => {
				try {
					move(W, tab, url, target);
				} catch (error) {
					console.error("[pshell] containers:", error);
				}
			}, 0);
		}
	};

	PARTS.push({
		name: "containers",
		containerOf,
		envId,
		start() {
			Services.obs.addObserver(observer, "http-on-modify-request");
			observing = true;
		},
		stop() {
			if (observing) Services.obs.removeObserver(observer, "http-on-modify-request");
			observing = false;
		}
	});
})();
