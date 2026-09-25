pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Which surface is open, on which screen, and where it hangs from the bar.
//
// Panels ("drawers") grow out of the bar below the button that opened them.
// Bars register the horizontal centre of every button per screen, so panels
// opened from a keybind or IPC still appear under their button.
// Modals (launcher, power, pickers) cover the screen; drawers and modals are
// mutually exclusive.
Singleton {
	id: root

	property string current: ""
	property var screen: null
	property string page: ""
	property var payload: null
	property string modal: ""
	property var modalScreen: null
	property var anchorMap: ({})

	// asks the shell to open the standalone RPG window (launcher "/rpg")
	signal rpgWindowRequested
	// emitted right before a panel opens so the bar can report its button position
	signal anchorRequested(var screen, string id)

	readonly property var primaryScreen: {
		for (const screen of Quickshell.screens)
			if (String(screen.name || "") === "DP-2")
				return screen;
		return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
	}

	// the bar element that opened the current panel, if any
	property var opener: null

	function screenKey(screen) {
		return String(screen?.name ?? "");
	}

	function registerAnchor(screen, id, x) {
		const key = root.screenKey(screen);
		const current = root.anchorMap[key]?.[id];
		if (current !== undefined && Math.abs(current - x) < 0.5)
			return;
		const next = Object.assign({}, root.anchorMap);
		next[key] = Object.assign({}, next[key] || {});
		next[key][id] = x;
		root.anchorMap = next;
	}

	function anchorFor(screen, id) {
		const x = root.anchorMap[root.screenKey(screen)]?.[id];
		if (x !== undefined)
			return x;
		return (screen?.width ?? 1920) / 2;
	}

	function isOpen(id) {
		return root.current === id;
	}

	function open(id, screen, page, payload, opener) {
		root.modal = "";
		root.opener = opener ?? null;
		root.screen = screen || root.screen || root.primaryScreen;
		root.page = page ?? "";
		root.payload = payload ?? null;
		root.anchorRequested(root.screen, id);
		root.current = id;
	}

	// Clicking the element that opened a panel closes it again, even when
	// the panel has navigated to another page since. Another element
	// pointing at a different page of the same panel switches to it.
	function toggle(id, screen, page, payload, opener) {
		const sameScreen = !screen || screen === root.screen;
		const samePage = page === undefined || page === "" || page === root.page;
		const sameOpener = opener !== undefined && opener !== null && opener === root.opener;
		if (root.current === id && sameScreen && (sameOpener || (samePage && payload === undefined)))
			root.close();
		else
			root.open(id, screen, page, payload, opener);
	}

	function close() {
		root.current = "";
	}

	function openModal(kind, screen) {
		root.current = "";
		root.modalScreen = screen || root.primaryScreen;
		root.modal = kind;
	}

	function toggleModal(kind, screen) {
		if (root.modal === kind)
			root.closeModal();
		else
			root.openModal(kind, screen);
	}

	function closeModal() {
		root.modal = "";
	}

	function closeAll() {
		root.current = "";
		root.modal = "";
	}

	// ── focused output (for keybinds / IPC) ────────────────────────────────
	property var pendingFocused: []

	function screenByName(name) {
		for (const screen of Quickshell.screens)
			if (String(screen.name || "") === String(name || ""))
				return screen;
		return null;
	}

	function withFocusedScreen(callback) {
		root.pendingFocused = root.pendingFocused.concat([callback]);
		if (!focusedOutput.running)
			focusedOutput.running = true;
	}

	function flushFocused(text) {
		let screen = root.primaryScreen;
		try {
			screen = root.screenByName(JSON.parse(String(text || "{}")).name) || root.primaryScreen;
		} catch (error) {}
		const callbacks = root.pendingFocused;
		root.pendingFocused = [];
		for (const callback of callbacks)
			callback(screen);
	}

	Process {
		id: focusedOutput

		command: ["niri", "msg", "-j", "focused-output"]
		stdout: StdioCollector {
			onStreamFinished: root.flushFocused(text)
		}
		onExited: exitCode => {
			if (exitCode !== 0 && root.pendingFocused.length > 0)
				root.flushFocused("");
		}
	}
}
