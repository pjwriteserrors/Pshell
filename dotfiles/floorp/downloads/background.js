// Tells the shell what this browser downloads and does what the shell asks
// (pause, resume, cancel), over native messaging: the browser starts
// scripts/downloads_host.py and talks to it through its stdin and stdout.
//
// Every new download is offered to the shell's download accelerator
// (scripts/downloads/boost.py) with what it needs to ask the server the
// same way (referrer, cookies, user agent). Where the server lets it go
// faster, the shell says "takeover" and the browser lets go of it; where
// not, the browser goes on as always and nothing changes.
//
// to the shell:   { type: "snapshot", browser, items }   everything under way
//                 { type: "item", item }                 one download changed
//                 { type: "gone", id }                   it left the browser's list
//                 { type: "tab", host, path, title }     the page in front, for the
//                                                        shell's screen time
//                 { type: "offer", item, referrer, cookies, userAgent, language }
//                                                        a new download, for the accelerator
//                 { type: "kept", id }                   too late to take over: it is complete
// from the shell: { type: "sync" }                       → snapshot
//                 { type: "cmd", cmd: "pause" | "resume" | "cancel" | "takeover", id }
//                 { type: "cmd", cmd: "fetch", url }     download it here after all

const HOST = "pshell_downloads";
let port = null;
let ticking = null;
let browserName = "Browser";

function plain(download) {
	return {
		id: download.id,
		url: download.url,
		file: download.filename,
		mime: download.mime || "",
		state: download.state,
		paused: !!download.paused,
		canResume: !!download.canResume,
		error: download.error || "",
		received: download.bytesReceived,
		total: download.totalBytes,
		started: download.startTime
	};
}

function send(message) {
	if (!port) return;
	try {
		port.postMessage(message);
	} catch (error) {
		port = null;
	}
}

// under way, or held: what the shell has to know about without being told
async function unfinished() {
	const all = await browser.downloads.search({});
	return all.filter(download => download.state === "in_progress" || download.paused);
}

async function snapshot() {
	send({ type: "snapshot", browser: browserName, items: (await unfinished()).map(plain) });
	watch();
	reportTab();
}

// only where it is, never what follows a ? or #, and nothing of a private window
async function reportTab() {
	const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
	let page = null;
	try {
		if (tab && !tab.incognito && /^https?:/.test(tab.url || "")) page = new URL(tab.url);
	} catch (error) {}
	send({ type: "tab", host: page ? page.host : "", path: page ? page.pathname : "", title: page ? tab.title || "" : "" });
}

// bytes arrive without an event: look every second while something runs
async function tick() {
	const running = await browser.downloads.search({ state: "in_progress" });
	for (const download of running) send({ type: "item", item: plain(download) });
	if (running.length === 0 || !port) {
		clearInterval(ticking);
		ticking = null;
	}
}

function watch() {
	if (!ticking && port) ticking = setInterval(tick, 1000);
}

async function report(id) {
	const [download] = await browser.downloads.search({ id });
	if (download) send({ type: "item", item: plain(download) });
	watch();
}

// what the server needs to answer the accelerator like it answers the browser
async function cookiesFor(url) {
	let all = [];
	try {
		all = await browser.cookies.getAll({ url, firstPartyDomain: null, partitionKey: {} });
	} catch (error) {
		try {
			all = await browser.cookies.getAll({ url });
		} catch (again) {}
	}
	const seen = {};
	return all.filter(cookie => !seen[cookie.name] && (seen[cookie.name] = true)).map(cookie => `${cookie.name}=${cookie.value}`).join("; ");
}

async function offer(download) {
	// what this extension fetched itself (the shell gave it back), private windows and anything not on the web stay
	if (!port || download.incognito || download.byExtensionId === browser.runtime.id || !/^https?:/.test(download.url || "")) return;
	if (download.state !== "in_progress") return;
	send({
		type: "offer",
		item: plain(download),
		referrer: download.referrer || "",
		cookies: await cookiesFor(download.url),
		userAgent: navigator.userAgent,
		language: (navigator.languages || []).join(",")
	});
}

// the accelerator has it: the browser lets go (what it began is removed with the cancel)
async function takeover(id) {
	const [download] = await browser.downloads.search({ id });
	if (!download || download.state === "complete") {
		send({ type: "kept", id });
		return;
	}
	try {
		await browser.downloads.cancel(id);
	} catch (error) {}
	try {
		await browser.downloads.erase({ id });
	} catch (error) {}
}

async function command(message) {
	if (message.cmd === "takeover") return takeover(message.id);
	if (message.cmd === "fetch") {
		try {
			await browser.downloads.download({ url: message.url });
		} catch (error) {}
		return;
	}
	try {
		if (message.cmd === "pause") await browser.downloads.pause(message.id);
		else if (message.cmd === "resume") await browser.downloads.resume(message.id);
		else if (message.cmd === "cancel") await browser.downloads.cancel(message.id);
	} catch (error) {
		// it ended meanwhile: the report below says how
	}
	report(message.id);
}

function connect() {
	try {
		port = browser.runtime.connectNative(HOST);
	} catch (error) {
		port = null;
		return setTimeout(connect, 15000);
	}
	port.onMessage.addListener(message => {
		if (message.type === "sync") snapshot();
		else if (message.type === "cmd") command(message);
	});
	port.onDisconnect.addListener(() => {
		port = null;
		setTimeout(connect, 15000);
	});
	snapshot();
}

browser.downloads.onCreated.addListener(download => {
	report(download.id);
	offer(download);
});
browser.downloads.onChanged.addListener(delta => report(delta.id));
browser.downloads.onErased.addListener(id => send({ type: "gone", id }));

browser.tabs.onActivated.addListener(reportTab);
browser.tabs.onUpdated.addListener((id, change, tab) => {
	if (tab.active && (change.url || change.title)) reportTab();
});
browser.windows.onFocusChanged.addListener(id => {
	if (id !== browser.windows.WINDOW_ID_NONE) reportTab();
});

browser.runtime.getBrowserInfo().then(info => {
	browserName = info.name;
}).finally(connect);
