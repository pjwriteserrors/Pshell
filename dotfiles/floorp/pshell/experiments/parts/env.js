/* Groups of sites by their address (Settings › Browser › Environments): Live,
 * Stage and Dev to begin with, any number of the user's own.
 *
 * Every group has an id, a name, a colour, host patterns ("staging.*",
 * "*.ddev.site", "localhost", "shop.example"; /…/ is a regular expression
 * matched against the host, with its port if it has one) and whether Alt+E
 * goes through it. A tab's address decides: the most specific pattern wins
 * (a whole host before a pattern, a longer one before a shorter, then the
 * list's order), giving the tab pshell-env="<id>", which the colour sheet
 * (made here from the list) turns into a dot and a tint. The tab in front
 * colours the page's frame and shows its group in the address bar. With
 * "Group" on, the tabs of a group live in a tab group of that name (Firefox's
 * own, saved with the session), in the list's order before every other tab; a
 * tab that goes elsewhere leaves it. A tab in a group of the user's own stays
 * where it is. Which tab groups are ours is kept in the session
 * (SessionStore's global value "pshell-env-groups", { group id: id }), so a
 * renamed entry renames its group.
 *
 * Alt+E (or a click on the mark) shows the same page in the next group that
 * Alt+E goes through: a tab already showing it, or a new one beside. The
 * first of those groups is where a site lives under its plain host; another
 * group's host comes from what is open (same project: the part of the host a
 * pattern's * stands for, its first label), else from the patterns. */
"use strict";

