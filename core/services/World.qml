pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The world grown from what is done in the shell (scripts/world/world.py). It
// is built when wanted and renewed when something changes; what stood before
// stays on screen until the new one is done.
//
// While the window is open it follows the shell: whatever happens is announced
// here with where it happens (`happened`), and the window flies there.
Singleton {
	id: root

	property bool windowOpen: false
	readonly property bool wallpaper: Plugins.on("world-wallpaper")
	readonly property bool windowLoaded: root.windowOpen
	readonly property bool wallpaperLoaded: root.wallpaper
	readonly property bool windowVisible: root.windowOpen
	readonly property bool wallpaperVisible: root.wallpaper
	readonly property bool wanted: root.windowOpen || root.wallpaper
	// world.json of the shown world; null until there is one
	property var scene: null
	property string folder: ""
	property string pickedDay: ""
	readonly property bool building: builder.running
	property string error: ""
	property real loadedAt: Date.now()
	property real now: Date.now()

	// what only shows while it goes on
	readonly property bool liveMusic: Plugins.on("media") && Media.playing
	readonly property bool liveAgents: Plugins.on("agents") && Object.keys(Agents.busy).length > 0
	readonly property bool liveLetters: Plugins.on("messages") && root.unread > 0
	readonly property int unread: Plugins.on("mail") ? Mail.unread : 0

	// the plot the timer runs on, and what it is building there
	readonly property var activePlot: {
		if (!Plugins.on("qtrack") || !QtrackTimer.tracking) return null;
		return (root.scene?.plots ?? []).find(plot => plot.project === QtrackTimer.project && plot.description === QtrackTimer.description) ?? null;
	}
	readonly property var activeSite: root.activePlot?.site ?? null
	readonly property real siteProgress: {
		const site = root.activeSite;
		if (!site) return 0;
		const minutes = site.credit + (root.now - root.loadedAt) / 60000;
		return (minutes % site.unit) / site.unit;
	}

	signal playRequested
	// something changed in the shell: a place and a word about it
	signal happened(real x, real z, string text)

	function show() {
		root.windowOpen = true;
		root.error = "";
	}

	function hide() {
		root.windowOpen = false;
		root.pickedDay = "";
	}

	function pick(day) {
		root.pickedDay = String(day || "");
	}

	function refresh() {
		if (!builder.running) builder.running = true;
		else root.stale = true;
	}
	property bool stale: false

	// the world begins again today; nothing from before counts
	function restart() {
		root.restartNext = true;
		if (builder.running) root.stale = true;
		else builder.running = true;
	}
	property bool restartNext: false

	function open(folder) {
		const next = String(folder || "").trim();
		if (next === "" || next === root.folder) return;
		loader.command = ["cat", `${next}/world.json`];
		loader.folder = next;
		loader.running = true;
	}

	function spot(name) {
		return root.scene?.spots?.[name] ?? root.scene?.spots?.capital ?? null;
	}

	// shown only while the window is there to see it
	function announce(name, text, place) {
		if (!root.windowOpen || !root.scene) return;
		const at = place ?? root.spot(name);
		if (at) root.happened(at[0], at[1], text);
	}

	// a change that adds to the world: it is built anew a moment later
	function grow() {
		if (root.wanted) growDelay.restart();
	}

	onWantedChanged: {
		if (root.wanted) {
			current.reload();
			root.refresh();
		} else {
			root.scene = null;
			root.folder = "";
		}
	}

	Component.onCompleted: if (root.wanted) {
		current.reload();
		root.refresh();
	}

	// new shell colours paint the world anew
	Connections {
		target: WorldPalette
		function onShellChanged() {
			root.grow();
		}
	}

	Timer {
		id: growDelay

		interval: 20000
		onTriggered: root.refresh()
	}

	Timer {
		interval: 5000
		repeat: true
		running: root.activeSite !== null
		onTriggered: root.now = Date.now()
	}

	FileView {
		id: current

		path: `${Paths.cache}/world/current`
		printErrors: false
		onLoaded: if (root.wanted && root.scene === null) root.open(current.text())
	}

	Process {
		id: builder

		command: ["nice", "-n", "15", "python3", `${Paths.scripts}/world/world.py`, "--palette", JSON.stringify({ shell: WorldPalette.shell.map(color => String(color)), primary: String(Theme.primary) }), ...(root.restartNext ? ["--restart"] : [])]
		stdout: StdioCollector { onStreamFinished: if (root.wanted) root.open(text) }
		stderr: StdioCollector { id: complaints }
		onRunningChanged: if (running) root.restartNext = false
		onExited: exitCode => {
			if (exitCode !== 0) root.error = complaints.text.trim().split("\n").pop() || "World failed";
			if (root.stale) {
				root.stale = false;
				root.refresh();
			}
		}
	}

	Process {
		id: loader

		property string folder: ""

		stdout: StdioCollector {
			onStreamFinished: {
				if (!root.wanted) return;
				try {
					const fresh = JSON.parse(text);
					const before = root.scene;
					root.scene = fresh;
					root.folder = loader.folder;
					root.loadedAt = Date.now();
					root.now = root.loadedAt;
					root.announceNew(before, fresh);
				} catch (error) {
					root.error = "World failed";
				}
			}
		}
	}

	// the new day's work lands where it was done
	function announceNew(before, fresh) {
		if (!before) return;
		const a = before.totals, b = fresh.totals;
		const houses = b.houses - a.houses, trees = b.trees - a.trees, water = b.water - a.water;
		const parts = [];
		if (houses > 0) parts.push(`${houses} ${houses === 1 ? "house" : "houses"}`);
		if (trees > 0) parts.push(`${trees} ${trees === 1 ? "tree" : "trees"}`);
		if (water > 0) parts.push(`${water * 250} ml water`);
		const last = fresh.days[fresh.days.length - 1];
		if (parts.length > 0 && last) root.announce("capital", parts.join(" · "), last.focus);
	}

	Timer {
		interval: 10 * 60 * 1000
		repeat: true
		running: root.wanted
		onTriggered: root.refresh()
	}

	// ── what happens in the shell ─────────────────────────────────────────
	Connections {
		target: Plugins.on("qtrack") ? QtrackTimer : null
		function onTrackingChanged() {
			if (QtrackTimer.tracking) {
				const plot = root.activePlot;
				if (plot) root.announce("capital", plot.name, [plot.site?.x ?? plot.x, plot.site?.z ?? plot.z]);
			} else {
				root.grow();
			}
		}
		function onDescriptionChanged() {
			const plot = root.activePlot;
			if (plot) root.announce("capital", plot.name, [plot.site?.x ?? plot.x, plot.site?.z ?? plot.z]);
		}
	}

	Connections {
		target: Plugins.on("breaks") ? Breaks : null
		function onWaterMlChanged() {
			root.announce("water", `${(Breaks.waterMl / 1000).toFixed(2)} l water`);
			root.grow();
		}
		function onTodayEntryChanged() {
			const breaks = Breaks.todayEntry.breaks || 0;
			if (breaks !== root.breaksSeen) {
				const more = root.breaksSeen >= 0 && breaks > root.breaksSeen;
				root.breaksSeen = breaks;
				if (more) {
					root.announce("rest", `Pause ${breaks}`);
					root.grow();
				}
			}
		}
	}
	property int breaksSeen: -1

	Connections {
		target: Plugins.on("media") ? Media : null
		function onPlayingChanged() {
			if (Media.playing) root.announce("tavern", String(Media.title || ""));
		}
	}

	Connections {
		target: Plugins.on("agents") ? Agents : null
		function onBusyChanged() {
			const count = Object.keys(Agents.busy).length;
			if (count > root.agentsSeen) root.announce("capital", `${count} Agent${count === 1 ? "" : "en"}`, root.activeSite ? [root.activeSite.x, root.activeSite.z] : null);
			root.agentsSeen = count;
		}
	}
	property int agentsSeen: 0

	onUnreadChanged: {
		if (root.unread > root.unreadSeen && root.unreadSeen >= 0) root.announce("letters", `${root.unread} ungelesen`);
		root.unreadSeen = root.unread;
	}
	property int unreadSeen: -1

	Connections {
		target: Plugins.on("downloads") ? Downloads : null
		function onFinished(item) {
			root.announce("capital", String(item?.name ?? item?.filename ?? "Download"));
			root.grow();
		}
	}

	Connections {
		target: Plugins.on("todos") ? Todos : null
		function onOpenTasksChanged() {
			const open = Todos.openTasks.length;
			if (root.todosSeen >= 0 && open !== root.todosSeen) {
				root.announce("capital", `${open} offen`);
				root.grow();
			}
			root.todosSeen = open;
		}
	}
	property int todosSeen: -1

	// a finished focus block builds, a pause grows the forest
	Connections {
		target: Plugins.on("screentime") ? Screentime : null
		function onBlockClosed(block) {
			root.announce("capital", `${block[1]} min ${block[3]}`);
			root.grow();
		}
		function onPauseEnded(pause) {
			root.announce("rest", `${pause[1]} min away`);
			root.grow();
		}
	}

	Connections {
		target: Plugins.on("games") ? Games : null
		function onRunningChanged() {
			if (Games.running.length > 0) root.announce("games", String(Games.running[0]?.name ?? "Spiel"));
			else root.grow();
		}
	}

	Connections {
		target: Plugins.on("weather") ? Weather : null
		function onIconChanged() {
			root.announce("capital", String(Weather.description || ""));
		}
	}
}
