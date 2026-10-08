pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Lines and cursors the way a code editor has them, in every text field:
// move and copy lines, several cursors (scripts/multicursor.py). The daemon
// takes the keyboards to see a shortcut before the window does, so the shell
// tells it where: in windows, and in none that knows these shortcuts itself
// or has no text to edit. The shortcuts and the apps that are left alone are
// set in the niri settings (MulticursorPage) and kept in multicursor.json.
Singleton {
	id: root

	readonly property bool available: Plugins.on("multicursor")
	property bool on: true
	readonly property bool enabled: root.available && root.on

	// what it does, with the keys a code editor has for it
	readonly property var actions: [
		{ id: "moveUp", title: "Move line up", icon: "arrow_up", key: "Alt+Up" },
		{ id: "moveDown", title: "Move line down", icon: "arrow_down", key: "Alt+Down" },
		{ id: "copyUp", title: "Copy line up", icon: "content_copy", key: "Ctrl+Alt+Shift+Up" },
		{ id: "copyDown", title: "Copy line down", icon: "content_copy", key: "Ctrl+Alt+Shift+Down" },
		{ id: "cursorUp", title: "Add cursor above", icon: "cursor_text", key: "Alt+Shift+Up" },
		{ id: "cursorDown", title: "Add cursor below", icon: "cursor_text", key: "Alt+Shift+Down" },
		{ id: "addCursor", title: "Add cursor", icon: "cursor_default_click_outline", key: "Alt+MouseLeft" }
	]
	// the keys that were changed: action → key, "" for none
	property var changed: ({})
	readonly property var binds: {
		const out = {};
		for (const action of root.actions) out[action.id] = root.changed[action.id] ?? action.key;
		return out;
	}

	// app ids that are left alone besides terminals, code editors, password
	// prompts and games (Autocorrect.excluded): file managers have these keys
	readonly property var fileManagers: ["org.gnome.Nautilus", "org.kde.dolphin", "thunar", "nemo", "pcmanfm", "pcmanfm-qt"]
	property var excluded: root.fileManagers

	readonly property var window: Niri.windows.find(w => w.is_focused) ?? null
	readonly property int windowId: root.window ? Number(root.window.id) : -1
	// no window has the keyboard while it is in the launcher or a panel
	readonly property bool active: root.enabled && !Session.locked && root.window !== null && !root.skips(root.window.app_id)
	// cursors in the text right now: 0 none, 1 one that was put down
	property int cursors: 0
	// the clipboard is the daemon's way into a text field: what passes through it is nobody's copy
	property bool reading: false
	property real readAt: 0
	// the daemon cannot work here; said once
	property bool failed: false

	readonly property var failures: ({
		permission: "The keyboard is not readable",
		keyboard: "No keyboard",
		layout: "Unknown keyboard layout",
		uinput: "/dev/uinput is not writable",
		clipboard: "The clipboard cannot be reached"
	})

	function quiet() {
		return root.reading || Date.now() - root.readAt < 1500;
	}

	function skips(appId) {
		const id = String(appId || "").toLowerCase();
		return Autocorrect.skips(id) || root.excluded.some(entry => String(entry).toLowerCase() === id);
	}

	function save() {
		settings.setText(JSON.stringify({ on: root.on, binds: root.changed, excluded: root.excluded }, null, "\t") + "\n");
	}

	function setOn(on) {
		root.on = on;
		root.save();
	}

	// "" takes the keys away; a key another action has moves over
	function setBind(action, key) {
		const changed = Object.assign({}, root.changed);
		if (key !== "") {
			for (const other of root.actions)
				if (other.id !== action && Keybinds.norm(root.binds[other.id]) === Keybinds.norm(key)) changed[other.id] = "";
		}
		changed[action] = key;
		for (const entry of root.actions)
			if (changed[entry.id] === entry.key) delete changed[entry.id];
		root.changed = changed;
		root.save();
	}

	function resetBind(action) {
		root.setBind(action, root.actions.find(entry => entry.id === action).key);
	}

	function setExcluded(appId, excluded) {
		const id = String(appId || "");
		const rest = root.excluded.filter(entry => String(entry).toLowerCase() !== id.toLowerCase());
		root.excluded = excluded ? rest.concat([id]) : rest;
		root.save();
	}

	// every change of window as well: the text is another one
	function tell() {
		if (daemon.running) daemon.write(JSON.stringify({ active: root.active, window: root.windowId, binds: root.binds }) + "\n");
	}

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (data.type === "ready") {
			root.tell();
		} else if (data.type === "cursors") {
			root.cursors = data.count;
		} else if (data.type === "clipboard") {
			root.reading = !!data.busy;
			root.readAt = Date.now();
		} else if (data.type === "panic") {
			// both Shift keys and Escape: the keyboards are free again
			root.setOn(false);
			Notifs.pushInternal("done", "Multicursor off", "", { icon: "cursor_text" });
		} else if (data.type === "error") {
			root.failed = true;
			Notifs.pushInternal("error", "Multicursor", root.failures[data.reason] ?? "", { icon: "cursor_text" });
		}
	}

	onActiveChanged: root.tell()
	onWindowIdChanged: root.tell()
	onBindsChanged: root.tell()
	onEnabledChanged: {
		root.failed = false;
		root.cursors = 0;
		root.reading = false;
	}

	FileView {
		id: settings

		path: Paths.stateFile("multicursor.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.on = data.on !== false;
				if (data.binds && typeof data.binds === "object") root.changed = data.binds;
				if (Array.isArray(data.excluded)) root.excluded = data.excluded;
			} catch (error) {}
		}
	}

	Process {
		id: daemon

		running: root.enabled && !root.failed
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/multicursor.py`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: {
			root.cursors = 0;
			root.reading = false;
			if (root.enabled && !root.failed) revive.restart();
		}
	}

	// a daemon that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.enabled && !root.failed && !daemon.running) daemon.running = true
	}
}