(function () {
	// Firefox's group colours, for the group itself (the sheet paints ours)
	const FIREFOX = {
		red: [229, 83, 75], orange: [224, 130, 61], yellow: [198, 144, 38], green: [87, 171, 90],
		cyan: [57, 197, 207], blue: [77, 158, 240], purple: [163, 113, 247], pink: [226, 117, 173], gray: [139, 148, 158]
	};
	const KEY = "pshell-env-groups";

	let rules = [];
	let list = [];

	function escape(text) {
		return text.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
	}

	const isRegex = pattern => /^\/.+\/$/.test(pattern);

	function compile(envs) {
		list = (envs.list || []).filter(entry => entry && entry.id);
		const out = [];
		list.forEach((entry, order) => {
			for (const raw of entry.patterns || []) {
				const text = String(raw || "").trim();
				if (!text) continue;
				if (isRegex(text)) {
					try {
						out.push({ env: entry.id, order, regex: true, exact: false, literal: -1, re: new RegExp(text.slice(1, -1), "i") });
					} catch (error) {}
					continue;
				}
				const pattern = text.toLowerCase();
				const exact = !pattern.includes("*");
				let source = pattern.split("*").map(escape).join("(.+?)");
				if (exact) source = `(?:www\\.)?(${source})`;
				out.push({ env: entry.id, order, regex: false, exact, literal: pattern.replace(/\*/g, "").length, withPort: pattern.includes(":"), re: new RegExp(`^${source}$`) });
			}
		});
		out.sort((a, b) => (b.exact - a.exact) || (b.literal - a.literal) || (a.order - b.order));
		rules = out;
	}

	function entryOf(id) {
		return list.find(entry => entry.id === id) || null;
	}

	function keyOf(base) {
		return base.replace(/^www\./, "").split(".")[0] || base;
	}

	// { env, base, key, host } of an address, or null
	function envOf(url) {
		let uri;
		try {
			uri = typeof url === "string" ? Services.io.newURI(url) : url;
		} catch (error) {
			return null;
		}
		if (!uri || !/^https?$/.test(uri.scheme)) return null;
		let host = "";
		let hostPort = "";
		try {
			host = uri.host.toLowerCase();
			hostPort = uri.hostPort.toLowerCase();
		} catch (error) {
			return null;
		}
		for (const rule of rules) {
			const match = rule.regex ? (rule.re.exec(hostPort) || rule.re.exec(host)) : rule.re.exec(rule.withPort ? hostPort : host);
			if (!match) continue;
			const base = (rule.regex ? match[1] : match.slice(1).filter(Boolean).join(".")) || host;
			return { env: rule.env, base, key: keyOf(base), host: hostPort, scheme: uri.scheme };
		}
		return null;
	}

	// a tab not loaded yet (after a restart) shows about:blank; its page is
	// in the session's state
	function urlOf(tab) {
		const browser = tab.linkedBrowser;
		if (!tab.linkedPanel) {
			try {
				const url = SessionStore.getLazyTabValue(tab, "url");
				if (url) return url;
			} catch (error) {}
		}
		const spec = browser?.currentURI?.spec || "";
		if (spec === "about:blank" && tab.hasAttribute("pending")) {
			try {
				const state = JSON.parse(SessionStore.getTabState(tab));
				const entry = state.entries?.[(state.index || state.entries.length) - 1];
				if (entry?.url) return entry.url;
			} catch (error) {}
		}
		return spec;
	}

	// ── our tab groups ─────────────────────────────────────────────────────
	function stored() {
		try {
			return JSON.parse(SessionStore.getCustomGlobalValue(KEY) || "{}") || {};
		} catch (error) {
			return {};
		}
	}

	function store(map) {
		try {
			SessionStore.setCustomGlobalValue(KEY, JSON.stringify(map));
		} catch (error) {}
	}

	// the group of an entry: the one we made, else one of its name (made
	// before we kept ids, or by hand) – taken over
	function groupFor(W, id) {
		const map = stored();
		const groups = W.gBrowser.tabGroups;
		let group = groups.find(g => map[g.id] === id);
		if (!group) {
			const name = entryOf(id)?.name;
			group = name ? groups.find(g => !map[g.id] && g.label === name) : null;
			if (group) {
				map[group.id] = id;
				store(map);
			}
		}
		return group || null;
	}

	function envOfGroup(group) {
		if (!group) return "";
		const id = stored()[group.id];
		if (id && entryOf(id)) return id;
		return list.find(entry => entry.name === group.label)?.id || "";
	}

	function isEnvGroup(group) {
		return !!envOfGroup(group);
	}

	function nearestColour(hex) {
		const rgb = [1, 3, 5].map(i => parseInt(String(hex).slice(i, i + 2), 16) || 0);
		let best = "gray";
		let distance = Infinity;
		for (const [name, c] of Object.entries(FIREFOX)) {
			const d = (c[0] - rgb[0]) ** 2 + (c[1] - rgb[1]) ** 2 + (c[2] - rgb[2]) ** 2;
			if (d < distance) {
				distance = d;
				best = name;
			}
		}
		return best;
	}

	// where a new group goes: before the groups of the entries after it, else
	// before the first tab that is in no earlier entry's group
	function anchorFor(W, id, tab) {
		const order = list.findIndex(entry => entry.id === id);
		for (const later of list.slice(order + 1)) {
			const group = groupFor(W, later.id);
			if (group && group.tabs.length) return group.tabs[0];
		}
		for (const other of W.gBrowser.tabs) {
			if (other.pinned) continue;
			const env = envOfGroup(other.group);
			if (env && list.findIndex(entry => entry.id === env) < order) continue;
			return other;
		}
		return tab;
	}

	function place(W, tab, env) {
		const tabs = tabsConfig();
		if (!tabs.envs.on || !tabs.envs.group || W.private || tab.pinned || tab.closing || !tab.isConnected) return;
		const group = tab.group;
		if (env) {
			if (group && envOfGroup(group) === env) return;
			if (group && !isEnvGroup(group)) return;
			const target = groupFor(W, env);
			if (target) {
				W.gBrowser.moveTabToExistingGroup(tab, target);
			} else {
				const entry = entryOf(env);
				const created = W.gBrowser.addTabGroup([tab], { label: entry.name, color: nearestColour(entry.color), insertBefore: anchorFor(W, env, tab) });
				if (created) {
					created.setAttribute("pshell-env", env);
					const map = stored();
					map[created.id] = env;
					store(map);
				}
			}
		} else if (group && isEnvGroup(group)) {
			W.gBrowser.ungroupTab(tab);
		}
	}

	// names, marks; groups of entries that are gone let their tabs go
	function markGroups(W) {
		const map = stored();
		let changed = false;
		for (const group of W.gBrowser.tabGroups) {
			const id = map[group.id];
			if (id && !entryOf(id)) {
				delete map[group.id];
				changed = true;
				group.removeAttribute("pshell-env");
				for (const tab of [...group.tabs]) W.gBrowser.ungroupTab(tab);
				continue;
			}
			const env = envOfGroup(group);
			if (!env) {
				group.removeAttribute("pshell-env");
				continue;
			}
			group.setAttribute("pshell-env", env);
			const name = entryOf(env).name;
			if (group.label !== name) group.label = name;
		}
		for (const id of Object.keys(map)) {
			if (!W.gBrowser.tabGroups.some(group => group.id === id) && !browserWindows().some(win => win.gBrowser.tabGroups.some(group => group.id === id))) {
				delete map[id];
				changed = true;
			}
		}
		if (changed) store(map);
	}

	function update(W, tab) {
		if (!tab || !tab.isConnected) return;
		const tabs = tabsConfig();
		const info = tabs.envs.on ? envOf(urlOf(tab)) : null;
		const env = info ? info.env : "";
		if (env) tab.setAttribute("pshell-env", env);
		else tab.removeAttribute("pshell-env");
		if (tab.selected) front(W);
		// after the location change has settled; the tab may move
		W.win.setTimeout(() => {
			try {
				place(W, tab, env);
				markGroups(W);
			} catch (error) {
				console.error("[pshell] env:", error);
			}
		}, 0);
	}

	function front(W) {
		const tab = W.gBrowser.selectedTab;
		const env = (tab && tab.getAttribute("pshell-env")) || "";
		const root = W.doc.documentElement;
		if (env) root.setAttribute("pshell-env", env);
		else root.removeAttribute("pshell-env");
		if (W.envChip) W.envChip.textContent = env ? entryOf(env)?.name || "" : "";
	}

	// the colours: a sheet of the window, made from the list
	function colours(W) {
		const css = list.map(entry => {
			const id = String(entry.id).replace(/[^a-z0-9-]/g, "");
			const color = /^#[0-9a-f]{6}$/i.test(entry.color) ? entry.color : "#8b949e";
			return `.tabbrowser-tab[pshell-env="${id}"], tab-group[pshell-env="${id}"], .pshell-rt[pshell-env="${id}"], :root[pshell-env="${id}"] body { --pshell-env: ${color}; }`;
		}).join("\n");
		const utils = W.win.windowUtils;
		if (W.envSheet) {
			try {
				utils.removeSheetUsingURIString(W.envSheet, utils.AUTHOR_SHEET);
			} catch (error) {}
		}
		W.envSheet = "data:text/css;charset=utf-8," + encodeURIComponent(css);
		try {
			utils.loadSheetUsingURIString(W.envSheet, utils.AUTHOR_SHEET);
		} catch (error) {
			W.envSheet = "";
		}
	}

	// ── Alt+E ───────────────────────────────────────────────────────────────
	function known() {
		const seen = [];
		for (const win of browserWindows()) {
			if (PrivateBrowsingUtils.isWindowPrivate(win)) continue;
			for (const tab of win.gBrowser.tabs) {
				const info = envOf(urlOf(tab));
				if (info) seen.push(Object.assign({ tab, win }, info));
			}
		}
		return seen;
	}

	// the groups Alt+E goes through, in order; the first is where a site
	// lives under its plain host
	function cycle() {
		return list.filter(entry => entry.cycle !== false);
	}

	function targetHost(info, env, open) {
		const same = open.find(item => item.env === env && item.key === info.key);
		if (same) return { host: same.host, scheme: same.scheme };
		const main = cycle()[0]?.id;
		const plain = pattern => !pattern.includes("*") && !isRegex(pattern);
		const liveBase = info.env === main ? info.base : (open.find(item => item.env === main && item.key === info.key)?.base
			|| (entryOf(main)?.patterns || []).find(host => plain(host) && keyOf(host) === info.key));
		const rest = liveBase ? liveBase.split(".").slice(1).join(".") : "";
		for (const pattern of entryOf(env)?.patterns || []) {
			if (isRegex(pattern)) continue;
			const stars = pattern.split("*").length - 1;
			let host = "";
			if (stars === 0) {
				// a host of its own: only one of the first group names its project
				if (env === main && keyOf(pattern) === info.key) host = pattern;
			} else if (stars === 1 && pattern.startsWith("*.")) {
				host = info.key + pattern.slice(1); // "*.ddev.site": the project's name
			} else if (stars === 1 && pattern.endsWith(".*") && liveBase) {
				host = pattern.slice(0, -1) + liveBase; // "staging.*": the live host
			} else if (stars === 2 && pattern.startsWith("*.") && pattern.endsWith(".*") && liveBase && rest) {
				host = `${info.key}${pattern.slice(1, -1)}${rest}`; // "*.staging.*"
			} else if (stars === 1) {
				host = pattern.replace("*", info.key); // "*-dev.example.de"
			}
			if (host) return { host, scheme: /^localhost|\.test$|\.local$|\.localhost$/.test(host.split(":")[0]) ? "http" : "https" };
		}
		return null;
	}

	function switchEnv(W, tab) {
		tab = tab || W.gBrowser.selectedTab;
		const url = urlOf(tab);
		const info = envOf(url);
		if (!info) return false;
		const ring = cycle().map(entry => entry.id);
		const start = ring.indexOf(info.env);
		if (start < 0) return false;
		const open = known();
		const uri = Services.io.newURI(url);
		for (let step = 1; step < ring.length; step++) {
			const env = ring[(start + step) % ring.length];
			const target = targetHost(info, env, open);
			if (!target) continue;
			const next = `${target.scheme}://${target.host}${uri.pathQueryRef}`;
			const same = open.find(item => {
				try {
					const other = Services.io.newURI(urlOf(item.tab));
					return item.env === env && other.hostPort === target.host && other.pathQueryRef === uri.pathQueryRef;
				} catch (error) {
					return false;
				}
			});
			if (same) {
				same.win.gBrowser.selectedTab = same.tab;
				same.win.focus();
			} else {
				const added = W.gBrowser.addTrustedTab(next, { relatedToCurrent: true, ownerTab: tab });
				W.gBrowser.selectedTab = added;
			}
			return true;
		}
		return false;
	}

	COMMANDS.env = async args => {
		const W = frontWindow();
		if (!W) return false;
		const tab = args.tabId >= 0 ? nativeTab(args.tabId) : null;
		return switchEnv(tab ? windowOf(tab) : W, tab);
	};

	function regroupAll(W) {
		for (const tab of W.gBrowser.tabs) update(W, tab);
	}

	// the groups in the list's order (a group goes before a group: before a
	// tab of one, Firefox would take it apart)
	function arrange(W) {
		const groups = list.map(entry => groupFor(W, entry.id)).filter(group => group && group.isConnected && group.tabs.length);
		for (let i = groups.length - 2; i >= 0; i--) {
			const at = group => W.gBrowser.tabs.indexOf(group.tabs[0]);
			if (at(groups[i]) > at(groups[i + 1])) W.gBrowser.moveTabBefore(groups[i], groups[i + 1]);
		}
	}

	function ungroupAll(W) {
		for (const entry of list) {
			const group = groupFor(W, entry.id);
			if (!group) continue;
			for (const tab of [...group.tabs]) W.gBrowser.ungroupTab(tab);
		}
	}

	PARTS.push({
		name: "env",
		envOf,
		urlOf,
		switchEnv,
		regroup: update,
		configured(tabs) {
			compile(tabs.envs);
		},
		attach(W) {
			if (!list.length) compile(tabsConfig().envs);
			W.envProgress = {
				onLocationChange(browser, webProgress) {
					if (!webProgress.isTopLevel) return;
					const tab = W.gBrowser.getTabForBrowser(browser);
					if (tab) update(W, tab);
				}
			};
			W.gBrowser.addTabsProgressListener(W.envProgress);
			on(W, W.gBrowser.tabContainer, "TabSelect", () => front(W));
			on(W, W.gBrowser.tabContainer, "TabOpen", event => update(W, event.target));
			on(W, W.gBrowser.tabContainer, "TabUnpinned", event => update(W, event.target));
			on(W, W.gBrowser.tabContainer, "TabGroupCreate", () => markGroups(W));

			const input = W.doc.getElementById("identity-box");
			if (input && input.parentNode) {
				W.envChip = el(W.doc, "span", { id: "pshell-env-chip", role: "button" });
				input.parentNode.insertBefore(W.envChip, input);
				on(W, W.envChip, "click", event => {
					event.stopPropagation();
					switchEnv(W);
				});
				on(W, W.envChip, "mousedown", event => event.stopPropagation());
			}
		},
		configure(W, tabs) {
			W.doc.documentElement.toggleAttribute("pshell-envs", tabs.envs.on);
			colours(W);
			const grouping = tabs.envs.on && tabs.envs.group;
			if (W.grouping && !grouping) ungroupAll(W);
			W.grouping = grouping;
			regroupAll(W);
			front(W);
			if (grouping) {
				// after the tabs have found their groups
				W.win.setTimeout(() => {
					try {
						arrange(W);
					} catch (error) {
						console.error("[pshell] env:", error);
					}
				}, 50);
			}
		},
		detach(W) {
			W.gBrowser.removeTabsProgressListener(W.envProgress);
			W.envChip?.remove();
			for (const tab of W.gBrowser.tabs) tab.removeAttribute("pshell-env");
			for (const group of W.gBrowser.tabGroups) group.removeAttribute("pshell-env");
			W.doc.documentElement.removeAttribute("pshell-env");
			W.doc.documentElement.removeAttribute("pshell-envs");
			if (W.envSheet) {
				try {
					W.win.windowUtils.removeSheetUsingURIString(W.envSheet, W.win.windowUtils.AUTHOR_SHEET);
				} catch (error) {}
			}
		}
	});
})();
