/* The window's own keys:
 *   Ctrl+K      the shell's launcher on >tab (instead of the search bar's)
 *   Alt+1…9     the recent tiles (instead of the tab with that number),
 *               Alt+0 the last of them
 *   Alt+E       the same page in the next environment
 *   Alt+Shift+S the page style editor (before the menu bar's History)
 * and Ctrl+Tab by use, with previews (Firefox's own, a pref).
 * With the shell's link connected a click in the address bar can open the
 * launcher as well (Settings, off by default). */
"use strict";

(function () {
	const OWN = [
		{ id: "pshell-key-launcher", key: "K", modifiers: "accel", replaces: ["key_search", "key_search2"], when: tabs => tabs.launcherKey && tabs.connected, run: () => emit("launcher") },
		{ id: "pshell-key-env", key: "E", modifiers: "alt", replaces: [], early: true, when: tabs => tabs.envs.on, run: W => PARTS.find(part => part.name === "env").switchEnv(W) },
		{ id: "pshell-key-restyle", key: "S", modifiers: "alt,shift", shift: true, replaces: [], early: true, private: true, when: () => true, run: () => emit("restyle") }
	];
	// Alt+1…9 the recent tiles in their places, Alt+0 the last of them
	for (let n = 0; n <= 9; n++) {
		const replaces = n === 9 ? ["key_selectLastTab"] : n > 0 ? [`key_selectTab${n}`] : [];
		OWN.push({ id: `pshell-key-recent${n}`, key: String(n), modifiers: "alt", replaces, when: tabs => tabs.recent.on, run: W => PARTS.find(part => part.name === "recent").pick(W, n) });
	}

	function setCtrlTab(on) {
		if (Services.prefs.getBoolPref("browser.ctrlTab.sortByRecentlyUsed", false) !== on) {
			Services.prefs.setBoolPref("browser.ctrlTab.sortByRecentlyUsed", on);
		}
	}

	PARTS.push({
		name: "keys",
		configured(tabs) {
			setCtrlTab(!!tabs.ctrlTab);
		},
		attach(W) {
			W.keyset = W.doc.createXULElement("keyset");
			W.keyset.id = "pshell-keyset";
			W.replaced = new Map();
			for (const own of OWN) {
				const key = W.doc.createXULElement("key");
				key.id = own.id;
				key.setAttribute("key", own.key);
				key.setAttribute("modifiers", own.modifiers);
				key.addEventListener("command", () => {
					if (own.early) return;
					if (own.when(tabsConfig()) && !W.private) own.run(W);
				});
				W.keyset.appendChild(key);
			}
			// Alt+E and Alt+Shift+S belong to the menu bar (Edit, History) first; taken before it
			on(W, W.win, "keydown", event => {
				if (!event.altKey || event.ctrlKey || event.metaKey || event.repeat) return;
				const own = OWN.find(item => item.early && event.key.toUpperCase() === item.key && !!item.shift === event.shiftKey);
				if (!own || !own.when(tabsConfig()) || (W.private && !own.private)) return;
				event.preventDefault();
				event.stopPropagation();
				own.run(W);
			}, true);
			const main = W.doc.getElementById("mainKeyset");
			(main ? main.parentNode : W.doc.documentElement).appendChild(W.keyset);

			const input = W.doc.getElementById("urlbar-input") || W.doc.querySelector("#urlbar .urlbar-input");
			if (input) {
				on(W, input, "mousedown", event => {
					const tabs = tabsConfig();
					if (!tabs.urlbarLauncher || !tabs.connected || W.private || event.button !== 0) return;
					if (W.doc.activeElement === input || input.contains(W.doc.activeElement)) return;
					event.preventDefault();
					event.stopPropagation();
					emit("launcher");
				}, true);
			}
		},
		configure(W, tabs) {
			// Firefox's keys step aside while ours are wanted, and come back after
			for (const own of OWN) {
				const active = own.when(tabs) && !W.private;
				W.doc.getElementById(own.id)?.toggleAttribute("disabled", !active);
				for (const id of own.replaces) {
					const theirs = W.doc.getElementById(id);
					if (!theirs) continue;
					if (!W.replaced.has(id)) W.replaced.set(id, theirs.getAttribute("disabled"));
					if (active) theirs.setAttribute("disabled", "true");
					else if (W.replaced.get(id) === null) theirs.removeAttribute("disabled");
				}
			}
		},
		detach(W) {
			W.keyset?.remove();
			for (const [id, was] of W.replaced || []) {
				const theirs = W.doc.getElementById(id);
				if (!theirs) continue;
				if (was === null) theirs.removeAttribute("disabled");
				else theirs.setAttribute("disabled", was);
			}
		}
	});
})();
