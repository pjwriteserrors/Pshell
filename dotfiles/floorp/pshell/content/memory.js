// The page's side of background/memory.js, only what the shell switched on
// and never in a private window:
//
// - index: after ten seconds in front the page's text is kept (not where a
//   password, a card number or a sign-in is asked for); then how long it
//   stays in front, how far it is read and how long something plays in it.
// - reading: on a long page where it was left; coming back (or on another
//   device) a small bar offers to go on there – nothing scrolls by itself.
// - highlights: text kept as a note is marked (CSS highlights, the page's
//   DOM stays as it is).
// - clips: what is copied goes to the shell's clipboard history with the
//   address and a text fragment back to it.
//
// Pages that change their address without loading (YouTube, …) count as a
// new page each time.

(() => {
	if (window.top !== window || !/^https?:$/.test(location.protocol)) return;
	if (browser.extension.inIncognitoContext) return;

	const SENSITIVE_URL = /(^|[./_-])(bank|banking|onlinebanking|paypal|klarna|login|log-in|signin|sign-in|signup|sign-up|auth|oauth|sso|account|accounts|checkout|payment|payments|wallet|password|passwort|2fa|mfa|anmelden|konto)([./_?#-]|$)/i;
	const VIDEO_URL = /^https?:\/\/((www|m)\.)?(youtube\.com\/(watch|shorts|live)|youtu\.be\/|vimeo\.com\/\d|twitch\.tv\/videos\/|dailymotion\.com\/video\/)/i;
	const BLOCKS = "p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, figcaption, dd, td";

	let features = {};
	let visit = null;
	let offerHost = null;

	// ── what may not be kept ───────────────────────────────────────────────
	function sensitive() {
		if (SENSITIVE_URL.test(location.hostname + location.pathname)) return true;
		if (document.querySelector("input[type=password], input[autocomplete^=cc-], input[autocomplete*=' cc-'], input[name*=iban i], input[name*=card i]")) return true;
		const fields = [...document.querySelectorAll("input:not([type=hidden]):not([type=search]):not([type=checkbox]):not([type=radio]):not([type=submit]), textarea, select")];
		return fields.length >= 4 && textLength() < 2500;
	}

	function mainOf() {
		return document.querySelector("article, main, [role=main]") || document.body;
	}

	function textLength() {
		const root = mainOf();
		return root ? (root.innerText || "").length : 0;
	}

	function long() {
		const root = document.scrollingElement || document.documentElement;
		return textLength() >= 5000 && root.scrollHeight >= window.innerHeight * 2.5;
	}

	function kindOf() {
		if (VIDEO_URL.test(location.href)) return "video";
		if (visit && visit.media >= 60) return "video";
		return document.querySelector("article") || long() ? "article" : "page";
	}

	// ── visits ─────────────────────────────────────────────────────────────
	function newVisit() {
		visit = { url: location.href, dwell: 0, media: 0, progress: 0, sent: false, sensitive: null };
	}

	function progressNow() {
		const root = document.scrollingElement || document.documentElement;
		const room = root.scrollHeight - window.innerHeight;
		return room > 0 ? Math.max(0, Math.min(1, window.scrollY / room)) : 1;
	}

	function report(final) {
		if (!features.index || !visit || visit.dwell < 10) return;
		if (visit.sensitive === null) visit.sensitive = sensitive();
		if (visit.sensitive) return;
		const message = {
			pshell: "memory:visit",
			url: visit.url,
			title: document.title,
			dwell: visit.dwell,
			media: visit.media,
			progress: visit.progress,
			kind: kindOf(),
			first: !visit.sent
		};
		if (!visit.sent || final === "text") message.text = (mainOf()?.innerText || "").slice(0, 60000);
		visit.sent = true;
		browser.runtime.sendMessage(message).catch(() => {});
	}

	let ticks = 0;
	setInterval(() => {
		if (!visit) return;
		if (location.href !== visit.url) return moved();
		const shown = document.visibilityState === "visible";
		if (shown && document.hasFocus()) visit.dwell += 5;
		if ([...document.querySelectorAll("video, audio")].some(media => !media.paused && !media.ended && media.readyState > 2)) visit.media += 5;
		if (shown) visit.progress = Math.max(visit.progress, progressNow());
		ticks++;
		if (visit.dwell >= 10 && !visit.sent) report();
		else if (ticks % 6 === 0) report();
	}, 5000);

	window.addEventListener("pagehide", () => {
		report();
		saveReading(true);
	});

	// an address changed without a load: the old page ends, a new one begins
	function moved() {
		report();
		saveReading(true);
		closeOffer();
		begin();
	}

	// ── where the page was left ────────────────────────────────────────────
	let lastSaved = -1;
	let readingDue = null;

	function anchorText() {
		let element = document.elementFromPoint(window.innerWidth / 2, Math.min(window.innerHeight * 0.2, 160));
		const block = element && element.closest ? element.closest(BLOCKS) : null;
		return block ? (block.innerText || "").replace(/\s+/g, " ").trim().slice(0, 160) : "";
	}

	function saveReading(now) {
		clearTimeout(readingDue);
		if (!features.reading || !visit || !long()) return;
		const go = () => {
			const progress = progressNow();
			if (Math.abs(progress - lastSaved) < 0.02) return;
			if (lastSaved < 0 && progress < 0.05) return;
			lastSaved = progress;
			browser.runtime.sendMessage({ pshell: "memory:reading", url: location.href, title: document.title, progress, anchor: progress >= 0.95 ? "" : anchorText() }).catch(() => {});
		};
		if (now) go();
		else readingDue = setTimeout(go, 1500);
	}

	window.addEventListener("scroll", () => saveReading(false), { passive: true });

	function findBlock(anchor) {
		const wanted = anchor.replace(/\s+/g, " ").trim();
		if (wanted.length < 12) return null;
		for (const block of document.querySelectorAll(BLOCKS)) {
			const text = (block.textContent || "").replace(/\s+/g, " ").trim();
			if (text.startsWith(wanted.slice(0, 120))) return block;
		}
		return null;
	}

	function goTo(place) {
		const block = place.anchor ? findBlock(place.anchor) : null;
		if (block) {
			block.scrollIntoView({ block: "start" });
			window.scrollBy(0, -Math.min(120, window.innerHeight * 0.15));
		} else {
			const root = document.scrollingElement || document.documentElement;
			window.scrollTo(0, place.progress * (root.scrollHeight - window.innerHeight));
		}
	}

	function closeOffer() {
		if (offerHost) offerHost.remove();
		offerHost = null;
	}

	// a small bar at the foot of the page: Continue, or away with it
	function offer(place) {
		if (offerHost || window.scrollY > window.innerHeight * 0.5) return;
		offerHost = document.createElement("pshell-continue");
		offerHost.style.cssText = "position:fixed;z-index:2147483646;left:50%;bottom:22px;transform:translateX(-50%);";
		const root = offerHost.attachShadow({ mode: "closed" });
		const where = `${Math.round(place.progress * 100)}%${place.device ? ` · ${place.device}` : ""}`;
		root.innerHTML = `<style>
			:host { all: initial; }
			.bar { display: flex; align-items: center; gap: 4px; padding: 5px 5px 5px 14px; border-radius: 999px;
				background: #1d1d1f; color: #f4ede6; font: 500 12.5px system-ui, sans-serif;
				box-shadow: 0 0 0 1px rgba(255,255,255,.12), 0 10px 30px rgba(0,0,0,.4); }
			.where { opacity: .7; margin-right: 6px; white-space: nowrap; }
			button { all: unset; cursor: pointer; height: 26px; padding: 0 12px; border-radius: 999px; font-weight: 600; }
			.go { background: #f4ede6; color: #1d1d1f; }
			.go:hover { opacity: .9; }
			.away { padding: 0 9px; opacity: .65; }
			.away:hover { opacity: 1; background: rgba(255,255,255,.08); }
		</style><div class="bar"><span class="where"></span><button class="go">Continue</button><button class="away" title="Close">✕</button></div>`;
		root.querySelector(".where").textContent = where;
		root.querySelector(".go").addEventListener("click", () => {
			goTo(place);
			closeOffer();
		});
		root.querySelector(".away").addEventListener("click", closeOffer);
		document.documentElement.append(offerHost);
		setTimeout(closeOffer, 25000);
	}

	// ── kept text marked ───────────────────────────────────────────────────
	// the page's text as one string with single spaces, and where each
	// character of it is in the DOM
	function textMap() {
		const nodes = [];
		const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
			acceptNode: node => {
				const parent = node.parentElement;
				if (!parent || /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|TEMPLATE)$/.test(parent.tagName)) return NodeFilter.FILTER_REJECT;
				return NodeFilter.FILTER_ACCEPT;
			}
		});
		let text = "";
		const where = [];
		let space = true;
		while (walker.nextNode()) {
			const node = walker.currentNode;
			const data = node.data;
			for (let i = 0; i < data.length; i++) {
				const char = data[i];
				if (/\s/.test(char)) {
					if (space) continue;
					space = true;
					text += " ";
				} else {
					space = false;
					text += char;
				}
				where.push([node, i]);
			}
			nodes.push(node);
		}
		return { text: text.toLowerCase(), where };
	}

	function mark(items) {
		if (!items.length || typeof Highlight === "undefined" || !CSS.highlights) return false;
		const map = textMap();
		const ranges = [];
		for (const item of items) {
			const wanted = item.text.replace(/\s+/g, " ").trim().toLowerCase();
			if (wanted.length < 3) continue;
			const at = map.text.indexOf(wanted);
			if (at < 0) continue;
			const [startNode, startOffset] = map.where[at];
			const [endNode, endOffset] = map.where[at + wanted.length - 1];
			const range = document.createRange();
			range.setStart(startNode, startOffset);
			range.setEnd(endNode, endOffset + 1);
			ranges.push(range);
		}
		if (ranges.length === 0) return false;
		CSS.highlights.set("pshell-kept", new Highlight(...ranges));
		return true;
	}

	function markSoon(items) {
		if (!features.highlights || !items.length) return;
		browser.runtime.sendMessage({ pshell: "memory:css" }).catch(() => {});
		let tries = 0;
		const again = () => {
			if (mark(items) || ++tries >= 3) return;
			setTimeout(again, tries * 2500);
		};
		again();
	}

	// ── copied text ────────────────────────────────────────────────────────
	function fragmentOf(text) {
		const enc = part => encodeURIComponent(part).replace(/-/g, "%2D");
		const plain = text.replace(/\s+/g, " ").trim();
		const words = plain.split(" ");
		if (plain.length <= 80 || words.length <= 8) return `#:~:text=${enc(plain)}`;
		return `#:~:text=${enc(words.slice(0, 4).join(" "))},${enc(words.slice(-4).join(" "))}`;
	}

	function copied() {
		if (!features.clips) return;
		const active = document.activeElement;
		if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)) return;
		const text = String(window.getSelection() || "");
		if (!text.trim() || text.length > 200000) return;
		if (visit && visit.sensitive === null) visit.sensitive = sensitive();
		if (visit ? visit.sensitive : sensitive()) return;
		const url = location.href.split("#")[0];
		browser.runtime.sendMessage({ pshell: "memory:copied", text: text.slice(0, 4000), url, title: document.title, fragment: fragmentOf(text) }).catch(() => {});
	}

	document.addEventListener("copy", copied, true);
	document.addEventListener("cut", copied, true);

	// ── the page ───────────────────────────────────────────────────────────
	async function begin() {
		newVisit();
		lastSaved = -1;
		let answer = null;
		try {
			answer = await browser.runtime.sendMessage({ pshell: "memory:page", url: location.href });
		} catch (error) {}
		if (!answer || !visit || visit.url !== location.href) return;
		features = answer.features || {};
		if (features.reading && answer.reading) {
			// a page that builds itself late is long only after a moment
			const tryOffer = (left) => {
				if (long()) offer(answer.reading);
				else if (left > 0) setTimeout(() => tryOffer(left - 1), 1500);
			};
			tryOffer(3);
		}
		markSoon(answer.highlights || []);
	}

	begin();
})();
