pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Continue from the phone (docs/browser.md): the page last open on the
// phone, offered on the new tab page and at the top of the launcher's >tab.
// Two sources, the newer wins:
//   - the app's "Continue on PC" (share a page to it): the phone's topic
//     phone.handoff carries { page: { url, title, at } } (docs/mobile.md);
//   - Firefox Sync, when the browser is signed in: the newest tab of a
//     phone or tablet (the extension's `syncedTabs`).
// Offered for 12 hours, not while it is open in a tab here, and not again
// once opened (phone-tab.json keeps the last addresses taken).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-link") && (Plugins.on("browser-newtab") || Plugins.on("browser-launcher"))
	readonly property real keep: 12 * 3600000
	// WebPage reads `offer` while it is built: nothing of WebLink or Phone before this one is
	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	// { url, title, at, device, from: "app" | "sync" }
	readonly property var fromApp: {
		if (!root.built || !root.enabled || !Plugins.on("phone-handoff")) return null;
		const page = Phone.of("phone.handoff")?.page;
		if (!page || !/^https?:\/\//.test(String(page.url || ""))) return null;
		return { url: String(page.url), title: String(page.title || ""), at: Number(page.at) || 0, device: Phone.name, from: "app" };
	}
	property var fromSync: null
	property var taken: []
	property real now: Date.now()

	readonly property var offer: {
		if (!root.built) return null;
		const open = new Set(WebLink.tabs.map(tab => tab.url));
		const fresh = [root.fromApp, root.fromSync].filter(page => page && root.now - page.at < root.keep && !open.has(page.url) && !root.taken.includes(page.url));
		if (fresh.length === 0) return null;
		const page = fresh.sort((a, b) => b.at - a.at)[0];
		let host = "";
		try {
			host = String(page.url).split("/")[2].replace(/^www\./, "");
		} catch (error) {}
		return Object.assign({ host: host }, page);
	}

	function refresh() {
		root.now = Date.now();
		if (!root.enabled || !WebLink.connected) return;
		WebLink.command("syncedTabs", {}, (ok, tabs) => {
			const mobile = ok && Array.isArray(tabs) ? tabs.filter(tab => /phone|mobile|tablet/i.test(String(tab.deviceType || ""))) : [];
			const tab = mobile[0];
			root.fromSync = tab ? { url: String(tab.url), title: String(tab.title || ""), at: Number(tab.lastUsed) || 0, device: String(tab.device || ""), from: "sync" } : null;
		});
	}

	function open() {
		const page = root.offer;
		if (!page) return;
		root.took(page.url);
		if (WebLink.connected) WebLink.open(page.url);
		else Browser.open(page.url);
	}

	// opened (here, or by the new tab page itself)
	function took(url) {
		if (!url || root.taken.includes(url)) return;
		root.taken = [String(url)].concat(root.taken).slice(0, 20);
		store.setText(JSON.stringify({ taken: root.taken }));
	}

	FileView {
		id: store

		path: Paths.stateFile("phone-tab.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.taken = JSON.parse(store.text() || "{}").taken ?? [];
			} catch (error) {}
		}
	}

	Timer {
		running: root.built && root.enabled && WebLink.connected
		repeat: true
		interval: 120000
		triggeredOnStart: true
		onTriggered: root.refresh()
	}
}
