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
		{ id: "pin", label: "Pin", icon: "pin_outline", shown: Screenshot.offers("pin"), run: () => Screenshot.pinMode() },
		{ id: "live", label: "Live", icon: "cast", shown: Screenshot.offers("live"), run: () => Screenshot.liveMode() },
		{ id: "color", label: "Color", icon: "eyedropper", shown: Screenshot.offers("picker"), run: () => Screenshot.picker() },
		{ id: "text", label: "Text", icon: "text_recognition", shown: Screenshot.offers("ocr"), run: () => Screenshot.ocr() },
		{ id: "qr", label: "QR", icon: "qrcode_scan", shown: Screenshot.offers("qr"), run: () => Screenshot.qr() },
		{ id: "scroll", label: "Scroll", icon: "arrow_expand_vertical", shown: Screenshot.offers("scroll"), run: () => Screenshot.scroll() },
		// the newest screenshot, straight into the picture viewer to draw on
		{ id: "lastshot", label: "Edit last", icon: "image_edit_outline", shown: Viewer.enabled && Screenshot.shots.length > 0, run: () => Viewer.open(Screenshot.shots[0].path, { mode: "markup", list: Screenshot.shots.map(shot => shot.path) }) },
		{
			id: "delay", label: "Timer", icon: "timer_outline", shown: Plugins.on("delayed-screenshot"),
			children: [3, 5, 10].map(seconds => ({
				id: `delay${seconds}`,
				label: `${seconds} s`,
				icon: "timer_outline",
				run: () => Screenshot.delayed(seconds)
			}))
		}
	].filter(entry => entry.shown !== false)

	readonly property var clipboardEntries: [
		{ id: "image", label: "Last image", icon: "image_outline", run: () => Clipboard.restoreLatest("image") },
		{ id: "imageedit", label: "Edit image", icon: "image_edit_outline", shown: Viewer.enabled, run: () => Viewer.paste() },
		{ id: "text", label: "Last text", icon: "text_short", run: () => Clipboard.restoreLatest("text") }
	].filter(entry => entry.shown !== false)

	readonly property var powerEntries: [
		{ id: "lock", label: Words.of("power.lock", "Lock"), icon: "lock", shown: Plugins.on("lock-screen"), run: () => Session.run("lock") },
		{ id: "suspend", label: Words.of("power.suspend", "Suspend"), icon: "sleep", run: () => Session.run("suspend") },
		{ id: "logout", label: Words.of("power.logout", "Log out"), icon: "logout", hold: true, danger: true, run: () => Session.run("logout") },
		{ id: "reboot", label: Words.of("power.reboot", "Restart"), icon: "restart", hold: true, danger: true, run: () => Session.run("reboot") },
		{ id: "shutdown", label: Words.of("power.shutdown", "Shut down"), icon: "power", hold: true, danger: true, run: () => Session.run("shutdown") }
	].filter(entry => entry.shown !== false)

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

	// the folders looked into lately, and the usual ways into Files
	readonly property var filesEntries: [
		{ id: "files-home", label: "Files", icon: "folder_open", run: () => Files.open("") },
		{ id: "files-downloads", label: "Downloads", icon: "download", run: () => Files.open(`${Paths.home}/Downloads`) }
	].concat(FileLibrary.visited.slice(0, 6).map((entry, index) => ({
		id: `files-${index}`,
		label: Files.nameOf(entry.path),
		icon: "folder_outline",
		run: () => Files.open(entry.path)
	})))

	readonly property var timerEntries: [
		{ id: "pause", label: "Pause", icon: "pause", enabled: QtrackTimer.tracking, run: () => QtrackTimer.pause() },
		{ id: "resume", label: "Resume", icon: "play", enabled: !QtrackTimer.tracking && QtrackTimer.canResume, run: () => QtrackTimer.runAction(["resume"]) },
		{
			id: "tasks", label: "Timer", icon: "timer_outline",
			enabled: QtrackTimer.todayTasks.length > 0,
			children: QtrackTimer.todayTasks.slice(0, 10).map((task, index) => ({
				id: `task-${index}`,
				label: String(task.description || task.project || ""),
				icon: "play",
				active: (QtrackTimer.tracking || QtrackTimer.paused) && QtrackTimer.taskKey(task.project, task.description) === QtrackTimer.taskKey(QtrackTimer.project, QtrackTimer.description),
				run: () => QtrackTimer.switchTo(task)
			}))
		}
	]

	readonly property var tree: {
		const entries = [];
		if (Plugins.on("screenshot"))
			entries.push({ id: "capture", label: Words.of("radial.capture", "Capture"), icon: "selection_drag", children: root.captureEntries });
		if (Plugins.on("clipboard"))
			entries.push({ id: "clipboard", label: Words.of("radial.clipboard", "Clipboard"), icon: "clipboard_outline", children: root.clipboardEntries });
		if (Plugins.on("dnd"))
			entries.push({ id: "dnd", label: Words.of("radial.dnd", "Do not disturb"), icon: Notifs.dnd ? "bell_off_outline" : "bell_outline", active: Notifs.dnd, run: () => Notifs.toggleDnd() });
		if (Plugins.on("sound"))
			entries.push({ id: "mic", label: Words.of("radial.mic", "Microphone"), icon: Audio.micIcon, active: Audio.micMuted, run: () => Audio.toggleMicMute() });
		if (Plugins.on("filemanager"))
			entries.push({ id: "files", label: Words.of("radial.files", "Files"), icon: "folder_outline", children: root.filesEntries });
		if (Plugins.on("task-manager"))
			entries.push({ id: "taskmgr", label: "Tasks", icon: "monitor_dashboard", children: [
				{ id: "taskmgr-open", label: "Task manager", icon: "monitor_dashboard", run: () => TaskManager.open() },
				{ id: "taskmgr-pause", label: "Pause app", icon: "pause", enabled: Niri.focusedId >= 0, run: () => TaskManager.pauseWindow(Niri.focusedId) },
				{ id: "taskmgr-end", label: "End app", icon: "close_octagon_outline", hold: true, danger: true, enabled: Niri.focusedId >= 0, run: () => TaskManager.endWindow(Niri.focusedId) }
			] });
		if (Plugins.on("music"))
			entries.push({ id: "music", label: Words.of("radial.music", "Music"), icon: "music_note", active: Music.playing, children: [
				{ id: "music-toggle", label: Music.playing ? "Pause" : "Play", icon: Music.playing ? "pause" : "play", run: () => Music.toggle() },
				{ id: "music-next", label: "Next song", icon: "skip_next", enabled: Music.queue.length > 1 || Music.repeatMode !== "off", run: () => Music.next() },
				{ id: "music-now", label: Music.current ? Music.titleOf(Music.path) : "What plays?", icon: "album", run: () => Music.showWindow() },
				{ id: "music-small", label: "Small player", icon: "arrow_collapse", run: () => Music.showSmall() }
			] });
		// while a video is open: the few things done with it from anywhere
		if (Plugins.on("video") && Video.current)
			entries.push({ id: "video", label: Words.of("radial.video", "Video"), icon: "movie_open_outline", active: Video.playing, children: [
				{ id: "video-toggle", label: Video.playing ? "Pause" : "Play", icon: Video.playing ? "pause" : "play", run: () => Video.toggle() },
				{ id: "video-pip", label: Video.pip ? "Back to the window" : "Picture in picture", icon: "picture_in_picture_bottom_right", run: () => Video.togglePip() },
				{ id: "video-full", label: Video.fullscreen ? "Leave fullscreen" : "Fullscreen", icon: Video.fullscreen ? "fullscreen_exit" : "fullscreen", run: () => Video.toggleFullscreen() },
				{ id: "video-now", label: Video.title, icon: "movie_outline", run: () => Video.showWindow() },
				{ id: "video-snapshot", label: "Take a picture of it", icon: "camera_outline", run: () => Video.snapshot(false) }
			] });
		// while a PDF is open: reading it, editing it, showing it as slides
		if (Plugins.on("pdf") && Pdf.current)
			entries.push({ id: "pdf", label: Words.of("radial.pdf", "PDF"), icon: "file_pdf_box", active: Pdf.windowOpen, children: [
				{ id: "pdf-now", label: Pdf.title, icon: "file_document_outline", run: () => Pdf.showWindow() },
				{ id: "pdf-edit", label: Pdf.editing ? "Back to reading" : "Edit", icon: Pdf.editing ? "book_open_page_variant_outline" : "file_document_edit_outline", run: () => {
					Pdf.showWindow();
					Pdf.toggleEditing();
				} },
				{ id: "pdf-present", label: Pdf.presenting ? "End the slides" : "Present", icon: "presentation_play", run: () => {
					Pdf.showWindow();
					Pdf.present();
				} },
				{ id: "pdf-night", label: Pdf.night ? "Pages as they are" : "Pages at night", icon: Pdf.night ? "white_balance_sunny" : "weather_night", run: () => Pdf.night = !Pdf.night },
				{ id: "pdf-save", label: "Save", icon: "content_save_outline", enabled: Pdf.dirty, run: () => Pdf.save() }
			] });
		entries.push({ id: "power", label: Words.of("radial.power", "Power"), icon: "power", children: root.powerEntries });
		if (Plugins.on("ssh"))
			entries.push({ id: "ssh", label: Words.of("radial.ssh", "SSH"), icon: "console", enabled: root.sshEntries.length > 0, children: root.sshEntries });
		if (Plugins.on("qtrack"))
			entries.push({ id: "qtrack", label: Words.of("radial.timer", "Timer"), icon: "timer_outline", active: QtrackTimer.tracking, children: root.timerEntries });
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
		else if (Plugins.on("ssh")) Ssh.refresh(false);
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
