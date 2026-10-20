pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// What the bar shows, where, in which order (Pshell settings › Bar). Three
// zones – left, centre, right – each an ordered list of item ids; what is in
// none of them waits on the shelf of the editor. An item exists only while
// its plugin is on; an item the saved layout does not know yet (a new one,
// or the layout is older) comes in at its usual place. Kept in bar.json.
Singleton {
	id: root

	readonly property var zones: ["left", "center", "right"]

	// every item the bar can show: its plugin(s) (all must be on, "" none),
	// where it goes when nothing else is said ("" = on the shelf), what it is
	readonly property var catalog: [
		{ id: "launcher", name: "Launcher", icon: "apps", plugin: "launcher-button", zone: "left", about: "Opens the launcher" },
		{ id: "workspaces", name: "Workspaces", icon: "view_grid_outline", plugin: "workspaces", zone: "left", about: "The workspaces of this screen" },
		{ id: "tray", name: "Tray", icon: "tray_full", plugin: "tray", zone: "left", about: "The apps' tray icons" },
		{ id: "taskbar", name: "Taskbar", icon: "dock_window", plugin: "taskbar", zone: "left", about: "Open windows" },
		{ id: "media", name: "Now playing", icon: "music_note", plugin: "media", zone: "left", about: "Title and bars of what plays" },
		{ id: "clock", name: "Clock", icon: "clock_outline", plugin: "clock", zone: "center", about: "Time; the date slides out" },
		{ id: "weather", name: "Weather", icon: "weather_partly_cloudy", plugin: "weather", zone: "center", about: "Temperature right now" },
		{ id: "timer", name: "Time tracking", icon: "timer_outline", plugin: "qtrack", zone: "center", about: "The running qtrack timer" },
		{ id: "activity", name: "Live activity", icon: "progress_clock", plugin: "", zone: "center", about: "Recording, downloads, file jobs while they run" },
		{ id: "notes", name: "Pinned notes", icon: "note_outline", plugin: "notes", zone: "right", about: "Notes as tabs" },
		{ id: "clipboard", name: "Clipboard", icon: "clipboard_text_multiple_outline", plugin: "clipboard", zone: "right", about: "Clipboard history" },
		{ id: "games", name: "Games", icon: "gamepad_variant", plugin: "games-bar", zone: "right", about: "Games panel; right click for the library" },
		{ id: "ssh", name: "SSH logins", icon: "server_network", plugin: "ssh", zone: "right", about: "Saved SSH logins" },
		{ id: "messages", name: "Messages", icon: "message_text_outline", plugin: "messages", zone: "right", about: "Mail and chats" },
		{ id: "status", name: "Status", icon: "wifi", plugin: "status", zone: "right", about: "Network, sound, battery; quick settings" },
		{ id: "notifications", name: "Notifications", icon: "bell_outline", plugin: "notifications", zone: "right", about: "The bell" },
		{ id: "power", name: "Session", icon: "power", plugin: "power-menu", zone: "right", about: "Lock, log out, restart" },

		// one-click buttons of plugins, on the shelf until placed
		{ id: "screenshot", name: "Screenshot", icon: "monitor_screenshot", plugin: "screenshot", zone: "", about: "Takes a region" },
		{ id: "color-picker", name: "Color picker", icon: "eyedropper", plugin: "color-picker", zone: "", about: "Picks a colour from the screen" },
		{ id: "ocr", name: "Text from screen", icon: "text_recognition", plugin: "ocr", zone: "", about: "Reads text off a region" },
		{ id: "files", name: "Files", icon: "folder_open", plugin: "filemanager", zone: "", about: "The file manager" },
		{ id: "game-library", name: "Game library", icon: "gamepad_variant", plugin: "games", zone: "", about: "The full library" },
		{ id: "game-mode", name: "Game mode", icon: "crosshairs", plugin: "game-mode", zone: "", about: "Shows and forces game mode" },
		{ id: "keep-awake", name: "Keep awake", icon: "coffee", plugin: "keep-awake", zone: "", about: "The screen stays on" },
		{ id: "dnd", name: "Do not disturb", icon: "bell_off_outline", plugin: "dnd", zone: "", about: "Silences notifications" },
		{ id: "overview", name: "Overview", icon: "view_dashboard_outline", plugin: "overview", zone: "", about: "The overview panel" },
		{ id: "updates", name: "Updates", icon: "package_up", plugin: "updates", zone: "", about: "Pending updates" },
		{ id: "breaks", name: "Breaks", icon: "cup_water", plugin: "breaks", zone: "", about: "Water, eye rest, stretching" },
		{ id: "screentime", name: "Screen time", icon: "chart_donut", plugin: "screentime", zone: "", about: "Where the day went" },
		{ id: "tracking", name: "Time report", icon: "chart_box_outline", plugin: "qtrack", zone: "", about: "qtrack's report" },
		{ id: "todos", name: "Todo lists", icon: "checkbox_marked_circle_outline", plugin: "todos", zone: "", about: "The todo lists in the launcher" },
		{ id: "translate", name: "Translate", icon: "translate", plugin: "translate", zone: "", about: "Translation in the launcher" },
		{ id: "torrents", name: "Torrents", icon: "magnet", plugin: "torrents", zone: "", about: "The torrent client" },
		{ id: "printer", name: "3D printer", icon: "printer_3d", plugin: "printer", zone: "", about: "The printer panel" },
		{ id: "watch", name: "Watch", icon: "watch", plugin: "watch", zone: "", about: "The watch panel" },
		{ id: "identities", name: "Fake identities", icon: "account_circle", plugin: "identities", zone: "", about: "Identities" },
		{ id: "vm", name: "Windows VM", icon: "microsoft_windows", plugin: "vm-launcher", zone: "", about: "Starts the VM" },
		{ id: "studio", name: "Studio", icon: "palette_outline", plugin: "studio-wallpaper", zone: "", about: "Wallpaper and theme" },
		{ id: "settings", name: "Pshell settings", icon: "tune_variant", plugin: "niri-settings", zone: "", about: "These settings" },
		{ id: "lock", name: "Lock", icon: "lock_outline", plugin: "lock-screen", zone: "", about: "Locks the screen" }
	]
	readonly property var byId: {
		const out = {};
		for (const item of root.catalog) out[item.id] = item;
		return out;
	}

	// what was saved: { left: [], center: [], right: [], shelf: [] }
	property var saved: ({})
	property bool loaded: false

	function available(id) {
		const item = root.byId[id];
		if (!item) return false;
		return item.plugin === "" || Plugins.on(item.plugin);
	}

	// every zone with every known id, saved order first, the rest where they go by default
	readonly property var full: {
		const out = { left: [], center: [], right: [], shelf: [] };
		const seen = {};
		for (const zone of ["left", "center", "right", "shelf"])
			for (const id of root.saved[zone] ?? [])
				if (root.byId[id] && !seen[id]) {
					seen[id] = true;
					out[zone].push(id);
				}
		for (const item of root.catalog)
			if (!seen[item.id]) out[item.zone !== "" ? item.zone : "shelf"].push(item.id);
		return out;
	}

	// what shows: only items whose plugin is on
	readonly property var left: root.full.left.filter(id => root.available(id))
	readonly property var center: root.full.center.filter(id => root.available(id))
	readonly property var right: root.full.right.filter(id => root.available(id))
	readonly property var shelf: root.full.shelf.filter(id => root.available(id))
	readonly property bool custom: Object.keys(root.saved).length > 0

	function ids(zone) {
		return zone === "left" ? root.left : zone === "center" ? root.center : zone === "right" ? root.right : root.shelf;
	}

	// puts an item into a zone before the shown item at `index` (or last)
	function place(id, zone, index) {
		if (!root.byId[id] || ["left", "center", "right", "shelf"].indexOf(zone) < 0) return;
		const next = {};
		for (const each of ["left", "center", "right", "shelf"]) next[each] = root.full[each].filter(other => other !== id);
		const shown = root.ids(zone).filter(other => other !== id);
		const before = index >= 0 && index < shown.length ? shown[index] : "";
		const at = before !== "" ? next[zone].indexOf(before) : -1;
		if (at < 0) next[zone].push(id);
		else next[zone].splice(at, 0, id);
		root.save(next);
	}

	function remove(id) {
		root.place(id, "shelf", -1);
	}

	function reset() {
		root.saved = {};
		file.setText("{}\n");
	}

	function save(next) {
		root.saved = next;
		file.setText(JSON.stringify(next, null, 2) + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("bar.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(file.text() || "{}"));
				root.saved = data && typeof data === "object" ? data : {};
			} catch (error) {
				root.saved = {};
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}
}
