pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Game deals (docs/games.md "Deals"): games free for a while on Steam and
// the Epic Games Store, the wish list with the stores' prices – both kept by
// pshell-core (pcore/server/pshell_core/gamedeals.py), so the phone and the
// portal see the same – and, for the browser's store pages, whether a game
// is in the library already (scripts/games.py owned, this PC's own).
//
// Core tells `free_game` (a game free for the first time) and `game_sale` (a
// wish whose discount rose) through the NAS daemon's relay (Nas.coreEvent);
// each becomes a notification whose button opens the store's page. Nothing
// is bought or claimed here.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("games")
	readonly property bool online: root.enabled && Netcore.online

	// [{ id, store, title, url, image, from, until, now }]
	property var free: []
	property var soon: []
	// [{ id, store, key, title, url, image, added, price: { discount, final, initial, currency, text } | null }]
	property var wishes: []
	property bool loaded: false
	readonly property var onSale: root.wishes.filter(wish => (wish.price?.discount ?? 0) > 0)
	// free ones not in the library
	readonly property var freeNew: root.free.filter(game => !root.ownedGame(game.store, String(game.id).split(":").slice(1).join(":"), game.title))
	readonly property int count: root.freeNew.length + root.onSale.length

	// ── what is in the library (games.py owned) ────────────────────────────
	// { steam: [appid], games: [{ id, name, normal, kind, store }] }
	property var owned: ({ steam: [], games: [] })
	property real ownedAt: 0
	property var ownedWaiting: []

	function normal(name) {
		return String(name || "").toLowerCase().replace(/[™®©]/g, "").replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
	}

	// the library's game for a store's game: its Steam app, else its name
	function ownedGame(store, key, title) {
		const games = root.owned.games ?? [];
		if (store === "steam" && /^\d+$/.test(String(key))) {
			const game = games.find(each => each.store === String(key) || (each.kind === "steam" && each.id === `steam:${key}`));
			if (game) return game;
			if ((root.owned.steam ?? []).includes(String(key))) return { id: `steam:${key}`, name: String(title || ""), kind: "steam" };
		}
		const name = root.normal(title);
		if (name === "") return null;
		// "Game: Definitive Edition" is the game
		const plain = name.replace(/ (game of the year|goty|definitive|complete|deluxe|enhanced|remastered|anniversary|ultimate|gold)( edition)?$/, "").replace(/ edition$/, "");
		return games.find(each => each.normal === name || each.normal === plain) ?? null;
	}

	function withOwned(then) {
		if (Date.now() - root.ownedAt < 10 * 60 * 1000) return then();
		root.ownedWaiting = root.ownedWaiting.concat([then]);
		if (!ownedReader.running) ownedReader.running = true;
	}

	Process {
		id: ownedReader

		command: ["python3", `${Paths.scripts}/games.py`, "owned"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(text);
					if (Array.isArray(data.games)) {
						root.owned = data;
						root.ownedAt = Date.now();
					}
				} catch (error) {}
				const waiting = root.ownedWaiting;
				root.ownedWaiting = [];
				for (const then of waiting) then();
			}
		}
	}

	// ── the browser's store pages (content/games.js asks through WebPage) ───
	// args { store, key, title } → { owned, name, wish, free, core }
	function answer(args, reply) {
		if (!root.enabled) return reply(false, "the games are off");
		const store = String(args?.store ?? "");
		const key = String(args?.key ?? "");
		const title = String(args?.title ?? "");
		root.withOwned(() => {
			const game = root.ownedGame(store, key, title);
			reply(true, {
				owned: !!game,
				name: game ? String(game.name || title) : "",
				wish: root.wishFor(store, key, title),
				free: root.free.find(each => each.store === store && (each.id === `${store}:${key}` || root.normal(each.title) === root.normal(title))) ?? null,
				core: root.online
			});
		});
	}

	function wishFor(store, key, title) {
		return root.wishes.find(wish => wish.store === store && (wish.key === String(key) || root.normal(wish.title) === root.normal(title))) ?? null;
	}

	// ── core ───────────────────────────────────────────────────────────────
	function load() {
		if (!root.online) return;
		Netcore.call("GET", "/api/games/free", null, data => {
			if (!data) return;
			root.free = data.free ?? [];
			root.soon = data.soon ?? [];
			root.loaded = true;
		});
		root.loadWishes();
	}

	function loadWishes(done) {
		Netcore.call("GET", "/api/games/wishes", null, data => {
			if (data) root.wishes = data.wishes ?? [];
			if (done) done();
		});
	}

	// { store, key, title, url, image } → reply(ok, wish | error)
	function wish(args, reply) {
		if (!root.online) return reply?.(false, "The server is not reachable");
		Netcore.call("POST", "/api/games/wishes", {
			store: String(args?.store ?? ""), key: String(args?.key ?? ""), title: String(args?.title ?? ""),
			url: String(args?.url ?? ""), image: String(args?.image ?? "")
		}, (data, error) => {
			if (!data) return reply?.(false, error);
			root.loadWishes();
			reply?.(true, data.wish);
		});
	}

	function unwish(id, reply) {
		if (!root.online) return reply?.(false, "The server is not reachable");
		Netcore.call("DELETE", `/api/games/wishes/${encodeURIComponent(String(id))}`, null, (data, error) => {
			root.wishes = root.wishes.filter(wish => wish.id !== id);
			reply?.(!!data, data ? null : error);
		});
	}

	function checkNow() {
		if (root.online) Netcore.call("POST", "/api/games/check", {}, () => refreshSoon.restart());
	}

	function open(url) {
		if (String(url || "").startsWith("https://")) WebLink.open(url);
	}

	function storeName(store) {
		return ({ steam: "Steam", epic: "Epic Games", gog: "GOG" })[store] ?? store;
	}

	function untilText(at) {
		if (!at) return "";
		const date = new Date(at * 1000);
		const days = Math.round((date.setHours(0, 0, 0, 0) - new Date().setHours(0, 0, 0, 0)) / 86400000);
		if (days <= 0) return `until ${Qt.formatTime(new Date(at * 1000), "HH:mm")}`;
		if (days === 1) return "until tomorrow";
		return `until ${Qt.formatDate(new Date(at * 1000), "d MMM")}`;
	}

	Connections {
		target: Nas
		enabled: root.enabled

		function onCoreEvent(message) {
			const type = String(message.type ?? String(message.event ?? "").slice(5));
			if (type === "hello") refreshSoon.restart();
			else if (type === "free_games") refreshSoon.restart();
			else if (type === "game_wishes") root.loadWishes();
			else if (type === "free_game") root.toldFree(message.game ?? {});
			else if (type === "game_sale") root.toldSale(message.wish ?? {});
		}
	}

	function toldFree(game) {
		if (!game.title) return;
		root.withOwned(() => {
			if (root.ownedGame(game.store, String(game.id).split(":").slice(1).join(":"), game.title)) return;
			const until = root.untilText(game.until);
			Notifs.post({
				app: "Games",
				icon: "applications-games",
				summary: `Free on ${root.storeName(game.store)}: ${game.title}`,
				body: until,
				image: String(game.image || ""),
				actions: [{ text: "Claim", identifier: "default", invoke: () => root.open(game.url) }]
			});
		});
	}

	function toldSale(wish) {
		const price = wish.price ?? {};
		if (!wish.title || !(price.discount > 0)) return;
		Notifs.post({
			app: "Games",
			icon: "applications-games",
			summary: price.discount >= 100 ? `Free on ${root.storeName(wish.store)}: ${wish.title}` : `${wish.title} −${price.discount} %`,
			body: price.discount >= 100 ? "" : `${price.text} on ${root.storeName(wish.store)}`,
			image: String(wish.image || ""),
			actions: [{ text: "Open", identifier: "default", invoke: () => root.open(wish.url) }]
		});
	}

	onOnlineChanged: if (root.online) refreshSoon.restart()

	Timer {
		id: refreshSoon

		interval: 1500
		onTriggered: root.load()
	}

	Timer {
		interval: 30 * 60 * 1000
		repeat: true
		running: root.online
		onTriggered: root.load()
	}
}
