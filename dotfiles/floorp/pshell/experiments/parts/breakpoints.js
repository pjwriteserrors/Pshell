/* Breakpoints (parts/spur.js has the columns): the toolbar button beside the
 * reload buttons, shown only while working, and the scrolling that keeps the
 * columns together – a small script in every page (asleep unless the page
 * state says it is a breakpoint column) reports how far down it is (a share
 * of the page), the others follow. */
"use strict";

(function () {
	const ID = "pshell-breakpoints-button";

	// the script in the pages (a frame script of its own); the page state
	// (base.js, sent on every page's hello) wakes it
	function pshellBreakpointsFrame() {
		/* global content, addEventListener, removeEventListener, sendAsyncMessage, addMessageListener, removeMessageListener */
		let on = false;
		let quietUntil = 0;
		let due = false;
		const onScroll = event => {
			if (!on || event.target !== content.document || Date.now() < quietUntil || due) return;
			due = true;
			content.requestAnimationFrame(() => {
				due = false;
				const max = content.scrollMaxY || 0;
				sendAsyncMessage("pshell:bp", { ratio: max > 0 ? content.scrollY / max : 0 });
			});
		};
		const onMessage = message => {
			const data = message.data || {};
			if (data.what === "state") {
				on = !!data.state?.breakpoints;
			} else if (data.what === "bpScroll") {
				if (!on) return;
				quietUntil = Date.now() + 200;
				const max = content.scrollMaxY || 0;
				content.scrollTo({ top: Math.round(max * data.ratio), behavior: "instant" });
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
