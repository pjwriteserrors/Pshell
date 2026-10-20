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

	// the game library: `games add <path>` opens it to add a program
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
	IpcHandler {
		target: "settings"
		enabled: Plugins.on("niri-settings")

		function open(page: string): void {
			if (page !== "") NiriSettings.page = page;
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function close(): void {
			if (Popups.modal === "niri") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("niri");
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

	// the same under its old name, which key binds may still call
	IpcHandler {
		target: "niri"
		enabled: Plugins.on("niri-settings")

		function open(page: string): void {
			if (page !== "") NiriSettings.page = page;
			Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
		}
		function close(): void {
			if (Popups.modal === "niri") Popups.closeModal();
		}
		function toggle(): void {
			root.modalOnFocused("niri");
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
			if (Popups.modal === "niri") Popups.closeModal();
		}
		function toggle(): void {
			NiriSettings.page = "keys";
			root.modalOnFocused("niri");
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

	// the light on the pointer, as shaking it brings
	IpcHandler {
		target: "findmouse"
		enabled: FindMouse.available

		function find(): void {
			FindMouse.show();
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
