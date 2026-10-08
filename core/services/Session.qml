pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Session actions shared by power menu, quick settings and IPC.
Singleton {
	id: root

	property bool locked: false
	signal lockRequested
	// the phone proved itself (docs/mobile.md, unlock); the lock screen decides
	signal unlockRequested

	// What a reboot or shutdown waits for (power menu, "After"):
	// { kind, what: "process" | "agent" | "download" | "downloads", pid, start,
	// window, key, name }. It lives in
	// the runtime dir as well, so a reload of the shell does not drop it.
	property var pending: null
	// the wait is over; the countdown toast runs
	property bool due: false
	readonly property int grace: 30
	// seconds of the countdown that are left
	property int left: 0
	// tells this niri session from the next one
	readonly property string sessionKey: Quickshell.env("NIRI_SOCKET") || ""
	property int serial: 0
	property var waiter: null
	property int toastId: 0
	property int idleTicks: 0
	// a browser was there to ask since the wait began, and polls without one
	property bool linked: false
	property int blindTicks: 0

	function after(kind, target) {
		if (kind !== "reboot" && kind !== "shutdown") return;
		root.cancelAfter();
		root.pending = Object.assign({}, target, { kind: kind });
		root.store();
		root.watch();
	}

	function cancelAfter() {
		if (!root.pending) return;
		root.pending = null;
		root.due = false;
		root.serial += 1;
		if (root.waiter) root.waiter.running = false;
		root.waiter = null;
		if (root.toastId) Notifs.removeToast(root.toastId);
		root.toastId = 0;
		root.store();
	}

	function store() {
		file.setText(JSON.stringify(root.pending ? Object.assign({ session: root.sessionKey }, root.pending) : null) + "\n");
	}

	function watch() {
		root.serial += 1;
		if (root.pending?.what !== "process") return;
		root.waiter = waiting.createObject(root, { serial: root.serial });
		root.waiter.command = ["python3", `${Paths.scripts}/power_after.py`, "wait", String(root.pending.pid), String(root.pending.start || 0)];
		root.waiter.running = true;
	}

	function busy() {
		const pending = root.pending;
		if (pending.what === "agent") {
			if (Niri.windows.length === 0) return true;
			const id = Number(pending.window);
			const window = Niri.windows.find(w => Number(w.id) === id);
			return !!window && (!!Agents.busy[id] || Agents.titleState(window.title) === "busy");
		}
		// after a reload the browser takes a moment to come back and say what
		// it loads; one that left or stays away has given its downloads up
		if (Downloads.connected) root.linked = true;
		else if (!root.linked) return ++root.blindTicks < 10;
		if (pending.what === "download") return Downloads.active.some(item => item.key === pending.key);
		return Downloads.active.length > 0;
	}

	function finish() {
		if (!root.pending || root.due) return;
		root.due = true;
		root.left = root.grace;
		const restart = root.pending.kind === "reboot";
		root.toastId = Notifs.pushInternal("running", `${restart ? "Restarting" : "Shutting down"} in ${root.grace} s`, `${root.pending.name} is done`, {
			icon: restart ? "restart" : "power",
			duration: root.grace * 1000,
			actions: [{ label: "Cancel", icon: "close", run: () => root.cancelAfter() }]
		});
	}

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
		if (kind !== "lock") root.cancelAfter();
		switch (kind) {
		case "lock": root.lock(); break;
		case "logout": root.logout(); break;
		case "reboot": root.reboot(); break;
		case "shutdown": root.shutdown(); break;
		}
	}

	Component {
		id: waiting

		Process {
			id: proc

			property int serial: 0

			onExited: exitCode => {
				if (exitCode === 0 && proc.serial === root.serial) root.finish();
				proc.destroy();
			}
		}
	}

	// An agent is done once its window stopped being busy for a moment, a
	// download once the browser no longer has it under way.
	Timer {
		interval: 3000
		repeat: true
		running: !!root.pending && root.pending.what !== "process" && !root.due
		onRunningChanged: {
			root.idleTicks = 0;
			root.blindTicks = 0;
			root.linked = false;
		}
		onTriggered: {
			if (root.busy()) root.idleTicks = 0;
			else root.idleTicks += 1;
			if (root.idleTicks >= 2) root.finish();
		}
	}

	Timer {
		interval: 1000
		repeat: true
		running: root.due
		onTriggered: {
			root.left -= 1;
			if (root.left <= 0 && root.pending) root.run(root.pending.kind);
		}
	}

	// a suspended machine would never get there
	Process {
		running: root.pending !== null
		command: ["systemd-inhibit", "--what=sleep", "--who=Quickshell", "--why=Waits to shut down", "--mode=block", "sleep", "infinity"]
	}

	FileView {
		id: file

		path: `${Paths.runtime}/power-after.json`
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const saved = JSON.parse(String(text() || "null"));
				if (!saved || saved.session !== root.sessionKey || !(saved.kind === "reboot" || saved.kind === "shutdown")) return;
				delete saved.session;
				root.pending = saved;
				Qt.callLater(root.watch);
			} catch (error) {}
		}
	}
}
