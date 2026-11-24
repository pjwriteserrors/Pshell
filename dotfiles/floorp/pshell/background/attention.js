// Media, devices and attention (docs/browser.md, "What the shell does with it"):
// commands the shell gives about what plays, and what content/attention.js
// reports from the pages. Loaded after bridge.js and adds to its COMMANDS.
//
// to the shell (events): played {tabId}       something started to play there
//                        track {tabId, title, artist, music, duration, position, playing}
//                        sleepDone {tabId}       the episode the sleep timer waited for ended
//                        codeField {tabId, frameId, host}   a one-time-code field got the focus
//                        codeUsed {tabId}
//                        timer {id, label, seconds, page, title}, timerCancel {id}
// from the shell (cmd):  attention {codes, timers}  what the pages offer
//                        hold {tag, fade}         → { tabs } everything that plays fades and pauses
//                        release {tag, tabs}      plays again what hold paused
//                        sleepAfter {tabId, fade, off}   pause when the episode ends
//                        mediaKey {tabId, op: toggle|seek, by}
//                        codes {tabId, frameId, codes: [{ code, from, ago }]}
//                        brake {tabId, text}
//                        timerGone {tabId, id}
//
// Nothing of a private window goes to the shell or comes from it.

let attentionConfig = { codes: false, timers: false };

browser.storage.local.get("attention").then(kept => {
	if (kept.attention) attentionConfig = kept.attention;
});

// every frame of a tab, the answer of each that has media
async function inFrames(tabId, func, args) {
	try {
		const results = await browser.scripting.executeScript({ target: { tabId, allFrames: true }, func, args: args || [] });
		return results.map(result => result.result).filter(result => result !== undefined && result !== null);
	} catch (error) {
		return [];
	}
}

// fades every playing medium of the frame to silence over `fade` ms, then
// pauses it and puts its volume back; marked with the tag for release
function fadeAndPause(tag, fade) {
	let count = 0;
	for (const media of document.querySelectorAll("video, audio")) {
		// a mark left on something that plays again is stale
		if (media.paused) continue;
		media.dataset.pshellHold = tag;
		count++;
		const start = media.volume;
		const begun = Date.now();
		if (!fade) {
			media.pause();
			continue;
		}
		const step = setInterval(() => {
			if (media.dataset.pshellHold !== tag) {
				clearInterval(step);
				media.volume = start;
				return;
			}
			const done = Math.min(1, (Date.now() - begun) / fade);
			media.volume = start * (1 - done) * (1 - done);
			if (done >= 1) {
				clearInterval(step);
				media.pause();
				media.volume = start;
			}
		}, 100);
	}
	return count || undefined;
}

function playAgain(tag) {
	let count = 0;
	for (const media of document.querySelectorAll("[data-pshell-hold]")) {
		if (media.dataset.pshellHold !== tag) continue;
		delete media.dataset.pshellHold;
		media.play().catch(() => {});
		count++;
	}
	return count || undefined;
}

Object.assign(COMMANDS, {
	async attention(message) {
		attentionConfig = { codes: !!message.codes, timers: !!message.timers };
		await browser.storage.local.set({ attention: attentionConfig });
	},
	async hold(message) {
		const tag = String(message.tag || "hold");
		const fade = Math.max(0, Math.min(120000, Number(message.fade) || 0));
		const tabs = [];
		// every tab, not only the audible ones: a muted or quiet one plays too
		for (const tab of await browser.tabs.query({})) {
			if (!scriptable(tab) || tab.discarded) continue;
			if ((await inFrames(tab.id, fadeAndPause, [tag, fade])).length > 0) tabs.push(tab.id);
		}
		return { tabs };
	},
	async release(message) {
		const tag = String(message.tag || "hold");
		const ids = Array.isArray(message.tabs) ? message.tabs : (await browser.tabs.query({})).map(tab => tab.id);
		for (const id of ids) await inFrames(id, playAgain, [tag]);
	},
	async sleepAfter(message) {
		return await browser.tabs.sendMessage(message.tabId, { pshell: "sleepAfter", off: !!message.off, fade: Number(message.fade) || 0 });
	},
	async mediaKey(message) {
		return await browser.tabs.sendMessage(message.tabId, { pshell: "mediaKey", op: String(message.op || ""), by: Number(message.by) || 0 });
	},
	async codes(message) {
		const tab = await browser.tabs.get(message.tabId);
		if (tab.incognito) return false;
		return await browser.tabs.sendMessage(message.tabId, { pshell: "codes", codes: message.codes || [] }, { frameId: message.frameId || 0 });
	},
	async brake(message) {
		return await browser.tabs.sendMessage(message.tabId, { pshell: "brake", text: String(message.text || "") }, { frameId: 0 });
	},
	async timerGone(message) {
		return await browser.tabs.sendMessage(message.tabId, { pshell: "timerGone", id: String(message.id || "") }, { frameId: 0 }).catch(() => false);
	}
});

// what the pages report: on to the shell, never from a private window
browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || !message.pshell) return;
	const tab = sender.tab;
	if (!tab || tab.incognito) return;
	const event = data => {
		toShell(Object.assign({ type: "event", tabId: tab.id }, data));
		return Promise.resolve(true);
	};
	switch (message.pshell) {
		case "attention":
			return Promise.resolve(attentionConfig);
		case "track":
			return event({
				name: "track",
				title: String(message.title || ""),
				artist: String(message.artist || ""),
				music: !!message.music,
				duration: Number(message.duration) || 0,
				position: Number(message.position) || 0,
				playing: !!message.playing
			});
		case "played":
			return event({ name: "played" });
		case "sleepDone":
			return event({ name: "sleepDone" });
		case "codeField":
			if (!attentionConfig.codes) return;
			return event({ name: "codeField", frameId: sender.frameId || 0, host: hostOf(tab.url || "") });
		case "codeUsed":
			return event({ name: "codeUsed" });
		case "timer":
			if (!attentionConfig.timers) return;
			return event({ name: "timer", id: String(message.id || ""), label: String(message.label || "").slice(0, 120), seconds: Number(message.seconds) || 0, page: tab.url || "", title: tab.title || "" });
		case "timerCancel":
			return event({ name: "timerCancel", id: String(message.id || "") });
	}
});
