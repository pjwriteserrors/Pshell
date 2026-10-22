// Keeps how far the video on this page was watched and starts it there again.
//
// Positions live in storage.local as "v:<video id>" → { t, d, title, at }:
// written every few seconds while it plays, and right away on pause, a seek,
// a hidden tab, closing the tab or the page moving on to another video – so a
// browser that is quit or a PC that goes down loses a few seconds at most.
// A video watched to its end is forgotten and starts from the beginning.
// A link with its own start (?t=, &start=) wins over what was kept, and so
// do ads: nothing is kept or sought while one plays.

const api = typeof browser !== "undefined" ? browser : chrome;
// shorter than this is not worth keeping, this close to the end counts as watched
const MIN = 5;
const TAIL = 15;
const EVERY = 3000;

let current = null; // { id, restored, ownStart }
let lastSave = 0;

function videoId() {
	const url = new URL(location.href);
	if (url.pathname === "/watch") return url.searchParams.get("v");
	const path = url.pathname.match(/^\/(?:embed|live)\/([\w-]{11})/);
	return path ? path[1] : null;
}

function ownStart() {
	const url = new URL(location.href);
	return url.searchParams.has("t") || url.searchParams.has("start") || /(^#|&)t=/.test(url.hash);
}

function player() {
	return document.getElementById("movie_player") || document.querySelector(".html5-video-player");
}

// the page's own player knows which video it has loaded; the address moves on first
function playerData() {
	try {
		return player()?.wrappedJSObject?.getVideoData?.() ?? null;
	} catch (error) {
		return null;
	}
}

function video() {
	return player()?.querySelector("video") ?? null;
}

function adShowing() {
	const p = player();
	return !!p && (p.classList.contains("ad-showing") || p.classList.contains("ad-interrupting"));
}

// the video element when it plays the video of the address, else null
function ready() {
	if (!current) return null;
	const v = video();
	if (!v || adShowing() || !Number.isFinite(v.duration) || v.duration <= 0) return null;
	const data = playerData();
	if (data && (data.video_id !== current.id || data.isLive)) return null;
	return v;
}

function title() {
	return playerData()?.title || document.title.replace(/^\(\d+\)\s*/, "").replace(/\s*-\s*YouTube$/, "");
}

function save() {
	const v = ready();
	if (!v || !current.restored) return;
	lastSave = Date.now();
	const key = `v:${current.id}`;
	const t = v.currentTime;
	const d = v.duration;
	try {
		if (t > d - TAIL || t / d > 0.97) api.storage.local.remove(key);
		else if (t >= MIN) api.storage.local.set({ [key]: { t, d, title: title(), at: Date.now() } });
		if (window === window.top) api.runtime.sendMessage({ type: "watching", id: current.id, title: title(), t, d });
	} catch (error) {
		// the extension was reloaded under this page
	}
}

function seek(v, t) {
	const p = player()?.wrappedJSObject;
	try {
		if (p?.seekTo) {
			p.seekTo(t, true);
			return;
		}
	} catch (error) {}
	v.currentTime = t;
}

async function restore(v) {
	const entry = current;
	entry.restored = "pending";
	let kept = null;
	try {
		kept = (await api.storage.local.get(`v:${entry.id}`))[`v:${entry.id}`];
	} catch (error) {}
	if (current !== entry) return;
	const usable = kept && !entry.ownStart && kept.t >= MIN && kept.t < v.duration - TAIL;
	if (usable && Math.abs(v.currentTime - kept.t) > 3) {
		seek(v, kept.t);
		// YouTube's own resume may still come in after it: once more, if so
		setTimeout(() => {
			const again = current === entry && ready();
			if (again && again.currentTime < kept.t - 5) seek(again, kept.t);
		}, 1500);
	}
	entry.restored = true;
}

function tick() {
	const id = videoId();
	if (id !== current?.id) {
		save();
		current = id ? { id, restored: false, ownStart: ownStart() } : null;
	}
	const v = ready();
	if (!v) return;
	if (current.restored === false) restore(v);
	else if (current.restored === true && !v.paused && Date.now() - lastSave >= EVERY) save();
}

setInterval(tick, 1000);
// media events do not bubble: caught on the way down
for (const type of ["pause", "seeked", "ended"]) document.addEventListener(type, () => save(), true);
document.addEventListener("visibilitychange", () => document.hidden && save());
window.addEventListener("pagehide", save);
window.addEventListener("beforeunload", save);
// YouTube changes pages without loading one
document.addEventListener("yt-navigate-start", save);
document.addEventListener("yt-navigate-finish", tick);
