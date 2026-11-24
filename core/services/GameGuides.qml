pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Guides for the game that runs (docs/games.md "Guides"). While a game runs
// the browser's tabs about it (its name in the title or the address: a wiki,
// a map, a walkthrough, a thread) are noted; when it ends they are kept for
// it (game-guides.json, at most eight, nothing of a private window). The
// next time it starts the shell offers them: Open puts them behind the tab
// in front, Show (or `ipc games guides`, Mod+Shift+G) floats them in a window
// of their own over the game (background/games.js `guide`); again closes it
// and the game has the focus again.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("games") && Plugins.on("browser-link")
	readonly property string cardPreface: "Guide · "

	// gameId → { name, tabs: [{ url, title, host }], at }
	property var guides: ({})
	// gameId → { url: { url, title, host, at } } of the run going on
	property var session: ({})
	property var wasRunning: []
	// the window that had the focus before the card came
	property int focusBefore: -1

	readonly property string current: String(Games.running[0] ?? "")

	function nameOf(id) {
		return String(Games.game(id)?.name ?? root.guides[id]?.name ?? "");
	}

	function normal(text) {
		return String(text || "").toLowerCase().replace(/[™®©]/g, "").replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
	}

	// the words that make a name (no "the", no edition)
	function wordsOf(name) {
		const skip = ["the", "of", "and", "a", "an", "edition", "definitive", "remastered", "goty", "complete", "deluxe", "enhanced"];
		return root.normal(name).split(" ").filter(word => word.length >= 2 && !skip.includes(word));
	}

	// a tab about this game: every word of its name in the title, or the
	// name run together in the address (eldenring.wiki.fextralife.com)
	function about(tab, name) {
		const words = root.wordsOf(name);
		if (words.length === 0 || !/^https?:/.test(String(tab.url || ""))) return false;
		const title = ` ${root.normal(tab.title)} `;
		if (words.every(word => title.includes(` ${word} `))) return true;
		const address = root.normal(decodeURIComponent(String(tab.url).replace(/^https?:\/\//, ""))).replace(/ /g, "");
		return words.join("").length >= 5 && address.includes(words.join(""));
	}

	function note(which) {
		const id = which ?? root.current;
		if (!root.enabled || !id) return;
		const name = root.nameOf(id);
		if (name === "") return;
		const seen = Object.assign({}, root.session[id] ?? {});
		let changed = false;
		for (const tab of WebLink.tabs) {
			if (!root.about(tab, name) || String(tab.title || "").startsWith(root.cardPreface)) continue;
			const url = String(tab.url);
			if (!seen[url]) changed = true;
			seen[url] = { url: url, title: String(tab.title || ""), host: String(tab.host || ""), at: Math.max(Number(tab.lastAccessed) || 0, seen[url]?.at ?? 0) };
		}
		if (changed) root.session = Object.assign({}, root.session, { [id]: seen });
	}

	function guidesOf(id) {
		const now = Object.values(root.session[id] ?? {});
		const kept = root.guides[id]?.tabs ?? [];
		const all = now.concat(kept.filter(tab => !now.some(each => each.url === tab.url)));
		return all.slice(0, 8);
	}

	function started(id) {
		if (!Games.loaded && !Games.loading) Games.refresh();
		const tabs = root.guides[id]?.tabs ?? [];
		if (tabs.length === 0) return;
		const name = root.nameOf(id);
		Notifs.pushInternal("", name ? `Guides for ${name}` : "Guides", tabs.map(tab => tab.title || tab.host).slice(0, 3).join(" · "), {
			icon: "book_open_page_variant_outline",
			app: "Games",
			duration: 12000,
			actions: [
				{ label: "Open", icon: "tab_plus", run: () => WebLink.command("guideOpen", { urls: tabs.map(tab => tab.url) }) },
				{ label: "Show", icon: "book_open_outline", run: () => root.show(id) }
			]
		});
	}

	function ended(id) {
		root.note(id);
		const tabs = Object.values(root.session[id] ?? {}).sort((a, b) => b.at - a.at).slice(0, 8).map(tab => ({ url: tab.url, title: tab.title, host: tab.host }));
		const next = Object.assign({}, root.session);
		delete next[id];
		root.session = next;
		if (tabs.length === 0) return;
		root.guides = Object.assign({}, root.guides, { [id]: { name: root.nameOf(id), tabs: tabs, at: Math.floor(Date.now() / 1000) } });
		store.setText(JSON.stringify(root.guides, null, 2) + "\n");
	}

	// the card: shown, or closed again
	function toggle() {
		if (!root.enabled) return;
		const card = root.cardWindow();
		if (card) return root.hide();
		if (root.current === "") return Notifs.pushInternal("", "No game runs", "", { icon: "gamepad_variant_outline" });
		root.show(root.current);
	}

	function show(id) {
		root.note();
		const tabs = root.guidesOf(id);
		if (tabs.length === 0) {
			const name = root.nameOf(id);
			return Notifs.pushInternal("", name ? `No guides for ${name}` : "No guides", "", { icon: "book_open_outline" });
		}
		if (root.cardWindow()) return;
		root.focusBefore = Niri.focusedId;
		WebLink.command("guide", { urls: tabs.map(tab => tab.url), title: root.nameOf(id) }, ok => {
			if (ok) {
				floatCard.tries = 0;
				floatCard.restart();
			}
		});
	}

	function hide() {
		WebLink.command("guideClose", {}, () => {
			const back = root.focusBefore;
			root.focusBefore = -1;
			if (back >= 0 && Niri.windows.some(window => Number(window.id) === back)) Niri.focusWindow(back);
		});
	}

	function cardWindow() {
		return Niri.windows.find(window => String(window.title || "").startsWith(root.cardPreface) && /floorp|firefox|librewolf|zen|waterfox/i.test(String(window.app_id || ""))) ?? null;
	}

	// dotfiles/niri/pshell.kdl floats it when it opens; a title that came
	// too late for the rule is floated here
	Timer {
		id: floatCard

		property int tries: 0

		interval: 150
		onTriggered: {
			const card = root.cardWindow();
			if (!card) {
				if (++tries < 30) restart();
				return;
			}
			if (!card.is_floating) Quickshell.execDetached(["niri", "msg", "action", "toggle-window-floating", "--id", String(card.id)]);
		}
	}

	Connections {
		target: Games
		enabled: root.enabled

		function onRunningChanged() {
			const now = Games.running.slice();
			for (const id of now) if (!root.wasRunning.includes(id)) root.started(id);
			for (const id of root.wasRunning) if (!now.includes(id)) root.ended(id);
			root.wasRunning = now;
			root.note();
		}
	}

	Connections {
		target: WebLink
		enabled: root.enabled && root.current !== ""

		function onTabsUpdated() {
			noteSoon.restart();
		}
	}

	// a name that came later (the library is read on the game's start)
	Timer {
		interval: 30000
		repeat: true
		running: root.enabled && root.current !== ""
		onTriggered: root.note()
	}

	Connections {
		target: Games
		enabled: root.enabled && root.current !== ""

		function onGamesChanged() {
			noteSoon.restart();
		}
	}

	Timer {
		id: noteSoon

		interval: 2000
		onTriggered: root.note()
	}

	FileView {
		id: store

		path: Paths.stateFile("game-guides.json")
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(store.text() || "{}"));
				root.guides = data && typeof data === "object" ? data : {};
			} catch (error) {}
		}
	}
}
