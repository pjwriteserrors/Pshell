pragma Singleton

import QtQuick
import Quickshell
import qs.style.theme

// The radial menu: quick actions as a tree, opened at the pointer.
//
// An entry is { id, label, icon } plus one of
//   children – a submenu
//   run      – the action; the menu closes first
// and optionally
//   hold     – must be held until the ring closes (Enter confirms instantly)
//   danger   – drawn in the danger colour
//   active   – a toggle that is on
//   enabled  – false greys it out
Singleton {
	id: root

	// ids of the opened submenus, outermost first
	property var path: []

	readonly property var captureEntries: [
		{ id: "region", label: "Region", icon: "selection_drag", run: () => Screenshot.region() },
		{ id: "screen", label: "Screen", icon: "monitor", run: () => Screenshot.screen() },
		{ id: "window", label: "Window", icon: "application_outline", run: () => Screenshot.window() },
		{ id: "pin", label: "Pin", icon: "pin_outline", run: () => Screenshot.pinMode() },
		{ id: "live", label: "Live", icon: "cast", run: () => Screenshot.liveMode() },
		{ id: "color", label: "Color", icon: "eyedropper", run: () => Screenshot.picker() },
		{ id: "text", label: "Text", icon: "text_recognition", run: () => Screenshot.ocr() },
		{ id: "qr", label: "QR", icon: "qrcode_scan", run: () => Screenshot.qr() },
		{ id: "scroll", label: "Scroll", icon: "arrow_expand_vertical", run: () => Screenshot.scroll() },
		{
			id: "delay", label: "Timer", icon: "timer_outline",
			children: [3, 5, 10].map(seconds => ({
				id: `delay${seconds}`,
				label: `${seconds} s`,
				icon: "timer_outline",
				run: () => Screenshot.delayed(seconds)
			}))
		}
	]

	readonly property var clipboardEntries: [
		{ id: "image", label: "Last image", icon: "image_outline", run: () => Clipboard.restoreLatest("image") },
		{ id: "text", label: "Last text", icon: "text_short", run: () => Clipboard.restoreLatest("text") }
	]

	readonly property var powerEntries: [
		{ id: "lock", label: Words.of("power.lock", "Lock"), icon: "lock", run: () => Session.run("lock") },
		{ id: "logout", label: Words.of("power.logout", "Log out"), icon: "logout", hold: true, danger: true, run: () => Session.run("logout") },
		{ id: "reboot", label: Words.of("power.reboot", "Restart"), icon: "restart", hold: true, danger: true, run: () => Session.run("reboot") },
		{ id: "shutdown", label: Words.of("power.shutdown", "Shut down"), icon: "power", hold: true, danger: true, run: () => Session.run("shutdown") }
	]

	readonly property int hostLimit: 8
	readonly property var sshEntries: Ssh.recent.slice(0, root.hostLimit).map(entry => {
		const id = String(entry.id || "");
		return {
			id: `host-${id}`,
			label: String(entry.display_name || entry.target || ""),
			icon: "server",
			children: [
				{ id: "terminal", label: "Terminal", icon: "console", run: () => Ssh.connect(id) },
				{ id: "password", label: "Password", icon: "key_variant", enabled: entry.auth_type !== "key", run: () => Ssh.copyPassword(id, true) }
			]
		};
	})

	readonly property var timerEntries: [
		{ id: "pause", label: "Pause", icon: "pause", enabled: Tmpo.tracking, run: () => Tmpo.pause() },
		{ id: "resume", label: "Resume", icon: "play", enabled: !Tmpo.tracking && Tmpo.canResume, run: () => Tmpo.runAction(["resume"]) },
		{
			id: "tasks", label: "Timer", icon: "timer_outline",
			enabled: Tmpo.todayTasks.length > 0,
			children: Tmpo.todayTasks.slice(0, 10).map((task, index) => ({
				id: `task-${index}`,
				label: String(task.description || task.project || ""),
				icon: "play",
				active: (Tmpo.tracking || Tmpo.paused) && Tmpo.taskKey(task.project, task.description) === Tmpo.taskKey(Tmpo.project, Tmpo.description),
				run: () => Tmpo.switchTo(task)
			}))
		}
	]

	readonly property var tree: {
		const entries = [
			{ id: "capture", label: Words.of("radial.capture", "Capture"), icon: "selection_drag", children: root.captureEntries },
			{ id: "clipboard", label: Words.of("radial.clipboard", "Clipboard"), icon: "clipboard_outline", children: root.clipboardEntries },
			{ id: "dnd", label: Words.of("radial.dnd", "Do not disturb"), icon: Notifs.dnd ? "bell_off_outline" : "bell_outline", active: Notifs.dnd, run: () => Notifs.toggleDnd() },
			{ id: "mic", label: Words.of("radial.mic", "Microphone"), icon: Audio.micIcon, active: Audio.micMuted, run: () => Audio.toggleMicMute() },
			{ id: "power", label: Words.of("radial.power", "Power"), icon: "power", children: root.powerEntries }
		];
		if (Host.has("ssh"))
			entries.push({ id: "ssh", label: Words.of("radial.ssh", "SSH"), icon: "console", enabled: root.sshEntries.length > 0, children: root.sshEntries });
		if (Host.has("qtrack"))
			entries.push({ id: "qtrack", label: Words.of("radial.timer", "Timer"), icon: "timer_outline", active: Tmpo.tracking, children: root.timerEntries });
		return entries;
	}

	// the opened submenus as entries; shorter than `path` when one of them is gone
	readonly property var trail: {
		const out = [];
		let level = root.tree;
		for (const id of root.path) {
			const entry = level.find(candidate => candidate.id === id);
			if (!entry || !Array.isArray(entry.children)) break;
			out.push(entry);
			level = entry.children;
		}
		return out;
	}
	readonly property var current: root.trail.length > 0 ? root.trail[root.trail.length - 1] : null
	readonly property var items: root.current ? root.current.children : root.tree
	readonly property bool open: Popups.modal === "radial"

	// the path is dropped on closing, so the view fades out as it was
	onOpenChanged: {
		if (!root.open) root.path = [];
		else if (Host.has("ssh")) Ssh.refresh(false);
	}


	function usable(entry) {
		return !!entry && entry.enabled !== false;
	}

	function activate(entry) {
		if (!root.usable(entry)) return;
		if (Array.isArray(entry.children)) {
			root.path = root.trail.map(parent => parent.id).concat([entry.id]);
			return;
		}
		Popups.closeModal();
		entry.run();
	}

	// one level up; at the top the menu closes
	function back() {
		if (root.trail.length === 0) Popups.closeModal();
		else root.path = root.trail.slice(0, -1).map(parent => parent.id);
	}
}
