// Media and attention in the page (background/attention.js, docs/browser.md):
//
// - media (every frame): the sleep timer's "after this episode" (the volume
//   fades over the last seconds, then it pauses), the watch's play/pause and
//   ±10 s on the medium that played last;
// - track (YouTube, top frame): what plays, named as the page names it, so
//   the shell's lyrics find the song of a music video;
// - codes (every frame): a one-time-code field with the focus asks the shell
//   for fresh codes; they show in a small card at the field, and only a click
//   puts one in;
// - timers (recipe pages, top frame): times in the steps ("25 Minuten backen")
//   get a small button that starts a timer in the shell;
// - brake (top frame): the shell's quiet hint after long scrolling.
//
// What the page shows lives in closed shadow roots, out of the page's reach.

(() => {
	const top = window.top === window;
	let config = { codes: false, timers: false };

	// ── what played last, and the sleep timer's end of episode ────────────
	let lastMedia = null;
	let toldPlay = 0;
	document.addEventListener("play", event => {
		if (!(event.target instanceof HTMLMediaElement)) return;
		lastMedia = event.target;
		// the shell knows which tab played last (the watch steers that one)
		if (Date.now() - toldPlay > 3000) {
			toldPlay = Date.now();
			browser.runtime.sendMessage({ pshell: "played" }).catch(() => {});
		}
	}, true);

	// what plays (the one that started last first), else what played last
	function current() {
		const last = lastMedia && lastMedia.isConnected ? lastMedia : null;
		if (last && !last.paused) return last;
		const all = [...document.querySelectorAll("video, audio")];
		return all.find(media => !media.paused) || last || all.find(media => media.duration > 0) || null;
	}

	let sleep = null; // { media, fade, volume, fading, done }
	function stopSleep() {
		if (!sleep) return;
		sleep.media.removeEventListener("timeupdate", sleep.check);
		sleep.media.removeEventListener("ended", sleep.end);
		sleep.media.removeEventListener("play", sleep.again);
		if (sleep.fading && !sleep.done) sleep.media.volume = sleep.volume;
		clearInterval(sleep.timer);
		sleep = null;
	}

	function armSleep(fade) {
		stopSleep();
		const media = current();
		if (!media) return false;
		const state = { media, fade: Math.max(0, fade || 0), volume: media.volume, fading: false, done: false, timer: null };
		state.end = () => {
			if (state.done) return;
			state.done = true;
			clearInterval(state.timer);
			media.pause();
			media.volume = state.volume;
			browser.runtime.sendMessage({ pshell: "sleepDone" }).catch(() => {});
			// a site's autoplay starting the next one right away is stopped too
			setTimeout(() => {
				if (sleep === state) stopSleep();
			}, 15000);
		};
		state.again = () => {
			if (state.done) media.pause();
		};
		state.check = () => {
			if (state.done || !isFinite(media.duration) || media.duration <= 0) return;
			const left = media.duration - media.currentTime;
			if (left <= 0.4) return state.end();
			if (!state.fading && state.fade > 0 && left * 1000 <= state.fade) {
				state.fading = true;
				state.volume = media.volume;
				// armed late: the fade takes what is left
				const span = Math.max(1000, left * 1000);
				state.timer = setInterval(() => {
					const rest = Math.max(0, (media.duration - media.currentTime) * 1000);
					const share = Math.min(1, rest / span);
					media.volume = state.volume * share * share;
				}, 100);
			}
		};
		media.addEventListener("timeupdate", state.check);
		media.addEventListener("ended", state.end);
		media.addEventListener("play", state.again);
		sleep = state;
		return { duration: media.duration || 0, position: media.currentTime };
	}

	// ── what plays, as the page names it (YouTube) ─────────────────────────
	const youtube = top && /(^|\.)youtube\.com$/.test(location.hostname);
	const ytMusic = location.hostname === "music.youtube.com";
	let lastTrack = "";
	let trackDue = null;

	function pageTrack(media) {
		const page = window.wrappedJSObject;
		let title = "";
		let artist = "";
		let music = false;
		if (ytMusic) {
			const meta = page.navigator.mediaSession && page.navigator.mediaSession.metadata;
			title = meta ? String(meta.title || "") : "";
			artist = meta ? String(meta.artist || "") : "";
			music = title !== "";
		} else {
			let response = null;
			try {
				const player = document.getElementById("movie_player");
				response = player && player.wrappedJSObject.getPlayerResponse ? player.wrappedJSObject.getPlayerResponse() : null;
			} catch (error) {}
			const details = (response && response.videoDetails) || {};
			const micro = (response && response.microformat && response.microformat.playerMicroformatRenderer) || {};
			title = String(details.title || "");
			artist = String(details.author || "");
			music = !!details.musicVideoType || String(micro.category || "") === "Music" || / - Topic$|VEVO$/.test(artist);
			// "Music" under the description: the song and its artist exactly
			const song = document.querySelector("ytd-watch-metadata yt-video-attribute-view-model .yt-video-attribute-view-model__title");
			const singer = document.querySelector("ytd-watch-metadata yt-video-attribute-view-model .yt-video-attribute-view-model__subtitle");
			if (song && song.textContent.trim()) {
				title = song.textContent.trim();
				artist = singer ? singer.textContent.trim().split(/\s*•\s*/)[0] : artist;
				music = true;
			} else {
				artist = artist.replace(/ - Topic$/, "").replace(/VEVO$/, "");
				const parts = title.split(/\s+[-–—]\s+/);
				if (music && parts.length >= 2) {
					artist = parts[0];
					title = parts.slice(1).join(" - ");
				}
			}
		}
		return {
			title,
			artist,
			music,
			duration: isFinite(media.duration) ? media.duration : 0,
			position: media.currentTime,
			playing: !media.paused
		};
	}

	function reportTrack(force) {
		trackDue = null;
		const media = current();
		if (!media || media.tagName !== "VIDEO" && !ytMusic) return;
		let track = null;
		try {
			track = pageTrack(media);
		} catch (error) {
			return;
		}
		if (!track.title) return;
		const key = JSON.stringify([track.title, track.artist, track.music, track.playing, Math.round(track.duration)]);
		if (!force && key === lastTrack) return;
		lastTrack = key;
		browser.runtime.sendMessage(Object.assign({ pshell: "track" }, track)).catch(() => {});
	}

	if (youtube) {
		const soon = force => {
			clearTimeout(trackDue);
			trackDue = setTimeout(() => reportTrack(force), 700);
		};
		for (const name of ["play", "pause", "seeked", "loadedmetadata", "durationchange", "ratechange"]) {
			document.addEventListener(name, () => soon(true), true);
		}
		document.addEventListener("yt-navigate-finish", () => soon(true));
		// the position now and then, so the shell's clock stays with it
		setInterval(() => {
			const media = current();
			if (media && !media.paused) reportTrack(true);
		}, 15000);
	}

	// ── one-time codes ─────────────────────────────────────────────────────
	const CODE_HINT = /one.?time|otp|2fa|mfa|totp|verif|security.?code|sms.?code|auth.?code|passcode|tan\b|token|bestätigung|sicherheitscode|einmal/i;

	function isCodeField(field) {
		if (!(field instanceof HTMLInputElement) || field.disabled || field.readOnly) return false;
		if (!/^(text|tel|number|password|)$/.test(field.type)) return false;
		if (field.autocomplete === "one-time-code") return true;
		const words = `${field.name} ${field.id} ${field.placeholder} ${field.getAttribute("aria-label") || ""} ${field.labels && field.labels[0] ? field.labels[0].textContent : ""}`;
		if (CODE_HINT.test(words)) return true;
		// six single-digit boxes in a row
		return field.maxLength === 1 && field.inputMode === "numeric";
	}

	let codeField = null;
	let card = null;

	function removeCard() {
		if (card) card.host.remove();
		card = null;
	}

	// the boxes of a split code (one digit each) or the field itself
	function boxesOf(field) {
		if (field.maxLength !== 1) return [field];
		const scope = field.form || field.parentElement?.parentElement || document;
		return [...scope.querySelectorAll("input")].filter(each => each.maxLength === 1 && !each.disabled);
	}

	function put(field, value) {
		const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
		setter.call(field, value);
		field.dispatchEvent(new Event("input", { bubbles: true }));
		field.dispatchEvent(new Event("change", { bubbles: true }));
	}

	function fill(field, code) {
		const boxes = boxesOf(field);
		if (boxes.length > 1 && boxes.length >= code.length) {
			code.split("").forEach((digit, i) => put(boxes[i], digit));
			boxes[Math.min(code.length, boxes.length) - 1].focus();
		} else {
			put(field, code);
			field.focus();
		}
		browser.runtime.sendMessage({ pshell: "codeUsed" }).catch(() => {});
	}

	function showCodes(codes) {
		const field = codeField;
		if (!field || !field.isConnected || !codes.length) return false;
		removeCard();
		const host = document.createElement("pshell-codes");
		host.style.cssText = "position:absolute;z-index:2147483646;top:0;left:0;";
		const root = host.attachShadow({ mode: "closed" });
		root.innerHTML = `<style>
			:host { all: initial; }
			.card { display: flex; gap: 4px; padding: 4px; border-radius: 12px; background: #1d1d1f; color: #f4ede6;
				box-shadow: 0 0 0 1px rgba(255,255,255,.12), 0 8px 24px rgba(0,0,0,.4); font: 12px system-ui, sans-serif; }
			button { all: unset; cursor: pointer; display: grid; padding: 5px 10px; border-radius: 9px; }
			button:hover, button:focus-visible { background: rgba(255,255,255,.1); }
			b { font: 600 14px ui-monospace, monospace; letter-spacing: .08em; }
			span { opacity: .62; font-size: 11px; }
		</style><div class="card"></div>`;
		const box = root.querySelector(".card");
		for (const entry of codes.slice(0, 3)) {
			const button = document.createElement("button");
			const code = document.createElement("b");
			code.textContent = String(entry.code);
			const from = document.createElement("span");
			from.textContent = [entry.from, entry.ago].filter(Boolean).join(" · ");
			button.append(code, from);
			button.addEventListener("mousedown", event => event.preventDefault());
			button.addEventListener("click", event => {
				event.preventDefault();
				event.stopPropagation();
				fill(field, String(entry.code));
				removeCard();
			});
			box.append(button);
		}
		const place = () => {
			if (!field.isConnected) return removeCard();
			const rect = field.getBoundingClientRect();
			host.style.transform = `translate(${Math.round(window.scrollX + rect.left)}px, ${Math.round(window.scrollY + rect.bottom + 6)}px)`;
		};
		document.documentElement.append(host);
		place();
		card = { host, place };
		return true;
	}

	window.addEventListener("scroll", () => card && card.place(), { passive: true, capture: true });
	window.addEventListener("resize", () => card && card.place(), { passive: true });
	document.addEventListener("keydown", event => {
		if (event.key === "Escape") removeCard();
	}, true);

	document.addEventListener("focusin", event => {
		if (!config.codes) return;
		const field = event.composedPath ? event.composedPath()[0] : event.target;
		if (!isCodeField(field)) return;
		if (field === codeField && card) return;
		codeField = field;
		browser.runtime.sendMessage({ pshell: "codeField" }).catch(() => {});
	}, true);

	document.addEventListener("focusout", () => {
		// a click on the card keeps the focus (mousedown is held back); anything else ends it
		setTimeout(() => {
			if (codeField && document.activeElement !== codeField && !boxesOf(codeField).includes(document.activeElement)) removeCard();
		}, 150);
	}, true);

	// ── timers on recipe pages ─────────────────────────────────────────────
	const DURATION = /(\d+(?:[.,]\d+)?)(?:\s*(?:-|–|bis|to|or|oder)\s*(\d+(?:[.,]\d+)?))?\s*(Stunden|Stunde|Std\.?|hours?|hrs?|h\b|Minuten|Minute|Min\.?|minutes?|mins?|Sekunden|Sek\.?|seconds?|secs?)(?![\wäöü])/gi;
	const timers = new Map(); // id → { button, end, tick }

	function isRecipe() {
		for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
			if (/"@type"\s*:\s*(\[[^\]]*)?"Recipe"/.test(script.textContent || "")) return true;
		}
		return !!document.querySelector('[itemtype*="schema.org/Recipe"]') || /rezept|recipe/i.test(location.pathname);
	}

	function secondsOf(match) {
		const low = parseFloat(match[1].replace(",", "."));
		const high = match[2] ? parseFloat(match[2].replace(",", ".")) : low;
		const unit = match[3].toLowerCase();
		// a range: the shorter time, the cook looks then
		const amount = Math.min(low, high);
		if (/^(stunde|std|hour|hr|h$)/.test(unit)) return Math.round(amount * 3600);
		if (/^(sek|sec)/.test(unit)) return Math.round(amount);
		return Math.round(amount * 60);
	}

	function clock(seconds) {
		const s = Math.max(0, Math.round(seconds));
		const h = Math.floor(s / 3600);
		const m = Math.floor((s % 3600) / 60);
		const rest = String(s % 60).padStart(2, "0");
		return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${rest}` : `${m}:${rest}`;
	}

	function stepRoot() {
		return document.querySelector('[itemprop="recipeInstructions"], .recipe-instructions, .wprm-recipe-instructions, .tasty-recipes-instructions, [class*="instruction"], [class*="preparation"], [class*="zubereitung"], [id*="zubereitung"], article, main') || document.body;
	}

	function timerButton(seconds, label) {
		const host = document.createElement("pshell-timer");
		host.style.cssText = "display:inline-block;vertical-align:middle;margin:0 .25em;";
		const root = host.attachShadow({ mode: "closed" });
		root.innerHTML = `<style>
			:host { all: initial; display: inline-block; }
			button { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 4px; height: 20px; padding: 0 8px 0 6px;
				border-radius: 999px; font: 600 11px system-ui, sans-serif; background: #1d1d1f; color: #f4ede6; opacity: .85; }
			button:hover { opacity: 1; }
			button.on { background: #f4ede6; color: #1d1d1f; }
			svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.7; }
		</style><button><svg viewBox="0 0 16 16"><circle cx="8" cy="9" r="5.5"/><path d="M8 6v3l2 1.5M6.5 1.8h3"/></svg><span></span></button>`;
		const button = root.querySelector("button");
		const text = root.querySelector("span");
		text.textContent = clock(seconds);
		let id = "";
		const reset = () => {
			const timer = timers.get(id);
			if (timer) clearInterval(timer.tick);
			timers.delete(id);
			id = "";
			button.classList.remove("on");
			text.textContent = clock(seconds);
		};
		button.addEventListener("click", event => {
			event.preventDefault();
			event.stopPropagation();
			if (id) {
				browser.runtime.sendMessage({ pshell: "timerCancel", id }).catch(() => {});
				return reset();
			}
			id = `t${Date.now().toString(36)}${Math.floor(Math.random() * 1000)}`;
			const end = Date.now() + seconds * 1000;
			button.classList.add("on");
			const tick = setInterval(() => {
				const left = (end - Date.now()) / 1000;
				text.textContent = clock(left);
				if (left <= 0) {
					clearInterval(tick);
					text.textContent = "0:00";
				}
			}, 500);
			timers.set(id, { reset, tick });
			browser.runtime.sendMessage({ pshell: "timer", id, label, seconds }).then(ok => {
				if (!ok) reset();
			}).catch(() => reset());
		});
		return host;
	}

	function sentenceAround(text, start, end) {
		const before = text.slice(0, start).split(/[.!?]\s/).pop();
		const after = text.slice(end).split(/[.!?](\s|$)/)[0];
		return `${before}${text.slice(start, end)}${after}`.replace(/\s+/g, " ").trim().slice(0, 100);
	}

	let timersMarked = false;
	function markTimers() {
		if (timersMarked || !top || !config.timers || !isRecipe()) return;
		timersMarked = true;
		const walker = document.createTreeWalker(stepRoot(), NodeFilter.SHOW_TEXT, {
			acceptNode: node => {
				const parent = node.parentElement;
				if (!parent || parent.closest("script, style, textarea, input, button, a, pshell-timer, [contenteditable]")) return NodeFilter.FILTER_REJECT;
				DURATION.lastIndex = 0;
				return DURATION.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
			}
		});
		const nodes = [];
		while (walker.nextNode()) nodes.push(walker.currentNode);
		let added = 0;
		for (const node of nodes) {
			const text = node.nodeValue;
			const context = node.parentElement.textContent || text;
			DURATION.lastIndex = 0;
			const found = [...text.matchAll(DURATION)];
			// last first, so the earlier offsets stay right
			for (const match of found.reverse()) {
				const seconds = secondsOf(match);
				if (seconds < 30 || seconds > 12 * 3600) continue;
				const end = match.index + match[0].length;
				const rest = node.splitText(end);
				const at = context.indexOf(match[0]);
				const label = at >= 0 ? sentenceAround(context, at, at + match[0].length) : match[0];
				rest.parentNode.insertBefore(timerButton(seconds, label), rest);
				if (++added >= 40) return;
			}
		}
	}

	// ── the scroll brake's hint ────────────────────────────────────────────
	let brake = null;
	function showBrake(text) {
		if (!top || !text) return false;
		if (brake) brake.remove();
		const host = document.createElement("pshell-brake");
		host.style.cssText = "position:fixed;z-index:2147483646;right:18px;bottom:18px;pointer-events:none;";
		const root = host.attachShadow({ mode: "closed" });
		root.innerHTML = `<style>
			:host { all: initial; }
			div { padding: 8px 14px; border-radius: 999px; background: rgba(29,29,31,.88); color: #f4ede6;
				font: 500 12.5px system-ui, sans-serif; box-shadow: 0 6px 22px rgba(0,0,0,.35);
				opacity: 0; transform: translateY(6px); transition: opacity .6s, transform .6s; }
			div.on { opacity: 1; transform: none; }
		</style><div></div>`;
		const pill = root.querySelector("div");
		pill.textContent = text;
		document.documentElement.append(host);
		brake = host;
		requestAnimationFrame(() => requestAnimationFrame(() => pill.classList.add("on")));
		setTimeout(() => pill.classList.remove("on"), 9000);
		setTimeout(() => {
			if (brake === host) brake = null;
			host.remove();
		}, 10000);
		return true;
	}

	// ── from the shell ─────────────────────────────────────────────────────
	browser.runtime.onMessage.addListener(message => {
		if (!message || !message.pshell) return;
		switch (message.pshell) {
			case "sleepAfter": {
				if (message.off) {
					const had = !!sleep;
					stopSleep();
					return had ? Promise.resolve(true) : undefined;
				}
				const armed = current() ? armSleep(message.fade) : false;
				return armed ? Promise.resolve(armed) : undefined;
			}
			case "mediaKey": {
				// play/pause goes back and forth on one medium
				const media = message.op === "toggle" && lastMedia && lastMedia.isConnected ? lastMedia : current();
				if (!media) return;
				lastMedia = media;
				if (message.op === "toggle") {
					if (media.paused) media.play().catch(() => {});
					else media.pause();
				} else if (message.op === "seek" && isFinite(media.duration)) {
					media.currentTime = Math.max(0, Math.min(media.duration - 0.5, media.currentTime + message.by));
				} else if (message.op === "seek") {
					media.currentTime = Math.max(0, media.currentTime + message.by);
				}
				return Promise.resolve({ playing: !media.paused, position: media.currentTime, duration: media.duration || 0 });
			}
			case "codes":
				return showCodes(message.codes || []) ? Promise.resolve(true) : undefined;
			case "brake":
				return top ? Promise.resolve(showBrake(message.text)) : undefined;
			case "timerGone": {
				const timer = timers.get(message.id);
				if (!timer) return;
				timer.reset();
				return Promise.resolve(true);
			}
		}
	});

	const configured = next => {
		config = next || config;
		if (config.timers) {
			if (document.readyState === "complete") setTimeout(markTimers, 800);
			else window.addEventListener("load", () => setTimeout(markTimers, 800), { once: true });
		}
	};
	browser.storage.local.get("attention").then(kept => configured(kept.attention));
	browser.storage.onChanged.addListener((changes, area) => {
		if (area === "local" && changes.attention) configured(changes.attention.newValue);
	});
})();
