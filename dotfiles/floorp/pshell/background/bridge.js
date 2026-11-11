// The browser as part of the shell (docs/browser.md). Over its own native
// host (pshell_browser → $XDG_RUNTIME_DIR/pshell/browser.sock,
// core/services/WebLink.qml) the shell learns what is open and the browser
// does what the shell asks:
//
// to the shell:   { type: "ready", browser, version }
//                 { type: "tabs", windows, tabs }      everything open (no private window)
//                 { type: "tab", tab }                 one tab changed
//                 { type: "tabGone", id }
//                 { type: "menu", action, info }       an entry of the Pshell menu was clicked
//                 { type: "event", name, ... }         mailto, calendar, identityUsed, blockedVisit, launcher, stale
//                 { type: "ask", rid, what, args }     the extension wants something (newtab, identities)
//                 { type: "answer", rid, ok, data | error }
// from the shell: { type: "sync" }                     → ready, tabs (the host sends it on reaching the shell)
//                 { type: "config", config }           menu entries, what to intercept, forms, blocked sites, the rail, tabs
//                 { type: "theme", theme }             browser.theme.update
//                 { type: "newtab", data }             what the new tab page shows
//                 { type: "cmd", rid, cmd, ... }       → answer (see COMMANDS)
//                 { type: "answer", rid, ok, data }    to an ask
//
// Nothing of a private window is ever reported; a click in its Pshell menu
// goes to the shell marked private, so the shell keeps nothing of it.

const bridge = new ShellLink("pshell_browser", {
	onMessage: message => fromShell(message),
	onConnect: () => {
		// "ready" and the tabs go with the host's "sync": it sends one each time
		// it reaches the shell, and anything sent before that is lost
		applyTabs(config.tabs, true);
		setTimeout(offerStale, 60 * 1000);
	},
	onDisconnect: () => {
		applyTabs(config.tabs, true);
		for (const [rid, waiting] of asks) {
			waiting.reject(new Error("the shell went away"));
			asks.delete(rid);
		}
	}
});

let config = { menu: [], intercept: { mailto: false, calendar: false }, forms: false, newtab: true, blocked: [] };
let newtabData = null;
const asks = new Map();
let nextAsk = 1;

function toShell(message) {
	return bridge.send(message);
}

function ask(what, args) {
	if (!bridge.connected) return Promise.reject(new Error("the shell is not there"));
	const rid = `x${nextAsk++}`;
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			asks.delete(rid);
			reject(new Error("the shell did not answer"));
		}, 6000);
		asks.set(rid, {
			resolve: value => {
				clearTimeout(timer);
				resolve(value);
			},
			reject: error => {
				clearTimeout(timer);
				reject(error);
			}
		});
		toShell({ type: "ask", rid, what, args: args || {} });
	});
}

// ── tabs ─────────────────────────────────────────────────────────────────────
const favicons = new Map(); // page favicon url → data: url ("" while fetching or failed)
const groups = new Map(); // group id → { id, title, color, collapsed }
const containers = new Map(); // cookieStoreId → { name, color, icon }

function hostOf(url) {
	try {
		return new URL(url).host;
	} catch (error) {
		return "";
	}
}

async function faviconOf(tab) {
	const url = tab.favIconUrl || "";
	if (!url) return "";
	if (url.startsWith("data:")) return url.length < 24000 ? url : "";
	if (!/^https?:/.test(url)) return "";
	if (favicons.has(url)) return favicons.get(url);
	favicons.set(url, "");
	try {
		const response = await fetch(url, { cache: "force-cache", credentials: "omit" });
		const blob = await response.blob();
		if (!response.ok || blob.size > 16000) return "";
		const data = await new Promise(resolve => {
			const reader = new FileReader();
			reader.onload = () => resolve(String(reader.result || ""));
			reader.onerror = () => resolve("");
			reader.readAsDataURL(blob);
		});
		favicons.set(url, data);
		if (favicons.size > 400) favicons.delete(favicons.keys().next().value);
		if (data) reportOneTab(tab.id);
		return data;
	} catch (error) {
		return "";
	}
}

async function groupOf(tab) {
	const id = tab.groupId;
	if (id === undefined || id === -1 || !browser.tabGroups) return null;
	if (!groups.has(id)) {
		try {
			const group = await browser.tabGroups.get(id);
			groups.set(id, { id, title: group.title || "", color: group.color || "grey", collapsed: !!group.collapsed });
		} catch (error) {
			return null;
		}
	}
	return groups.get(id);
}

