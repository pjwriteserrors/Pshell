pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Live status of the shell for the bar and the trays: what the services
// know right now (load, throughput, downloads, the timer, the phone …) as
// one kind of thing. Each source says whether something is happening
// (`busy`), a short value (`text`), how full it is (`level`, -1 none), a
// short history to draw (`history`), a tone (normal, accent, good, warn,
// bad, muted) and whether it wants attention (`pulse`); a click opens the
// panel behind it or does what fits (`act`), the wheel may change it.
// How each looks is kept in live.json: { <id>: { style, hide, label } }.
// Shown as `live-<id>` in BarLayout and as widget `live:<id>` in trays.
Singleton {
	id: root

	component Source: QtObject {
		property string key
		property string name
		property string glyph: "heart_pulse"
		property string group: "shell"
		property string plugin: ""
		property string about: ""
		// the plugin is on and there is something to show at all
		property bool ready: true
		readonly property bool available: root.pluginOn(plugin) && ready
		property bool busy: true
		property string text: ""
		// the widest the value gets, so the bar does not twitch with every change
		property string widest: ""
		property string detail: ""
		property real level: -1
		// what `auto` looks like: chip, ring or spark (fixed, so nothing reflows with the values)
		property string prefers: "chip"
		property var history: null
		property real maximum: 0
		property string tone: "normal"
		property bool pulse: false
		// hidden while idle unless said otherwise
		property bool quiet: false
		property string panel: ""
		property string page: ""
		property string hint: ""
		property var act: null
		property var wheel: null
	}

	readonly property var groups: [
		{ id: "system", name: "System" },
		{ id: "shell", name: "Activity" },
		{ id: "day", name: "Your day" },
		{ id: "devices", name: "Devices" },
		{ id: "media", name: "Media" }
	]
	readonly property var styles: [
		{ value: "auto", label: "Auto", icon: "auto_fix" },
		{ value: "chip", label: "Value", icon: "numeric" },
		{ value: "ring", label: "Ring", icon: "circle_slice_8" },
		{ value: "spark", label: "Curve", icon: "chart_bell_curve_cumulative" },
		{ value: "bar", label: "Bar", icon: "chart_bar" },
		{ value: "icon", label: "Icon", icon: "circle_small" }
	]

	readonly property var sources: [cpu, memory, network, battery, volume, mic, brightness, power, bluetooth,
		notifications, messages, updates, downloads, torrents, filejobs, recording, sharing, gamemode, agents, keepawake, clipboard, shelf,
		timer, worked, screentime, water, eyes, meeting, todos, weather,
		phone, watch, mouse, printer, vm, pcs, game, media]
	readonly property var byId: {
		const out = {};
		for (const each of root.sources) out[each.key] = each;
		return out;
	}
	// the catalog entries of the bar and the trays; taken once, so a glyph
	// that changes does not make the bar build its items anew
	property var catalog: []
	Component.onCompleted: root.catalog = root.sources.map(each => ({ id: each.key, name: each.name, glyph: each.glyph, plugin: each.plugin, group: each.group, about: each.about }))

	function source(id) {
		return root.byId[String(id ?? "").replace(/^live[-:]/, "")] ?? null;
	}
	function pluginOn(plugin) {
		return plugin === "" || Plugins.on(plugin);
	}

	// ── how each looks ──────────────────────────────────────────────────
	property var options: ({})
	property bool loaded: false

	function optionOf(id) {
		const src = root.source(id);
		const saved = root.options[src?.key ?? id] ?? {};
		return {
			style: saved.style ?? "auto",
			hide: saved.hide ?? (src?.quiet ?? false),
			label: saved.label ?? false
		};
	}
	// what `auto` becomes: what the source prefers
	function styleOf(id) {
		const style = root.optionOf(id).style;
		return style !== "auto" ? style : (root.source(id)?.prefers ?? "chip");
	}
	function setOption(id, patch) {
		const key = root.source(id)?.key ?? id;
		const next = Object.assign({}, root.options);
		next[key] = Object.assign({}, next[key] ?? {}, patch);
		root.options = next;
		file.setText(JSON.stringify(root.options, null, 2) + "\n");
	}
	// shown at all: its plugin is on, and it is not hidden while idle
	function shows(id) {
		const src = root.source(id);
		if (!src?.available) return false;
		return src.busy || !root.optionOf(id).hide;
	}

	// ── what a click and the wheel do ───────────────────────────────────
	function activate(id, screen, opener) {
		const src = root.source(id);
		if (!src) return;
		if (src.act) {
			src.act(screen);
			return;
		}
		if (src.panel === "") return;
		const on = screen ?? Popups.focusedScreen();
		Popups.toggle(src.panel, on, src.page, undefined, opener);
	}
	function scroll(id, up) {
		const src = root.source(id);
		if (src?.wheel) src.wheel(up);
	}

	// ── who looks: the services sample only while something shows them ──
	property var holds: ({})

	function hold(id, delta) {
		const key = root.source(id)?.key ?? id;
		const next = Object.assign({}, root.holds);
		next[key] = Math.max(0, (next[key] ?? 0) + delta);
		root.holds = next;
	}
	function held(id) {
		return (root.holds[id] ?? 0) > 0;
	}

	Binding {
		target: Network
		property: "liveWatched"
		value: root.held("network")
	}

	Binding {
		target: SysStats
		property: "liveWatched"
		value: root.held("cpu") || root.held("memory")
	}

	// minutes and countdowns tick
	property real now: Date.now()

	Timer {
		running: root.held("meeting") || root.held("eyes") || root.held("worked")
		interval: 15000
		repeat: true
		triggeredOnStart: true
		onTriggered: root.now = Date.now()
	}

	function percent(value) {
		return `${Math.round(value)}%`;
	}
	function minutes(seconds) {
		const s = Math.max(0, Math.round(seconds));
		if (s < 60) return `${s} s`;
		if (s < 3600) return `${Math.round(s / 60)} min`;
		const h = Math.floor(s / 3600);
		const m = Math.round((s % 3600) / 60);
		return m > 0 ? `${h} h ${m}` : `${h} h`;
	}

	// ── system ──────────────────────────────────────────────────────────
	Source {
		id: cpu

		key: "cpu"
		prefers: "spark"
		widest: "100%"
		name: "Processor"
		glyph: "cpu_64_bit"
		group: "system"
		about: "Load of all cores, with its last minute"
		text: root.percent(SysStats.cpu)
		detail: SysStats.cpuText !== "" ? `${SysStats.cpuText} · ${Math.round(SysStats.cpu)}% busy` : `${Math.round(SysStats.cpu)}% busy`
		level: SysStats.cpu / 100
		history: SysStats.cpuHistory
		maximum: 100
		tone: SysStats.cpu > 90 ? "bad" : (SysStats.cpu > 70 ? "warn" : "normal")
		busy: SysStats.cpu > 25
		panel: "control"
		page: "system"
		hint: "Opens the system page"
	}

	Source {
		id: memory

		key: "memory"
		prefers: "spark"
		widest: "100%"
		name: "Memory"
		glyph: "expansion_card"
		group: "system"
		about: "How full the memory is"
		text: root.percent(SysStats.memory)
		detail: SysStats.memoryText
		level: SysStats.memory / 100
		history: SysStats.memoryHistory
		maximum: 100
		tone: SysStats.memory > 90 ? "bad" : (SysStats.memory > 75 ? "warn" : "normal")
		busy: SysStats.memory > 60
		panel: "control"
		page: "system"
		hint: "Opens the system page"
	}

	Source {
		id: network

		key: "network"
		prefers: "spark"
		widest: "88.8 MB/s"
		name: "Network"
		glyph: Network.icon || "wifi"
		group: "system"
		plugin: "network"
		about: "What comes in right now, and what goes out"
		text: Network.online ? Format.rate(Network.download) : "Offline"
		detail: Network.online ? `${Network.label}${Network.ssid !== "" ? ` · ${Network.ssid}` : ""} · ↓ ${Format.rate(Network.download)} · ↑ ${Format.rate(Network.upload)}` : "No connection"
		history: Network.online ? Network.downloadHistory : null
		tone: Network.online ? (Network.download > 1048576 ? "accent" : "normal") : "bad"
		busy: !Network.online || Network.download > 262144 || Network.upload > 262144
		panel: "control"
		page: "network"
		hint: "Opens the network page"
	}

	Source {
		id: battery

		key: "battery"
		prefers: "ring"
		widest: "100%"
		name: "Battery"
		glyph: SysStats.batteryIcon
		group: "system"
		plugin: "battery"
		about: "The laptop's charge"
		ready: SysStats.batteryAvailable
		text: `${SysStats.batteryPercent}%`
		detail: SysStats.charging ? "Charging" : (SysStats.charged ? "Full" : `${SysStats.batteryPercent}% left`)
		level: SysStats.batteryPercent / 100
		tone: SysStats.charging ? "good" : (SysStats.batteryPercent <= 10 ? "bad" : (SysStats.batteryPercent <= 25 ? "warn" : "normal"))
		pulse: !SysStats.charging && SysStats.batteryPercent <= 10
		busy: SysStats.charging || SysStats.batteryPercent <= 30
		panel: "control"
		page: "power"
	}

	Source {
		id: volume

		key: "volume"
		prefers: "ring"
		widest: "100%"
		name: "Volume"
		glyph: Audio.icon
		group: "system"
		about: "Loudness of the output; the wheel turns it"
		text: Audio.muted ? "Muted" : root.percent(Audio.volume * 100)
		detail: Audio.sinkName
		level: Audio.muted ? 0 : Math.min(1, Audio.volume)
		tone: Audio.muted ? "muted" : (Audio.volume > 1 ? "warn" : "normal")
		panel: "control"
		page: "audio"
		hint: "Click: sound page · wheel: louder or quieter"
		wheel: up => Audio.setVolume(Math.max(0, Math.min(1.5, Audio.volume + (up ? 0.05 : -0.05))))
	}

	Source {
		id: mic

		key: "mic"
		prefers: "ring"
		widest: "100%"
		name: "Microphone"
		glyph: Audio.micIcon
		group: "system"
		about: "Whether the microphone hears you; a click mutes it"
		text: Audio.micMuted ? "Muted" : root.percent(Audio.micVolume * 100)
		detail: Audio.micMuted ? "Nobody hears you" : "The microphone is open"
		level: Audio.micMuted ? 0 : Math.min(1, Audio.micVolume)
		tone: Audio.micMuted ? "muted" : "accent"
		busy: !Audio.micMuted
		hint: "Click: mute or unmute · wheel: level"
		act: screen => {
			if (Audio.source?.audio) Audio.source.audio.muted = !Audio.source.audio.muted;
		}
		wheel: up => Audio.setMicVolume(Math.max(0, Math.min(1.5, Audio.micVolume + (up ? 0.05 : -0.05))))
	}

	Source {
		id: brightness

		key: "brightness"
		prefers: "ring"
		widest: "100%"
		name: "Brightness"
		glyph: "brightness_6"
		group: "system"
		plugin: "backlight"
		about: "The screen's brightness; the wheel changes it"
		ready: Brightness.available
		text: root.percent(Brightness.value * 100)
		level: Brightness.value
		busy: false
		hint: "Wheel: brighter or darker"
		wheel: up => Brightness.set(Math.max(0.01, Math.min(1, Brightness.value + (up ? 0.05 : -0.05))))
	}

	Source {
		id: power

		key: "power"
		name: "Power profile"
		glyph: PowerProfile.icons[PowerProfile.current] ?? "scale_balance"
		group: "system"
		plugin: "power-profiles"
		about: "Saver, balanced or performance; a click goes to the next"
		ready: PowerProfile.available
		text: PowerProfile.labels[PowerProfile.current] ?? ""
		tone: PowerProfile.current === "performance" ? "warn" : (PowerProfile.current === "power-saver" ? "good" : "normal")
		busy: PowerProfile.current !== "balanced"
		hint: "Click: the next profile"
		act: screen => {
			const list = PowerProfile.profiles;
			PowerProfile.set(list[(list.indexOf(PowerProfile.current) + 1) % list.length]);
		}
	}

	Source {
		id: bluetooth

		key: "bluetooth"
		name: "Bluetooth"
		glyph: Bluetooth.icon
		group: "system"
		plugin: "bluetooth"
		about: "What is connected"
		ready: Bluetooth.available
		text: Bluetooth.connected.length > 0 ? (Bluetooth.connected.length === 1 ? String(Bluetooth.connected[0].name ?? "1") : `${Bluetooth.connected.length}`) : (Bluetooth.powered ? "On" : "Off")
		detail: Bluetooth.summary
		tone: Bluetooth.connected.length > 0 ? "accent" : (Bluetooth.powered ? "normal" : "muted")
		busy: Bluetooth.connected.length > 0
		panel: "control"
		page: "bluetooth"
	}

	// ── the shell at work ───────────────────────────────────────────────
	Source {
		id: notifications

		readonly property bool urgent: Notifs.groups.some(group => Number(group.urgency ?? 0) === 2)

		key: "notifications"
		name: "Notifications"
		glyph: Notifs.dnd ? "bell_off_outline" : (Notifs.count > 0 ? "bell_badge_outline" : "bell_outline")
		group: "shell"
		plugin: "notifications"
		about: "How many wait; quiet while do not disturb is on"
		text: Notifs.count > 0 ? `${Notifs.count}` : (Notifs.dnd ? "Quiet" : "0")
		detail: Notifs.dnd ? `Do not disturb${Notifs.dndReason ? ` · ${Notifs.dndReason}` : ""}` : (Notifs.count > 0 ? `${Notifs.count} waiting` : "Nothing new")
		tone: notifications.urgent ? "bad" : (Notifs.dnd ? "muted" : (Notifs.count > 0 ? "accent" : "normal"))
		pulse: notifications.urgent
		busy: Notifs.count > 0 || Notifs.dnd
		panel: "today"
	}

	Source {
		id: messages

		key: "messages"
		name: "Messages"
		glyph: "message_text_outline"
		group: "shell"
		plugin: "messages"
		about: "Unread mail and chats"
		text: `${Messages.unread}`
		detail: Messages.unread > 0 ? `${Messages.unread} unread` : "All read"
		tone: Messages.unread > 0 ? "accent" : "muted"
		busy: Messages.unread > 0
		quiet: true
		act: screen => Messages.toggle()
	}

	Source {
		id: updates

		key: "updates"
		name: "Updates"
		glyph: Updates.running ? "progress_download" : "package_up"
		group: "shell"
		plugin: "updates"
		about: "Pending packages, and the upgrade while it runs"
		text: Updates.running ? root.percent(Updates.progress * 100) : `${Updates.packages.length}`
		detail: Updates.running ? (Updates.progressLabel || "Upgrading") : (Updates.packages.length > 0 ? `${Updates.packages.length} packages to update${Updates.rebootNeeded ? " · restart pending" : ""}` : (Updates.rebootNeeded ? "Restart to use the new kernel" : "Up to date"))
		level: Updates.running ? Updates.progress : -1
		tone: Updates.rebootNeeded ? "warn" : (Updates.packages.length >= Updates.remindAt ? "warn" : (Updates.packages.length > 0 ? "accent" : "good"))
		pulse: Updates.running
		busy: Updates.running || Updates.packages.length > 0 || Updates.rebootNeeded
		quiet: true
		panel: "updates"
	}

	Source {
		id: downloads

		key: "downloads"
		prefers: "ring"
		widest: "88.8 MB/s"
		name: "Downloads"
		glyph: Downloads.phase === "done" ? "check_circle" : "download"
		group: "shell"
		plugin: "downloads"
		about: "The browsers' downloads: how far, how fast"
		text: Downloads.phase === "running" ? Format.rate(Downloads.speed) : (Downloads.phase === "paused" ? "Paused" : (Downloads.phase === "done" ? "Done" : "–"))
		detail: Downloads.active.length > 0 ? `${Downloads.active.length} ${Downloads.active.length === 1 ? "file" : "files"}${Downloads.ratio >= 0 ? ` · ${Math.floor(Downloads.ratio * 100)}%` : ""}${Downloads.eta >= 0 ? ` · ${Downloads.formatEta(Downloads.eta)} left` : ""}` : "Nothing comes in"
		level: Downloads.phase === "done" ? 1 : Math.max(-1, Downloads.ratio)
		tone: Downloads.phase === "done" ? "good" : (Downloads.phase === "paused" ? "muted" : "accent")
		pulse: Downloads.phase === "running"
		busy: Downloads.phase !== "idle"
		quiet: true
		panel: "downloads"
	}

	Source {
		id: torrents

		key: "torrents"
		prefers: "spark"
		widest: "88.8 MB/s"
		name: "Torrents"
		glyph: "magnet"
		group: "shell"
		plugin: "torrents"
		about: "Speed and progress of the torrents that run"
		text: Torrents.running.length > 0 ? Format.rate(Torrents.down) : "Idle"
		detail: Torrents.running.length > 0 ? `${Torrents.running.length} running · ↓ ${Format.rate(Torrents.down)} · ↑ ${Format.rate(Torrents.up)}` : `${Torrents.torrents.length} torrents`
		level: Torrents.running.length > 0 ? Math.max(0, Torrents.ratio) : -1
		history: Torrents.running.length > 0 && Torrents.live.length > 1 ? Torrents.live.slice(-30).map(pair => Number(pair[0]) || 0) : null
		tone: Torrents.running.length > 0 ? "accent" : "muted"
		pulse: Torrents.running.length > 0 && Torrents.down > 0
		busy: Torrents.running.length > 0
		quiet: true
		act: screen => Torrents.toggle()
	}

	Source {
		id: filejobs

		readonly property var jobs: Files.activeJobs.filter(job => Number(job.elapsed) > 1.2 && !["rename", "mkdir", "newfile", "batchrename", "link"].includes(job.kind))
		readonly property real ratio: {
			let done = 0;
			let total = 0;
			for (const job of filejobs.jobs)
				if (job.bytesTotal > 0) {
					done += job.bytes;
					total += job.bytesTotal;
				}
			if (total > 0) return done / total;
			const job = filejobs.jobs[0];
			return job && job.filesTotal > 0 ? job.files / job.filesTotal : -1;
		}

		key: "filejobs"
		prefers: "ring"
		name: "File jobs"
		glyph: "folder_sync_outline"
		group: "shell"
		plugin: "filemanager"
		about: "Copies, unpacking, uploads while they run"
		text: filejobs.jobs.some(job => job.state === "conflict") ? "Asks" : (filejobs.ratio >= 0 ? root.percent(filejobs.ratio * 100) : `${filejobs.jobs.length}`)
		detail: filejobs.jobs.length > 0 ? `${filejobs.jobs.length} ${filejobs.jobs.length === 1 ? "job" : "jobs"} running` : "Nothing runs"
		level: filejobs.jobs.length > 0 ? filejobs.ratio : -1
		tone: filejobs.jobs.some(job => job.state === "conflict") ? "warn" : "accent"
		pulse: filejobs.jobs.some(job => job.state === "conflict")
		busy: filejobs.jobs.length > 0
		quiet: true
		act: screen => Files.show({ paths: [], kind: "folders", newTab: false })
	}

	Source {
		id: recording

		key: "recording"
		name: "Recording"
		glyph: "record_rec"
		group: "shell"
		plugin: "recording"
		about: "The screen recording and its time; a click stops it"
		text: Recorder.active ? Recorder.elapsed : "Off"
		detail: Recorder.active ? `Recording for ${Recorder.elapsed}` : "Not recording"
		tone: Recorder.active ? "bad" : "muted"
		pulse: Recorder.active
		busy: Recorder.active
		quiet: true
		hint: "Click: stop"
		act: screen => {
			if (Recorder.active) Recorder.stop();
		}
	}

	Source {
		id: sharing

		key: "sharing"
		name: "Screen sharing"
		glyph: "monitor_share"
		group: "shell"
		about: "Lights up while an app watches the screen"
		text: Notifs.sharing ? "Shared" : "Private"
		detail: Notifs.sharing ? "An app sees your screen" : "Nobody sees your screen"
		tone: Notifs.sharing ? "bad" : "muted"
		pulse: Notifs.sharing
		busy: Notifs.sharing
		quiet: true
	}

	Source {
		id: gamemode

		key: "gamemode"
		name: "Game mode"
		glyph: "crosshairs"
		group: "shell"
		plugin: "game-mode"
		about: "On while a game plays; a click forces it"
		text: GameMode.active ? (GameMode.title !== "" ? GameMode.title : "On") : "Off"
		detail: GameMode.active ? `Game mode${GameMode.force === "on" ? " (forced)" : ""}` : (GameMode.force === "off" ? "Kept off" : "Follows the games")
		tone: GameMode.active ? "good" : "muted"
		busy: GameMode.active
		quiet: true
		hint: "Click: force on or off"
		act: screen => GameMode.setForce(GameMode.active ? (GameMode.force === "on" ? "auto" : "off") : (GameMode.force === "off" ? "auto" : "on"))
	}

	Source {
		id: agents

		readonly property int count: Object.keys(Agents.busy ?? {}).length

		key: "agents"
		name: "AI agents"
		glyph: "robot_outline"
		group: "shell"
		plugin: "agents"
		about: "Coding agents that are working"
		text: agents.count > 0 ? `${agents.count} working` : "Idle"
		detail: agents.count > 0 ? `${agents.count} ${agents.count === 1 ? "agent works" : "agents work"} in a terminal` : "No agent works"
		tone: agents.count > 0 ? "accent" : "muted"
		pulse: agents.count > 0
		busy: agents.count > 0
		quiet: true
	}

	Source {
		id: keepawake

		key: "keepawake"
		name: "Keep awake"
		glyph: "coffee"
		group: "shell"
		plugin: "keep-awake"
		about: "Whether the screen stays on; a click switches it"
		text: KeepAwake.active ? "Awake" : "Off"
		tone: KeepAwake.active ? "warn" : "muted"
		busy: KeepAwake.active
		quiet: true
		act: screen => KeepAwake.toggle()
	}

	Source {
		id: clipboard

		key: "clipboard"
		name: "Clipboard"
		glyph: "clipboard_text_multiple_outline"
		group: "shell"
		plugin: "clipboard"
		about: "Entries in the clipboard history"
		text: `${Clipboard.entries.length}`
		detail: `${Clipboard.entries.length} entries`
		busy: false
		panel: "clipboard"
	}

	Source {
		id: shelf

		readonly property int count: Shelf.shelves.reduce((sum, each) => sum + (each.items?.length ?? 0), 0)

		key: "shelf"
		name: "Shelves"
		glyph: "tray_full"
		group: "shell"
		plugin: "shelves"
		about: "Files waiting on the shelves"
		text: `${shelf.count}`
		detail: `${shelf.count} ${shelf.count === 1 ? "file" : "files"} on ${Shelf.shelves.length} ${Shelf.shelves.length === 1 ? "shelf" : "shelves"}`
		tone: shelf.count > 0 ? "accent" : "muted"
		busy: shelf.count > 0
		quiet: true
	}

	// ── the day ─────────────────────────────────────────────────────────
	Source {
		id: timer

		key: "timer"
		widest: "0:00:00"
		name: "Timer"
		glyph: QtrackTimer.paused ? "timer_sand" : "timer_outline"
		group: "day"
		plugin: "qtrack"
		about: "The running qtrack timer"
		text: QtrackTimer.tracking ? QtrackTimer.duration : "Idle"
		detail: QtrackTimer.tracking ? [QtrackTimer.project, QtrackTimer.description].filter(each => each !== "").join(" · ") || "Tracking" : "No timer runs"
		tone: QtrackTimer.tracking ? (QtrackTimer.paused ? "warn" : "accent") : "muted"
		pulse: QtrackTimer.paused
		busy: QtrackTimer.tracking
		panel: "timer"
	}

	Source {
		id: worked

		key: "worked"
		prefers: "ring"
		name: "Worked today"
		glyph: "briefcase_outline"
		group: "day"
		plugin: "qtrack"
		about: "Tracked time today against eight hours"
		text: root.minutes(QtrackTimer.todayLive)
		detail: `${root.minutes(QtrackTimer.todayLive)} of 8 h`
		level: Math.min(1, QtrackTimer.todayLive / (8 * 3600))
		tone: QtrackTimer.todayLive >= 8 * 3600 ? "good" : "normal"
		busy: QtrackTimer.tracking
		panel: "tracking"
	}

	Source {
		id: screentime

		readonly property real seconds: {
			Screentime.stamp;
			return Screentime.total(Screentime.today);
		}

		key: "screentime"
		prefers: "ring"
		name: "Screen time"
		glyph: "chart_donut"
		group: "day"
		plugin: "screentime"
		about: "Time in front of the screen today"
		text: root.minutes(screentime.seconds)
		detail: `${root.minutes(screentime.seconds)} today`
		level: Math.min(1, screentime.seconds / (10 * 3600))
		tone: screentime.seconds > 10 * 3600 ? "warn" : "normal"
		busy: false
		panel: "screentime"
	}

	Source {
		id: water

		key: "water"
		prefers: "ring"
		name: "Water"
		glyph: "cup_water"
		group: "day"
		plugin: "water"
		about: "What you drank today against the goal"
		text: Breaks.formatLitres(Breaks.waterMl)
		detail: `${Breaks.formatLitres(Breaks.waterMl)} of ${Breaks.formatLitres(Breaks.goalMl)}`
		level: Math.min(1, Breaks.waterMl / Breaks.goalMl)
		tone: Breaks.waterMl >= Breaks.goalMl ? "good" : (Breaks.waterMl < Breaks.paceMl * 0.6 ? "warn" : "accent")
		busy: Breaks.waterMl < Breaks.goalMl
		panel: "breaks"
	}

	Source {
		id: eyes

		readonly property int left: Math.max(0, Breaks.eyesSeconds - Breaks.sinceEyes)

		key: "eyes"
		prefers: "ring"
		name: "Eye rest"
		glyph: "eye_outline"
		group: "day"
		plugin: "eye-rest"
		about: "How long until the next look into the distance"
		text: eyes.left > 0 ? root.minutes(eyes.left) : "Now"
		detail: eyes.left > 0 ? `Next eye rest in ${root.minutes(eyes.left)}` : "Time to look away for 20 seconds"
		level: 1 - eyes.left / Breaks.eyesSeconds
		tone: eyes.left <= 0 ? "warn" : (eyes.left < 120 ? "accent" : "normal")
		pulse: eyes.left <= 0
		busy: eyes.left < 300
		panel: "breaks"
	}

	Source {
		id: meeting

		readonly property var today: {
			const key = MsCalendar.dayKey(new Date(root.now));
			return (MsCalendar.byDay[key] ?? []).filter(event => !event.allDay && MsCalendar.active(event) && event.showAs !== "free");
		}
		readonly property var current: meeting.today.find(event => Date.parse(event.start) <= root.now && root.now < Date.parse(event.end)) ?? null
		readonly property var next: meeting.today.filter(event => Date.parse(event.start) > root.now).sort((a, b) => Date.parse(a.start) - Date.parse(b.start))[0] ?? null
		readonly property real until: meeting.next ? (Date.parse(meeting.next.start) - root.now) / 1000 : -1

		key: "meeting"
		name: "Meetings"
		glyph: meeting.current ? "account_group" : "calendar_clock"
		group: "day"
		plugin: "microsoft-calendar"
		about: "The meeting now, or how long until the next"
		ready: MsCalendar.signedIn
		text: meeting.current ? "Now" : (meeting.next ? `in ${root.minutes(meeting.until)}` : "Free")
		detail: meeting.current ? `${meeting.current.subject} · until ${Qt.formatTime(new Date(meeting.current.end), "HH:mm")}` : (meeting.next ? `${meeting.next.subject} · ${Qt.formatTime(new Date(meeting.next.start), "HH:mm")}` : "Nothing more today")
		level: meeting.current ? (root.now - Date.parse(meeting.current.start)) / Math.max(1, Date.parse(meeting.current.end) - Date.parse(meeting.current.start)) : -1
		tone: meeting.current ? "accent" : (meeting.next && meeting.until < 600 ? "warn" : "normal")
		pulse: !!meeting.next && meeting.until < 300 && !meeting.current
		busy: !!meeting.current || (!!meeting.next && meeting.until < 3600)
		panel: "today"
	}

	Source {
		id: todos

		key: "todos"
		name: "Todos"
		glyph: "checkbox_marked_circle_outline"
		group: "day"
		plugin: "todos"
		about: "Open tasks"
		text: `${Todos.openTasks.length}`
		detail: `${Todos.openTasks.length} open of ${Todos.tasks.length}`
		level: Todos.tasks.length > 0 ? 1 - Todos.openTasks.length / Todos.tasks.length : -1
		tone: Todos.openTasks.length > 0 ? "normal" : "good"
		busy: Todos.openTasks.length > 0
		act: screen => Popups.open("launcher", screen ?? Popups.focusedScreen(), "", ">todo ")
	}

	Source {
		id: weather

		key: "weather"
		name: "Weather"
		glyph: Weather.icon || "weather_partly_cloudy"
		group: "day"
		plugin: "weather"
		about: "The temperature outside"
		ready: Weather.available
		text: Weather.temperature
		detail: `${Weather.description}${Weather.location !== "" ? ` · ${Weather.location}` : ""} · feels ${Weather.feelsLike}`
		busy: false
		panel: "today"
	}

	// ── devices ─────────────────────────────────────────────────────────
	Source {
		id: phone

		key: "phone"
		prefers: "ring"
		name: "Phone"
		glyph: Phone.reachable ? Phone.batteryIcon : "cellphone_off"
		group: "devices"
		plugin: "phone"
		about: "The phone's battery and whether it is near"
		ready: Phone.paired
		text: Phone.reachable && Phone.battery >= 0 ? `${Phone.battery}%` : "Away"
		detail: Phone.reachable ? `${Phone.name}${Phone.charging ? " · charging" : ""}${Phone.network !== "" ? ` · ${Phone.network}` : ""}` : `${Phone.name} is not reachable`
		level: Phone.reachable && Phone.battery >= 0 ? Phone.battery / 100 : -1
		tone: !Phone.reachable ? "muted" : (Phone.charging ? "good" : (Phone.battery <= 15 ? "bad" : "normal"))
		busy: Phone.reachable
		panel: "control"
		page: "phone"
	}

	Source {
		id: watch

		readonly property var day: Watch.days.length > 0 ? Watch.days[Watch.days.length - 1] : null

		key: "watch"
		prefers: "ring"
		name: "Watch"
		glyph: "watch"
		group: "devices"
		plugin: "watch"
		about: "Steps today and the watch's battery"
		ready: Watch.paired || Watch.known
		text: watch.day ? `${Number(watch.day.steps ?? 0).toLocaleString(Qt.locale(), "f", 0)}` : (Watch.battery >= 0 ? `${Watch.battery}%` : "–")
		detail: `${Watch.name}${Watch.battery >= 0 ? ` · ${Watch.battery}%` : ""}${watch.day ? ` · ${watch.day.steps ?? 0} of ${watch.day.stepsGoal ?? 8000} steps` : ""}`
		level: watch.day ? Math.min(1, Number(watch.day.steps ?? 0) / Math.max(1, Number(watch.day.stepsGoal ?? 8000))) : -1
		tone: watch.day && Number(watch.day.steps ?? 0) >= Number(watch.day.stepsGoal ?? 8000) ? "good" : (Watch.connected ? "normal" : "muted")
		busy: Watch.connected
		panel: "watch"
	}

	Source {
		id: mouse

		key: "mouse"
		prefers: "ring"
		name: "Mouse battery"
		glyph: "mouse"
		group: "devices"
		plugin: "mouse-battery"
		about: "The mouse's charge"
		ready: SysStats.mouseFound
		text: SysStats.mouseText
		detail: `${SysStats.mouseName}${SysStats.mouseStatus !== "" ? ` · ${SysStats.mouseStatus}` : ""}`
		level: SysStats.mouseLevel
		tone: SysStats.mouseLevel <= 0.1 ? "bad" : (SysStats.mouseLevel <= 0.2 ? "warn" : "normal")
		pulse: SysStats.mouseLevel <= 0.1
		busy: SysStats.mouseLevel <= 0.3
	}

	Source {
		id: printer

		key: "printer"
		prefers: "ring"
		widest: "100%"
		name: "3D printer"
		glyph: "printer_3d_nozzle"
		group: "devices"
		plugin: "printer"
		about: "How far the print is, and how long it still takes"
		text: Printer.printing ? (Printer.paused ? "Paused" : root.percent(Printer.progress * 100)) : (Printer.online ? "Ready" : "Off")
		detail: Printer.printing ? `Layer ${Printer.layer} of ${Printer.layers} · ${root.minutes(Printer.secondsLeft)} left` : (Printer.online ? "Waits for a print" : "Not reachable")
		level: Printer.printing ? Printer.progress : -1
		tone: Printer.printing ? (Printer.paused ? "warn" : "accent") : (Printer.online ? "normal" : "muted")
		pulse: Printer.paused
		busy: Printer.printing
		quiet: true
		panel: "printer"
	}

	Source {
		id: vm

		key: "vm"
		name: "Windows VM"
		glyph: "microsoft_windows"
		group: "devices"
		plugin: "vm-launcher"
		about: "Whether the VM starts or runs"
		text: Machines.launching ? "Starting" : (Machines.lgOpen ? "Running" : "Off")
		detail: Machines.launching ? `Starting · ${Machines.step}` : (Machines.lgOpen ? "Looking Glass is open" : "Not running")
		level: Machines.launching ? (Machines.steps.indexOf(Machines.step) + 1) / (Machines.steps.length + 1) : -1
		tone: Machines.launching ? "accent" : (Machines.lgOpen ? "good" : "muted")
		pulse: Machines.launching
		busy: Machines.launching || Machines.lgOpen
		quiet: true
		act: screen => Popups.toggleModal("vm", screen ?? Popups.focusedScreen())
	}

	Source {
		id: pcs

		key: "pcs"
		name: "Other PCs"
		glyph: "monitor_multiple"
		group: "devices"
		plugin: "pc-link"
		about: "Linked PCs that are reachable, and files on the way"
		ready: Pcs.devices.length > 0
		text: Pcs.transfers.length > 0 ? `${Pcs.transfers.length} on the way` : `${Pcs.reachable.length}`
		detail: Pcs.reachable.length > 0 ? Pcs.reachable.map(each => each.name ?? "PC").join(", ") : "None reachable"
		tone: Pcs.transfers.length > 0 ? "accent" : (Pcs.reachable.length > 0 ? "good" : "muted")
		pulse: Pcs.transfers.length > 0
		busy: Pcs.reachable.length > 0
		panel: "control"
		page: "phone"
	}

	Source {
		id: game

		key: "game"
		name: "Playing"
		glyph: "gamepad_variant"
		group: "devices"
		plugin: "games"
		about: "The game that runs"
		text: GameMode.playing ? (GameMode.title !== "" ? GameMode.title : "Playing") : "–"
		detail: GameMode.playing ? `Playing ${GameMode.title}` : "No game runs"
		tone: GameMode.playing ? "good" : "muted"
		busy: GameMode.playing
		quiet: true
		act: screen => Popups.toggleModal("games", screen ?? Popups.focusedScreen())
	}

	// ── media ───────────────────────────────────────────────────────────
	Source {
		id: media

		key: "media"
		name: "Now playing"
		glyph: Media.playing ? "music_note" : "pause"
		group: "media"
		plugin: "media"
		about: "Title and progress; a click plays or pauses, the wheel turns it"
		text: Media.hasPlayer ? Media.title : "Silence"
		detail: Media.hasPlayer ? [Media.artist, Media.hasProgress ? `${Format.clock(Media.position)} / ${Format.clock(Media.length)}` : ""].filter(each => each !== "").join(" · ") : "Nothing plays"
		level: Media.hasProgress ? Media.position / Media.length : -1
		tone: Media.playing ? "accent" : "muted"
		busy: Media.playing
		quiet: true
		hint: "Click: play or pause · wheel: player volume"
		act: screen => Media.player?.togglePlaying()
		wheel: up => {
			if (Media.player) Media.player.volume = Math.max(0, Math.min(1, Number(Media.player.volume ?? 1) + (up ? 0.05 : -0.05)));
		}
	}

	FileView {
		id: file

		path: Paths.stateFile("live.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(file.text() || "{}"));
				root.options = data && typeof data === "object" ? data : {};
			} catch (error) {
				root.options = {};
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}
}
