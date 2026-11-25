/* Breakpoints (parts/spur.js has the columns): the toolbar button beside the
 * reload buttons, shown only while working, and the scrolling that keeps the
 * columns together – a small script in every page (asleep unless the page
 * state says it is a breakpoint column) reports how far down it is (a share
 * of the page), the others follow; the window or, on pages that keep it
 * still, the largest element that scrolls. */
"use strict";

(function () {
	const ID = "pshell-breakpoints-button";

	// the script in the pages (a frame script of its own); the page state
	// (base.js, sent on every page's hello) wakes it
	function pshellBreakpointsFrame() {
		/* global content, addEventListener, removeEventListener, sendAsyncMessage, addMessageListener, removeMessageListener */
		let on = false;
		let due = false;
		// where a follow put the page: its own scroll events there are no news
		let placed = null;
		let placedUntil = 0;
		let inner = null;

		// what scrolls the page: the window, or – on pages that keep it still
		// (html/body at 100 %, a wrapper) – the largest element that scrolls
		const big = element => {
			const view = content.innerWidth * content.innerHeight;
			return element.clientWidth * element.clientHeight >= view * 0.4;
		};
		const scrolls = element => {
			if (!element || element.scrollHeight - element.clientHeight < 2) return false;
			const overflow = content.getComputedStyle(element).overflowY;
			return overflow === "auto" || overflow === "scroll" || overflow === "overlay";
		};
		const scroller = () => {
			if ((content.scrollMaxY || 0) > 0) return null;
			if (inner?.isConnected && scrolls(inner)) return inner;
			inner = null;
			let best = 0;
			const doc = content.document;
			for (const element of doc.body ? [doc.documentElement, doc.body, ...doc.body.querySelectorAll("*")] : []) {
				if (!scrolls(element) || !big(element)) continue;
				const area = element.clientWidth * element.clientHeight;
				if (area > best) {
					best = area;
					inner = element;
				}
			}
			return inner;
		};
		const position = element => element
			? { top: element.scrollTop, max: element.scrollHeight - element.clientHeight }
			: { top: content.scrollY, max: content.scrollMaxY || 0 };

		const onScroll = event => {
			if (!on || due) return;
			const doc = content.document;
			const target = event.target;
			let element = null;
			if (target !== doc) {
				if (!target || target.nodeType !== 1 || !scrolls(target) || !big(target)) return;
				if (target !== doc.documentElement) element = target;
				inner = element;
			}
			due = true;
			content.requestAnimationFrame(() => {
				due = false;
				const { top, max } = position(element);
				if (placed !== null && Date.now() < placedUntil && Math.abs(top - placed) <= 2) return;
				placed = null;
				sendAsyncMessage("pshell:bp", { ratio: max > 0 ? top / max : 0 });
			});
		};
		const onMessage = message => {
			const data = message.data || {};
			if (data.what === "state") {
				on = !!data.state?.breakpoints;
			} else if (data.what === "bpScroll") {
				if (!on) return;
				const element = scroller();
				const { max } = position(element);
				const top = Math.round(max * Math.min(1, Math.max(0, data.ratio)));
				placed = top;
				placedUntil = Date.now() + 1000;
				if (element) element.scrollTo({ top, behavior: "instant" });
				else content.scrollTo({ top, behavior: "instant" });
			} else if (data.what === "unload") {
				on = false;
				removeEventListener("scroll", onScroll, true);
				removeMessageListener("pshell:to", onMessage);
			}
		};
		addEventListener("scroll", onScroll, true);
		addMessageListener("pshell:to", onMessage);
	}

	const frameUrl = "data:application/javascript;charset=utf-8," + encodeURIComponent(`(${pshellBreakpointsFrame.toString()})();`);
	const spur = () => PARTS.find(part => part.name === "spur");

	// a column came or went: its page learns it (pageState below)
	function watch(W, browser) {
		updatePage(W, browser);
		refresh(W);
	}

	function unwatch(W) {
		W.win.setTimeout(() => refresh(W), 0);
	}

	// the button: there while working, checked on a tab showing breakpoints
	function refresh(W) {
		const button = W.doc.getElementById(ID);
		if (!button) return;
		const work = tabsConfig().work && !W.private;
		button.hidden = !work;
		button.toggleAttribute("checked", work && !!spur()?.isBreakpoints(W, W.gBrowser.selectedTab));
	}

	PARTS.push({
		name: "breakpoints",
		watch,
		unwatch,
		pageState(W, browser, state) {
			state.breakpoints = (spur()?.columnsBeside(W, browser) || []).length > 0;
		},
		attach(W) {
			W.win.messageManager.loadFrameScript(frameUrl, true);
			W.cleanup.push(() => {
				W.win.messageManager.removeDelayedFrameScript(frameUrl);
				W.win.messageManager.broadcastAsyncMessage("pshell:to", { what: "unload" });
			});
			W.bpListener = message => {
				const ratio = Number(message.data?.ratio);
				if (Number.isFinite(ratio)) {
					for (const other of spur()?.columnsBeside(W, message.target) || []) {
						try {
							sendPage(other, "bpScroll", { ratio });
						} catch (error) {}
					}
				}
			};
			W.win.messageManager.addMessageListener("pshell:bp", W.bpListener);
			W.cleanup.push(() => W.win.messageManager.removeMessageListener("pshell:bp", W.bpListener));
			on(W, W.gBrowser.tabContainer, "TabSelect", () => refresh(W));

			const item = W.doc.getElementById("stop-reload-button");
			if (!item || W.doc.getElementById(ID)) return;
			const button = W.doc.createXULElement("toolbarbutton");
			button.id = ID;
			button.className = "toolbarbutton-1";
			button.setAttribute("tooltiptext", "Breakpoints");
			button.hidden = true;
			button.addEventListener("command", () => {
				spur()?.breakpoints(W, W.gBrowser.selectedTab);
				refresh(W);
			});
			item.appendChild(button);
			W.cleanup.push(() => button.remove());
		},
		configure(W) {
			refresh(W);
		}
	});
})();
