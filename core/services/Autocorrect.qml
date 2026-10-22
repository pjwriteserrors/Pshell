pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Corrects what is typed the way a phone keyboard does, in German and
// English: typos, capitals, punctuation (scripts/autocorrect.py). The daemon
// sees keys, not windows, so the shell tells it where typing may be
// corrected: in windows, and in none where a word is a command, a password
// or a key of a game. Of the shell itself only the fields that ask for it
// are corrected: what is written in Messages.
Singleton {
	id: root

	readonly property bool available: Plugins.on("autocorrect")
	// the switch of the quick settings
	property bool on: true
	readonly property bool enabled: root.available && root.on
	// app ids that are left alone; the host profile's autocorrect.exclude adds its own
	readonly property var excluded: [
		// terminals
		".*(kitty|alacritty|wezterm|ghostty|konsole|terminal|terminator|tilix|ptyxis|xterm|rxvt).*",
		"foot(client)?", "st", "rio", "warp", "org\\.gnome\\.console",
		// code
		"code(-oss|-insiders|-url-handler)?", "(vs)?codium", "cursor", "(dev\\.zed\\.)?zed.*", "jetbrains-.*",
		"sublime_text", "neovide", "emacs.*", "lapce",
		// file managers
		"org\\.gnome\\.nautilus", "thunar", "org\\.kde\\.dolphin", "nemo", "pcmanfm.*", "org\\.gnome\\.files", "spacefm", "doublecmd", "krusader",
		// passwords
		".*keepass.*", "bitwarden", "1password", "enpass", ".*pinentry.*", ".*askpass.*", "gcr-prompter", "polkit.*",
		// games and other machines
		"steam_app_.*", "gamescope", ".*\\.exe", ".*minecraft.*", "virt-(manager|viewer)", "remote-viewer",
		"org\\.remmina\\.remmina", ".*vnc.*", "looking-glass-client", ".*moonlight.*", "parsec", "rustdesk", "anydesk", "scrcpy"
	].concat(Host.profile.autocorrect?.exclude ?? [])

	// browsers: their address field is left alone (the daemon follows the
	// shortcuts that lead into it); the host profile's autocorrect.browsers adds its own
	readonly property var browsers: [
		".*(firefox|floorp|librewolf|waterfox|zen|chromium|chrome|brave|vivaldi|opera|edge|epiphany|qutebrowser|thorium|helium).*"
	].concat(Host.profile.autocorrect?.browsers ?? [])
	readonly property bool browser: root.window !== null && root.matches(root.browsers, root.window.app_id)

	readonly property var window: Niri.windows.find(w => w.is_focused) ?? null
	readonly property int windowId: root.window ? Number(root.window.id) : -1
	// a window of the shell: Messages popped out, the studio
	readonly property bool own: root.window !== null && String(root.window.app_id || "") === "org.quickshell"
	// the field of the shell that is being written in (enter, leave)
	property var field: null
	// Messages in a window of its own has the keyboard only while niri says so:
	// Qt's word for it can stay behind after the window went away
	readonly property bool writing: root.field !== null && (!Messages.windowed || root.own)
	// no window has the keyboard while it is in the launcher or a panel
	readonly property bool active: root.enabled && !Session.locked
		&& (root.writing || (root.window !== null && !root.own && !root.skips(root.window.app_id)))
	// how a correction is typed; of several one is picked each time
	readonly property var animations: [
		Plugins.on("autocorrect-scramble") ? "scramble" : "",
		Plugins.on("autocorrect-decode") ? "decode" : "",
		Plugins.on("autocorrect-typewriter") ? "typewriter" : ""
	].filter(name => name !== "")
	// the daemon cannot work here; said once
	property bool failed: false

	readonly property var failures: ({
		dictionaries: "No dictionary (hunspell-de, hunspell-en_us)",
		permission: "The keyboard is not readable",
		keyboard: "No keyboard",
		layout: "Unknown keyboard layout",
		uinput: "/dev/uinput is not writable"
	})

	function toggle() {
		root.on = !root.on;
		settings.setText(JSON.stringify({ on: root.on }) + "\n");
	}

	function enter(item) {
		root.field = item;
	}

	function leave(item) {
		if (root.field === item) root.field = null;
	}

	function skips(appId) {
		return root.matches(root.excluded, appId);
	}

	function matches(patterns, appId) {
		const id = String(appId || "");
		return patterns.some(pattern => {
			try {
				return new RegExp(`^(?:${pattern})$`, "i").test(id);
			} catch (error) {
				return false;
			}
		});
	}

	// every change of window as well: the text in front of the cursor is another one
	function tell() {
		if (daemon.running) daemon.write(JSON.stringify({ active: root.active, browser: root.browser, animations: root.animations }) + "\n");
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
		} else if (data.type === "error") {
			root.failed = true;
			Notifs.pushInternal("error", "Autocorrect", root.failures[data.reason] ?? "", { icon: "keyboard" });
		}
	}

	onActiveChanged: root.tell()
	onWindowIdChanged: root.tell()
	onFieldChanged: root.tell()
	onWritingChanged: root.tell()
	onBrowserChanged: root.tell()
	onAnimationsChanged: root.tell()
	onEnabledChanged: root.failed = false

	FileView {
		id: settings

		path: Paths.stateFile("autocorrect-switch.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.on = JSON.parse(String(text() || "{}")).on !== false;
			} catch (error) {}
		}
	}

	Process {
		id: daemon

		running: root.enabled && !root.failed
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/autocorrect.py`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: if (root.enabled && !root.failed) revive.restart()
	}

	// a daemon that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.enabled && !root.failed && !daemon.running) daemon.running = true
	}
}
