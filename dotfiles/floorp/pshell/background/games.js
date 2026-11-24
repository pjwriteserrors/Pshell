// Games (docs/games.md "Deals", "Guides"), beside bridge.js and sharing its
// scope (`ask`, `COMMANDS`):
//
// - a store's page (content/games.js) asks the shell whether the game is in
//   the library and keeps it on the wish list: ask `game`, `gameWish`,
//   `gameUnwish` (never from a private window);
// - the guides of the game that runs: `guide {urls, title}` opens them in a
//   window of their own that floats over the game ("Guide · " before its
//   title, dotfiles/niri/pshell.kdl), again closes it; `guideOpen {urls}`
//   opens them as tabs behind the one in front.

const GUIDE_PREFACE = "Guide · ";
let guideWindow = null;

browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || !["game", "gameWish", "gameUnwish"].includes(message.pshell)) return;
	const tab = sender.tab;
	if (!tab || tab.incognito) return Promise.resolve(null);
	const args = Object.assign({}, message);
	delete args.pshell;
	return ask(message.pshell, args).then(
		data => (message.pshell === "game" ? data : { ok: true, data }),
		error => (message.pshell === "game" ? null : { ok: false, error: String(error && error.message || error) })
	);
});

function pages(urls) {
	return (Array.isArray(urls) ? urls : []).map(String).filter(url => /^https?:\/\//.test(url)).slice(0, 12);
}

browser.windows.onRemoved.addListener(id => {
	if (id === guideWindow) guideWindow = null;
});

COMMANDS.guide = async message => {
	if (guideWindow !== null) {
		const id = guideWindow;
		guideWindow = null;
		try {
			await browser.windows.remove(id);
			return { open: false };
		} catch (error) {}
	}
	const urls = pages(message.urls);
	if (urls.length === 0) throw new Error("no guides");
	const window = await browser.windows.create({ url: urls, titlePreface: GUIDE_PREFACE, focused: true, width: 900, height: 1000 });
	guideWindow = window.id;
	return { open: true, windowId: window.id, title: GUIDE_PREFACE };
};

COMMANDS.guideClose = async () => {
	if (guideWindow === null) return { open: false };
	const id = guideWindow;
	guideWindow = null;
	await browser.windows.remove(id).catch(() => {});
	return { open: false };
};

COMMANDS.guideOpen = async message => {
	const urls = pages(message.urls);
	const [front] = await browser.tabs.query({ active: true, lastFocusedWindow: true, windowType: "normal" });
	const windowId = front && !front.incognito && front.windowId !== guideWindow ? front.windowId : undefined;
	const open = (await browser.tabs.query({})).filter(tab => !tab.incognito).map(tab => tab.url);
	let opened = 0;
	for (const url of urls) {
		if (open.includes(url)) continue;
		await browser.tabs.create(Object.assign({ url, active: false }, windowId !== undefined ? { windowId } : {}));
		opened++;
	}
	return { opened };
};
