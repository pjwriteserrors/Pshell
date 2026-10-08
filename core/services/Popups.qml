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
			if (String(screen.name || "") === Host.primaryOutput)
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

	// the plugin behind a panel or modal; what is not named here always exists
	readonly property var providers: ({
		control: "quick-settings",
		breaks: "breaks",
		media: "media",
		clipboard: "clipboard",
		tray: "tray",
		overview: "overview",
		updates: "updates",
		timer: "qtrack",
		tracking: "qtrack",
		ssh: "ssh",
		notes: "notes",
		messages: "messages",
		reader: "fast-reader",
		screentime: "screentime",
		niri: "niri-settings",
		power: "power-menu",
		radial: "radial-menu",
		eyerest: "eye-rest",
		stretch: "stretch",
		theme: "studio-wallpaper",
		animation: "studio-motion",
		dress: "studio-dress",
		styles: "studio-styles",
		combinations: "studio-combinations"
	})

	function exists(id) {
		if (id === "today")
			return Plugins.on("notifications") || Plugins.on("calendar") || Plugins.on("weather");
		const plugin = root.providers[id];
		return plugin === undefined || Plugins.on(plugin);
	}

	function open(id, screen, page, payload, opener) {
		if (!root.exists(id)) return;
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
		if (!root.exists(kind)) return;
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

	// ── Studio: the look-and-feel pages, each a full-screen modal ─────────
	readonly property var studioPages: [
		{ id: "wallpaper", modal: "theme", label: "Wallpaper", icon: "palette" },
		{ id: "motion", modal: "animation", label: "Motion", icon: "animation_play" },
		{ id: "dress", modal: "dress", label: "Icons & Pointer", icon: "cursor_default_outline" },
		{ id: "styles", modal: "styles", label: "Style", icon: "source_branch" },
		{ id: "combinations", modal: "combinations", label: "Combinations", icon: "bookmark_outline" }
	].filter(page => root.exists(page.modal))
	readonly property int studioIndex: root.studioPages.findIndex(page => page.modal === root.modal)

	function openStudio(page, screen) {
		const target = root.studioPages.find(entry => entry.id === page || entry.modal === page) ?? root.studioPages[0];
		if (!target) return;
		root.openModal(target.modal, screen || root.modalScreen);
	}

	// Ctrl+Tab and friends: pages wrap around
	function stepStudio(delta) {
		const count = root.studioPages.length;
		if (count === 0) return;
		const index = root.studioIndex < 0 ? 0 : (root.studioIndex + delta + count) % count;
		root.openModal(root.studioPages[index].modal, root.modalScreen);
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
