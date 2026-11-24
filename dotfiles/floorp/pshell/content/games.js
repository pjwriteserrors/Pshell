// A game's page in a store (Steam, GOG, Epic, IsThereAnyDeal): whether the
// game is in the shell's library already, and the wish list kept on
// pshell-core (docs/games.md "Deals"). A small pill at the page's corner;
// nothing is shown while the shell does not answer.
"use strict";

(() => {
	if (window.top !== window || window.pshellGames) return;
	window.pshellGames = true;

	function meta(name) {
		const node = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
		return node ? String(node.content || "").trim() : "";
	}

	function text(selector) {
		const node = document.querySelector(selector);
		return node ? node.textContent.replace(/\s+/g, " ").trim() : "";
	}

	// { store, key, title, url, image } of the page, or null
	function gameOfPage() {
		const url = new URL(location.href);
		const host = url.hostname;
		const image = meta("og:image");
		if (host === "store.steampowered.com") {
			const match = url.pathname.match(/^\/app\/(\d+)/);
			if (!match) return null;
			const title = text("#appHubAppName") || meta("og:title").replace(/ on Steam$/, "");
			return { store: "steam", key: match[1], title, url: `https://store.steampowered.com/app/${match[1]}/`, image };
		}
		if (/(^|\.)gog\.com$/.test(host)) {
			if (!/\/game\//.test(url.pathname)) return null;
			const card = document.querySelector("[card-product]");
			const key = card ? card.getAttribute("card-product") : "";
			const title = text("h1.productcard-basics__title") || meta("og:title").replace(/\s*\|\s*GOG\.com$/, "");
			return key ? { store: "gog", key, title, url: `${url.origin}${url.pathname}`, image } : null;
		}
		if (host === "store.epicgames.com") {
			const match = url.pathname.match(/\/p\/([^/?#]+)/);
			if (!match) return null;
			const title = text("h1") || meta("og:title").split(" | ")[0];
			return { store: "epic", key: match[1], title, url: `https://store.epicgames.com/p/${match[1]}`, image };
		}
		if (/(^|\.)isthereanydeal\.com$/.test(host)) {
			if (!/^\/game\//.test(url.pathname)) return null;
			const steam = document.querySelector('a[href*="store.steampowered.com/app/"]');
			const appid = steam ? (steam.href.match(/\/app\/(\d+)/) || [])[1] : "";
			const title = text("h1") || meta("og:title").split(" | ")[0].replace(/ - IsThereAnyDeal$/, "");
			return appid ? { store: "steam", key: appid, title, url: `https://store.steampowered.com/app/${appid}/`, image }
				: { store: "", key: "", title, url: "", image };
		}
		return null;
	}

	let host = null;
	let root = null;
	let shown = "";

	function pill() {
		if (host && host.isConnected) return root;
		host = document.createElement("pshell-games");
		host.style.cssText = "all: initial; position: fixed; right: 18px; bottom: 18px; z-index: 2147483646;";
		root = host.attachShadow({ mode: "closed" });
		const sheet = new CSSStyleSheet();
		sheet.replaceSync(`
			:host { --bg: var(--pshell-layer2, #23232b); --fg: var(--pshell-fg, #ececf1); --primary: var(--pshell-primary, #8ab4f8);
				--on-primary: var(--pshell-on-primary, #0b1a33); --muted: var(--pshell-muted, #a9a9b6); --success: var(--pshell-success, #7fd18b); }
			.pill { display: flex; align-items: center; gap: 6px; padding: 5px; border-radius: 999px; background: var(--bg); color: var(--fg);
				font: 600 13px/1 system-ui, sans-serif; box-shadow: 0 6px 22px rgba(0,0,0,.35); }
			.tag { padding: 7px 10px; border-radius: 999px; }
			.owned { color: var(--success); }
			.sale { color: var(--primary); }
			button { all: unset; cursor: pointer; padding: 7px 12px; border-radius: 999px; background: var(--primary); color: var(--on-primary); }
			button.on { background: transparent; color: var(--fg); box-shadow: inset 0 0 0 1.5px var(--muted); }
			button:hover { filter: brightness(1.1); }
			.close { background: transparent; color: var(--muted); padding: 7px 9px; }
		`);
		root.adoptedStyleSheets = [sheet];
		document.documentElement.appendChild(host);
		return root;
	}

	function hide() {
		if (host) host.remove();
		host = null;
		shown = "";
	}

	function render(game, state) {
		const shadow = pill();
		shadow.textContent = "";
		const box = document.createElement("div");
		box.className = "pill";
		const add = (tag, className, label) => {
			const node = document.createElement(tag);
			node.className = className;
			node.textContent = label;
			box.appendChild(node);
			return node;
		};
		if (state.owned) add("span", "tag owned", state.name && state.name !== game.title ? `Owned · ${state.name}` : "Owned");
		const price = state.wish && state.wish.price;
		if (price && price.discount > 0) add("span", "tag sale", `−${price.discount} % · ${price.text}`);
		if (!state.owned && state.core && game.store) {
			const wished = !!state.wish;
			const button = add("button", wished ? "on" : "", wished ? "Wished" : "Wish");
			button.addEventListener("click", async () => {
				button.disabled = true;
				try {
					const message = wished ? { pshell: "gameUnwish", id: state.wish.id } : Object.assign({ pshell: "gameWish" }, game);
					const answer = await browser.runtime.sendMessage(message);
					if (answer && answer.ok) look(true);
				} catch (error) {}
				button.disabled = false;
			});
		}
		if (!box.childElementCount) return hide();
		add("button", "close", "✕").addEventListener("click", () => {
			hide();
			shown = location.href;
		});
		shadow.appendChild(box);
	}

	let asked = "";
	async function look(again) {
		const href = location.href;
		if (href === shown || (!again && href === asked)) return;
		asked = href;
		const game = gameOfPage();
		if (!game || !game.title) return hide();
		let state = null;
		try {
			state = await browser.runtime.sendMessage(Object.assign({ pshell: "game" }, game));
		} catch (error) {}
		if (location.href !== href) return;
		if (!state) return hide();
		render(game, state);
	}

	look();
	// stores that change the page without loading (Epic) and late titles
	setTimeout(() => look(true), 2500);
	setInterval(() => look(false), 1500);
})();
