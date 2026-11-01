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
		// shown somewhere (Live.hold): only then it reads its service, so a
		// source nobody shows neither wakes a service nor costs anything
		readonly property bool on: root.held(key) && root.pluginOn(plugin)
		// the plugin is on and there is something to show at all (known while on)
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
		text: cpu.on ? (root.percent(SysStats.cpu)) : ""
		detail: cpu.on ? (SysStats.cpuText !== "" ? `${SysStats.cpuText} · ${Math.round(SysStats.cpu)}% busy` : `${Math.round(SysStats.cpu)}% busy`) : ""
		level: cpu.on ? (SysStats.cpu / 100) : -1
		history: cpu.on ? (SysStats.cpuHistory) : null
		maximum: 100
		tone: cpu.on ? (SysStats.cpu > 90 ? "bad" : (SysStats.cpu > 70 ? "warn" : "normal")) : "normal"
		busy: cpu.on ? (SysStats.cpu > 25) : false
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
		text: memory.on ? (root.percent(SysStats.memory)) : ""
		detail: memory.on ? (SysStats.memoryText) : ""
		level: memory.on ? (SysStats.memory / 100) : -1
		history: memory.on ? (SysStats.memoryHistory) : null
		maximum: 100
		tone: memory.on ? (SysStats.memory > 90 ? "bad" : (SysStats.memory > 75 ? "warn" : "normal")) : "normal"
		busy: memory.on ? (SysStats.memory > 60) : false
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
		glyph: network.on ? (Network.icon || "wifi") : "wifi"
		group: "system"
		plugin: "network"
		about: "What comes in right now, and what goes out"
		text: network.on ? (Network.online ? Format.rate(Network.download) : "Offline") : ""
		detail: network.on ? (Network.online ? `${Network.label}${Network.ssid !== "" ? ` · ${Network.ssid}` : ""} · ↓ ${Format.rate(Network.download)} · ↑ ${Format.rate(Network.upload)}` : "No connection") : ""
		history: network.on ? (Network.online ? Network.downloadHistory : null) : null
		tone: network.on ? (Network.online ? (Network.download > 1048576 ? "accent" : "normal") : "bad") : "normal"
		busy: network.on ? (!Network.online || Network.download > 262144 || Network.upload > 262144) : false
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
		glyph: battery.on ? (SysStats.batteryIcon) : "battery"
		group: "system"
		plugin: "battery"
		about: "The laptop's charge"
		ready: battery.on ? (SysStats.batteryAvailable) : false
		text: battery.on ? (`${SysStats.batteryPercent}%`) : ""
		detail: battery.on ? (SysStats.charging ? "Charging" : (SysStats.charged ? "Full" : `${SysStats.batteryPercent}% left`)) : ""
		level: battery.on ? (SysStats.batteryPercent / 100) : -1
		tone: battery.on ? (SysStats.charging ? "good" : (SysStats.batteryPercent <= 10 ? "bad" : (SysStats.batteryPercent <= 25 ? "warn" : "normal"))) : "normal"
		pulse: battery.on ? (!SysStats.charging && SysStats.batteryPercent <= 10) : false
		busy: battery.on ? (SysStats.charging || SysStats.batteryPercent <= 30) : false
		panel: "control"
		page: "power"
	}

	Source {
		id: volume

		key: "volume"
		prefers: "ring"
		widest: "100%"
		name: "Volume"
		glyph: volume.on ? (Audio.icon) : "volume_high"
		group: "system"
		about: "Loudness of the output; the wheel turns it"
		text: volume.on ? (Audio.muted ? "Muted" : root.percent(Audio.volume * 100)) : ""
		detail: volume.on ? (Audio.sinkName) : ""
		level: volume.on ? (Audio.muted ? 0 : Math.min(1, Audio.volume)) : -1
		tone: volume.on ? (Audio.muted ? "muted" : (Audio.volume > 1 ? "warn" : "normal")) : "normal"
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
		glyph: mic.on ? (Audio.micIcon) : "microphone"
		group: "system"
		about: "Whether the microphone hears you; a click mutes it"
		text: mic.on ? (Audio.micMuted ? "Muted" : root.percent(Audio.micVolume * 100)) : ""
		detail: mic.on ? (Audio.micMuted ? "Nobody hears you" : "The microphone is open") : ""
		level: mic.on ? (Audio.micMuted ? 0 : Math.min(1, Audio.micVolume)) : -1
		tone: mic.on ? (Audio.micMuted ? "muted" : "accent") : "normal"
		busy: mic.on ? (!Audio.micMuted) : false
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
		ready: brightness.on ? (Brightness.available) : false
		text: brightness.on ? (root.percent(Brightness.value * 100)) : ""
		level: brightness.on ? (Brightness.value) : -1
		busy: false
		hint: "Wheel: brighter or darker"
		wheel: up => Brightness.set(Math.max(0.01, Math.min(1, Brightness.value + (up ? 0.05 : -0.05))))
	}

	Source {
		id: power

		key: "power"
		name: "Power profile"
		glyph: power.on ? (PowerProfile.icons[PowerProfile.current] ?? "scale_balance") : "scale_balance"
		group: "system"
		plugin: "power-profiles"
		about: "Saver, balanced or performance; a click goes to the next"
		ready: power.on ? (PowerProfile.available) : false
		text: power.on ? (PowerProfile.labels[PowerProfile.current] ?? "") : ""
		tone: power.on ? (PowerProfile.current === "performance" ? "warn" : (PowerProfile.current === "power-saver" ? "good" : "normal")) : "normal"
		busy: power.on ? (PowerProfile.current !== "balanced") : false
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
		glyph: bluetooth.on ? (Bluetooth.icon) : "bluetooth"
		group: "system"
		plugin: "bluetooth"
		about: "What is connected"
		ready: bluetooth.on ? (Bluetooth.available) : false
		text: bluetooth.on ? (Bluetooth.connected.length > 0 ? (Bluetooth.connected.length === 1 ? String(Bluetooth.connected[0].name ?? "1") : `${Bluetooth.connected.length}`) : (Bluetooth.powered ? "On" : "Off")) : ""
		detail: bluetooth.on ? (Bluetooth.summary) : ""
		tone: bluetooth.on ? (Bluetooth.connected.length > 0 ? "accent" : (Bluetooth.powered ? "normal" : "muted")) : "normal"
		busy: bluetooth.on ? (Bluetooth.connected.length > 0) : false
		panel: "control"
		page: "bluetooth"
	}

	// ── the shell at work ───────────────────────────────────────────────
	Source {
		id: notifications

		readonly property bool urgent: notifications.on ? (Notifs.groups.some(group => Number(group.urgency ?? 0) === 2)) : false

		key: "notifications"
		name: "Notifications"
		glyph: notifications.on ? (Notifs.dnd ? "bell_off_outline" : (Notifs.count > 0 ? "bell_badge_outline" : "bell_outline")) : "bell_outline"
		group: "shell"
		plugin: "notifications"
		about: "How many wait; quiet while do not disturb is on"
		text: notifications.on ? (Notifs.count > 0 ? `${Notifs.count}` : (Notifs.dnd ? "Quiet" : "0")) : ""
		detail: notifications.on ? (Notifs.dnd ? `Do not disturb${Notifs.dndReason ? ` · ${Notifs.dndReason}` : ""}` : (Notifs.count > 0 ? `${Notifs.count} waiting` : "Nothing new")) : ""
		tone: notifications.on ? (notifications.urgent ? "bad" : (Notifs.dnd ? "muted" : (Notifs.count > 0 ? "accent" : "normal"))) : "normal"
		pulse: notifications.on ? (notifications.urgent) : false
		busy: notifications.on ? (Notifs.count > 0 || Notifs.dnd) : false
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
		text: messages.on ? (`${Messages.unread}`) : ""
		detail: messages.on ? (Messages.unread > 0 ? `${Messages.unread} unread` : "All read") : ""
		tone: messages.on ? (Messages.unread > 0 ? "accent" : "muted") : "normal"
		busy: messages.on ? (Messages.unread > 0) : false
		quiet: true
		act: screen => Messages.toggle()
	}

	Source {
		id: updates

		key: "updates"
		name: "Updates"
		glyph: updates.on ? (Updates.running ? "progress_download" : "package_up") : "package_up"
		group: "shell"
		plugin: "updates"
		about: "Pending packages, and the upgrade while it runs"
		text: updates.on ? (Updates.running ? root.percent(Updates.progress * 100) : `${Updates.packages.length}`) : ""
		detail: updates.on ? (Updates.running ? (Updates.progressLabel || "Upgrading") : (Updates.packages.length > 0 ? `${Updates.packages.length} packages to update${Updates.rebootNeeded ? " · restart pending" : ""}` : (Updates.rebootNeeded ? "Restart to use the new kernel" : "Up to date"))) : ""
		level: updates.on ? (Updates.running ? Updates.progress : -1) : -1
		tone: updates.on ? (Updates.rebootNeeded ? "warn" : (Updates.packages.length >= Updates.remindAt ? "warn" : (Updates.packages.length > 0 ? "accent" : "good"))) : "normal"
		pulse: updates.on ? (Updates.running) : false
		busy: updates.on ? (Updates.running || Updates.packages.length > 0 || Updates.rebootNeeded) : false
		quiet: true
		panel: "updates"
	}

	Source {
		id: downloads

		key: "downloads"
		prefers: "ring"
		widest: "88.8 MB/s"
		name: "Downloads"
		glyph: downloads.on ? (Downloads.phase === "done" ? "check_circle" : "download") : "download"
		group: "shell"
		plugin: "downloads"
		about: "The browsers' downloads: how far, how fast"
		text: downloads.on ? (Downloads.phase === "running" ? Format.rate(Downloads.speed) : (Downloads.phase === "paused" ? "Paused" : (Downloads.phase === "done" ? "Done" : "–"))) : ""
		detail: downloads.on ? (Downloads.active.length > 0 ? `${Downloads.active.length} ${Downloads.active.length === 1 ? "file" : "files"}${Downloads.ratio >= 0 ? ` · ${Math.floor(Downloads.ratio * 100)}%` : ""}${Downloads.eta >= 0 ? ` · ${Downloads.formatEta(Downloads.eta)} left` : ""}` : "Nothing comes in") : ""
		level: downloads.on ? (Downloads.phase === "done" ? 1 : Math.max(-1, Downloads.ratio)) : -1
		tone: downloads.on ? (Downloads.phase === "done" ? "good" : (Downloads.phase === "paused" ? "muted" : "accent")) : "normal"
		pulse: downloads.on ? (Downloads.phase === "running") : false
		busy: downloads.on ? (Downloads.phase !== "idle") : false
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
		text: torrents.on ? (Torrents.running.length > 0 ? Format.rate(Torrents.down) : "Idle") : ""
		detail: torrents.on ? (Torrents.running.length > 0 ? `${Torrents.running.length} running · ↓ ${Format.rate(Torrents.down)} · ↑ ${Format.rate(Torrents.up)}` : `${Torrents.torrents.length} torrents`) : ""
		level: torrents.on ? (Torrents.running.length > 0 ? Math.max(0, Torrents.ratio) : -1) : -1
		history: torrents.on ? (Torrents.running.length > 0 && Torrents.live.length > 1 ? Torrents.live.slice(-30).map(pair => Number(pair[0]) || 0) : null) : null
		tone: torrents.on ? (Torrents.running.length > 0 ? "accent" : "muted") : "normal"
		pulse: torrents.on ? (Torrents.running.length > 0 && Torrents.down > 0) : false
		busy: torrents.on ? (Torrents.running.length > 0) : false
		quiet: true
		act: screen => Torrents.toggle()
	}

	Source {
		id: filejobs

		readonly property var jobs: filejobs.on ? (Files.activeJobs.filter(job => Number(job.elapsed) > 1.2 && !["rename", "mkdir", "newfile", "batchrename", "link"].includes(job.kind))) : []
		readonly property real ratio: {
			if (!filejobs.on) return -1;
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
		text: filejobs.on ? (filejobs.jobs.some(job => job.state === "conflict") ? "Asks" : (filejobs.ratio >= 0 ? root.percent(filejobs.ratio * 100) : `${filejobs.jobs.length}`)) : ""
		detail: filejobs.on ? (filejobs.jobs.length > 0 ? `${filejobs.jobs.length} ${filejobs.jobs.length === 1 ? "job" : "jobs"} running` : "Nothing runs") : ""
		level: filejobs.on ? (filejobs.jobs.length > 0 ? filejobs.ratio : -1) : -1
		tone: filejobs.on ? (filejobs.jobs.some(job => job.state === "conflict") ? "warn" : "accent") : "normal"
		pulse: filejobs.on ? (filejobs.jobs.some(job => job.state === "conflict")) : false
		busy: filejobs.on ? (filejobs.jobs.length > 0) : false
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
		text: recording.on ? (Recorder.active ? Recorder.elapsed : "Off") : ""
		detail: recording.on ? (Recorder.active ? `Recording for ${Recorder.elapsed}` : "Not recording") : ""
		tone: recording.on ? (Recorder.active ? "bad" : "muted") : "normal"
		pulse: recording.on ? (Recorder.active) : false
		busy: recording.on ? (Recorder.active) : false
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
		text: sharing.on ? (Notifs.sharing ? "Shared" : "Private") : ""
		detail: sharing.on ? (Notifs.sharing ? "An app sees your screen" : "Nobody sees your screen") : ""
		tone: sharing.on ? (Notifs.sharing ? "bad" : "muted") : "normal"
		pulse: sharing.on ? (Notifs.sharing) : false
		busy: sharing.on ? (Notifs.sharing) : false
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
		text: gamemode.on ? (GameMode.active ? (GameMode.title !== "" ? GameMode.title : "On") : "Off") : ""
		detail: gamemode.on ? (GameMode.active ? `Game mode${GameMode.force === "on" ? " (forced)" : ""}` : (GameMode.force === "off" ? "Kept off" : "Follows the games")) : ""
		tone: gamemode.on ? (GameMode.active ? "good" : "muted") : "normal"
		busy: gamemode.on ? (GameMode.active) : false
		quiet: true
		hint: "Click: force on or off"
		act: screen => GameMode.setForce(GameMode.active ? (GameMode.force === "on" ? "auto" : "off") : (GameMode.force === "off" ? "auto" : "on"))
	}

	Source {
		id: agents

		readonly property int count: agents.on ? (Object.keys(Agents.busy ?? {}).length) : 0

		key: "agents"
		name: "AI agents"
		glyph: "robot_outline"
		group: "shell"
		plugin: "agents"
		about: "Coding agents that are working"
		text: agents.on ? (agents.count > 0 ? `${agents.count} working` : "Idle") : ""
		detail: agents.on ? (agents.count > 0 ? `${agents.count} ${agents.count === 1 ? "agent works" : "agents work"} in a terminal` : "No agent works") : ""
		tone: agents.on ? (agents.count > 0 ? "accent" : "muted") : "normal"
		pulse: agents.on ? (agents.count > 0) : false
		busy: agents.on ? (agents.count > 0) : false
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
		text: keepawake.on ? (KeepAwake.active ? "Awake" : "Off") : ""
		tone: keepawake.on ? (KeepAwake.active ? "warn" : "muted") : "normal"
		busy: keepawake.on ? (KeepAwake.active) : false
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
		text: clipboard.on ? (`${Clipboard.entries.length}`) : ""
		detail: clipboard.on ? (`${Clipboard.entries.length} entries`) : ""
		busy: false
		panel: "clipboard"
	}

	Source {
		id: shelf

		readonly property int count: shelf.on ? (Shelf.shelves.reduce((sum, each) => sum + (each.items?.length ?? 0), 0)) : 0

		key: "shelf"
		name: "Shelves"
		glyph: "tray_full"
		group: "shell"
		plugin: "shelves"
		about: "Files waiting on the shelves"
		text: shelf.on ? (`${shelf.count}`) : ""
		detail: shelf.on ? (`${shelf.count} ${shelf.count === 1 ? "file" : "files"} on ${Shelf.shelves.length} ${Shelf.shelves.length === 1 ? "shelf" : "shelves"}`) : ""
		tone: shelf.on ? (shelf.count > 0 ? "accent" : "muted") : "normal"
		busy: shelf.on ? (shelf.count > 0) : false
		quiet: true
	}

	// ── the day ─────────────────────────────────────────────────────────
	Source {
		id: timer

		key: "timer"
		widest: "0:00:00"
		name: "Timer"
		glyph: timer.on ? (QtrackTimer.paused ? "timer_sand" : "timer_outline") : "timer_outline"
		group: "day"
		plugin: "qtrack"
		about: "The running qtrack timer"
		text: timer.on ? (QtrackTimer.tracking ? QtrackTimer.duration : "Idle") : ""
		detail: timer.on ? (QtrackTimer.tracking ? [QtrackTimer.project, QtrackTimer.description].filter(each => each !== "").join(" · ") || "Tracking" : "No timer runs") : ""
		tone: timer.on ? (QtrackTimer.tracking ? (QtrackTimer.paused ? "warn" : "accent") : "muted") : "normal"
		pulse: timer.on ? (QtrackTimer.paused) : false
		busy: timer.on ? (QtrackTimer.tracking) : false
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
		text: worked.on ? (root.minutes(QtrackTimer.todayLive)) : ""
		detail: worked.on ? (`${root.minutes(QtrackTimer.todayLive)} of 8 h`) : ""
		level: worked.on ? (Math.min(1, QtrackTimer.todayLive / (8 * 3600))) : -1
		tone: worked.on ? (QtrackTimer.todayLive >= 8 * 3600 ? "good" : "normal") : "normal"
		busy: worked.on ? (QtrackTimer.tracking) : false
		panel: "tracking"
	}

	Source {
		id: screentime

		readonly property real seconds: {
			if (!screentime.on) return 0;
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
		text: screentime.on ? (root.minutes(screentime.seconds)) : ""
		detail: screentime.on ? (`${root.minutes(screentime.seconds)} today`) : ""
		level: screentime.on ? (Math.min(1, screentime.seconds / (10 * 3600))) : -1
		tone: screentime.on ? (screentime.seconds > 10 * 3600 ? "warn" : "normal") : "normal"
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
		text: water.on ? (Breaks.formatLitres(Breaks.waterMl)) : ""
		detail: water.on ? (`${Breaks.formatLitres(Breaks.waterMl)} of ${Breaks.formatLitres(Breaks.goalMl)}`) : ""
		level: water.on ? (Math.min(1, Breaks.waterMl / Breaks.goalMl)) : -1
		tone: water.on ? (Breaks.waterMl >= Breaks.goalMl ? "good" : (Breaks.waterMl < Breaks.paceMl * 0.6 ? "warn" : "accent")) : "normal"
		busy: water.on ? (Breaks.waterMl < Breaks.goalMl) : false
		panel: "breaks"
	}

	Source {
		id: eyes

		readonly property int left: eyes.on ? (Math.max(0, Breaks.eyesSeconds - Breaks.sinceEyes)) : 0

		key: "eyes"
		prefers: "ring"
		name: "Eye rest"
		glyph: "eye_outline"
		group: "day"
		plugin: "eye-rest"
		about: "How long until the next look into the distance"
		text: eyes.on ? (eyes.left > 0 ? root.minutes(eyes.left) : "Now") : ""
		detail: eyes.on ? (eyes.left > 0 ? `Next eye rest in ${root.minutes(eyes.left)}` : "Time to look away for 20 seconds") : ""
		level: eyes.on ? (1 - eyes.left / Breaks.eyesSeconds) : -1
		tone: eyes.on ? (eyes.left <= 0 ? "warn" : (eyes.left < 120 ? "accent" : "normal")) : "normal"
		pulse: eyes.on ? (eyes.left <= 0) : false
		busy: eyes.on ? (eyes.left < 300) : false
		panel: "breaks"
	}

	Source {
		id: meeting

		readonly property var today: {
			if (!meeting.on) return [];
			const key = MsCalendar.dayKey(new Date(root.now));
			return (MsCalendar.byDay[key] ?? []).filter(event => !event.allDay && MsCalendar.active(event) && event.showAs !== "free");
		}
		readonly property var current: meeting.on ? (meeting.today.find(event => Date.parse(event.start) <= root.now && root.now < Date.parse(event.end)) ?? null) : null
		readonly property var next: meeting.on ? (meeting.today.filter(event => Date.parse(event.start) > root.now).sort((a, b) => Date.parse(a.start) - Date.parse(b.start))[0] ?? null) : null
		readonly property real until: meeting.on ? (meeting.next ? (Date.parse(meeting.next.start) - root.now) / 1000 : -1) : 0

		key: "meeting"
		name: "Meetings"
		glyph: meeting.on ? (meeting.current ? "account_group" : "calendar_clock") : "calendar_clock"
		group: "day"
		plugin: "microsoft-calendar"
		about: "The meeting now, or how long until the next"
		ready: meeting.on ? (MsCalendar.signedIn) : false
		text: meeting.on ? (meeting.current ? "Now" : (meeting.next ? `in ${root.minutes(meeting.until)}` : "Free")) : ""
		detail: meeting.on ? (meeting.current ? `${meeting.current.subject} · until ${Qt.formatTime(new Date(meeting.current.end), "HH:mm")}` : (meeting.next ? `${meeting.next.subject} · ${Qt.formatTime(new Date(meeting.next.start), "HH:mm")}` : "Nothing more today")) : ""
		level: meeting.on ? (meeting.current ? (root.now - Date.parse(meeting.current.start)) / Math.max(1, Date.parse(meeting.current.end) - Date.parse(meeting.current.start)) : -1) : -1
		tone: meeting.on ? (meeting.current ? "accent" : (meeting.next && meeting.until < 600 ? "warn" : "normal")) : "normal"
		pulse: meeting.on ? (!!meeting.next && meeting.until < 300 && !meeting.current) : false
		busy: meeting.on ? (!!meeting.current || (!!meeting.next && meeting.until < 3600)) : false
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
		text: todos.on ? (`${Todos.openTasks.length}`) : ""
		detail: todos.on ? (`${Todos.openTasks.length} open of ${Todos.tasks.length}`) : ""
		level: todos.on ? (Todos.tasks.length > 0 ? 1 - Todos.openTasks.length / Todos.tasks.length : -1) : -1
		tone: todos.on ? (Todos.openTasks.length > 0 ? "normal" : "good") : "normal"
		busy: todos.on ? (Todos.openTasks.length > 0) : false
		act: screen => Popups.open("launcher", screen ?? Popups.focusedScreen(), "", ">todo ")
	}

	Source {
		id: weather

		key: "weather"
		name: "Weather"
		glyph: weather.on ? (Weather.icon || "weather_partly_cloudy") : "weather_partly_cloudy"
		group: "day"
		plugin: "weather"
		about: "The temperature outside"
		ready: weather.on ? (Weather.available) : false
		text: weather.on ? (Weather.temperature) : ""
		detail: weather.on ? (`${Weather.description}${Weather.location !== "" ? ` · ${Weather.location}` : ""} · feels ${Weather.feelsLike}`) : ""
		busy: false
		panel: "today"
	}

	// ── devices ─────────────────────────────────────────────────────────
	Source {
		id: phone

		key: "phone"
		prefers: "ring"
		name: "Phone"
		glyph: phone.on ? (Phone.reachable ? Phone.batteryIcon : "cellphone_off") : "cellphone"
		group: "devices"
		plugin: "phone"
		about: "The phone's battery and whether it is near"
		ready: phone.on ? (Phone.paired) : false
		text: phone.on ? (Phone.reachable && Phone.battery >= 0 ? `${Phone.battery}%` : "Away") : ""
		detail: phone.on ? (Phone.reachable ? `${Phone.name}${Phone.charging ? " · charging" : ""}${Phone.network !== "" ? ` · ${Phone.network}` : ""}` : `${Phone.name} is not reachable`) : ""
		level: phone.on ? (Phone.reachable && Phone.battery >= 0 ? Phone.battery / 100 : -1) : -1
		tone: phone.on ? (!Phone.reachable ? "muted" : (Phone.charging ? "good" : (Phone.battery <= 15 ? "bad" : "normal"))) : "normal"
		busy: phone.on ? (Phone.reachable) : false
		panel: "control"
		page: "phone"
	}

	Source {
		id: watch

		readonly property var day: watch.on ? (Watch.days.length > 0 ? Watch.days[Watch.days.length - 1] : null) : null

		key: "watch"
		prefers: "ring"
		name: "Watch"
		glyph: "watch"
		group: "devices"
		plugin: "watch"
		about: "Steps today and the watch's battery"
		ready: watch.on ? (Watch.paired || Watch.known) : false
		text: watch.on ? (watch.day ? `${Number(watch.day.steps ?? 0).toLocaleString(Qt.locale(), "f", 0)}` : (Watch.battery >= 0 ? `${Watch.battery}%` : "–")) : ""
		detail: watch.on ? (`${Watch.name}${Watch.battery >= 0 ? ` · ${Watch.battery}%` : ""}${watch.day ? ` · ${watch.day.steps ?? 0} of ${watch.day.stepsGoal ?? 8000} steps` : ""}`) : ""
		level: watch.on ? (watch.day ? Math.min(1, Number(watch.day.steps ?? 0) / Math.max(1, Number(watch.day.stepsGoal ?? 8000))) : -1) : -1
		tone: watch.on ? (watch.day && Number(watch.day.steps ?? 0) >= Number(watch.day.stepsGoal ?? 8000) ? "good" : (Watch.connected ? "normal" : "muted")) : "normal"
		busy: watch.on ? (Watch.connected) : false
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
		ready: mouse.on ? (SysStats.mouseFound) : false
		text: mouse.on ? (SysStats.mouseText) : ""
		detail: mouse.on ? (`${SysStats.mouseName}${SysStats.mouseStatus !== "" ? ` · ${SysStats.mouseStatus}` : ""}`) : ""
		level: mouse.on ? (SysStats.mouseLevel) : -1
		tone: mouse.on ? (SysStats.mouseLevel <= 0.1 ? "bad" : (SysStats.mouseLevel <= 0.2 ? "warn" : "normal")) : "normal"
		pulse: mouse.on ? (SysStats.mouseLevel <= 0.1) : false
		busy: mouse.on ? (SysStats.mouseLevel <= 0.3) : false
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
		text: printer.on ? (Printer.printing ? (Printer.paused ? "Paused" : root.percent(Printer.progress * 100)) : (Printer.online ? "Ready" : "Off")) : ""
		detail: printer.on ? (Printer.printing ? `Layer ${Printer.layer} of ${Printer.layers} · ${root.minutes(Printer.secondsLeft)} left` : (Printer.online ? "Waits for a print" : "Not reachable")) : ""
		level: printer.on ? (Printer.printing ? Printer.progress : -1) : -1
		tone: printer.on ? (Printer.printing ? (Printer.paused ? "warn" : "accent") : (Printer.online ? "normal" : "muted")) : "normal"
		pulse: printer.on ? (Printer.paused) : false
		busy: printer.on ? (Printer.printing) : false
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
		text: vm.on ? (Machines.launching ? "Starting" : (Machines.lgOpen ? "Running" : "Off")) : ""
		detail: vm.on ? (Machines.launching ? `Starting · ${Machines.step}` : (Machines.lgOpen ? "Looking Glass is open" : "Not running")) : ""
		level: vm.on ? (Machines.launching ? (Machines.steps.indexOf(Machines.step) + 1) / (Machines.steps.length + 1) : -1) : -1
		tone: vm.on ? (Machines.launching ? "accent" : (Machines.lgOpen ? "good" : "muted")) : "normal"
		pulse: vm.on ? (Machines.launching) : false
		busy: vm.on ? (Machines.launching || Machines.lgOpen) : false
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
		ready: pcs.on ? (Pcs.devices.length > 0) : false
		text: pcs.on ? (Pcs.transfers.length > 0 ? `${Pcs.transfers.length} on the way` : `${Pcs.reachable.length}`) : ""
		detail: pcs.on ? (Pcs.reachable.length > 0 ? Pcs.reachable.map(each => each.name ?? "PC").join(", ") : "None reachable") : ""
		tone: pcs.on ? (Pcs.transfers.length > 0 ? "accent" : (Pcs.reachable.length > 0 ? "good" : "muted")) : "normal"
		pulse: pcs.on ? (Pcs.transfers.length > 0) : false
		busy: pcs.on ? (Pcs.reachable.length > 0) : false
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
		text: game.on ? (GameMode.playing ? (GameMode.title !== "" ? GameMode.title : "Playing") : "–") : ""
		detail: game.on ? (GameMode.playing ? `Playing ${GameMode.title}` : "No game runs") : ""
		tone: game.on ? (GameMode.playing ? "good" : "muted") : "normal"
		busy: game.on ? (GameMode.playing) : false
		quiet: true
		act: screen => Popups.toggleModal("games", screen ?? Popups.focusedScreen())
	}

	// ── media ───────────────────────────────────────────────────────────
	Source {
		id: media

		key: "media"
		name: "Now playing"
		glyph: media.on ? (Media.playing ? "music_note" : "pause") : "music_note"
		group: "media"
		plugin: "media"
		about: "Title and progress; a click plays or pauses, the wheel turns it"
		text: media.on ? (Media.hasPlayer ? Media.title : "Silence") : ""
		detail: media.on ? (Media.hasPlayer ? [Media.artist, Media.hasProgress ? `${Format.clock(Media.position)} / ${Format.clock(Media.length)}` : ""].filter(each => each !== "").join(" · ") : "Nothing plays") : ""
		level: media.on ? (Media.hasProgress ? Media.position / Media.length : -1) : -1
		tone: media.on ? (Media.playing ? "accent" : "muted") : "normal"
		busy: media.on ? (Media.playing) : false
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
