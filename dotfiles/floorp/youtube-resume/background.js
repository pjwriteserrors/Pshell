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

api.runtime.onMessage.addListener(async (message, sender) => {
	if (message.type !== "watching" || !sender.tab) return;
	await started;
	const tab = sender.tab;
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
