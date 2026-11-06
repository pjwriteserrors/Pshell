pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services

// Every IPC target used by keybinds and scripts (`scripts/ipc.sh <target>
// <function>`). Lives in the core so a style can never drop one.
Scope {
	id: root

	// identity of the checked-out style branch, read once per load; a reload
	// that fails keeps the old config and so still reports the old style,
	// which is how scripts/branch_styles.py notices and rolls back
	readonly property string styleId: {
		try {
			return String(JSON.parse(styleManifest.text() || "{}").name || "");
		} catch (error) {
			return "";
		}
	}
	property bool styleSwitching: false

	FileView {
		id: styleManifest

		path: `${Quickshell.shellDir}/.quickshell-style.json`
		blockLoading: true
	}

	IpcHandler {
		target: "styleSession"

		function state(): string {
			return JSON.stringify({
				locked: Session.locked,
				style: root.styleId,
				shellDir: Quickshell.shellDir,
				switching: root.styleSwitching
			});
		}
		function freeze(): void {
			root.styleSwitching = true;
			Quickshell.watchFiles = false;
		}
		function thaw(): void {
			root.styleSwitching = false;
		}
		// never reload from inside the call being answered: the handler is
		// part of the tree that is about to be torn down
		function reload(): void {
			styleReload.restart();
		}
	}

	Timer {
		id: styleReload

		interval: 1
		onTriggered: Quickshell.reload(true)
	}

	function drawerOnFocused(id, page) {
		if (Popups.current === id && (page === undefined || page === "" || Popups.page === page)) {
			Popups.close();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.open(id, screen, page));
	}

	function modalOnFocused(kind) {
		if (Popups.modal === kind) {
			Popups.closeModal();
			return;
		}
		Popups.withFocusedScreen(screen => Popups.openModal(kind, screen));
	}

	IpcHandler {
		target: "launcher"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("launcher", screen));
		}
		function close(): void {
			if (Popups.current === "launcher") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("launcher");
		}
		// opens on a preset query, e.g. ">t guten morgen" or ">todo "
		function search(query: string): void {
			Popups.withFocusedScreen(screen => {
				// reopening applies the query even when the launcher is already up
				if (Popups.current === "launcher") Popups.close();
				Popups.open("launcher", screen, "", query);
			});
		}
	}

	// the window switcher (Alt+Tab). niri's binds call next/prev with the
	// scope (all, others, output, workspace; "" = the setting) and the
	// filter ("app": only windows of the focused app)
	IpcHandler {
		target: "switcher"

		function next(scope: string, filter: string): void {
			if (Plugins.on("window-switcher")) Switcher.step(1, scope, filter);
		}
		function prev(scope: string, filter: string): void {
			if (Plugins.on("window-switcher")) Switcher.step(-1, scope, filter);
		}
		// open without a held key: stays until something is picked
		// (`show` would be taken by `qs ipc` itself)
		function open(): void {
			if (Plugins.on("window-switcher")) Switcher.show("", "");
		}
		function cancel(): void {
			Switcher.cancel();
		}
		function layout(name: string): void {
			Switcher.set("layout", name);
		}
		// shell | niri: whose switcher Alt+Tab opens (writes niri's binds)
		function engine(name: string): void {
			Switcher.useEngine(name, null);
		}
		function status(): string {
			return JSON.stringify({ engine: Switcher.engine, layout: Switcher.layout, open: Switcher.open, shown: Switcher.shown,
				held: Switcher.held, index: Switcher.index, items: Switcher.items.map(item => `${item.id} ${item.appId}`) });
		}
	}

	// the plugin switches (>plugins)
	IpcHandler {
		target: "plugins"

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("plugins", screen));
		}
		function close(): void {
			if (Popups.modal === "plugins") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("plugins");
		}
		function enable(id: string): void {
			Plugins.set(id, true);
		}
		function disable(id: string): void {
			Plugins.set(id, false);
		}
		function isOn(id: string): bool {
			return Plugins.on(id);
		}
		// every plugin that is on, one per line
		function list(): string {
			return Plugins.list.filter(plugin => Plugins.on(plugin.id)).map(plugin => plugin.id).join("\n");
		}
	}

	IpcHandler {
		target: "power"
		enabled: Plugins.on("power-menu")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("power", screen));
		}
		function close(): void {
			if (Popups.modal === "power") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("power");
		}
		// reboot or shutdown once a process is gone: `power after shutdown 1234`
		function after(kind: string, pid: int): void {
			Session.after(kind, { what: "process", pid: pid, start: 0, name: `Process ${pid}` });
		}
		function cancelAfter(): void {
			Session.cancelAfter();
		}
	}

	// the downloads panel; `downloads add <url>` downloads a link through the
	// accelerator (several connections where the server allows them)
	IpcHandler {
		target: "downloads"
		enabled: Plugins.on("downloads")

		function open(): void {
			Downloads.openPanel();
		}
		function toggle(): void {
			Downloads.togglePanel();
		}
		function close(): void {
			Downloads.closePanel();
		}
		function add(url: string): void {
			Boost.add(url);
			Downloads.openPanel();
		}
		function list(): string {
			return JSON.stringify(Downloads.order.map(key => Downloads.table[key]).map(item => ({ key: item.key, name: item.name, state: item.state, mode: item.source === "boost" ? item.mode : (item.source === "torrent" ? "torrent" : "browser"), received: item.received, total: item.total, speed: item.speed, connections: item.connections ?? 1, note: item.note ?? "" })));
		}
		function stats(): string {
			return JSON.stringify(Downloads.stats);
		}
	}

	// what is followed: `streams open`, `streams follow <link>`, `streams next <series name>`
	IpcHandler {
		target: "streams"
		enabled: Plugins.on("streams")

		function open(): void {
			Streams.open();
		}
		function toggle(): void {
			Streams.toggle();
		}
		function close(): void {
			Streams.close();
		}
		function popOut(): void {
			Streams.popOut();
		}
		function dock(): void {
			Streams.dock();
		}
		function page(name: string): void {
			Streams.open({ page: name });
		}
		function tonight(): void {
			Streams.open({ tonight: true });
		}
		function follow(link: string): void {
			Streams.follow(link);
		}
		function series(name: string): void {
			const item = Streams.series.find(entry => entry.name.toLowerCase() === name.toLowerCase());
			if (item) Streams.open({ page: "series", series: item.id });
		}
		// one video and the series it is in
		function video(id: string): void {
			Streams.open({ page: "feed", video: { id: id } });
		}
		// the rule workshop, filled in: {"name", "sources": [ids], "rule": {…}}
		function newSeries(preset: string): void {
			Streams.open({ newSeries: JSON.parse(preset || "{}") });
		}
		function panel(name: string): void {
			Streams.playerPanelWanted = name;
		}
		function book(tab: string): void {
			Streams.bookTabWanted = "";
			Streams.bookTabWanted = tab;
		}
		function mini(): void {
			Streams.playerMini = !Streams.playerMini;
		}
		// the series inside a suggestion
		function parts(name: string): void {
			const item = Streams.discoveries.find(entry => entry.name.toLowerCase() === name.toLowerCase());
			if (item?.parts.length > 0) Streams.open({ parts: { name: item.name, parts: item.parts, whole: item } });
		}
		function next(name: string): void {
			const item = Streams.series.find(entry => entry.name.toLowerCase() === name.toLowerCase());
			if (item) Streams.playNext(item.id);
		}
		function list(): string {
			return JSON.stringify({ live: Streams.liveStreams.map(item => item.name), series: Streams.series.map(item => ({ name: item.name, watched: item.watched, total: item.total, left: item.left })) });
		}
	}

	// the game library: `games add <path>` opens it to add a program
	// the task manager; `taskmgr top` and `taskmgr ports` answer as JSON
	IpcHandler {
		target: "taskmgr"
		enabled: Plugins.on("task-manager")

		function open(): void {
			TaskManager.open();
		}
		function toggle(): void {
			TaskManager.toggle();
		}
		function close(): void {
			TaskManager.close();
		}
		function popOut(): void {
			TaskManager.popOut();
		}
		function dock(): void {
			TaskManager.dock();
		}
		// apps, performance, services, startup, ports or history
		function tab(name: string): void {
			TaskManager.open(name);
		}
		// an app's id, a pid or a row key
		function reveal(what: string): void {
			TaskManager.resolve(what, key => TaskManager.showKey(key));
		}
		function end(what: string): void {
			TaskManager.actOn(what, "end");
		}
		function kill(what: string): void {
			TaskManager.actOn(what, "kill");
		}
		function pause(what: string): void {
			TaskManager.actOn(what, "pause");
		}
		function resume(what: string): void {
			TaskManager.actOn(what, "resume");
		}
		// ends the focused window's app
		function endFocused(): void {
			if (Niri.focusedId >= 0) TaskManager.endWindow(Niri.focusedId);
		}
		function top(): string {
			return JSON.stringify(TaskManager.top.map(item => ({ key: item.key, name: item.name, cpu: item.c, mem: item.m, windows: item.w })));
		}
		function ports(): string {
			return JSON.stringify(TaskManager.lastPorts);
		}
	}

	IpcHandler {
		target: "torrents"
		enabled: Plugins.on("torrents")

		function open(): void {
			Torrents.open();
		}
		function toggle(): void {
			Torrents.toggle();
		}
		function close(): void {
			Torrents.close();
		}
		// under the bar ↔ a window of its own
		function popOut(): void {
			Torrents.popOut();
		}
		function dock(): void {
			Torrents.dock();
		}
		// a magnet link, a .torrent file (path or file://) or a link to one:
		// the window asks where it goes
		function add(uri: string): void {
			Torrents.add(uri);
		}
		// the window on one torrent ("" for all of them)
		function select(hash: string): void {
			Torrents.select(hash);
			Torrents.open();
		}
		function list(): string {
			return JSON.stringify(Torrents.torrents.map(item => ({ hash: item.hash, name: item.name, phase: item.phase, progress: item.progress, eta: item.eta })));
		}
	}

	IpcHandler {
		target: "games"
		enabled: Plugins.on("games")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("games", screen));
		}
		function close(): void {
			if (Popups.modal === "games") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("games");
		}
		function add(path: string): void {
			Popups.withFocusedScreen(screen => {
				Popups.openModal("games", screen);
				Games.addRequested(path);
			});
		}
		function launch(id: string): void {
			Games.launch(id, "");
		}
		// the panel under the bar (games-bar)
		function panel(): void {
			if (Plugins.on("games-bar")) root.drawerOnFocused("gamebar");
			else root.modalOnFocused("games");
		}
		function list(): string {
			return JSON.stringify(Games.games.map(game => ({ id: game.id, name: game.name, kind: game.kind, running: Games.isRunning(game.id) })));
		}
	}

	// the VM launcher: `vm launch win11` starts a machine without the popup
	IpcHandler {
		target: "vm"
		enabled: Plugins.on("vm-launcher")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("vm", screen));
		}
		function close(): void {
			if (Popups.modal === "vm") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("vm");
		}
		function launch(name: string): void {
			Machines.launch(name);
		}
		function shutdown(name: string): void {
			Machines.shutdown(name);
		}
		function status(): string {
			return JSON.stringify({ vms: Machines.vms.map(vm => ({ name: vm.name, state: vm.state })), target: Machines.target, step: Machines.step, failure: Machines.failure, lookingGlass: Machines.lgState });
		}
	}

	// quick actions around the pointer
	// the Logitech mouse: `mouse profile Gaming`, `mouse next`, `mouse rumble games`
	IpcHandler {
		target: "mouse"
		enabled: Plugins.on("mouse")

		// Solaar's settings and rules come over, Solaar stops
		function takeover(): void {
			Mouse.takeOver();
		}
		function open(): void {
			NiriSettings.page = "mouse";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function profile(name: string): bool {
			return Mouse.useProfile(name);
		}
		function next(): void {
			Mouse.nextProfile();
		}
		function profiles(): string {
			return JSON.stringify({ active: Mouse.activeProfile, profiles: Mouse.profiles.map(p => ({ id: p.id, name: p.name, apps: p.apps ?? [], games: p.games === true })) });
		}
		// the rules the page has and the ones the daemon goes by (asked a moment
		// earlier: call twice), for finding out why a button does something else
		function state(): string {
			Mouse.send({ op: "state" });
			return JSON.stringify({ page: Mouse.ruleKeys(), daemon: Mouse.daemonState, active: Mouse.activeProfile, auto: Mouse.autoProfile, focus: Mouse.focusApp });
		}
		// off | games | always
		function rumble(mode: string): void {
			Mouse.setOption("rumble", ["off", "games", "always"].includes(mode) ? mode : "off");
		}
		// the virtual controller of the game haptics: `mouse pad on|off`
		function pad(on: string): void {
			Mouse.setOption("rumblePad", on === "on" || on === "true" || on === "1");
		}
		// game haptics: `mouse feel no` – the sound just felt was not an
		// action, never feel it again; `mouse feel forget` starts the game over
		// `mouse feel record` keeps 2 minutes of the game's sound and presses for tuning
		// draw HUD zones for the game haptics on the real screen (a keybind in the game)
		function hud(): void {
			Mouse.hudDraw();
		}
		function feel(what: string): void {
			if (what === "forget") Mouse.forgetGame();
			else if (what === "record") Mouse.recordEars(120);
			else Mouse.muteSound(-1);
		}

	}

	// the Logitech keyboard: `keyboard open`, `keyboard flash pulse`, `keyboard light up`
	IpcHandler {
		target: "keyboard"
		enabled: Plugins.on("keyboard")

		function open(): void {
			NiriSettings.page = "keyboard";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		// pulse | blink | glow | once
		function flash(pattern: string): void {
			Keyboard.flash(pattern || undefined);
		}
		// up | down | toggle | auto | max
		function light(step: string): void {
			Keyboard.test({ kind: "keyboard", op: `backlight-${step}` });
		}
		function state(): string {
			Keyboard.send({ op: "state" });
			return JSON.stringify({ device: Keyboard.device?.name ?? "", online: Keyboard.online, rules: Keyboard.rules.length, daemon: Keyboard.daemonState });
		}
	}

	// the SteelSeries Apex: `apex open`, `apex config 2|next`, `apex light 7|up|down`, `apex oled clock`
	IpcHandler {
		target: "apex"
		enabled: Plugins.on("apex")

		function open(): void {
			NiriSettings.page = "apex";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function config(which: string): void {
			if (which === "next" || which === "previous") Apex.test({ kind: "apex", op: `config-${which}` });
			else Apex.switchSlot(Math.max(1, Math.min(5, Number(which) || 1)) - 1);
		}
		function light(level: string): void {
			if (level === "up" || level === "down") Apex.test({ kind: "apex", op: `brightness-${level}` });
			else Apex.setBrightness(Math.max(0, Math.min(10, Number(level) || 0)));
		}
		// play | record | stop, a macro by its name
		function macro(what: string, name: string): void {
			const id = Object.keys(Apex.macros).find(k => Apex.macros[k].name === name) ?? (Apex.macros[name] ? name : "");
			if (id || what === "stop") Apex.macro(id, what);
		}
		// own | clock | media | system | text | picture
		function oled(mode: string): void {
			Apex.setOption("oled", mode || "own");
		}
		function state(): string {
			Apex.send({ op: "state" });
			return JSON.stringify({ online: Apex.online, slot: Apex.slot, firmware: Apex.info.firmware ?? "", rules: Apex.rules.length, daemon: Apex.daemonState });
		}
	}

	// the Sennheiser headset: `headset open`, `headset sidetone on|off|up|down|0-30`, `headset mic mute`, `headset state`
	IpcHandler {
		target: "headset"
		enabled: Plugins.on("headset")

		function open(): void {
			NiriSettings.page = "headset";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function sidetone(level: string): void {
			if (level === "on" || level === "off") Headset.setSidetoneOn(level === "on");
			else if (level === "up" || level === "down") Headset.test({ kind: "headset", op: `sidetone-${level}` });
			else if (level === "toggle") Headset.test({ kind: "headset", op: "sidetone" });
			else Headset.setSidetone(Math.max(0, Math.min(30, Number(level) || 0)));
		}
		// mute | unmute | toggle
		function mic(what: string): void {
			Headset.setMicMuted(what === "toggle" ? !Headset.micMuted : what !== "unmute");
		}
		function state(): string {
			Headset.send({ op: "state" });
			return JSON.stringify({ online: Headset.online, serial: Headset.serial, sidetone: Headset.sidetone, sidetoneOn: Headset.sidetoneOn, cable: Headset.cable, profile: Headset.profile, watching: Headset.watching, recording: Headset.recording, rules: Headset.rules.length, daemon: Headset.daemonState });
		}
	}

	// the Avantree AS50: `as50 open`, `as50 connect|disconnect|toggle`, `as50 mic on|off|call|toggle`,
	// `as50 codec aac|sbc|sbc-xq|faststream|next`, `as50 battery`, `as50 state`
	IpcHandler {
		target: "as50"
		enabled: Plugins.on("as50")

		function open(): void {
			NiriSettings.page = "as50";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function connect(): void {
			As50.connect();
		}
		function disconnect(): void {
			As50.disconnect();
		}
		function toggle(): void {
			if (As50.online) As50.disconnect();
			else As50.connect();
		}
		function mic(what: string): void {
			if (what === "toggle") As50.ownOp("mic");
			else if (what === "call") As50.setMic("headset-head-unit");
			else As50.setMic(what === "on" ? "a2dp-sink-faststream_duplex" : "");
		}
		function codec(name: string): void {
			const profiles = { aac: "a2dp-sink", sbc: "a2dp-sink-sbc", "sbc-xq": "a2dp-sink-sbc_xq", faststream: "a2dp-sink-faststream" };
			if (name === "next") As50.ownOp("codec");
			else if (profiles[name]) As50.setMusic(profiles[name]);
		}
		function battery(): string {
			return As50.battery === null ? "" : String(As50.battery);
		}
		function state(): string {
			As50.send({ op: "state" });
			return JSON.stringify({ online: As50.online, present: As50.present, address: As50.address, battery: As50.battery, profile: As50.profile, codec: As50.transport?.codec ?? "", volume: As50.raw, watching: As50.watching, rules: As50.rules.length, daemon: As50.daemonState });
		}
	}

	// the Amazfit watch: `amazfit open`, `amazfit find on|off`, `amazfit time`, `amazfit hr`,
	// `amazfit battery`, `amazfit key <hex>`, `amazfit state`
	IpcHandler {
		target: "amazfit"
		enabled: Plugins.on("amazfit")

		function open(): void {
			NiriSettings.page = "amazfit";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function find(on: string): void {
			Amazfit.findWatch(on !== "off");
		}
		function time(): void {
			Amazfit.syncTime();
		}
		function hr(): string {
			return Amazfit.hr ? String(Amazfit.hr) : "";
		}
		function battery(): string {
			return Amazfit.battery === null ? "" : String(Amazfit.battery);
		}
		function key(hex: string): void {
			Amazfit.setKey(hex);
		}
		function state(): string {
			Amazfit.send({ op: "state" });
			return JSON.stringify({ online: Amazfit.online, present: Amazfit.present, zepp: Amazfit.zeppState, keySet: Amazfit.keySet, battery: Amazfit.battery, firmware: Amazfit.info.software ?? "", clock: Amazfit.clock, settings: Object.keys(Amazfit.zepp.config ?? {}).length, rules: Amazfit.rules.length, daemon: Amazfit.daemonState });
		}
	}

	// the 8BitDo Ultimate 2 Wireless: `ultimate open`, `ultimate light dynamic|hotwheel|custom|off`, `ultimate state`
	IpcHandler {
		target: "ultimate"
		enabled: Plugins.on("ultimate")

		function open(): void {
			NiriSettings.page = "ultimate";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function light(theme: string): void {
			Ultimate.setTheme(theme || "dynamic");
		}
		function state(): string {
			return JSON.stringify({ online: Ultimate.online, linked: Ultimate.linked, slot: Ultimate.slot, battery: Ultimate.pad?.battery ?? -1, theme: Ultimate.device.theme ?? "" });
		}
	}

	// every HID device and who looks after it
	IpcHandler {
		target: "devices"
		enabled: Plugins.on("niri-settings")

		function open(): void {
			NiriSettings.page = "devices";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
	}

	IpcHandler {
		target: "radial"
		enabled: Plugins.on("radial-menu")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.openModal("radial", screen));
		}
		function close(): void {
			if (Popups.modal === "radial") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("radial");
		}
	}

	IpcHandler {
		target: "screenshot"
		enabled: Plugins.on("screenshot")

		function region(): void {
			Screenshot.region();
		}
		function screen(): void {
			Screenshot.screen();
		}
		function window(): void {
			Screenshot.window();
		}
		function picker(): void {
			Screenshot.picker();
		}
		function ocr(): void {
			Screenshot.ocr();
		}
		function pin(): void {
			Screenshot.pinMode();
		}
		function live(): void {
			Screenshot.liveMode();
		}
		function unpinAll(): void {
			Screenshot.unpinAll();
		}
		function beautifyFile(path: string): void {
			Screenshot.beautifyFile(path);
		}
		function qr(): void {
			Screenshot.qr();
		}
		function scroll(): void {
			Screenshot.scroll();
		}
		function delayed(seconds: int): void {
			Screenshot.delayed(seconds);
		}
		function close(): void {
			Screenshot.cancel();
		}
	}

	IpcHandler {
		target: "lock"
		enabled: Plugins.on("lock-screen")

		function lock(): void {
			Session.lock();
		}
		function isLocked(): bool {
			return Session.locked;
		}
	}

	IpcHandler {
		target: "panels"

		function toggleCalendar(): void {
			root.drawerOnFocused("today");
		}
		function toggleWeather(): void {
			root.drawerOnFocused("today");
		}
		function toggleNotifications(): void {
			root.drawerOnFocused("today");
		}
		function toggleMedia(): void {
			root.drawerOnFocused("media");
		}
		function toggleBluetooth(): void {
			if (!Plugins.on("bluetooth")) return;
			root.drawerOnFocused("control", "bluetooth");
		}
		function toggleNetwork(): void {
			if (!Plugins.on("network")) return;
			root.drawerOnFocused("control", "network");
		}
		function toggleResources(): void {
			if (!Plugins.on("system-monitor")) return;
			root.drawerOnFocused("control", "system");
		}
		function toggleControl(): void {
			root.drawerOnFocused("control", "main");
		}
		function toggleUpdates(): void {
			root.drawerOnFocused("updates");
		}
		function toggleOverview(): void {
			root.drawerOnFocused("overview");
		}
		function closeAll(): void {
			Popups.closeAll();
		}
		// any panel by id: control, today, timer, media, clipboard, ssh, notes, launcher
		function toggle(name: string): void {
			root.drawerOnFocused(name);
		}
		// a page of a panel, e.g. control audio
		function togglePage(name: string, page: string): void {
			root.drawerOnFocused(name, page);
		}
	}

	// names the song that is playing, in the media panel
	IpcHandler {
		target: "song"
		enabled: Plugins.on("song-detection")

		function detect(): void {
			if (Popups.current !== "media") Popups.withFocusedScreen(screen => Popups.open("media", screen));
			SongDetect.detect();
		}
		function cancel(): void {
			SongDetect.cancel();
		}
	}

	// the words of the song that is playing, in the media panel
	IpcHandler {
		target: "lyrics"
		enabled: Plugins.on("lyrics")

		function toggle(): void {
			if (Popups.current === "media" && Lyrics.open) Lyrics.show(false);
			else open();
		}
		function open(): void {
			Lyrics.show(true);
			if (Popups.current !== "media") Popups.withFocusedScreen(screen => Popups.open("media", screen));
		}
		function close(): void {
			Lyrics.show(false);
		}
	}

	IpcHandler {
		target: "updates"
		enabled: Plugins.on("updates")

		function open(): void {
			root.drawerOnFocused("updates");
		}
		function check(): void {
			Updates.check();
		}
		function updateAll(): void {
			Updates.updateAll();
		}
		function update(name: string): void {
			Updates.updateOne(name);
		}
		function count(): int {
			return Updates.count;
		}
	}

	IpcHandler {
		target: "clipboard"
		enabled: Plugins.on("clipboard")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("clipboard", screen));
		}
		function close(): void {
			if (Popups.current === "clipboard") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("clipboard");
		}
	}

	IpcHandler {
		target: "qtrack"
		enabled: Plugins.on("qtrack")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("timer", screen));
		}
		function close(): void {
			if (Popups.current === "timer") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("timer");
		}
		// the day board: every tracked day, to edit and send to Teamwork
		function days(): void {
			root.drawerOnFocused("tracking");
		}
	}

	IpcHandler {
		target: "world"
		enabled: Plugins.on("world")

		function open(): void {
			World.show();
		}
		function close(): void {
			World.hide();
		}
		function toggle(): void {
			if (World.windowOpen) World.hide();
			else World.show();
		}
		function day(day: string): void {
			World.show();
			World.pick(day);
		}
		function play(): void {
			World.show();
			World.playRequested();
		}
		function wallpaper(): void {
			Plugins.toggle("world-wallpaper");
		}
		function refresh(): void {
			World.refresh();
		}
		function restart(): void {
			World.restart();
		}
		function go(place: string): void {
			World.show();
			World.announce(place, place);
		}
	}

	IpcHandler {
		target: "ssh"
		enabled: Plugins.on("ssh")

		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("ssh", screen));
		}
		function close(): void {
			if (Popups.current === "ssh") Popups.close();
		}
		function toggle(): void {
			root.drawerOnFocused("ssh");
		}
	}

	// the Pshell settings (>settings); a page: displays, layout, looks, input,
	// keys, multicursor, rules, workspaces, overview, system, sounds,
	// lighting, debug
	// the app trays: open the ones that hide (a key for the "key" ones),
	// put something in
	IpcHandler {
		target: "apptray"
		enabled: Plugins.on("app-tray")

		// every tray that hides, or the one of that name or id
		function toggle(name: string): void {
			const tray = AppTray.trays.find(each => each.id === name || each.name === name);
			if (tray) AppTray.toggle(tray.id);
			else AppTray.toggleAll();
		}
		// an app (its desktop id), a file or folder, a link or a shell line
		function add(what: string): void {
			const value = String(what).trim();
			if (value === "") return;
			if (/^https?:/.test(value)) AppTray.addToTray({ kind: "link", url: value, name: AppTray.hostOf(value) });
			else if (value.startsWith(">")) AppTray.addToTray({ kind: "command", command: value.slice(1).trim() });
			else if (value.startsWith("/")) AppTray.addToTray(AppTray.itemOfPath(value));
			else if (DesktopEntries.byId(value.replace(/\.desktop$/, ""))) AppTray.addToTray({ kind: "app", app: String(DesktopEntries.byId(value.replace(/\.desktop$/, "")).id) });
			else AppTray.addToTray({ kind: "shell", exec: value, name: value.split(/\s+/)[0] });
		}
		// the n-th item (1…9) of the tray with the keyboard, else the first one shown
		function launch(n: string): void {
			AppTray.launchIndex(Number(n) || 1, "");
		}
		// a tray takes the keyboard: arrows, Enter, 1…9, Escape
		function focus(name: string): void {
			const tray = AppTray.trays.find(each => each.id === name || each.name === name);
			AppTray.focusTray(tray?.id ?? "");
		}
		function profile(name: string): void {
			if (name === "") AppTray.saveProfile(AppTray.profile || "Default");
			else if (AppTray.profiles[name]) AppTray.useProfile(name);
			else AppTray.saveProfile(name);
		}
		// a .pshell-tray.json file comes in as a tray
		function load(path: string): void {
			AppTray.importTray(path);
		}
		function list(): string {
			return JSON.stringify(AppTray.trays.map(tray => ({ id: tray.id, name: tray.name, output: AppTray.outputOf(tray), edge: tray.edge, reveal: tray.reveal, items: (tray.items ?? []).map(item => AppTray.nameOf(item)) })));
		}
	}

	// the live status of the shell (Live): what each shown source says right
	// now (a source reads its service only while shown), and putting one on
	// the bar or taking it off
	IpcHandler {
		target: "live"

		function list(): string {
			return JSON.stringify(Live.sources.filter(src => src.on && src.available).map(src => ({ id: src.key, name: src.name, busy: src.busy, text: src.text, detail: src.detail, level: src.level, tone: src.tone })));
		}
		function bar(id: string): void {
			if (!Live.source(id)) return;
			const key = `live-${Live.source(id).key}`;
			if (BarLayout.left.includes(key) || BarLayout.center.includes(key) || BarLayout.right.includes(key)) BarLayout.remove(key);
			else BarLayout.place(key, "right", 0);
		}
		// style: auto, chip, ring, spark, bar, icon
		function style(id: string, style: string): void {
			if (Live.source(id) && Live.styles.some(each => each.value === style)) Live.setOption(id, { style: style });
		}
	}

	IpcHandler {
		target: "settings"
		enabled: Plugins.on("niri-settings")

		function open(page: string): void {
			if (page !== "") NiriSettings.page = page;
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function close(): void {
			Popups.closeSettings();
		}
		function toggle(): void {
			Popups.toggleModal("niri");
		}
	}

	// what plays (MPRIS): for key binds and scripts, instead of playerctl
	IpcHandler {
		target: "media"

		function playPause(): void {
			Media.player?.togglePlaying();
		}
		function pause(): void {
			if (Media.player?.canPause) Media.player.pause();
		}
		function next(): void {
			if (Media.player?.canGoNext) Media.player.next();
		}
		function previous(): void {
			if (Media.player?.canGoPrevious) Media.player.previous();
		}
		// every player that plays
		function pauseAll(): void {
			Media.pauseAll();
		}
	}

	// the workspace above or below, with a pulse of the mouse (key binds)
	IpcHandler {
		target: "workspace"

		function up(): void {
			Niri.focusWorkspaceRelative(-1);
			Haptics.play("workspace");
		}
		function down(): void {
			Niri.focusWorkspaceRelative(1);
			Haptics.play("workspace");
		}
	}

	// window switch: trade places with the window on the monitor in that direction
	IpcHandler {
		target: "window"

		function switchLeft(): void {
			Niri.swapWindow("left");
		}
		function switchRight(): void {
			Niri.swapWindow("right");
		}
		function switchUp(): void {
			Niri.swapWindow("up");
		}
		function switchDown(): void {
			Niri.swapWindow("down");
		}
	}

	// parked windows: the focused one onto its screen's right edge, the last one back
	IpcHandler {
		target: "parking"
		enabled: Plugins.on("parked-windows")

		function park(): void {
			Parking.parkFocused();
		}
		function restore(): void {
			Parking.restoreLast();
		}
	}

	// the same under its old name, which key binds may still call
	IpcHandler {
		target: "niri"
		enabled: Plugins.on("niri-settings")

		function open(page: string): void {
			if (page !== "") NiriSettings.page = page;
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function close(): void {
			Popups.closeSettings();
		}
		function toggle(): void {
			Popups.toggleModal("niri");
		}
	}

	// sounds: play a moment of Sounds (`sounds play notification`), switch
	// what plays (all, buttons, system, off) or the pack (`sounds pack cosy`)
	IpcHandler {
		target: "sounds"
		enabled: Plugins.on("sounds")

		function play(moment: string): void {
			Sounds.play(moment);
		}
		function mode(mode: string): void {
			if (["all", "buttons", "system", "off"].includes(mode)) Sounds.setMode(mode);
		}
		function pack(id: string): void {
			if (Sounds.packs.some(entry => entry.id === id)) Sounds.setPack(id);
		}
		// a known pack whose zip lies in ~/Downloads
		function install(id: string): void {
			Sounds.install(Sounds.available.find(entry => entry.id === id));
		}
	}

	// the key binds page of it, under its old name
	IpcHandler {
		target: "keybinds"
		enabled: Plugins.on("niri-settings")

		function open(): void {
			NiriSettings.page = "keys";
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function close(): void {
			Popups.closeSettings();
		}
		function toggle(): void {
			NiriSettings.page = "keys";
			Popups.toggleModal("niri");
		}
	}

	// the text editor (scripts/editor/)
	IpcHandler {
		target: "editor"
		enabled: Plugins.on("editor")

		function open(path: string): void {
			Editor.open(path, 0);
		}
		function scratch(): void {
			Editor.scratch();
		}
		// a code block of the editor runs in the terminal
		function terminal(script: string): void {
			Editor.terminal(script);
		}
	}

	// the fast reader: a text one word at a time
	IpcHandler {
		target: "reader"
		enabled: Plugins.on("fast-reader")

		function read(text: string): void {
			Reader.read(text);
		}
		// plays and pauses while the reader is up
		function toggle(): void {
			if (Popups.current === "reader") Reader.toggle();
		}
		function close(): void {
			if (Popups.current === "reader") Popups.close();
		}
	}

	// mail and whatever else reaches the user, as chats
	IpcHandler {
		target: "messages"
		enabled: Plugins.on("messages")

		function open(): void {
			Messages.open("");
		}
		function close(): void {
			Messages.close();
		}
		function toggle(): void {
			Messages.toggle();
		}
		// a window of its own, or back under the bar
		function window(): void {
			if (Messages.windowed) Messages.dock();
			else Messages.popOut();
		}
		// a chat by its id, as notifications name it
		function chat(id: string): void {
			Mail.show(id);
		}
		// WhatsApp, with the chat of that id in it; `id` may be empty
		function whatsapp(id: string): void {
			if (id === "") Messages.open("whatsapp");
			else WhatsApp.show(id);
		}
		// a new mail; `to` may be empty
		function compose(to: string): void {
			Messages.open(to === "" ? "new" : `new:${to}`);
		}
		function settings(): void {
			Messages.open("settings");
		}
		// the newsletters of the private mailboxes
		function newsletters(): void {
			Messages.open("newsletters");
		}
		function refresh(): void {
			Mail.refresh();
		}
		function unread(): int {
			return Messages.unread;
		}
	}

	// ~/.local/bin/record reports here so the bar can show the recording
	IpcHandler {
		target: "shelf"
		enabled: Plugins.on("shelves")

		function toggle(): void {
			Shelf.toggle();
		}
		// a new shelf with what the clipboard holds
		function clipboard(): void {
			Shelf.fromClipboard();
		}
		function reopen(): void {
			Shelf.reopen("");
		}
		function closeAll(): void {
			Shelf.closeAll();
		}
		function add(path: string): void {
			Shelf.arrived(path);
		}
	}

	IpcHandler {
		target: "files"
		enabled: Plugins.on("filemanager")

		function toggle(): void {
			Files.toggle();
		}
		// a folder (or home), in the tab that shows it or the current one
		function open(path: string): void {
			Files.open(path);
		}
		function tab(path: string): void {
			Files.openInTab(path);
		}
		// files picked in their folder
		function reveal(path: string): void {
			Files.reveal([path]);
		}
		function search(query: string): void {
			Files.searchFor(query);
		}
		// what takes the space of a folder (home without one)
		function space(path: string): void {
			Files.goTo({ kind: "storage", path: path || Paths.home });
		}
		// copies of the same file below a folder
		function copies(path: string): void {
			Files.goTo({ kind: "duplicates", path: path || Paths.home });
		}
		// two folders side by side, compared
		function compare(left: string, right: string): void {
			Files.show({ paths: [], kind: "compare", left: left, right: right, newTab: false });
		}
		function close(): void {
			Files.close();
		}
		// the chooser, asked the way apps ask it: open, open-multiple,
		// folder, folders, save, save-files; the answer goes to the log
		function choose(kind: string): void {
			Files.tryChooser(kind);
		}
	}

	IpcHandler {
		target: "viewer"
		enabled: Plugins.on("viewer")

		// a picture (its folder can be walked)
		function open(path: string): void {
			Viewer.open(path);
		}
		// straight into a way of changing it: adjust, crop, markup
		function edit(path: string, mode: string): void {
			Viewer.open(path, { mode: mode || "adjust" });
		}
		// grown out of a spot of a screen: x y w h in its logical pixels
		function from(path: string, screen: string, x: real, y: real, w: real, h: real): void {
			Viewer.open(path, { from: { screen: screen, x: x, y: y, w: w, h: h } });
		}
		// the picture in the clipboard
		function paste(): void {
			Viewer.paste();
		}
		function toggle(): void {
			Viewer.toggle();
		}
		// the window on its own: as it was left, the last picture, or Pictures
		// ("show" is a word of qs ipc itself)
		function start(): void {
			Viewer.showWindow();
		}
		function close(): void {
			Viewer.close();
		}
		function next(): void {
			Viewer.step(1);
		}
		function previous(): void {
			Viewer.step(-1);
		}
		function mode(mode: string): void {
			Viewer.setMode(mode);
		}
		function save(): void {
			Viewer.saveCopy();
		}
		// what the window's buttons do: auto, horizon, page, cutout, export,
		// copy, wallpaper, look:<id>, aspect:<id>, turn, mirror, fit, actual
		function act(action: string): void {
			Viewer.act(action);
		}
		function state(): string {
			return JSON.stringify({ open: Viewer.windowOpen, path: Viewer.path, index: Viewer.index, count: Viewer.files.length, mode: Viewer.mode, edited: Viewer.edited, saved: Viewer.saved, busy: Viewer.busy, recipe: Viewer.recipe, info: Viewer.info, error: Viewer.error });
		}
		// the newest screenshot, to draw on
		function last(): void {
			if (Screenshot.shots.length > 0) Viewer.open(Screenshot.shots[0].path, { mode: "markup", list: Screenshot.shots.map(shot => shot.path) });
		}
		// a slideshow of a folder (or of what is open), F5 in the window
		function slideshow(path: string): void {
			if (path) Viewer.open(path);
			Qt.callLater(() => Viewer.slideshow(true));
		}
		// sorting a folder out: up keeps, down rejects
		function cull(path: string): void {
			if (path) Viewer.open(path);
			Viewer.culling = true;
		}
		// the copied changes onto these pictures (paths separated by newlines)
		function apply(paths: string): void {
			Viewer.batch(paths.split("\n").filter(p => p));
		}
		// a collage of these pictures (paths separated by newlines)
		function collage(paths: string): void {
			Viewer.collage(paths.split("\n").filter(p => p));
		}
		// a recipe set from outside (testing, scripts): JSON of Recipe.js
		function recipe(json: string): void {
			try {
				Viewer.commit(Object.assign(Viewer.blankRecipe(), JSON.parse(json)));
			} catch (error) {}
		}
	}

	IpcHandler {
		target: "music"
		enabled: Plugins.on("music")

		// songs, one per line: one alone plays with the rest of its folder after it
		function open(paths: string): void {
			Music.openMany(paths.split("\n").filter(p => p));
		}
		// into the queue, at its end
		function add(paths: string): void {
			Music.add(paths.split("\n").filter(p => p), false);
		}
		// a voice message (or any sound) between the songs, in the strip, at the voice speed
		function voice(path: string, from: string): void {
			Music.playVoice(path, { artist: from });
		}
		// A then B, or off: a stretch played again and again
		function loop(): void {
			Music.cycleLoop();
		}
		// the equalizer: a preset's name ("Bass", "Flat", …)
		function eq(preset: string): void {
			const found = Music.eqPresets.find(p => p.name.toLowerCase() === preset.toLowerCase());
			if (found) Music.setEq(found.gains, found.name);
		}
		// quieter for a reason (0..100, 100 again ends it)
		function duck(reason: string, percent: int): void {
			Music.duck(reason || "ipc", percent / 100);
		}
		// the small strip at once
		function small(): void {
			Music.showSmall();
		}
		// a setting of music.json, its value as JSON ("true", "\"ring\"", "4")
		function set(name: string, value: string): void {
			try {
				Music.setSetting(name, JSON.parse(value));
			} catch (error) {
				Music.setSetting(name, value);
			}
		}
		// into the queue, next
		function upnext(paths: string): void {
			Music.add(paths.split("\n").filter(p => p), true);
		}
		// the window as it was left (the queue of last time when nothing is queued)
		function start(): void {
			Music.showWindow();
		}
		function window(): void {
			Music.toggleWindow();
		}
		function close(): void {
			Music.close();
		}
		function toggle(): void {
			Music.toggle();
		}
		function play(): void {
			Music.play();
		}
		function pause(): void {
			Music.pause();
		}
		function next(): void {
			Music.next();
		}
		function previous(): void {
			Music.previous();
		}
		function stop(): void {
			Music.stop();
		}
		// seconds, or +n / -n from here
		function seek(to: string): void {
			if (/^[+-]/.test(to)) Music.seekBy(Number(to));
			else Music.seek(Number(to));
		}
		function volume(percent: int): void {
			Music.setVolume(percent);
		}
		function speed(value: string): void {
			Music.setSpeed(Number(value) || 1);
		}
		function shuffle(): void {
			Music.toggleShuffle();
		}
		function repeat(): void {
			Music.cycleRepeat();
		}
		// minutes until it fades out; -1 after this song, 0 off
		function sleep(minutes: int): void {
			Music.sleep(minutes);
		}
		// queue | lyrics | none
		function pane(name: string): void {
			Music.setSetting("pane", name === "none" ? "" : name);
		}
		function mini(): void {
			const w = Music.niriWindow();
			Music.toggleMini(w?.layout?.window_size?.[0] ?? 1040, w?.layout?.window_size?.[1] ?? 640);
		}
		function state(): string {
			return JSON.stringify({ open: Music.windowOpen, playing: Music.playing, idle: Music.idle, path: Music.path, index: Music.index, queue: Music.queue.length,
				position: Math.round(Music.positionNow() * 10) / 10, duration: Music.duration, speed: Music.speed, volume: Music.volume, repeat: Music.repeatMode,
				shuffle: Music.shuffled, pane: Music.pane, sleepAt: Music.sleepAt, song: Music.song, art: Music.art, accent: Music.accentHex,
				wave: Music.wave.length, lyrics: Music.lyrics.state ?? "", lyricLine: Music.lyricLine });
		}
	}

	IpcHandler {
		target: "agents"
		enabled: Plugins.on("agents")

		// scripts/agent_hook.py: state is "busy" or "idle"
		function report(window: int, state: string, agent: string): void {
			Agents.report(window, state, agent);
		}
	}

	IpcHandler {
		target: "recording"
		enabled: Plugins.on("recording")

		function started(file: string): void {
			Recorder.started(file);
		}
		function stopped(file: string): void {
			Recorder.stopped(file);
		}
		function stop(): void {
			Recorder.stop();
		}
	}

	IpcHandler {
		target: "dnd"
		enabled: Plugins.on("dnd")

		function toggle(): void {
			Notifs.toggleDnd();
		}
		function on(): void {
			Notifs.setDnd(true);
		}
		function off(): void {
			Notifs.setDnd(false);
		}
		function active(): bool {
			return Notifs.dnd;
		}
	}

	IpcHandler {
		target: "todos"
		enabled: Plugins.on("todos")

		// the editor on a new note (Mod+T)
		function create(): void {
			Todos.newNote();
		}
		// the editor on the note of that name, made when there is none
		function edit(name: string): void {
			const path = Todos.findNote(name)?.path ?? Todos.createNote(name);
			if (path !== "") Todos.openEditor(path, -1);
		}
		function close(): void {
			Todos.closeEditor();
		}
		// a task into a group ("" the inbox); "#group" and "!"…"!!!" in the text work too
		function add(group: string, text: string): string {
			return Todos.addTask(group, text);
		}
	}

	IpcHandler {
		target: "keepawake"
		enabled: Plugins.on("keep-awake")

		function toggle(): void {
			KeepAwake.toggle();
		}
	}

	IpcHandler {
		target: "autocorrect"
		enabled: Autocorrect.available

		function toggle(): void {
			Autocorrect.toggle();
		}
	}

	IpcHandler {
		target: "multicursor"
		enabled: Multicursor.available

		function toggle(): void {
			Multicursor.setOn(!Multicursor.on);
		}
	}

	// the pointer grown, as shaking it does
	IpcHandler {
		target: "findmouse"
		enabled: FindMouse.available

		function find(): void {
			FindMouse.show();
		}
	}

	// the pointer as a laser dot, for presentations
	IpcHandler {
		target: "laser"
		enabled: Laser.available

		function toggle(): void {
			Laser.toggle();
		}
	}

	// a made-up person with a mailbox and a number, to sign up with
	IpcHandler {
		target: "identity"
		enabled: Plugins.on("identities")

		// opens with a new one
		function create(): void {
			Identities.create();
		}
		function open(): void {
			Identities.open("");
		}
		// the saved ones
		function list(): void {
			Identities.open("list");
		}
		function close(): void {
			Identities.close();
		}
		function toggle(): void {
			Identities.toggle();
		}
		// a window of its own, or back under the bar
		function window(): void {
			if (Identities.windowed) Identities.dock();
			else Identities.popOut();
		}
	}

	IpcHandler {
		target: "watch"
		enabled: Plugins.on("watch")

		function toggle(): void {
			root.drawerOnFocused("watch");
		}
		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("watch", screen));
		}
	}

	IpcHandler {
		target: "screentime"
		enabled: Plugins.on("screentime")

		function toggle(): void {
			root.drawerOnFocused("screentime");
		}
		function open(): void {
			Popups.withFocusedScreen(screen => Popups.open("screentime", screen));
		}
	}

	IpcHandler {
		target: "printer"
		enabled: Plugins.on("printer")

		function toggle(): void {
			if (Printer.windowed) Printer.toggle();
			else root.drawerOnFocused("printer");
		}
		function open(): void {
			Printer.open();
		}
		// the panel on a job: its folder name under the jobs folder
		function show(id: string): void {
			Printer.show(id);
		}
		// "print" | "ace" | "stats"
		function tab(name: string): void {
			Printer.tab = name;
			Printer.open();
		}
		// a window of its own, or back under the bar
		function window(): void {
			if (Printer.windowed) Printer.dock();
			else Printer.popOut();
		}
		function camera(): void {
			Printer.setCamera(!Printer.camera);
		}
		function light(): void {
			Printer.setLight(!Printer.light);
		}
		function refresh(): void {
			Printer.refresh();
		}
		function pause(): void {
			Printer.pause();
		}
		function resume(): void {
			Printer.resume();
		}
	}

	IpcHandler {
		target: "breaks"
		enabled: Plugins.on("breaks")

		function toggle(): void {
			root.drawerOnFocused("breaks");
		}
		function drink(): void {
			Breaks.drinkGlass();
		}
		function undrink(): void {
			Breaks.removeGlass();
		}
		function refill(): void {
			Breaks.refill();
		}
		function uncount(): void {
			Breaks.uncount();
		}
		function bottle(left: int): void {
			Breaks.setBottleLevel(left);
		}
		function headache(): void {
			Breaks.logHeadache();
		}
		function eyes(): void {
			Breaks.startEyeRest();
		}
		function stretch(): void {
			if (Popups.modal === "stretch") Breaks.finishStretch(false);
			else Breaks.startStretch();
		}
		function toggleReminders(): void {
			Breaks.setEnabled(!Breaks.enabled);
		}
	}

	IpcHandler {
		target: "phone"
		enabled: Phone.offered

		function sendClipboard(): void {
			Phone.sendClipboard();
		}
		function sendText(text: string): void {
			Phone.sendText(text);
		}
		function ring(): void {
			Phone.ring();
		}
		// what plays here continues on the phone
		function handoff(): void {
			Phone.handoffMedia();
		}
		function sendFile(path: string): void {
			Phone.shareFile(path);
		}
		function pair(): void {
			Phone.startPairing();
			Popups.withFocusedScreen(screen => Popups.open("control", screen, "phone"));
		}
	}

	// other PCs with Pshell: pc is a name or the start of an id, "" the first connected one
	IpcHandler {
		target: "pcs"
		enabled: Pcs.enabled

		function sendFile(pc: string, path: string): string {
			const device = Pcs.find(pc);
			if (!device) return "no such PC connected";
			Pcs.sendFiles(device.id, [path]);
			return `sending to ${device.name}`;
		}
		function sendText(pc: string, text: string): string {
			const device = Pcs.find(pc);
			if (!device) return "no such PC connected";
			Pcs.sendText(device.id, text);
			return `sent to ${device.name}`;
		}
		function sendClipboard(pc: string): string {
			const device = Pcs.find(pc);
			if (!device) return "no such PC connected";
			Pcs.sendClipboard(device.id);
			return `sent to ${device.name}`;
		}
		function list(): string {
			return Pcs.devices.map(device => `${device.connected ? "●" : "○"} ${device.name} ${device.id.slice(0, 12)}`).join("\n");
		}
		// mouse and keyboard back to this PC (or another PC's back to it)
		function mouseHome(): void {
			Kvm.home();
		}
		// shows this PC's code (for the other one to type in) and the form to pair
		function pair(): void {
			Phone.startPairing();
			Popups.withFocusedScreen(screen => Popups.open("control", screen, "phone"));
		}
	}

	IpcHandler {
		target: "volume"
		enabled: Plugins.on("sound")

		function raise(): void {
			Audio.adjust(1);
		}
		function lower(): void {
			Audio.adjust(-1);
		}
		function muteToggle(): void {
			Audio.toggleMute();
		}
		function micMuteToggle(): void {
			Audio.toggleMicMute();
		}
	}

	IpcHandler {
		target: "brightness"

		function raise(): void {
			Brightness.adjust(1);
		}
		function lower(): void {
			Brightness.adjust(-1);
		}
	}

	// game mode: on, off or auto (follows the games)
	IpcHandler {
		target: "gamemode"

		function set(value: string): void {
			GameMode.setForce(value);
		}
		function state(): string {
			return JSON.stringify({ active: GameMode.active, focused: GameMode.focused, force: GameMode.force, windows: Games.windows });
		}
	}

	// whether the shell draws the wallpaper (scripts/apply_wallpaper_runtime.sh asks)
	IpcHandler {
		target: "wallpaper"

		function owned(): bool {
			return Wallpaper.enabled;
		}
		// bloom, fade or none
		function transition(name: string): void {
			Wallpaper.setTransition(name);
		}
		// the overview's copy: sharp, blur or dim
		function backdrop(name: string): void {
			Wallpaper.setBackdrop(name);
		}
	}

	IpcHandler {
		target: "theme"

		function reload(): void {
			Theme.reload();
		}
		function painted(): void {
			Popups.wallpaperPainted();
		}
		function progress(done: int, total: int): void {
			Osd.advance("theme", "Theme", done, total, "palette");
		}
	}

	// Studio: wallpaper, motion, dress, styles, combinations
	IpcHandler {
		target: "studio"

		function open(page: string): void {
			Popups.withFocusedScreen(screen => Popups.openStudio(page, screen));
		}
		function close(): void {
			if (Popups.studioIndex >= 0) Popups.closeModal();
		}
		function toggle(page: string): void {
			if (Popups.studioIndex >= 0 && (page === "" || Popups.studioPages[Popups.studioIndex].id === page))
				Popups.closeModal();
			else
				Popups.withFocusedScreen(screen => Popups.openStudio(page, screen));
		}
	}
}