async function containerOf(tab) {
	const store = tab.cookieStoreId || "";
	if (!store || store === "firefox-default" || !browser.contextualIdentities) return null;
	if (!containers.has(store)) {
		try {
			const identity = await browser.contextualIdentities.get(store);
			containers.set(store, { name: identity.name, color: identity.colorCode || identity.color, icon: identity.icon });
		} catch (error) {
			return null;
		}
	}
	return containers.get(store);
}

async function plainTab(tab) {
	const sharing = tab.sharingState || {};
	return {
		id: tab.id,
		windowId: tab.windowId,
		index: tab.index,
		title: tab.title || "",
		url: tab.url || "",
		host: hostOf(tab.url || ""),
		favicon: await faviconOf(tab),
		active: !!tab.active,
		audible: !!tab.audible,
		muted: !!(tab.mutedInfo && tab.mutedInfo.muted),
		pinned: !!tab.pinned,
		hidden: !!tab.hidden,
		discarded: !!tab.discarded,
		loading: tab.status === "loading",
		lastAccessed: tab.lastAccessed || 0,
		group: await groupOf(tab),
		container: await containerOf(tab),
		sharing: {
			camera: !!sharing.camera,
			microphone: !!sharing.microphone,
			screen: sharing.screen || ""
		}
	};
}

async function reportAll() {
	if (!bridge.connected) return;
	const windows = (await browser.windows.getAll()).filter(window => !window.incognito);
	const tabs = (await browser.tabs.query({})).filter(tab => !tab.incognito);
	toShell({
		type: "tabs",
		windows: windows.map(window => ({ id: window.id, focused: !!window.focused, title: window.title || "" })),
		tabs: await Promise.all(tabs.map(plainTab))
	});
}

// onUpdated fires for every bit of loading: one report per tab and moment
const dueTabs = new Map();
function reportOneTab(id) {
	if (!bridge.connected || dueTabs.has(id)) return;
	dueTabs.set(id, setTimeout(async () => {
		dueTabs.delete(id);
		try {
			const tab = await browser.tabs.get(id);
			if (!tab.incognito) toShell({ type: "tab", tab: await plainTab(tab) });
		} catch (error) {}
	}, 150));
}

let dueAll = null;
function reportAllSoon() {
	clearTimeout(dueAll);
	dueAll = setTimeout(reportAll, 200);
}

browser.tabs.onCreated.addListener(tab => reportOneTab(tab.id));
browser.tabs.onUpdated.addListener((id, change, tab) => {
	if (!tab.incognito) reportOneTab(id);
});
browser.tabs.onActivated.addListener(info => reportAllSoon());
browser.tabs.onMoved.addListener(() => reportAllSoon());
browser.tabs.onAttached.addListener(() => reportAllSoon());
browser.tabs.onRemoved.addListener(id => toShell({ type: "tabGone", id }));
browser.windows.onFocusChanged.addListener(() => reportAllSoon());
browser.windows.onRemoved.addListener(() => reportAllSoon());
if (browser.tabGroups) {
	const regroup = group => {
		if (group && group.id !== undefined) groups.delete(group.id);
		reportAllSoon();
	};
	browser.tabGroups.onCreated?.addListener(regroup);
	browser.tabGroups.onUpdated?.addListener(regroup);
	browser.tabGroups.onRemoved?.addListener(regroup);
}
if (browser.contextualIdentities) {
	browser.contextualIdentities.onUpdated?.addListener(() => {
		containers.clear();
		reportAllSoon();
	});
}

// ── the theme ────────────────────────────────────────────────────────────────
// kept, so the browser starts in the colours it had and not in its own
async function applyTheme(theme) {
	if (!theme || !theme.colors) return;
	try {
		await browser.theme.update(theme);
		await browser.storage.local.set({ theme });
	} catch (error) {
		console.error("[pshell] theme:", error);
	}
}

// the tab rail's style (Settings › Browser › Tabs), through the extension's
// part in the browser window (experiments/chrome.js); without it, Floorp's own
let railApplied = "";
function applyRail(rail) {
	if (!rail || !browser.pshellChrome) return;
	const key = JSON.stringify(rail);
	if (key === railApplied) return;
	railApplied = key;
	browser.storage.local.set({ rail });
	browser.pshellChrome.setRail(rail).catch(error => console.error("[pshell] rail:", error));
}

