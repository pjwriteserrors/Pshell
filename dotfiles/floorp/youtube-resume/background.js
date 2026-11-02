// Which tabs have a YouTube video open, kept in storage.local as "open"
// ({ tab id: { id, title, url } }) whenever it changes. Closing a window or
// the browser leaves the list as it is, so the next start finds the tabs that
// were open at the end and keeps them as "session" for the popup.

const api = typeof browser !== "undefined" ? browser : chrome;
// positions kept at most, the ones not touched for longest go first
const KEEP = 3000;
const open = {};

const started = (async () => {
	const all = await api.storage.local.get(null);
	const last = Object.values(all.open || {});
	if (last.length > 0) await api.storage.local.set({ session: { at: Date.now(), tabs: last } });
	else await api.storage.local.remove("session");
	persist();
	const kept = Object.entries(all).filter(([key]) => key.startsWith("v:")).sort((a, b) => b[1].at - a[1].at);
	if (kept.length > KEEP) await api.storage.local.remove(kept.slice(KEEP).map(([key]) => key));
})();

function persist() {
	api.storage.local.set({ open });
}

// The shell's series (scripts/streams/native_host.py): how far a video is and
// that it ended; the shell can have the next one open in the tab that played
// this one. Without the host everything else works the same.
let shell = null;
let shellRetry = 0;
let lastTab = null;

function connectShell() {
	if (shell || Date.now() < shellRetry) return;
	try {
		shell = api.runtime.connectNative("pshell_streams");
		shell.onMessage.addListener(message => {
			if (message.type !== "open") return;
			if (lastTab !== null) api.tabs.update(lastTab, { url: message.url, active: true }).catch(() => api.tabs.create({ url: message.url }));
			else api.tabs.create({ url: message.url });
		});
		shell.onDisconnect.addListener(() => {
			shell = null;
			shellRetry = Date.now() + 60000;
		});
	} catch (error) {
		shell = null;
		shellRetry = Date.now() + 60000;
	}
}

function tellShell(message) {
	connectShell();
	try {
		if (shell) shell.postMessage(message);
	} catch (error) {
		shell = null;
	}
}

api.runtime.onMessage.addListener(async (message, sender) => {
	if (message.type === "ended" && sender.tab) {
		lastTab = sender.tab.id;
		tellShell({ what: "ended", video: message.id });
		return;
	}
	if (message.type !== "watching" || !sender.tab) return;
	await started;
	const tab = sender.tab;
	lastTab = tab.id;
	tellShell({ what: "position", video: message.id, t: message.t, d: message.d });
	const known = open[tab.id];
	open[tab.id] = { id: message.id, title: message.title, url: `https://www.youtube.com/watch?v=${message.id}` };
	if (!known || known.id !== message.id || known.title !== message.title) persist();
});

api.tabs.onRemoved.addListener(async (tabId, info) => {
	await started;
	// a window that closes (or the browser) keeps its tabs for the next start
	if (info.isWindowClosing || !(tabId in open)) return;
	delete open[tabId];
	persist();
});

api.tabs.onUpdated.addListener(async (tabId, change) => {
	if (!change.url) return;
	await started;
	const url = new URL(change.url);
	const watch = /(^|\.)youtube\.com$/.test(url.hostname) && url.pathname === "/watch";
	if (!watch && tabId in open) {
		delete open[tabId];
		persist();
	}
});
