pragma Singleton

import QtQuick
import Quickshell

// Session actions shared by power menu, quick settings and IPC.
Singleton {
	id: root

	property bool locked: false
	signal lockRequested
	// the phone proved itself (docs/mobile.md, unlock); the lock screen decides
	signal unlockRequested

	function lock() {
		root.lockRequested();
	}

	function unlock() {
		root.unlockRequested();
	}

	function logout() {
		// niri runs as a systemd user service outside the login session scope, so
		// `loginctl terminate-session` would only kill the session wrapper and leave
		// niri running without DRM access (black screen). Quit niri instead: the
		// niri-session wrapper then exits cleanly and SDDM shows the greeter again.
		Quickshell.execDetached(["niri", "msg", "action", "quit", "--skip-confirmation"]);
	}

	function reboot() {
		Quickshell.execDetached(["systemctl", "reboot"]);
	}

	function shutdown() {
		Quickshell.execDetached(["systemctl", "poweroff"]);
	}

	function run(kind) {
		Popups.closeAll();
		switch (kind) {
		case "lock": root.lock(); break;
		case "logout": root.logout(); break;
		case "reboot": root.reboot(); break;
		case "shutdown": root.shutdown(); break;
		}
	}
}