// tabs and pages (Settings › Browser: Tabs, Environments, Navigation,
// Archive) go to the chrome part as they are, with whether the shell is there
let tabsApplied = "";
function applyTabs(tabs, force) {
	if (!browser.pshellChrome) return;
	const next = Object.assign({}, tabs || {}, { connected: bridge.connected });
	const key = JSON.stringify(next);
	if (key === tabsApplied && !force) return;
	tabsApplied = key;
	if (tabs) browser.storage.local.set({ tabs });
	browser.pshellChrome.setTabs(next).catch(error => console.error("[pshell] tabs:", error));
}

// what the chrome part reports: Ctrl+K wants the shell's launcher
if (browser.pshellChrome) {
	browser.pshellChrome.onEvent.addListener((name, data) => {
		if (name === "launcher") toShell({ type: "event", name: "launcher" });
	});
}

// tabs nobody looked at for long: offered to the archive by the shell (which
// asks; nothing is closed here without its "archive" command)
async function offerStale() {
	const archive = config.tabs && config.tabs.archive;
	if (!bridge.connected || !archive || !archive.on) return;
	const after = Math.max(1, Number(archive.after) || 24) * 3600 * 1000;
	const now = Date.now();
	let drafts = [];
	try {
		drafts = browser.pshellChrome ? await browser.pshellChrome.command("drafts", {}) : [];
	} catch (error) {}
	const tabs = (await browser.tabs.query({})).filter(tab =>
		!tab.incognito && !tab.pinned && !tab.active && !tab.audible && !drafts.includes(tab.id) &&
		!(tab.sharingState && (tab.sharingState.camera || tab.sharingState.microphone || tab.sharingState.screen)) &&
		/^https?:/.test(tab.url || "") && tab.lastAccessed && now - tab.lastAccessed >= after);
	if (tabs.length === 0) return;
	toShell({
		type: "event",
		name: "stale",
		tabs: tabs.map(tab => ({ id: tab.id, title: tab.title || "", url: tab.url, host: hostOf(tab.url), lastAccessed: tab.lastAccessed }))
	});
}
setInterval(offerStale, 10 * 60 * 1000);

browser.storage.local.get(["theme", "config", "rail", "tabs"]).then(kept => {
	if (kept.theme) browser.theme.update(kept.theme).catch(() => {});
	if (kept.config) config = Object.assign(config, kept.config);
	applyRail(kept.rail);
	if (kept.tabs && !config.tabs) config.tabs = kept.tabs;
	applyTabs(kept.tabs);
	buildMenu();
});

// ── the Pshell menu ──────────────────────────────────────────────────────────
// the entries are the shell's: it sends them with the config, each with the
// contexts it belongs to ("selection", "link", "image", "video", "audio",
// "page", "tab") and optionally a group to sit under a separator with
async function buildMenu() {
	await browser.menus.removeAll();
	const entries = (config.menu || []).filter(entry => entry && entry.id && entry.title);
	if (entries.length === 0) return;
	browser.menus.create({ id: "pshell", title: "Pshell", contexts: ["all", "tab"] });
	let lastGroup = null;
	let separators = 0;
	for (const entry of entries) {
		if (lastGroup !== null && entry.group !== lastGroup) {
			browser.menus.create({ id: `pshell-sep-${separators++}`, parentId: "pshell", type: "separator", contexts: ["all", "tab"] });
		}
		lastGroup = entry.group ?? null;
		browser.menus.create({
			id: `pshell:${entry.id}`,
			parentId: "pshell",
			title: entry.title,
			contexts: entry.contexts && entry.contexts.length ? entry.contexts : ["page"],
			...(entry.targets && entry.targets.length ? { targetUrlPatterns: entry.targets } : {}),
			...(entry.documents && entry.documents.length ? { documentUrlPatterns: entry.documents } : {})
		});
	}
}

// a blob: picture or video lives only in its page: read there, sent as data:
async function blobData(src, tabId, frameId) {
	try {
		const [url] = await browser.tabs.executeScript(tabId, {
			frameId: frameId || 0,
			code: `(async () => {
				const blob = await (await fetch(${JSON.stringify(src)})).blob();
				if (blob.size > 200 * 1024 * 1024) return "";
				return await new Promise(done => {
					const reader = new FileReader();
					reader.onload = () => done(reader.result);
					reader.onerror = () => done("");
					reader.readAsDataURL(blob);
				});
			})()`
		});
		return typeof url === "string" ? url : "";
	} catch (error) {
		return "";
	}
}

