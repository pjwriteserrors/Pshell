/* The tabs of the browser on other devices (Firefox Sync), for "Continue
 * from the phone": the command `syncedTabs` → [{ device, deviceType, title,
 * url, lastUsed (ms) }], newest first. Nothing while Sync is not signed in
 * (its machinery is not even loaded then). */
"use strict";

(function () {
	COMMANDS.syncedTabs = async () => {
		if (!Services.prefs.getStringPref("services.sync.username", "")) return [];
		let SyncedTabs;
		try {
			({ SyncedTabs } = ChromeUtils.importESModule("resource://services-sync/SyncedTabs.sys.mjs"));
		} catch (error) {
			return [];
		}
		if (!SyncedTabs.isConfiguredToSyncTabs) return [];
		const out = [];
		for (const client of await SyncedTabs.getTabClients()) {
			for (const tab of client.tabs || []) {
				if (!/^https?:/.test(tab.url || "")) continue;
				const used = Number(tab.lastUsed) || 0;
				out.push({
					device: String(client.name || ""),
					deviceType: String(client.clientType || ""),
					title: String(tab.title || ""),
					url: tab.url,
					lastUsed: used < 1e12 ? used * 1000 : used
				});
			}
		}
		return out.sort((a, b) => b.lastUsed - a.lastUsed).slice(0, 40);
	};
})();
