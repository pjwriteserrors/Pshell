/* What every part shares: the browser windows, the settings from the shell,
 * events to the extension (and on to the shell) and the script in the pages.
 *
 * A part registers itself in PARTS with any of
 *   attach(W)              a window was opened (W: { win, doc, gBrowser, private, … })
 *   configure(W, tabs)     the settings changed (and right after attach)
 *   detach(W)              the extension goes away; undo everything
 *   page: { what(W, browser, data) }   a message from the page script
 * and commands in COMMANDS (the extension's pshellChrome.command). */
"use strict";

/* exported PARTS, COMMANDS, listeners, emit, tabsConfig, on, every, el, frontWindow,
   pageMessage, sendPage, chromeRect, setRail, setTabs, command, start, stop, SYSTEM, browserWindows, windowOf */

var COMMANDS = {};
var listeners = new Set();
var config = { rail: null, tabs: null };
var running = false;
// the windows taken over; a window's W is found here, not as an expando on
// the window (one set from here is not always seen through other wrappers)
var attached = new Set();

var { PrivateBrowsingUtils } = ChromeUtils.importESModule("resource://gre/modules/PrivateBrowsingUtils.sys.mjs");
// the browser window's (its module moved between versions)
var SessionStore = null;

var SYSTEM = () => Services.scriptSecurityManager.getSystemPrincipal();
var XHTML = "http://www.w3.org/1999/xhtml";

// the settings the shell sends (WebPage.tabs); also what applies before it did
var DEFAULT_TABS = {
	recent: { on: true, minutes: 10, count: 6 },
	dock: true,
	ctrlTab: true,
	states: true,
	filter: true,
	bySite: true,
	envs: {
		on: true,
		group: true,
		list: [
			{ id: "live", name: "Live", color: 1, patterns: [], cycle: true },
			{ id: "stage", name: "Stage", color: 4, patterns: ["staging.*", "stage.*", "*.staging.*"], cycle: true },
			{ id: "dev", name: "Dev", color: 2, patterns: ["localhost", "*.test", "*.ddev.site", "*.local"], cycle: true }
		]
	},
	hints: { on: true, chars: "asdfghjkl" },
	peek: { on: true, external: "peek" },
	spur: { on: true, columns: 3 },
	archive: { on: true, after: 24, keep: 30 },
	launcherKey: true,
	urlbarLauncher: false,
	// set by the extension: whether the shell is there to take Ctrl+K
	connected: false
};

function merged(base, over) {
	const out = {};
	for (const key of Object.keys(base)) {
		const a = base[key];
		const b = over ? over[key] : undefined;
		out[key] = a && typeof a === "object" && !Array.isArray(a) ? merged(a, b && typeof b === "object" ? b : {}) : b === undefined ? a : b;
	}
	return out;
}

function tabsConfig() {
	return config.tabs || DEFAULT_TABS;
}

function emit(name, data) {
	for (const listener of listeners) {
		try {
			listener(name, data || {});
		} catch (error) {
			console.error("[pshell]", error);
		}
	}
}

function browserWindows() {
	return [...Services.wm.getEnumerator("navigator:browser")].filter(win => !win.closed && win.gBrowser);
}

// the W of a window, or of a tab, browser or document in it
function windowOf(thing) {
	if (!thing) return null;
	const doc = thing.ownerDocument || thing.document || thing;
	for (const W of attached) if (W.doc === doc || W.win === thing) return W;
	return null;
}

function frontWindow() {
	return windowOf(Services.wm.getMostRecentWindow("navigator:browser"));
}

// listeners and timers that go away with the window's W
function on(W, target, type, listener, options) {
	target.addEventListener(type, listener, options);
	W.cleanup.push(() => target.removeEventListener(type, listener, options));
}

function every(W, ms, run) {
	const id = W.win.setInterval(run, ms);
	W.cleanup.push(() => W.win.clearInterval(id));
}

// an HTML element in the browser window: el(doc, "div", { id, class, … }, parent)
function el(doc, tag, attributes, parent) {
	const node = doc.createElementNS(XHTML, tag);
	for (const [key, value] of Object.entries(attributes || {})) {
		if (key === "text") node.textContent = value;
		else if (value !== null && value !== undefined && value !== false) node.setAttribute(key, value === true ? "" : String(value));
	}
	if (parent) parent.appendChild(node);
	return node;
}

// a rectangle the page reported (CSS pixels of its viewport) in the window's
function chromeRect(browser, rect) {
	const box = browser.getBoundingClientRect();
	const zoom = browser.fullZoom || 1;
	if (!rect) return { x: box.x + box.width / 2 - 20, y: box.y + box.height / 2 - 20, width: 40, height: 40 };
	return { x: box.x + rect.x * zoom, y: box.y + rect.y * zoom, width: rect.width * zoom, height: rect.height * zoom };
}

// ── the page script (parts/frame.js) ───────────────────────────────────────
// one frame script for every page of the window – tabs, the Peek card and the
// Spur's columns alike; it reports with "pshell:page" and listens on "pshell:to"
var frameUrl = "";