browser.menus.onClicked.addListener(async (info, tab) => {
	const id = String(info.menuItemId || "");
	if (!id.startsWith("pshell:")) return;
	// a click on the tab strip has no page under it
	const onTab = !info.pageUrl && !info.frameUrl && !info.linkUrl && !info.srcUrl && !info.selectionText;
	const kind = info.mediaType || (info.linkUrl ? "link" : info.selectionText ? "selection" : onTab ? "tab" : "page");
	let src = info.srcUrl || "";
	if (src.startsWith("blob:") && tab) src = (await blobData(src, tab.id, info.frameId)) || src;
	toShell({
		type: "menu",
		action: id.slice("pshell:".length),
		info: {
			kind,
			text: info.selectionText || "",
			link: info.linkUrl || "",
			linkText: info.linkText || "",
			src,
			page: (tab && tab.url) || info.pageUrl || "",
			title: (tab && tab.title) || "",
			tabId: tab ? tab.id : -1,
			private: !!(tab && tab.incognito)
		}
	});
});

// ── what the shell asks ─────────────────────────────────────────────────────
function answer(rid, data) {
	toShell({ type: "answer", rid, ok: true, data: data === undefined ? null : data });
}

function failed(rid, error) {
	toShell({ type: "answer", rid, ok: false, error: String((error && error.message) || error || "failed") });
}

async function inTab(tabId, func, args) {
	const [result] = await browser.scripting.executeScript({ target: { tabId }, func, args: args || [] });
	return result ? result.result : undefined;
}

async function activeTab() {
	const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
	return tab;
}

// pages a script may run in (not about:, not the add-ons store)
function scriptable(tab) {
	return tab && !tab.incognito && /^(https?|file):/.test(tab.url || "") && !/^https:\/\/addons\.mozilla\.org\//.test(tab.url);
}

