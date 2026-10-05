// Tells the shell what this browser downloads and does what the shell asks
// (pause, resume, cancel), over native messaging: the browser starts
// scripts/downloads_host.py and talks to it through its stdin and stdout.
//
// to the shell:   { type: "snapshot", browser, items }   everything under way
//                 { type: "item", item }                 one download changed
//                 { type: "gone", id }                   it left the browser's list
// from the shell: { type: "sync" }                       → snapshot
//                 { type: "cmd", cmd: "pause" | "resume" | "cancel", id }

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

async function command(message) {
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

browser.downloads.onCreated.addListener(download => report(download.id));
browser.downloads.onChanged.addListener(delta => report(delta.id));
browser.downloads.onErased.addListener(id => send({ type: "gone", id }));

browser.runtime.getBrowserInfo().then(info => {
	browserName = info.name;
}).finally(connect);