function sendPage(browser, what, data) {
	try {
		browser.messageManager?.sendAsyncMessage("pshell:to", Object.assign({ what }, data || {}));
	} catch (error) {}
}

// what a page needs to know about itself
function pageState(W, browser) {
	const tabs = tabsConfig();
	const state = {
		hints: tabs.hints.on,
		chars: tabs.hints.chars,
		peekOn: tabs.peek.on && !W.private,
		spurOn: tabs.spur.on && !W.private,
		states: tabs.states,
		rail: false,
		filtering: false,
		peek: false,
		spur: false
	};
	for (const part of PARTS) part.pageState?.(W, browser, state);
	return state;
}

function updatePage(W, browser) {
	sendPage(browser, "state", { state: pageState(W, browser) });
}

function pageMessage(message) {
	const browser = message.target;
	const W = windowOf(browser);
	if (!W) return;
	const data = message.data || {};
	if (data.what === "hello") return updatePage(W, browser);
	for (const part of PARTS) {
		const handler = part.page && part.page[data.what];
		if (handler) {
			try {
				handler(W, browser, data);
			} catch (error) {
				console.error("[pshell]", part.name, data.what, error);
			}
		}
	}
}

// ── windows ─────────────────────────────────────────────────────────────────
function attach(win) {
	if (windowOf(win) || !win.gBrowser) return;
	if (!SessionStore) SessionStore = win.SessionStore;
	const W = {
		win,
		doc: win.document,
		gBrowser: win.gBrowser,
		private: PrivateBrowsingUtils.isWindowPrivate(win),
		cleanup: []
	};
	attached.add(W);
	win.pshell = W; // for a look from the browser console only
	const sheet = `${base}chrome.css`;
	try {
		win.windowUtils.loadSheetUsingURIString(sheet, win.windowUtils.AUTHOR_SHEET);
		W.cleanup.push(() => win.windowUtils.removeSheetUsingURIString(sheet, win.windowUtils.AUTHOR_SHEET));
	} catch (error) {
		console.error("[pshell] sheet:", error);
	}
	win.messageManager.addMessageListener("pshell:page", pageMessage);
	W.cleanup.push(() => win.messageManager.removeMessageListener("pshell:page", pageMessage));
	if (frameUrl) {
		win.messageManager.loadFrameScript(frameUrl, true);
		W.cleanup.push(() => {
			win.messageManager.removeDelayedFrameScript(frameUrl);
			win.messageManager.broadcastAsyncMessage("pshell:to", { what: "unload" });
		});
	}
	for (const part of PARTS) {
		try {
			part.attach?.(W);
		} catch (error) {
			console.error("[pshell]", part.name, "attach:", error);
		}
	}
	configureWindow(W);
}

function detach(win) {
	const W = windowOf(win);
	if (!W) return;
	for (const part of [...PARTS].reverse()) {
		try {
			part.detach?.(W);
		} catch (error) {
			console.error("[pshell]", part.name, "detach:", error);
		}
	}
	for (const undo of W.cleanup.splice(0).reverse()) {
		try {
			undo();
		} catch (error) {}
	}
	attached.delete(W);
	delete win.pshell;
}

function configureWindow(W) {
	const tabs = tabsConfig();
	for (const part of PARTS) {
		try {
			part.configure?.(W, tabs);
		} catch (error) {
			console.error("[pshell]", part.name, "configure:", error);
		}
	}
	for (const browser of W.gBrowser.browsers) updatePage(W, browser);
}

// every browser window once it has finished starting (also the first one,
// which may still be starting when the extension does)
var opened = {
	observe(subject, topic) {
		if (topic !== "browser-delayed-startup-finished") return;
		// the sidebar finishes its own setup a moment later
		subject.setTimeout(() => attach(subject), 300);
	}
};

function ready(win) {
	return win.gBrowser && win.gBrowserInit && win.gBrowserInit.delayedStartupFinished;
}

// ── what chrome.js calls ────────────────────────────────────────────────────
function setRail(rail) {
	config.rail = { style: rail.style, width: rail.width || 0 };
	for (const part of PARTS) part.rail?.(config.rail);
}

function setTabs(tabs) {
	config.tabs = merged(DEFAULT_TABS, tabs || {});
	for (const part of PARTS) part.configured?.(config.tabs);
	for (const W of attached) configureWindow(W);
}

async function command(name, args) {
	const run = COMMANDS[name];
	if (!run) throw new Error(`unknown command ${name}`);
	return await run(args);
}

function start() {
	if (running) return;
	running = true;
	if (typeof pshellFrame === "function") {
		frameUrl = "data:application/javascript;charset=utf-8," + encodeURIComponent(`(${pshellFrame.toString()})();`);
	}
	for (const part of PARTS) part.start?.();
	for (const win of browserWindows()) if (ready(win)) attach(win);
	Services.obs.addObserver(opened, "browser-delayed-startup-finished");
}

function stop() {
	if (!running) return;
	running = false;
	Services.obs.removeObserver(opened, "browser-delayed-startup-finished");
	for (const win of browserWindows()) detach(win);
	for (const part of PARTS) part.stop?.();
}