const COMMANDS = {
	// bring a tab to the front; the shell then focuses its window in niri
	async activate(message) {
		const tab = await browser.tabs.update(message.tabId, { active: true });
		await browser.windows.update(tab.windowId, { focused: true });
		const window = await browser.windows.get(tab.windowId);
		return { windowId: tab.windowId, title: tab.title, windowTitle: window.title || "" };
	},
	async close(message) {
		await browser.tabs.remove(message.tabId);
	},
	async mute(message) {
		await browser.tabs.update(message.tabId, { muted: !!message.muted });
	},
	async open(message) {
		// the new tab page cannot be named, only left out
		const url = !message.url || message.url === "about:newtab" || message.url === "about:home" ? undefined : message.url;
		if (message.window) return (await browser.windows.create(url ? { url } : {})).id;
		const tab = await browser.tabs.create(url ? { url, active: true } : { active: true });
		await browser.windows.update(tab.windowId, { focused: true });
		return { tabId: tab.id };
	},
	// bookmarks and history for the launcher (open tabs it has already)
	async search(message) {
		const query = String(message.query || "").trim();
		const limit = Math.max(1, Math.min(50, message.limit || 12));
		if (!query) return { bookmarks: [], history: [] };
		const bookmarks = (await browser.bookmarks.search(query))
			.filter(mark => mark.url && /^(https?|file):/.test(mark.url))
			.slice(0, limit)
			.map(mark => ({ title: mark.title, url: mark.url, host: hostOf(mark.url) }));
		const history = (await browser.history.search({ text: query, maxResults: limit * 2, startTime: 0 }))
			.filter(item => item.url && /^https?:/.test(item.url))
			.sort((a, b) => (b.visitCount || 0) - (a.visitCount || 0))
			.slice(0, limit)
			.map(item => ({ title: item.title || "", url: item.url, host: hostOf(item.url), visits: item.visitCount || 0, last: item.lastVisitTime || 0 }));
		return { bookmarks, history };
	},
	// the page as a picture: what shows, or the whole page (Firefox draws it
	// without scrolling); the host writes the picture to a file
	async capture(message) {
		const tab = message.tabId >= 0 ? await browser.tabs.get(message.tabId) : await activeTab();
		if (!tab || tab.incognito) throw new Error("no page");
		if (!/^(https?|file|moz-extension):/.test(tab.url || "")) throw new Error("this page cannot be captured");
		const options = { format: "png" };
		if (message.full && scriptable(tab)) {
			const size = await inTab(tab.id, () => ({
				width: Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0),
				height: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)
			}));
			if (size) options.rect = { x: 0, y: 0, width: Math.min(size.width, 8000), height: Math.min(size.height, 30000) };
		}
		const dataUrl = await browser.tabs.captureTab(tab.id, options);
		return { dataUrl, title: tab.title, url: tab.url, tabId: tab.id };
	},
	// the readable text of a page (for the reader, AI and translation of a page)
	async text(message) {
		const tab = message.tabId >= 0 ? await browser.tabs.get(message.tabId) : await activeTab();
		if (!scriptable(tab)) throw new Error("no page");
		const text = await inTab(tab.id, () => {
			const picked = String(window.getSelection() || "").trim();
			if (picked) return picked;
			const root = document.querySelector("article, main, [role=main]") || document.body;
			return root ? root.innerText : "";
		});
		return { title: tab.title, url: tab.url, text: String(text || "").slice(0, 400000) };
	},
	// everything that plays stops (for a break); the shell gets the tabs back to resume
	async pauseMedia() {
		const paused = [];
		for (const tab of await browser.tabs.query({})) {
			if (!scriptable(tab) || tab.discarded) continue;
			try {
				const count = await inTab(tab.id, () => {
					let count = 0;
					for (const media of document.querySelectorAll("video, audio")) {
						if (!media.paused) {
							media.pause();
							media.dataset.pshellPaused = "1";
							count++;
						}
					}
					return count;
				});
				if (count > 0) paused.push(tab.id);
			} catch (error) {}
		}
		return { tabs: paused };
	},
	async resumeMedia(message) {
		for (const tabId of message.tabs || []) {
			try {
				await inTab(tabId, () => {
					for (const media of document.querySelectorAll("[data-pshell-paused]")) {
						delete media.dataset.pshellPaused;
						media.play().catch(() => {});
					}
				});
			} catch (error) {}
		}
	},
	// what plays in a tab: playing, paused, where (for the bar's media card)
	async media(message) {
		const tab = await browser.tabs.get(message.tabId);
		if (!scriptable(tab)) return null;
		return await inTab(tab.id, () => {
			const media = [...document.querySelectorAll("video, audio")].find(item => !item.paused) || document.querySelector("video, audio");
			return media ? { playing: !media.paused, position: media.currentTime, duration: media.duration || 0 } : null;
		});
	},
	// an identity the user picked goes into the form of a tab (content/page.js)
	async fill(message) {
		return await browser.tabs.sendMessage(message.tabId, { pshell: "fill", identity: message.identity });
	},
	// the tabs the shell's toast was agreed to: closed, their pages handed back
	async archive(message) {
		const kept = [];
		const ids = [];
		for (const id of message.tabIds || []) {
			try {
				const tab = await browser.tabs.get(id);
				if (tab.incognito) continue;
				kept.push({ title: tab.title || "", url: tab.url || "", host: hostOf(tab.url || ""), favicon: await faviconOf(tab), closedAt: Date.now() });
				ids.push(id);
			} catch (error) {}
		}
		if (ids.length) await browser.tabs.remove(ids);
		return kept;
	},
	// a page as a PDF (Firefox asks where to)
	async pdf(message) {
		const tab = message.tabId >= 0 ? await browser.tabs.get(message.tabId) : await activeTab();
		if (!tab.active) await browser.tabs.update(tab.id, { active: true });
		return await browser.tabs.saveAsPDF({});
	},
	// the chrome part's: peek {url, source}, hints {mode}, spur {tabId},
	// pin {tabId, slot}, env {tabId}, slot {slot}
	async peek(message) {
		return await chromeCommand("peek", { url: message.url, source: message.source || "" });
	},
	async hints(message) {
		return await chromeCommand("hints", { mode: message.mode || "open" });
	},
	async spur(message) {
		return await chromeCommand("spur", { tabId: message.tabId ?? -1 });
	},
	async pin(message) {
		return await chromeCommand("pin", { tabId: message.tabId, slot: message.slot || 1 });
	},
	async env(message) {
		return await chromeCommand("env", { tabId: message.tabId ?? -1 });
	},
	async slot(message) {
		return await chromeCommand("slot", { slot: message.slot || 1 });
	}
};

async function chromeCommand(name, args) {
	if (!browser.pshellChrome) throw new Error("the window part is off (extensions.experiments.enabled)");
	return await browser.pshellChrome.command(name, args);
}

async function runCommand(message) {
	const run = COMMANDS[message.cmd];
	if (!run) return failed(message.rid, `unknown command ${message.cmd}`);
	try {
		answer(message.rid, await run(message));
	} catch (error) {
		failed(message.rid, error);
	}
}

function fromShell(message) {
	if (message.type === "sync") {
		toShell({ type: "ready", browser: browserName, version: browser.runtime.getManifest().version });
		return reportAll();
	}
	if (message.type === "cmd") return runCommand(message);
	if (message.type === "answer") {
		const waiting = asks.get(message.rid);
		if (!waiting) return;
		asks.delete(message.rid);
		return message.ok ? waiting.resolve(message.data) : waiting.reject(new Error(message.error || "failed"));
	}
	if (message.type === "theme") return applyTheme(message.theme);
	if (message.type === "config") {
		config = Object.assign({}, config, message.config || {});
		// what the pages' script reads: no menu, nothing of the blocked sites
		browser.storage.local.set({
			config: { intercept: config.intercept, forms: config.forms, newtab: config.newtab },
			pageConfig: { intercept: config.intercept, forms: config.forms }
		});
		applyRail(config.rail);
		applyTabs(config.tabs);
		return buildMenu();
	}
	if (message.type === "newtab") {
		newtabData = message.data || null;
		browser.runtime.sendMessage({ pshell: "newtab", data: newtabData }).catch(() => {});
	}
}

// ── blocked sites ────────────────────────────────────────────────────────────
// only what the shell sends after the user agreed (focus time); a visit goes
// to a page that says so, with the way on
function blockedRule(url) {
	const host = hostOf(url).replace(/^www\./, "");
	const now = Date.now();
	return (config.blocked || []).find(rule => rule && (!rule.until || rule.until > now) && (host === rule.host || host.endsWith(`.${rule.host}`)));
}

browser.webNavigation.onBeforeNavigate.addListener(details => {
	if (details.frameId !== 0 || !/^https?:/.test(details.url)) return;
	const rule = blockedRule(details.url);
	if (!rule) return;
	const page = browser.runtime.getURL(`blocked/blocked.html?u=${encodeURIComponent(details.url)}&until=${rule.until || 0}`);
	browser.tabs.update(details.tabId, { url: page }).catch(() => {});
	toShell({ type: "event", name: "blockedVisit", host: hostOf(details.url) });
});

// ── the pages of the extension and its page script ──────────────────────────
browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || !message.pshell) return;
	const tab = sender.tab;
	switch (message.pshell) {
		case "newtab":
			if (bridge.connected && !newtabData) ask("newtab").then(data => {
				newtabData = data;
				browser.runtime.sendMessage({ pshell: "newtab", data }).catch(() => {});
			}).catch(() => {});
			return Promise.resolve(newtabData);
		case "newtabOpen":
			// a tile or a card of the new tab page: the shell opens what is its own
			toShell({ type: "event", name: "newtabOpen", what: message.what, id: message.id || "" });
			return Promise.resolve(true);
		case "identities":
			if (!tab || tab.incognito) return Promise.resolve([]);
			return ask("identities", { host: hostOf(tab.url || "") }).catch(() => []);
		case "identityUsed":
			if (tab && !tab.incognito) toShell({ type: "event", name: "identityUsed", id: message.id, host: hostOf(tab.url || "") });
			return Promise.resolve(true);
		case "mailto":
			toShell({ type: "event", name: "mailto", url: message.url, private: !!(tab && tab.incognito) });
			return Promise.resolve(true);
		case "calendar":
			toShell({ type: "event", name: "calendar", url: message.url, page: tab ? tab.url : "", private: !!(tab && tab.incognito) });
			return Promise.resolve(true);
		case "unblock":
			config.blocked = (config.blocked || []).filter(rule => rule.host !== message.host);
			toShell({ type: "event", name: "unblock", host: message.host });
			return Promise.resolve(true);
		case "connected":
			return Promise.resolve(bridge.connected);
	}
});

browser.runtime.getBrowserInfo().then(info => {
	browserName = info.name;
}).finally(() => bridge.connect());
