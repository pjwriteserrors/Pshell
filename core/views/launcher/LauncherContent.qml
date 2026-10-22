pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.launcher
import "../../lib/fuzzysort.js" as Fuzzy
import qs.core.views.todos

// Launcher content: apps, commands (>), calculator (>c), files (>file),
// Ollama chats (>chat, >chats), model manager (>ollama), display setup
// (>setup), niri settings (>niri, >keys), translator (>t), converter (>conv), tasks and notes (>todo), web
// search (>w), Ollama
// actions on the clipboard (>ai) and KDE Connect (>phone). The newer modes
// live in overlays/launcher/*View.qml and share one small interface
// (move, activate, handleKey, cancel) that the input fields route to.
Item {
	id: root

	signal closeRequested
	signal launchRequested
	signal openStudioRequested(string page)
	signal openRpgRequested
	signal openUpdatesRequested
	signal openPluginsRequested


	property string searchText: ""
	property bool chatAutoFollow: true
	property bool chatSelectionActive: false
	property bool commandInputActive: false
	property bool commandInputHasSeparator: false
	property bool commandInputSyncing: false
	property bool aiAttachmentPickerOpen: false
	property string aiAttachmentDirectory: Quickshell.env("HOME")
	property var aiAttachmentEntries: []
	property bool aiAttachmentDirectoryLoading: false
	property string aiAttachmentDirectoryError: ""
	property string aiAttachmentListTargetDirectory: ""
	property string fileBrowserDirectory: Quickshell.env("HOME")
	property var fileBrowserEntries: []
	property bool fileBrowserDirectoryLoading: false
	property string fileBrowserDirectoryError: ""
	property string fileBrowserListTargetDirectory: ""
	// a command with a `plugin` only exists while that plugin is on, a group
	// (`children`) while one of its commands does
	readonly property var commands: {
		const on = root.allCommands.filter(command => command.shown !== false && (!command.plugin || Plugins.on(command.plugin)));
		return on.map(command => command.children && command.children.length === 0 ? Object.assign({}, command, { children: on.filter(child => child.parent === command.command) }) : command)
			.filter(command => !command.children || command.children.length > 0);
	}
	// the bands of the palette; a command without one is found by typing only
	readonly property var commandGroups: [
		{ id: "tools", label: "Tools" },
		{ id: "ai", label: "AI" },
		{ id: "panels", label: "Panels" },
		{ id: "system", label: "System" }
	]
	// command: what is typed after ">", aliases: what else may be typed (it
	// becomes the command once a space follows), keywords: words it is found
	// by, status: what there is to know right now, parent: the group it is in
	property var allCommands: [
		{ id: "capture", command: "shot", group: "tools", name: "Capture", aliases: ["capture", "screenshot"], children: [] },
		{ id: "pin", plugin: "pins", parent: "shot", command: "pin", name: "Pin Screenshot", keywords: "keep on top" },
		{ id: "live", plugin: "live-pins", parent: "shot", command: "live", name: "Live Pin", keywords: "window region on top" },
		{ id: "ocr", plugin: "ocr", parent: "shot", command: "ocr", name: "Text from Screen", aliases: ["text"], keywords: "copy recognise" },
		{ id: "qr", plugin: "qr", parent: "shot", command: "qr", name: "QR Code", keywords: "barcode read scan" },
		{ id: "color-picker", plugin: "color-picker", parent: "shot", command: "color", name: "Color Picker", aliases: ["picker", "colour"], keywords: "pick" },
		{ id: "delay", plugin: "delayed-screenshot", parent: "shot", command: "delay", name: "Delayed Screenshot", keywords: "5 seconds timer" },
		{ id: "scroll", plugin: "scroll-screenshot", parent: "shot", command: "scroll", name: "Scroll Screenshot", keywords: "long page" },
		{ id: "shots", plugin: "screenshot-history", parent: "shot", command: "shots", name: "Screenshot History", aliases: ["history"], status: Screenshot.shots.length > 0 ? String(Screenshot.shots.length) : "" },
		{ id: "unpin", plugin: "pins", parent: "shot", command: "unpin", name: "Remove Pins", keywords: "close pinned" },
		{ id: "calculator", plugin: "calculator", group: "tools", command: "c", name: "Calculator", aliases: ["calc", "calculator"], keywords: "math" },
		{ id: "converter", plugin: "converter", group: "tools", command: "conv", name: "Convert", aliases: ["convert"], keywords: "units currency" },
		{ id: "translate", plugin: "translate", group: "tools", command: "t", name: "Translate", aliases: ["translate", "tr"], keywords: "language" },
		{ id: "web-search", plugin: "web-search", group: "tools", command: "w", name: "Web Search", aliases: ["web", "search"], keywords: "browser" },
		// with the file manager on, >file opens it (and searches for what follows)
		{ id: "file-browser", plugin: "files", shown: !Plugins.on("filemanager"), group: "tools", command: "file", name: "Files", aliases: ["files"], keywords: "browse open folder" },
		{ id: "file-manager", plugin: "filemanager", group: "tools", command: "file", name: "Files", aliases: ["files", "fm", "explorer", "manager"], keywords: "file manager folders window tabs browse open" },
		{ id: "todo", plugin: "todos", group: "tools", command: "todo", name: "Todo", aliases: ["todos"], keywords: "lists tasks notes" },
		{ id: "shelf", plugin: "shelves", group: "tools", command: "shelf", name: "Shelf", keywords: "stash files text", status: Shelf.shelves.length > 0 ? String(Shelf.shelves.length) : "" },
		{ id: "shelf-clipboard", plugin: "shelves", group: "tools", command: "shelfclip", name: "Shelf from Clipboard", aliases: ["clipshelf"], keywords: "stash copied" },
		{ id: "identity", plugin: "identities", group: "tools", command: "identity", name: "Fake Identity", aliases: ["fake", "account"], keywords: "new person sign up mail sms phone temporary" },
		{ id: "identities", plugin: "identities", group: "tools", command: "identities", name: "Identities", keywords: "saved fake accounts", status: Identities.saved.length > 0 ? String(Identities.saved.length) : "" },
		{ id: "phone", plugin: Phone.plugin, group: "tools", command: "phone", name: "Phone", keywords: `send ${Phone.name}` },
		{ id: "chat", plugin: "chat", group: "ai", command: "chat", name: "Chat", keywords: "ai assistant" },
		{ id: "chats", plugin: "chat", group: "ai", command: "chats", name: "Chats", keywords: "saved history" },
		{ id: "ai-actions", plugin: "ai-actions", group: "ai", command: "ai", name: "AI", aliases: ["actions", "ki"], keywords: "explain summarize translate clipboard ask find files chat" },
		{ id: "ollama", plugin: "ollama", group: "ai", command: "ollama", name: "Ollama", aliases: ["models"], keywords: "installed running" },
		{ id: "messages", plugin: "messages", group: "panels", command: "messages", name: "Messages", aliases: ["msg"], keywords: "mail chats inbox", status: Messages.unread > 0 ? String(Messages.unread) : "" },
		{ id: "mail", plugin: "mail", group: "panels", command: "mail", name: "New Mail", aliases: ["compose"], keywords: "write" },
		{ id: "updates", plugin: "updates", group: "panels", command: "updates", name: "Updates", aliases: ["update"], keywords: "arch packages", status: Updates.count > 0 ? String(Updates.count) : "" },
		{ id: "screentime", plugin: "screentime", group: "panels", command: "screentime", name: "Screen Time", aliases: ["time", "usage"], keywords: "statistics", status: Screentime.clock(Screentime.total(Screentime.today)) },
		{ id: "watch", plugin: "watch", group: "panels", command: "watch", name: "Watch", aliases: ["uhr", "sleep", "schlaf", "amazfit", "health"], keywords: "sleep night heart steps stress blood oxygen amazfit wrist", status: Watch.lastNight ? Watch.span(Watch.lastNight.total) : "" },
		{ id: "printer", plugin: "printer", group: "panels", command: "printer", name: "3D Printer", aliases: ["print", "kobra", "ace"], keywords: "gcode filament orca slicer", status: Printer.printing ? `${Math.round(Printer.progress * 100)} %` : "" },
		{ id: "lyrics", plugin: "lyrics", group: "panels", command: "lyrics", name: "Lyrics", keywords: "song words" },
		{ id: "song", plugin: "song-detection", group: "panels", command: "song", name: "Song Detection", aliases: ["detect"], keywords: "name music" },
		{ id: "plugins", group: "system", command: "plugins", name: "Plugins", keywords: "switch features", status: `${Plugins.list.filter(plugin => Plugins.on(plugin.id)).length}/${Plugins.list.length}` },
		{
			id: "studio", shown: Popups.studioPages.length > 0, group: "system", command: "studio", name: "Studio", aliases: ["theme"],
			// its pages are what it leads to
			children: Popups.studioPages.map(page => ({ id: "studio-page", page: page.id, command: `studio ${page.id}`, name: page.label, glyph: page.icon, keywords: "" }))
		},
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "settings", page: "", name: "Pshell Settings", aliases: ["niri", "pshell", "preferences"], keywords: "layout borders input rules workspaces sounds" },
		{ id: "niri-settings", plugin: "sounds", shown: Plugins.on("niri-settings"), group: "system", command: "sounds", page: "sounds", name: "Sounds", glyph: "volume_high", aliases: ["sound"], keywords: "clicks notifications volume mute" },
		{ id: "niri-settings", shown: Plugins.on("niri-settings") && Lighting.enabled, group: "system", command: "lighting", page: "lighting", name: "Lighting", glyph: "led_strip_variant", aliases: ["rgb", "openrgb", "leds"], keywords: "keyboard fans gpu wallpaper screen live ambient" },
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "keys", page: "keys", name: "Key Binds", aliases: ["binds", "keybinds", "shortcuts"], keywords: "niri" },
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "setup", page: "displays", name: "Display Setup", aliases: ["display", "displays", "monitors"], keywords: "arrange" },
		{
			id: "mouse", plugin: "mouse", group: "system", command: "mouse", name: "Mouse Profiles", aliases: ["maus", "profile", "profiles", "logitech"], keywords: "mx master dpi gaming haptics buttons",
			status: Mouse.active?.name ?? "",
			// a profile each, then what else the mouse has
			children: Mouse.profiles.map(p => ({ id: "mouse-profile", profile: p.id, command: `mouse ${p.name.toLowerCase()}`, name: p.name, glyph: p.icon || "mouse_variant", status: p.id === Mouse.activeProfile ? "In use" : ((p.apps ?? []).length > 0 ? p.apps.join(", ") : (p.games ? "While playing" : "")), keywords: `profile ${(p.apps ?? []).join(" ")}` }))
				.concat([
					{ id: "mouse-new", command: "mouse new", name: "New Profile", glyph: "plus", keywords: "copy duplicate add" },
					{ id: "mouse-rumble", command: "mouse rumble", name: "Game Haptics", glyph: "vibrate", status: ({ off: "Off", games: "In games", always: "Always" })[Mouse.option("rumble", "off")], keywords: "rumble bass feel vibration" },
					{ id: "niri-settings", command: "mouse settings", page: "mouse", name: "Mouse Settings", glyph: "tune_variant", keywords: "buttons gestures dpi" }
				])
		},
		{ id: "torrents", plugin: "torrents", group: "tools", command: "torrents", name: "Torrents", aliases: ["torrent", "magnet", "bittorrent", "p2p"], keywords: "download magnet link seed peers mirror", status: Torrents.running.length > 0 && Torrents.ratio >= 0 ? `${Math.floor(Torrents.ratio * 100)} %` : "" },
		{ id: "games", plugin: "games", group: "tools", command: "games", name: "Games", aliases: ["game", "play", "steam", "library"], keywords: "steam proton wine library play launch covers", status: Games.running.length > 0 ? "Playing" : "" },
		{ id: "vm", plugin: "vm-launcher", group: "system", command: "vm", name: "Virtual Machines", aliases: ["vms", "windows", "win", "virt"], keywords: "looking glass qemu libvirt start boot", status: Machines.vms.some(vm => vm.running) ? "On" : "" },
		{ id: "dnd", plugin: "dnd", group: "system", command: "dnd", name: "Do Not Disturb", aliases: ["quiet", "silent"], keywords: "notifications", status: Notifs.dnd ? "On" : "" },
		{ id: "rpg", plugin: "rpg", group: "system", command: "rpg", prefix: "/", name: "Productivity RPG", keywords: "game" }
	]

	// ── the palette ─────────────────────────────────────────────────────────
	// commands kept on top, by what is typed for them (launcher-commands.json)
	property var commandPins: []
	// the tile that is picked, an index into `paletteCells`
	property int paletteIndex: 0

	// every command once, those of a group behind it
	readonly property var flatCommands: root.commands.filter(command => !command.parent).reduce((all, command) => all.concat(command.children ? [command].concat(command.children.filter(child => child.id !== "studio-page" && !String(child.id).startsWith("mouse-"))) : [command]), [])
	// the group whose commands are shown: ">shot", ">studio wall"
	readonly property var openGroup: {
		if (!root.inCommandMode) return null;
		const token = root.commandQuery.split(/\s+/)[0];
		return root.commands.find(command => command.children && command.command === token) || null;
	}
	readonly property string paletteFilter: root.openGroup ? root.commandQuery.slice(root.openGroup.command.length).trim() : root.commandQuery

	function commandUsage(command) {
		return Number(AppUsage.usageMap[`>${command.command}`] || 0);
	}

	// how well a command answers what is typed; 0 when it does not, 60 and
	// more when a word of it starts that way
	function commandScore(command, query) {
		if (query === "") return 1;
		const token = String(command.command || "").toLowerCase();
		const name = String(command.name || "").toLowerCase();
		const aliases = command.aliases || [];
		let score = 0;
		if (token === query) score = 100;
		else if (aliases.includes(query)) score = 95;
		else if (token.startsWith(query)) score = 80;
		else if (name.startsWith(query)) score = 75;
		else if (aliases.some(alias => alias.startsWith(query))) score = 70;
		else if (name.split(/\s+/).some(word => word.startsWith(query))) score = 60;
		else if (query.length > 1 && name.includes(query)) score = 40;
		else if (query.length > 2 && String(command.keywords || "").toLowerCase().includes(query)) score = 25;
		else if (query.length > 2) {
			const fuzzy = Fuzzy.single(query, name);
			if (fuzzy && fuzzy.score > 0.35) score = 5 + fuzzy.score * 15;
		}
		return score > 0 ? score + Math.min(9, root.commandUsage(command)) : 0;
	}

	// [{ label, cells: [{ index, row, column, command, glyph, match, score, pinned }] }]
	readonly property var paletteSections: {
		if (root.mode !== "commands") return [];
		const filter = root.paletteFilter;
		const sections = [];
		let index = 0;
		let row = 0;
		const add = (label, list, pinned) => {
			if (list.length === 0) return;
			const cells = list.map((command, at) => {
				let shown = command;
				let score = root.commandScore(command, filter);
				// a group answers for its commands: the best of them takes its place
				if (command.children && filter !== "" && !root.openGroup) {
					for (const child of command.children) {
						const each = root.commandScore(child, filter);
						if (each > score) {
							score = each;
							shown = child;
						}
					}
				}
				return { index: index++, row: row + Math.floor(at / 4), column: at % 4, command: shown, glyph: root.commandGlyph(shown), match: score > 0, score: score, pinned: pinned && root.commandPins.includes(shown.command) };
			});
			row += Math.ceil(list.length / 4);
			sections.push({ label: label, cells: cells });
		};
		if (root.openGroup) {
			add(root.openGroup.name, root.openGroup.children, false);
			return sections;
		}
		// what is pinned, filled up to a row with what is used most
		const pinned = root.commandPins.map(token => root.flatCommands.find(command => command.command === token)).filter(command => command);
		const used = root.flatCommands.filter(command => !command.children && root.commandUsage(command) > 0 && !root.commandPins.includes(command.command))
			.sort((a, b) => root.commandUsage(b) - root.commandUsage(a));
		add("Favourites", pinned.concat(used.slice(0, Math.max(0, 4 - pinned.length))), true);
		for (const group of root.commandGroups)
			add(group.label, root.commands.filter(command => command.group === group.id), false);
		return sections;
	}
	// what the tiles take, for the launcher's height (the palette's own measures)
	readonly property real paletteHeight: root.paletteSections.reduce((sum, section) => sum + Math.ceil(section.cells.length / 4) * 52 - 6, 0) + Math.max(0, root.paletteSections.length - 1) * 14
	readonly property var paletteCells: root.paletteSections.reduce((all, section) => all.concat(section.cells), [])
	readonly property var paletteCommand: root.paletteCells[root.paletteIndex]?.match ? root.paletteCells[root.paletteIndex].command : null

	// the tile that answers best
	function pickPaletteCell() {
		let best = -1;
		root.paletteCells.forEach(cell => {
			if (cell.match && (best < 0 || cell.score > root.paletteCells[best].score)) best = cell.index;
		});
		root.paletteIndex = best;
	}

	// to the next tile that matches: sideways through all of them, up and
	// down to the nearest one of the next row that has any
	function movePalette(dx, dy) {
		const cells = root.paletteCells.filter(cell => cell.match);
		if (cells.length === 0) return;
		const current = root.paletteCells[root.paletteIndex];
		if (!current || !current.match) {
			root.paletteIndex = cells[0].index;
			return;
		}
		if (dx !== 0) {
			const at = cells.findIndex(cell => cell.index === current.index);
			root.paletteIndex = cells[Math.max(0, Math.min(cells.length - 1, at + dx))].index;
			return;
		}
		const beyond = cells.filter(cell => dy > 0 ? cell.row > current.row : cell.row < current.row);
		if (beyond.length === 0) return;
		const row = dy > 0 ? Math.min(...beyond.map(cell => cell.row)) : Math.max(...beyond.map(cell => cell.row));
		root.paletteIndex = beyond.filter(cell => cell.row === row)
			.reduce((best, cell) => Math.abs(cell.column - current.column) < Math.abs(best.column - current.column) ? cell : best).index;
	}

	function togglePin(command) {
		if (!command || command.id === "studio-page") return;
		const token = String(command.command);
		root.commandPins = root.commandPins.includes(token) ? root.commandPins.filter(each => each !== token) : root.commandPins.concat([token]);
		commandStateFile.setText(JSON.stringify({ pins: root.commandPins }));
	}

	// what is typed for a command instead of its token becomes the token
	function canonicalToken(text) {
		const typed = String(text || "").slice(1).toLowerCase();
		const command = root.flatCommands.find(each => (each.aliases || []).includes(typed) && !root.flatCommands.some(other => other.command === typed));
		return command ? `>${command.command}` : String(text || "");
	}

	// commands that answer the app search, best first
	readonly property var appCommands: {
		const query = root.searchText.trim().toLowerCase();
		if (root.mode !== "apps" || query.length < 2) return [];
		return root.flatCommands.map(command => ({ command: command, score: root.commandScore(command, query) }))
			.filter(entry => entry.score >= 40).sort((a, b) => b.score - a.score).slice(0, 4);
	}

	FileView {
		id: commandStateFile

		path: Paths.stateFile("launcher-commands.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const pins = (JSON.parse(String(text() || "{}")) || {}).pins;
				root.commandPins = Array.isArray(pins) ? pins.map(String) : [];
			} catch (error) {}
		}
	}

	readonly property bool inCommandMode: root.searchText.trim().startsWith(">") || root.searchText.trim().startsWith("/")
	readonly property string commandQuery: root.searchText.trim().slice(1).trim().toLowerCase()
	readonly property bool inCalculatorMode: Plugins.on("calculator") && root.isCalculatorQuery(root.commandQuery)
	readonly property bool inAiMode: Plugins.on("chat") && (root.commandQuery === "chats" || root.commandQuery.startsWith("chats "))
	readonly property bool inChatMode: Plugins.on("chat") && (root.commandQuery === "chat" || root.commandQuery.startsWith("chat "))
	readonly property bool inOllamaMode: Plugins.on("ollama") && root.commandQuery === "ollama"
	// the phone and the chat pick their files here as well
	readonly property bool inFileMode: ((Plugins.on("files") && !Plugins.on("filemanager")) || Phone.pickingFile) && (root.commandQuery === "file" || root.commandQuery.startsWith("file "))
	// with the file manager on, >file finds files right here (FileFinderView)
	readonly property bool inFinderMode: Plugins.on("filemanager") && !Phone.pickingFile && /^(file|files|fm)( |$)/.test(root.commandQuery)
	readonly property string fileManagerQuery: ""
	readonly property bool inTranslateMode: Plugins.on("translate") && (root.commandQuery === "t" || root.commandQuery.startsWith("t "))
	readonly property bool inConvertMode: Plugins.on("converter") && (root.commandQuery === "conv" || root.commandQuery.startsWith("conv "))
	readonly property bool inTodoMode: Plugins.on("todos") && (root.commandQuery === "todo" || root.commandQuery.startsWith("todo "))
	readonly property bool inWebMode: Plugins.on("web-search") && (root.commandQuery === "w" || root.commandQuery.startsWith("w "))
	readonly property bool inAiActionsMode: Plugins.on("ai-actions") && (root.commandQuery === "ai" || root.commandQuery.startsWith("ai "))
	readonly property bool inPhoneMode: Phone.offered && (root.commandQuery === "phone" || root.commandQuery.startsWith("phone "))
	readonly property bool inShotsMode: Plugins.on("screenshot-history") && (root.commandQuery === "shots" || root.commandQuery.startsWith("shots "))
	readonly property bool inViewMode: root.inTranslateMode || root.inConvertMode || root.inTodoMode || root.inWebMode || root.inAiActionsMode || root.inPhoneMode || root.inShotsMode || root.inFinderMode
	// what follows the command token, as typed (">t fr hello" → "fr hello")
	readonly property string modeArgument: {
		const match = /^>\S+\s([\s\S]*)$/.exec(root.searchText);
		return match ? match[1] : "";
	}
	// true while reset() clears the input, so leaving file mode then does not
	// cancel a file pick another surface just asked for
	property bool resetting: false
	readonly property string commandInputToken: root.commandInputActive ? commandTokenField.text : ""
	readonly property string commandInputArgument: root.commandInputActive ? searchField.text : ""
	readonly property string highlightedCommandInput: root.commandInputHighlight(root.searchText)
	readonly property string chatsSearchQuery: root.chatsSearchQueryFromInput(root.searchText)
	readonly property string fileBrowserSearchQuery: root.fileBrowserSearchQueryFromInput(root.searchText)
	readonly property var filteredAiChats: {
		const query = root.chatsSearchQuery.toLowerCase();
		if (query === "") return AiChat.aiChats;
		const words = query.split(/\s+/).filter(word => word !== "");
		return AiChat.aiChats.filter(chat => {
			const title = String(chat?.title || "").toLowerCase();
			return words.every(word => title.includes(word));
		});
	}
	readonly property var filteredFileBrowserEntries: {
		const query = root.fileBrowserSearchQuery.toLowerCase();
		if (query === "") return root.fileBrowserEntries;
		const words = query.split(/\s+/).filter(word => word !== "");
		return root.fileBrowserEntries.filter(entry => {
			const name = String(entry?.name || "").toLowerCase();
			return words.every(word => name.includes(word));
		});
	}
	readonly property string chatPrompt: root.chatPromptFromSearch(root.searchText)
	readonly property string calculatorExpression: root.calculatorExpressionFromQuery(root.searchText.trim().slice(1).trim())
	readonly property var calculatorEvaluation: root.evaluateCalculatorExpression(root.calculatorExpression)
	ListModel {
		id: chatMessageModel
		dynamicRoles: true
	}

	Timer {
		id: chatScrollTimer
		interval: 32
		repeat: false
		onTriggered: {
			if (!root.chatAutoFollow || root.chatSelectionActive) return;
			chatList.contentY = Math.max(0, chatList.contentHeight - chatList.height);
		}
	}

	Timer {
		id: chatSelectionReleaseTimer
		interval: 80
		repeat: false
		onTriggered: {
			const shouldFollow = root.chatNearEnd();
			root.chatSelectionActive = false;
			root.syncChatMessageModel();
			root.chatAutoFollow = shouldFollow;
			if (shouldFollow) root.scrollChatToEnd(true);
		}
	}



	function isCalculatorQuery(query) {
		const value = String(query || "").trim().toLowerCase();
		return value === "c" || value.startsWith("c ") || value === "calc" || value.startsWith("calc ");
	}

	function styledTextEscape(text) {
		return String(text || "")
			.replace(/&/g, "&amp;")
			.replace(/</g, "&lt;")
			.replace(/>/g, "&gt;")
			.replace(/\n/g, "<br>");
	}

	function blendedColorHex(front, back, amount) {
		const blend = channel => Math.round((front[channel] * amount + back[channel] * (1 - amount)) * 255)
			.toString(16)
			.padStart(2, "0");
		return `#${blend("r")}${blend("g")}${blend("b")}`;
	}

	function commandInputHighlight(text) {
		const match = /^>([^\s]+)([\s\S]*)$/.exec(String(text || ""));
		if (!match) return "";
		const muted = root.blendedColorHex(Theme.text, Theme.layer2, 0.48);
		return `<font color="${muted}">&gt;${root.styledTextEscape(match[1])}</font>${root.styledTextEscape(match[2])}`;
	}

	function appendMarkdownTextSegments(segments, text) {
		const value = String(text || "");
		if (value === "") return;
		const bareImagePattern = /(^|\n)[ \t]*((?:https?:\/\/|file:\/\/|\/)[^\s]+?\.(?:png|jpe?g|gif|webp|bmp|svg)(?:\?[^\s]*)?|data:image\/[a-z0-9.+-]+;base64,[a-z0-9+/=]+)[ \t]*(?=\n|$)/gi;
		let cursor = 0;
		let match = null;
		while ((match = bareImagePattern.exec(value)) !== null) {
			const textEnd = match.index + String(match[1] || "").length;
			if (textEnd > cursor)
				segments.push({ kind: "text", text: value.slice(cursor, textEnd) });
			segments.push({
				kind: "image",
				source: String(match[2] || ""),
				alt: ""
			});
			cursor = bareImagePattern.lastIndex;
		}
		if (cursor < value.length)
			segments.push({ kind: "text", text: value.slice(cursor) });
	}

	function markdownImageSegments(text) {
		const value = String(text || "");
		const segments = [];
		const markdownImagePattern = /!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+["'][^"']*["'])?\s*\)/g;
		let cursor = 0;
		let match = null;
		while ((match = markdownImagePattern.exec(value)) !== null) {
			root.appendMarkdownTextSegments(segments, value.slice(cursor, match.index));
			segments.push({
				kind: "image",
				source: String(match[2] || match[3] || ""),
				alt: String(match[1] || "")
			});
			cursor = markdownImagePattern.lastIndex;
		}
		root.appendMarkdownTextSegments(segments, value.slice(cursor));
		return segments.length > 0 ? segments : [{ kind: "text", text: value }];
	}

	function resolveMarkdownImageSource(source) {
		const value = String(source || "").trim();
		if (value === "" || /^(?:[a-z][a-z0-9+.-]*:|\/)/i.test(value)) return value;
		return `${Quickshell.shellDir}/${value.replace(/^\.\//, "")}`;
	}








	function parseAttachmentDirectory(raw) {
		if (root.aiAttachmentListTargetDirectory !== root.aiAttachmentDirectory) return;
		const entries = [];
		for (const record of String(raw || "").split("\x1e")) {
			if (record === "") continue;
			const fields = record.split("\x1f");
			if (fields.length < 4) continue;
			const type = String(fields[0] || "");
			const name = String(fields[2] || "");
			const path = fields.slice(3).join("\x1f");
			if (name === "" || name.startsWith(".")) continue;
			const suffixMatch = /\.([^.]+)$/.exec(name);
			const suffix = suffixMatch ? String(suffixMatch[1]).toLowerCase() : "";
			entries.push({
				name,
				path,
				size: Number(fields[1] || 0),
				suffix,
				mimeType: "",
				isDir: type === "d",
				isImage: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"].includes(suffix)
			});
		}
		entries.sort((left, right) => {
			if (Boolean(left.isDir) !== Boolean(right.isDir)) return left.isDir ? -1 : 1;
			return String(left.name || "").localeCompare(String(right.name || ""));
		});
		root.aiAttachmentEntries = entries;
		root.aiAttachmentDirectoryError = "";
		root.aiAttachmentDirectoryLoading = false;
	}

	function refreshAttachmentDirectory() {
		if (!root.aiAttachmentPickerOpen || attachmentListProcess.running) return;
		root.aiAttachmentDirectoryLoading = true;
		root.aiAttachmentDirectoryError = "";
		root.aiAttachmentListTargetDirectory = root.aiAttachmentDirectory;
		attachmentListProcess.exec([
			"find",
			"-L",
			root.aiAttachmentListTargetDirectory,
			"-mindepth", "1",
			"-maxdepth", "1",
			"-printf", "%y\\037%s\\037%f\\037%p\\036"
		]);
	}

	function openAttachmentPicker() {
		if (!root.inChatMode || AiChat.aiStreaming) return;
		root.aiAttachmentPickerOpen = true;
		if (root.aiAttachmentDirectory === "") root.aiAttachmentDirectory = Quickshell.env("HOME");
		root.refreshAttachmentDirectory();
		Qt.callLater(function() {
			attachmentFileList.forceActiveFocus();
		});
	}

	function closeAttachmentPicker() {
		root.aiAttachmentPickerOpen = false;
		Qt.callLater(function() {
			searchField.cursorPosition = searchField.text.length;
			searchField.forceActiveFocus();
		});
	}

	function attachmentParentDirectory(path) {
		const value = String(path || "").replace(/\/+$/, "");
		if (value === "" || value === "/") return "/";
		const separator = value.lastIndexOf("/");
		return separator <= 0 ? "/" : value.slice(0, separator);
	}

	function parseFileBrowserDirectory(raw) {
		if (root.fileBrowserListTargetDirectory !== root.fileBrowserDirectory) return;
		const entries = [];
		for (const record of String(raw || "").split("\x1e")) {
			if (record === "") continue;
			const fields = record.split("\x1f");
			if (fields.length < 4) continue;
			const type = String(fields[0] || "");
			const name = String(fields[2] || "");
			const path = fields.slice(3).join("\x1f");
			if (name === "" || name.startsWith(".")) continue;
			const suffixMatch = /\.([^.]+)$/.exec(name);
			const suffix = suffixMatch ? String(suffixMatch[1]).toLowerCase() : "";
			entries.push({
				name,
				path,
				size: Number(fields[1] || 0),
				suffix,
				mimeType: "",
				isDir: type === "d",
				isImage: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"].includes(suffix)
			});
		}
		entries.sort((left, right) => {
			if (Boolean(left.isDir) !== Boolean(right.isDir)) return left.isDir ? -1 : 1;
			return String(left.name || "").localeCompare(String(right.name || ""));
		});
		root.fileBrowserEntries = entries;
		root.fileBrowserDirectoryError = "";
		root.fileBrowserDirectoryLoading = false;
	}

	function refreshFileBrowserDirectory() {
		if (!root.inFileMode || fileBrowserListProcess.running) return;
		root.fileBrowserDirectoryLoading = true;
		root.fileBrowserDirectoryError = "";
		root.fileBrowserListTargetDirectory = root.fileBrowserDirectory;
		fileBrowserListProcess.exec([
			"find",
			"-L",
			root.fileBrowserListTargetDirectory,
			"-mindepth", "1",
			"-maxdepth", "1",
			"-printf", "%y\\037%s\\037%f\\037%p\\036"
		]);
	}

	function openPathWithDefaultApp(path) {
		const value = String(path || "");
		if (value === "") return;
		root.closeRequested();
		Quickshell.execDetached(["xdg-open", value]);
		root.launchRequested();
	}

	function openFileBrowserEntry(entry) {
		if (!entry) return;
		if (Boolean(entry.isDir)) {
			root.fileBrowserDirectory = String(entry.path || root.fileBrowserDirectory);
			root.refreshFileBrowserDirectory();
			return;
		}
		if (Phone.pickingFile) {
			Phone.shareFile(entry.path);
			Phone.pickingFile = false;
			root.closeRequested();
			root.launchRequested();
			return;
		}
		root.openPathWithDefaultApp(entry.path);
	}

	function revealSelectedFileBrowserEntry() {
		const entry = root.filteredFileBrowserEntries[fileBrowserList.currentIndex];
		if (!entry) return;
		if (entry.isDir) Files.open(entry.path);
		else Files.reveal([entry.path]);
		root.closeRequested();
	}

	function openSelectedFileBrowserEntry() {
		if (!root.inFileMode) return;
		if (fileBrowserList.currentIndex < 0 || fileBrowserList.currentIndex >= root.filteredFileBrowserEntries.length)
			return;
		root.openFileBrowserEntry(root.filteredFileBrowserEntries[fileBrowserList.currentIndex]);
	}

	function openAttachmentEntry(entry) {
		if (!entry) return;
		if (Boolean(entry.isDir)) {
			root.aiAttachmentDirectory = String(entry.path || root.aiAttachmentDirectory);
			root.refreshAttachmentDirectory();
			return;
		}
		AiChat.addPendingAttachment(entry);
	}














	function chatsSearchQueryFromInput(text) {
		const match = /^>chats(?:\s+([\s\S]*))?$/i.exec(String(text || "").trim());
		return match ? String(match[1] || "").trim() : "";
	}

	function fileBrowserSearchQueryFromInput(text) {
		const match = /^>file(?:\s+([\s\S]*))?$/i.exec(String(text || "").trim());
		return match ? String(match[1] || "").trim() : "";
	}

	function calculatorExpressionFromQuery(query) {
		const value = String(query || "").trim();
		const lower = value.toLowerCase();
		if (lower === "c") return "";
		if (lower.startsWith("c ")) return value.slice(2).trim();
		if (lower === "calc") return "";
		if (lower.startsWith("calc ")) return value.slice(5).trim();
		return "";
	}

	function evaluateCalculatorExpression(expression) {
		const raw = String(expression || "").trim();
		if (raw === "") return { valid: false, result: "", message: "Type an expression, for example >c 5+5" };
		const evaluation = Calc.evaluate(raw);
		if (!evaluation.ok) return { valid: false, result: "", message: evaluation.error === "no finite result" ? "Calculation has no finite result" : "Invalid expression" };
		return { valid: true, result: evaluation.text, message: `${raw} = ${evaluation.text}` };
	}

	function calculatorCommand() {
		const evaluation = root.calculatorEvaluation;
		const expression = root.calculatorExpression;
		return {
			id: "calculator-result",
			name: evaluation.valid ? evaluation.result : "Calculator",
			description: evaluation.message,
			icon: "accessories-calculator-symbolic",
			result: evaluation.result,
			expression,
			valid: evaluation.valid
		};
	}

	function chatPromptFromSearch(text) {
		const value = String(text || "").trim();
		const lower = value.toLowerCase();
		if (lower === ">chat") return "";
		if (lower.startsWith(">chat ")) return value.slice(6).trim();
		return "";
	}





























	function syncLauncherSearch() {
		if (root.commandInputSyncing) return;
		root.searchText = root.commandInputActive
			? `${commandTokenField.text}${root.commandInputHasSeparator ? ` ${searchField.text}` : ""}`
			: searchField.text;
		if (root.inCommandMode)
			root.pickPaletteCell();
	}

	function enterCommandInput(text, focusArgument) {
		const value = String(text || "");
		const match = /^(>[^\s]*)(?:\s([\s\S]*))?$/.exec(value);
		if (!match) return;
		root.commandInputSyncing = true;
		root.commandInputActive = true;
		root.commandInputHasSeparator = Boolean(focusArgument) || /\s/.test(value);
		// an alias with something behind it is the command already
		commandTokenField.text = root.commandInputHasSeparator ? root.canonicalToken(match[1]) : String(match[1] || ">");
		searchField.text = String(match[2] || "");
		root.commandInputSyncing = false;
		root.syncLauncherSearch();
		Qt.callLater(function() {
			if (root.commandInputHasSeparator) {
				searchField.cursorPosition = searchField.text.length;
				searchField.forceActiveFocus();
			} else {
				commandTokenField.cursorPosition = commandTokenField.text.length;
				commandTokenField.forceActiveFocus();
			}
		});
	}

	function focusCommandArgument() {
		if (!root.commandInputActive) return;
		const token = root.canonicalToken(commandTokenField.text);
		if (token !== commandTokenField.text) {
			root.commandInputSyncing = true;
			commandTokenField.text = token;
			root.commandInputSyncing = false;
		}
		root.commandInputHasSeparator = true;
		root.syncLauncherSearch();
		searchField.cursorPosition = searchField.text.length;
		searchField.forceActiveFocus();
	}

	function focusCommandTokenFromEmptyArgument() {
		if (!root.commandInputActive || searchField.text !== "" || searchField.cursorPosition !== 0) return false;
		root.commandInputHasSeparator = false;
		root.syncLauncherSearch();
		commandTokenField.cursorPosition = commandTokenField.text.length;
		commandTokenField.forceActiveFocus();
		return true;
	}

	function leaveCommandInput(text) {
		root.commandInputSyncing = true;
		root.commandInputActive = false;
		root.commandInputHasSeparator = false;
		commandTokenField.text = ">";
		searchField.text = String(text || "");
		root.commandInputSyncing = false;
		root.syncLauncherSearch();
		Qt.callLater(function() {
			searchField.cursorPosition = searchField.text.length;
			searchField.forceActiveFocus();
		});
	}

	// Tab / Shift+Tab: apps → calculator → files → chat → chats → ollama,
	// those whose plugin is on; the footer shows them as tabs
	readonly property var modeCycle: [
		{ mode: "apps", query: "", label: "Apps", glyph: "apps", plugin: "" },
		{ mode: "calc", query: ">c ", label: "Calculator", glyph: "calculator", plugin: "calculator" },
		{ mode: "files", query: ">file ", label: "Files", glyph: "folder", plugin: "files" },
		{ mode: "chat", query: ">chat ", label: "Chat", glyph: "chat", plugin: "chat" },
		{ mode: "chats", query: ">chats ", label: "Chats", glyph: "forum", plugin: "chat" },
		{ mode: "ollama", query: ">ollama ", label: "Ollama", glyph: "robot", plugin: "ollama" }
	].filter(entry => entry.plugin === "" || Plugins.on(entry.plugin))

	function cycleMode(delta) {
		const count = root.modeCycle.length;
		const index = Math.max(0, root.modeCycle.findIndex(entry => entry.mode === root.mode));
		root.setLauncherSearch(root.modeCycle[(index + delta + count) % count].query);
	}

	function handleModeCycleKey(event) {
		if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab) return false;
		root.cycleMode(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1);
		return true;
	}

	function setLauncherSearch(text) {
		const value = String(text || "");
		if (value.startsWith(">")) root.enterCommandInput(value, /\s/.test(value));
		else root.leaveCommandInput(value);
	}

	function syncChatMessageModel() {
		chatMessageModel.clear();
		for (const message of AiChat.activeMessages)
			chatMessageModel.append({ entry: message });
	}

	function updateVisibleChatMessage(index, message) {
		if (!AiChat.streamingChatMatchesView() || root.chatSelectionActive) return;
		if (index < 0 || index >= chatMessageModel.count) {
			root.syncChatMessageModel();
			return;
		}
		chatMessageModel.setProperty(index, "entry", message);
	}

	function updateChatSelection(selectedText) {
		if (String(selectedText || "") !== "") {
			chatSelectionReleaseTimer.stop();
			root.chatSelectionActive = true;
			root.chatAutoFollow = false;
			return;
		}
		if (root.chatSelectionActive) chatSelectionReleaseTimer.restart();
	}



	function openAiOverview() {
		AiChat.editingMessageId = "";
		AiChat.clearPendingAttachments();
		root.aiAttachmentPickerOpen = false;
		root.setLauncherSearch(">chats ");
	}




















	function scrollChatToEnd(force) {
		if (AiChat.aiStreaming && !AiChat.streamingChatMatchesView()) return;
		if (force) root.chatAutoFollow = true;
		if (!root.chatAutoFollow || root.chatSelectionActive) return;
		chatScrollTimer.restart();
	}

	function followChatImmediately() {
		if (!AiChat.aiStreaming || !AiChat.streamingChatMatchesView()) return;
		if (!root.chatAutoFollow || root.chatSelectionActive) return;
		chatList.contentY = Math.max(0, chatList.contentHeight - chatList.height);
	}

	function chatNearEnd() {
		return chatList.contentY >= Math.max(0, chatList.contentHeight - chatList.height) - 36;
	}

	function formatChatTime(timestamp) {
		return Qt.formatDateTime(new Date(Number(timestamp || Date.now())), "dd.MM. HH:mm");
	}

	function activateCurrent(modifiers) {
		if (root.activeModeView) {
			root.activeModeView.activate(modifiers || 0);
			return;
		}

		if (root.inChatMode) {
			if (AiChat.editingMessageId !== "") AiChat.submitEditedMessage(root.chatPrompt);
			else AiChat.sendChatPrompt(root.chatPrompt);
			return;
		}

		if (root.fileManagerQuery !== "") {
			root.closeRequested();
			Files.searchFor(root.fileManagerQuery);
			return;
		}

		if (root.inFileMode) {
			// Shift+Enter shows it in the file manager instead
			if ((modifiers & Qt.ShiftModifier) && Plugins.on("filemanager") && !Phone.pickingFile) root.revealSelectedFileBrowserEntry();
			else root.openSelectedFileBrowserEntry();
			return;
		}

		if (root.inCalculatorMode) {
			root.launchCommand(root.calculatorCommand());
			return;
		}

		if (root.inCommandMode)
			root.launchCommand(root.paletteCommand);
	}

	function launchApp(entry) {
		if (!entry) return;

		AppUsage.recordLaunch(entry);
		Quickshell.execDetached({
			command: entry.runInTerminal ? ["app2unit", "--"].concat(Terminal.command({}, entry.command)) : ["app2unit", "--", ...entry.command],
			workingDirectory: entry.workingDirectory
		});
		closeAfterLaunch.restart();
	}

	// one of the app's own actions (a private window, a new document …)
	function launchAppAction(entry, action) {
		if (!entry || !action) return;

		AppUsage.recordLaunch(entry);
		Quickshell.execDetached({
			command: entry.runInTerminal ? ["app2unit", "--"].concat(Terminal.command({}, action.command)) : ["app2unit", "--", ...action.command],
			workingDirectory: entry.workingDirectory
		});
		closeAfterLaunch.restart();
	}

	// the app starts at once; the launcher stays a moment for its icon to bloom
	Timer {
		id: closeAfterLaunch

		interval: 130
		onTriggered: {
			root.closeRequested();
			root.launchRequested();
		}
	}

	function launchCommand(command) {
		if (!command) return;
		if (command.id !== "calculator-result" && command.id !== "studio-page") AppUsage.recordLaunch({ id: `>${command.command}` });
		// a group shows what is in it
		if (command.children) {
			root.setLauncherSearch(`>${command.command} `);
			return;
		}

		switch (String(command.id || "")) {
		case "plugins":
			root.closeRequested();
			root.openPluginsRequested();
			break;
		case "rpg":
			root.closeRequested();
			root.openRpgRequested();
			break;
		case "studio-page":
			root.closeRequested();
			root.openStudioRequested(command.page);
			break;
		case "mouse-profile":
			root.closeRequested();
			Mouse.useProfile(command.profile);
			break;
		case "mouse-new":
			root.closeRequested();
			Mouse.newProfile("", "");
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "mouse", "open"]);
			break;
		case "mouse-rumble":
			// off → in games → always → off
			Mouse.setOption("rumble", ({ off: "games", games: "always", always: "off" })[Mouse.option("rumble", "off")]);
			break;
		case "niri-settings":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "settings", "open", command.page || ""]);
			break;
		case "calculator":
			root.setLauncherSearch(">c ");
			break;
		case "file-browser":
			root.setLauncherSearch(">file ");
			root.refreshFileBrowserDirectory();
			break;
		case "file-manager":
			root.setLauncherSearch(">file ");
			break;
		case "chats":
			root.setLauncherSearch(">chats ");
			break;
		case "ollama":
			root.setLauncherSearch(">ollama");
			break;
		case "chat":
			AiChat.startNewChat();
			break;
		case "translate":
			root.setLauncherSearch(">t ");
			break;
		case "converter":
			root.setLauncherSearch(">conv ");
			break;
		case "todo":
			root.setLauncherSearch(">todo ");
			break;
		case "web-search":
			root.setLauncherSearch(">w ");
			break;
		case "ai-actions":
			root.setLauncherSearch(">ai ");
			break;
		case "phone":
			root.setLauncherSearch(">phone ");
			break;
		case "color-picker":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "picker"]);
			break;
		case "ocr":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "ocr"]);
			break;
		case "pin":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "pin"]);
			break;
		case "live":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "live"]);
			break;
		case "shelf":
			root.closeRequested();
			Shelf.toggle();
			break;
		case "shelf-clipboard":
			root.closeRequested();
			Shelf.fromClipboard();
			break;
		case "qr":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "qr"]);
			break;
		case "delay":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "delayed", "5"]);
			break;
		case "scroll":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screenshot", "scroll"]);
			break;
		case "shots":
			root.setLauncherSearch(">shots");
			break;
		case "unpin":
			Screenshot.unpinAll();
			root.closeRequested();
			break;
		case "song":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "song", "detect"]);
			break;
		case "lyrics":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "lyrics", "open"]);
			break;
		case "messages":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "messages", "open"]);
			break;
		case "mail":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "messages", "compose", ""]);
			break;
		case "updates":
			root.openUpdatesRequested();
			break;
		case "identity":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "identity", "create"]);
			break;
		case "identities":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "identity", "list"]);
			break;
		case "screentime":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "screentime", "open"]);
			break;
		case "printer":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "printer", "open"]);
			break;
		case "watch":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "watch", "open"]);
			break;
		case "torrents":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "torrents", "open"]);
			break;
		case "games":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "games", "open"]);
			break;
		case "vm":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "vm", "open"]);
			break;
		case "dnd":
			Notifs.toggleDnd();
			root.closeRequested();
			break;
		case "calculator-result":
			if (!command.valid) return;
			Quickshell.execDetached(["wl-copy", "--", String(command.result)]);
			root.closeRequested();
			root.launchRequested();
			break;
		}
	}

	function reset() {
		AiChat.editingMessageId = "";
		root.aiAttachmentPickerOpen = false;
		root.resetting = true;
		root.leaveCommandInput("");
		root.resetting = false;
		appsView.reset();
	}

	// Ctrl+P keeps the picked command on top, or lets it go again
	function handlePinKey(event) {
		if (root.mode !== "commands" || event.key !== Qt.Key_P || !(event.modifiers & Qt.ControlModifier)) return false;
		root.togglePin(root.paletteCommand);
		event.accepted = true;
		return true;
	}

	// screen tools start once the launcher has left the screen
	function runAfterClose(command) {
		Quickshell.execDetached(["sh", "-c", 'sleep 0.3; exec "$@"', "sh"].concat(command));
	}

	// >ai: a new temporary chat with the clipboard attached, streaming in the chat view
	function runClipboardAction(prompt, text) {
		const content = String(text || "");
		if (!Plugins.on("ai-actions")) return;
		if (content.trim() === "" || AiChat.aiStreaming) return;
		if (content.length > 500000) {
			AiChat.aiError = "Clipboard text is too long";
			return;
		}
		AiChat.startNewChat();
		if (AiActions.model !== "" && AiChat.aiModels.some(model => String(model.name || model.model || "") === AiActions.model))
			AiChat.selectedAiModel = AiActions.model;
		AiChat.aiPendingAttachments = [{
			id: AiChat.makeId("clipboard"),
			path: "",
			name: "Clipboard",
			mimeType: "text/plain",
			size: content.length,
			kind: "text",
			status: "ready",
			content,
			data: "",
			source: "clipboard"
		}];
		AiChat.sendChatPrompt(prompt);
	}

	function pickFileForPhone() {
		Phone.pickingFile = true;
		root.setLauncherSearch(">file ");
	}

	// a tile that went (a plugin switched off) takes the pick with it
	onPaletteCellsChanged: if (root.paletteIndex >= root.paletteCells.length) root.pickPaletteCell()

	onFilteredFileBrowserEntriesChanged: {
		if (!root.inFileMode) return;
		if (filteredFileBrowserEntries.length === 0) fileBrowserList.currentIndex = -1;
		else if (fileBrowserList.currentIndex < 0 || fileBrowserList.currentIndex >= filteredFileBrowserEntries.length)
			fileBrowserList.currentIndex = 0;
	}

	onInAiModeChanged: {
		if (!inAiMode) return;
		AiChat.wake();
		if (root.commandInputHasSeparator)
			Qt.callLater(function() {
				searchField.forceActiveFocus();
			});
	}

	onInChatModeChanged: {
		if (inChatMode) {
			AiChat.wake();
			root.syncChatMessageModel();
			root.scrollChatToEnd(true);
			AiChat.refreshOllamaRunningModels();
			Qt.callLater(AiChat.capturePrimarySelection);
		} else {
			AiChat.editingMessageId = "";
			Qt.callLater(AiChat.primePrimarySelection);
		}
	}

	onInFileModeChanged: {
		if (!inFileMode) {
			if (!root.resetting) Phone.pickingFile = false;
			return;
		}
		root.aiAttachmentPickerOpen = false;
		root.refreshFileBrowserDirectory();
		if (root.commandInputHasSeparator)
			Qt.callLater(function() {
				searchField.forceActiveFocus();
			});
	}

	onInOllamaModeChanged: {
		if (!inOllamaMode) return;
		AiChat.wake();
		AiChat.refreshOllamaOverview();
		if (root.commandInputHasSeparator)
			Qt.callLater(function() {
				searchField.forceActiveFocus();
			});
	}

	onAiAttachmentDirectoryChanged: {
		if (root.aiAttachmentPickerOpen) root.refreshAttachmentDirectory();
	}

	onFileBrowserDirectoryChanged: {
		if (root.inFileMode) root.refreshFileBrowserDirectory();
	}













	Process {
		id: attachmentListProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseAttachmentDirectory(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (
					message !== ""
					&& root.aiAttachmentListTargetDirectory === root.aiAttachmentDirectory
				) root.aiAttachmentDirectoryError = message;
			}
		}

		onExited: exitCode => {
			root.aiAttachmentDirectoryLoading = false;
			if (
				exitCode !== 0
				&& root.aiAttachmentListTargetDirectory === root.aiAttachmentDirectory
			) root.aiAttachmentEntries = [];
			if (
				root.aiAttachmentPickerOpen
				&& root.aiAttachmentListTargetDirectory !== root.aiAttachmentDirectory
			) Qt.callLater(root.refreshAttachmentDirectory);
		}
	}

	Process {
		id: fileBrowserListProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseFileBrowserDirectory(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (
					message !== ""
					&& root.fileBrowserListTargetDirectory === root.fileBrowserDirectory
				) root.fileBrowserDirectoryError = message;
			}
		}

		onExited: exitCode => {
			root.fileBrowserDirectoryLoading = false;
			if (
				exitCode !== 0
				&& root.fileBrowserListTargetDirectory === root.fileBrowserDirectory
			) root.fileBrowserEntries = [];
			if (
				root.inFileMode
				&& root.fileBrowserListTargetDirectory !== root.fileBrowserDirectory
			) Qt.callLater(root.refreshFileBrowserDirectory);
		}
	}




	// the chat views: their state is AiChat's, what the view does it asks for
	Binding {
		target: AiChat
		property: "chatOpen"
		value: root.inChatMode
	}

	Binding {
		target: AiChat
		property: "selecting"
		value: root.chatSelectionActive
	}

	Connections {
		target: AiChat

		function onSearchRequested(text) {
			root.setLauncherSearch(text);
		}
		function onMessagesReplaced() {
			root.syncChatMessageModel();
		}
		function onMessageUpdated(index, message) {
			root.updateVisibleChatMessage(index, message);
		}
		function onScrollRequested(force) {
			root.scrollChatToEnd(force);
		}
		function onFollowRequested() {
			root.chatAutoFollow = true;
			root.chatSelectionActive = false;
		}
		function onPickerClosed() {
			root.aiAttachmentPickerOpen = false;
		}
	}

	// ══ presentation ═══════════════════════════════════════════════════════

	readonly property string mode: {
		if (root.inTranslateMode) return "translate";
		if (root.inConvertMode) return "convert";
		if (root.inTodoMode) return "todo";
		if (root.inWebMode) return "web";
		if (root.inAiActionsMode) return "ai";
		if (root.inPhoneMode) return "phone";
		if (root.inShotsMode) return "shots";
		if (root.inFinderMode) return "finder";
		if (root.inChatMode) return "chat";
		if (root.inAiMode) return "chats";
		if (root.inOllamaMode) return "ollama";
		if (root.inFileMode) return "files";
		if (root.inCalculatorMode) return "calc";
		if (root.inCommandMode) return "commands";
		return "apps";
	}
	readonly property string inputGlyph: {
		if (AiChat.editingMessageId !== "") return "pencil";
		switch (root.mode) {
		case "calc": return "calculator";
		case "files": return Phone.pickingFile ? "cellphone" : "folder";
		case "translate": return "translate";
		case "convert": return "swap_horizontal";
		case "todo": return "format_list_checks";
		case "web": return "web";
		case "ai": return "creation";
		case "phone": return "cellphone";
		case "shots": return "image_multiple";
		case "finder": return "folder_search_outline";
		case "chat": return "chat";
		case "chats": return "forum";
		case "ollama": return "robot";
		case "commands": return "console";
		default: return "magnify";
		}
	}
	property bool modelMenuOpen: false

	function commandGlyph(command) {
		switch (String(command?.id || "")) {
		case "capture": return "monitor_screenshot";
		case "plugins": return "puzzle";
		case "rpg": return "gamepad_variant";
		case "studio": return "palette";
		case "studio-page": return command.glyph;
		case "mouse":
		case "mouse-profile":
		case "mouse-new":
		case "mouse-rumble": return command.glyph ?? "mouse_variant";
		case "niri-settings": return command.glyph ?? (command.page === "keys" ? "keyboard" : (command.page === "displays" ? "monitor_multiple" : "tune_variant"));
		case "calculator":
		case "calculator-result": return "calculator";
		case "file-browser": return "folder";
		case "chat": return "chat";
		case "chats": return "forum";
		case "ollama": return "robot";
		case "translate": return "translate";
		case "converter": return "swap_horizontal";
		case "todo": return "format_list_checks";
		case "web-search": return "web";
		case "ai-actions": return "creation";
		case "phone": return "cellphone";
		case "color-picker": return "eyedropper";
		case "ocr": return "text_recognition";
		case "pin": return "pin_outline";
		case "live": return "cast";
		case "shelf": return "tray_full";
		case "shelf-clipboard": return "content_paste";
		case "qr": return "qrcode_scan";
		case "delay": return "timer_outline";
		case "scroll": return "arrow_expand_vertical";
		case "shots": return "image_multiple";
		case "unpin": return "pin_off_outline";
		case "song": return "waveform";
		case "lyrics": return "microphone_variant";
		case "messages": return "forum_outline";
		case "mail": return "email_plus_outline";
		case "updates": return "package_up";
		case "screentime": return "progress_clock";
		case "identity": return "account_circle";
		case "identities": return "account_multiple";
		case "dnd": return "minus_circle";
		case "vm": return "microsoft_windows";
		case "games": return "gamepad_variant";
		case "torrents": return "magnet";
		case "printer": return "printer_3d";
		case "watch": return "watch";
		}
		return "console";
	}

	// the view of the current mode when it handles keys itself
	// what the apps want of the launcher's height: tall shelves, or as tall as the results
	readonly property real appsHeight: appsView.preferredHeight + searchBox.implicitHeight + 30 + frame.spacing * 2

	readonly property var activeModeView: {
		switch (root.mode) {
		case "translate": return translateView;
		case "convert": return convertView;
		case "todo": return todoView;
		case "web": return webSearchView;
		case "ai": return aiActionsView;
		case "phone": return phoneView;
		case "shots": return shotsView;
		case "finder": return finderView;
		case "apps": return appsView;
		default: return null;
		}
	}
	readonly property string modePlaceholder: {
		switch (root.mode) {
		case "translate": return "Text";
		case "convert": return "5 kg in lb";
		case "todo": return todoView.placeholder;
		case "web": return "Search the web";
		case "ai": return "Ask, find, translate…";
		case "phone": return "Text to send";
		case "finder": return "Search your files";
		case "apps": return "Search apps  ·  > for commands";
		default: return "";
		}
	}
	// what the footer calls a mode Tab does not reach
	readonly property string modeLabel: {
		switch (root.mode) {
		case "commands": return root.openGroup ? root.openGroup.name : "Commands";
		case "translate": return "Translate";
		case "convert": return "Convert";
		case "todo": return "Todo";
		case "web": return "Web Search";
		case "ai": return "AI";
		case "phone": return "Phone";
		case "shots": return "Screenshots";
		case "finder": return "Files";
		default: return "";
		}
	}
	readonly property string enterHint: {
		switch (root.mode) {
		case "chat": return AiChat.editingMessageId !== "" ? "resend" : "send";
		case "calc":
		case "convert":
		case "translate": return "copy";
		case "todo": return todoView.enterHint;
		case "web": return webSearchView.showingResults ? "open" : "search";
		case "ai": return "run";
		case "phone": return "send";
		case "shots": return "copy";
		case "apps": return appsView.zone === "actions" ? "run" : (appsView.current === null && appsView.searching && Plugins.on("web-search") ? "search the web" : "open");
		default: return "open";
		}
	}

	function pathCrumbs(path) {
		const value = String(path || "/");
		const home = Quickshell.env("HOME");
		const crumbs = [];
		let base = "";
		let rest = value;
		if (home && (value === home || value.startsWith(home + "/"))) {
			crumbs.push({ label: "~", path: home });
			base = home;
			rest = value.slice(home.length);
		} else {
			crumbs.push({ label: "/", path: "/" });
		}
		for (const part of rest.split("/").filter(p => p !== "")) {
			base = base === "/" || base === "" ? `${base === "/" ? "" : base}/${part}` : `${base}/${part}`;
			crumbs.push({ label: part, path: base });
		}
		return crumbs;
	}

	function fileGlyph(file) {
		if (file.isDir) return "folder";
		if (file.isImage) return "image";
		const kind = AiChat.attachmentKind(file);
		if (kind === "pdf" || kind === "document") return "file_document";
		if (kind === "text") return "text_box";
		return "file";
	}

	function focusSearch() {
		searchField.cursorPosition = searchField.text.length;
		searchField.forceActiveFocus();
	}

	onModeChanged: {
		root.modelMenuOpen = false;
		if (root.mode === "commands" && !root.openGroup) palette.replay();
	}
	// a group that opens sweeps its commands in
	onOpenGroupChanged: if (root.mode === "commands") palette.replay()

	component ModeLayer: Item {
		id: layer

		required property bool current

		anchors.fill: parent
		opacity: layer.current ? 1 : 0
		visible: opacity > 0.01
		enabled: layer.current
		transform: Translate {
			y: layer.current ? 0 : 14
			Behavior on y {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: layer.current ? Motion.medium : Motion.micro
			}
		}
	}

	component KeyHint: RowLayout {
		id: hint

		required property string key
		required property string label

		spacing: 5

		Rectangle {
			Layout.preferredHeight: 20
			Layout.preferredWidth: Math.max(22, keyText.implicitWidth + 10)
			radius: 6
			color: Theme.layer2

			StyledText {
				id: keyText
				anchors.centerIn: parent
				text: hint.key
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}

		StyledText {
			text: hint.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	component Meta: StyledText {
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
	}

	ColumnLayout {
		id: frame

		anchors.fill: parent
		spacing: 14

		// ── search ────────────────────────────────────────────────────────
		Rectangle {
			id: searchBox

			readonly property bool lit: searchField.activeFocus || commandTokenField.activeFocus || AiChat.editingMessageId !== ""

			Layout.fillWidth: true
			implicitHeight: root.inChatMode
				? Math.min(168, Math.max(56, searchField.contentHeight + 28))
				: 56
			radius: Theme.radius.huge
			color: searchBox.lit ? Theme.layer2 : Theme.layer1
			border.width: 1
			border.color: AiChat.editingMessageId !== "" ? Theme.warning : (searchBox.lit ? Qt.alpha(Theme.primary, 0.45) : Theme.outline)

			// a soft light around the field while something is typed into it
			RectangularShadow {
				z: -1
				anchors.fill: parent
				radius: parent.radius
				blur: 22
				spread: -2
				color: AiChat.editingMessageId !== "" ? Theme.warning : Theme.primary
				opacity: searchBox.lit && root.searchText !== "" ? (Theme.dark ? 0.32 : 0.22) : 0

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}
			}

			Behavior on implicitHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on radius {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			// the mode, on a badge that changes with it
			Rectangle {
				id: lead

				x: 10
				y: root.inChatMode ? 10 : (parent.height - height) / 2
				width: 36
				height: 36
				radius: Theme.radius.medium
				color: searchBox.lit ? Theme.primarySoft : "transparent"

				Behavior on color {
					ColorAnim {}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: root.inputGlyph
					size: 20
					color: searchBox.lit ? Theme.primary : Theme.textMuted
				}
			}

			Rectangle {
				id: commandTokenBox

				x: lead.x + lead.width + 10
				y: root.inChatMode ? 12 : (parent.height - height) / 2
				width: visible ? Math.min(150, Math.max(40, commandTokenField.contentWidth + 22)) : 0
				height: 30
				visible: root.commandInputActive
				radius: 15
				color: commandTokenField.activeFocus ? Theme.primary : Theme.primaryContainer
				scale: visible ? 1 : 0.6

				Behavior on width {
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on color {
					ColorAnim {}
				}

				TextInput {
					id: commandTokenField

					anchors.fill: parent
					anchors.leftMargin: 11
					anchors.rightMargin: 11
					text: ">"
					color: activeFocus ? Theme.onPrimary : Theme.primary
					selectionColor: Qt.alpha(Theme.text, 0.3)
					selectedTextColor: Theme.text
					cursorVisible: activeFocus
					verticalAlignment: Text.AlignVCenter
					clip: true
					font.family: Theme.monoFamily
					font.pixelSize: 14
					font.weight: Font.Bold

					onTextChanged: {
						if (root.commandInputSyncing) return;
						if (text === "") {
							root.leaveCommandInput("");
							return;
						}
						if (!text.startsWith(">")) {
							root.commandInputSyncing = true;
							text = `>${text.replace(/^>+/, "")}`;
							cursorPosition = text.length;
							root.commandInputSyncing = false;
						}
						root.syncLauncherSearch();
					}

					Keys.onEscapePressed: {
						if (!root.activeModeView || !root.activeModeView.cancel()) root.closeRequested();
					}
					Keys.onLeftPressed: event => {
						if (root.mode === "commands") root.movePalette(-1, 0);
						else event.accepted = false;
					}
					Keys.onRightPressed: event => {
						if (root.mode === "commands") root.movePalette(1, 0);
						else event.accepted = false;
					}
					Keys.onPressed: event => {
						if (root.handlePinKey(event)) return;
						if (event.key === Qt.Key_Space) {
							root.focusCommandArgument();
							event.accepted = true;
							return;
						}
						if (event.key === Qt.Key_Backspace && commandTokenField.text === ">") {
							root.leaveCommandInput("");
							event.accepted = true;
							return;
						}
						if (root.activeModeView && root.activeModeView.handleKey(event)) {
							event.accepted = true;
							return;
						}
						if (root.handleModeCycleKey(event)) {
							event.accepted = true;
							return;
						}
						if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
							root.activateCurrent(event.modifiers);
							event.accepted = true;
						}
					}
					Keys.onDownPressed: {
						if (root.activeModeView) {
							root.activeModeView.move(1);
							return;
						}
						if (root.inFileMode) {
							if (root.filteredFileBrowserEntries.length === 0) return;
							fileBrowserList.currentIndex = Math.min(root.filteredFileBrowserEntries.length - 1, fileBrowserList.currentIndex + 1);
							fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
							return;
						}
						root.movePalette(0, 1);
					}
					Keys.onUpPressed: {
						if (root.activeModeView) {
							root.activeModeView.move(-1);
							return;
						}
						if (root.inFileMode) {
							if (root.filteredFileBrowserEntries.length === 0) return;
							fileBrowserList.currentIndex = Math.max(0, fileBrowserList.currentIndex - 1);
							fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
							return;
						}
						root.movePalette(0, -1);
					}
				}
			}

			TextArea {
				id: searchField

				z: 1
				anchors.left: root.commandInputActive ? commandTokenBox.right : lead.right
				anchors.leftMargin: root.commandInputActive ? 6 : 8
				anchors.right: trailing.left
				anchors.rightMargin: 6
				anchors.top: parent.top
				anchors.topMargin: 5
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 5
				color: Theme.text
				placeholderText: root.activeModeView
					? root.modePlaceholder
					: root.inChatMode
					? (AiChat.editingMessageId !== "" ? "Edit your message" : "Message  ·  Shift+Enter for a new line")
					: (root.inAiMode
						? "Search chats"
						: (root.inFileMode
							? "Filter this folder"
							: (root.inCalculatorMode
								? "Expression, e.g. 12*(3+4)"
								: (root.mode === "commands" ? "" : (root.commandInputActive ? "Arguments" : "Search apps  ·  > for commands  ·  /rpg")))))
				placeholderTextColor: Theme.textSubtle
				selectedTextColor: Theme.text
				selectionColor: Qt.alpha(Theme.primary, 0.35)
				selectByMouse: true
				focus: true
				cursorVisible: activeFocus
				clip: true
				wrapMode: root.inChatMode ? TextEdit.Wrap : TextEdit.NoWrap
				horizontalAlignment: Text.AlignLeft
				verticalAlignment: Text.AlignVCenter
				font.family: Theme.fontFamily
				font.pixelSize: root.inChatMode ? 14 : 18
				background: Item {}
				cursorDelegate: Rectangle {
					visible: searchField.activeFocus
					width: 2
					radius: 1
					height: searchField.font.pixelSize + 4
					color: Theme.primary
				}

				// the rest of the name Enter starts, after what is typed
				Text {
					id: ghost

					readonly property rect end: searchField.positionToRectangle(searchField.length)

					x: ghost.end.x + 1
					y: ghost.end.y + (ghost.end.height - height) / 2
					text: root.mode === "apps" ? appsView.completion : ""
					color: Theme.textFaint
					font: searchField.font
					opacity: text !== "" ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				onTextChanged: {
					if (root.commandInputSyncing) return;
					if (!root.commandInputActive && text.startsWith(">")) {
						root.enterCommandInput(text, false);
						return;
					}
					if (root.commandInputActive && text !== "" && !root.commandInputHasSeparator)
						root.commandInputHasSeparator = true;
					root.syncLauncherSearch();
				}

				onActiveFocusChanged: {
					if (!activeFocus || !root.commandInputActive || root.commandInputHasSeparator) return;
					root.commandInputHasSeparator = true;
					root.syncLauncherSearch();
				}

				Keys.onEscapePressed: {
					if (root.modelMenuOpen) root.modelMenuOpen = false;
					else if (!root.activeModeView || !root.activeModeView.cancel()) root.closeRequested();
				}
				Keys.onPressed: event => {
					if (root.handlePinKey(event)) return;
					if (event.key === Qt.Key_Backspace && root.commandInputActive && searchField.text === "" && searchField.cursorPosition === 0) {
						event.accepted = root.focusCommandTokenFromEmptyArgument();
						if (event.accepted) return;
					}
					if (root.activeModeView && root.activeModeView.handleKey(event)) {
						event.accepted = true;
						return;
					}
					if (root.handleModeCycleKey(event)) {
						event.accepted = true;
						return;
					}
					if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;
					if (root.inChatMode && (event.modifiers & Qt.ShiftModifier)) {
						searchField.insert(searchField.cursorPosition, "\n");
						event.accepted = true;
						return;
					}
					root.activateCurrent(event.modifiers);
					event.accepted = true;
				}
				Keys.onLeftPressed: event => {
					if (root.mode === "commands") root.movePalette(-1, 0);
					else event.accepted = false;
				}
				Keys.onRightPressed: event => {
					if (root.mode === "commands") root.movePalette(1, 0);
					else event.accepted = false;
				}
				Keys.onReleased: event => {
					if (root.mode === "apps") appsView.handleKeyRelease(event);
				}
				Keys.onDownPressed: {
					if (root.activeModeView) {
						root.activeModeView.move(1);
						return;
					}
					if (root.inFileMode) {
						if (root.filteredFileBrowserEntries.length === 0) return;
						fileBrowserList.currentIndex = Math.min(root.filteredFileBrowserEntries.length - 1, fileBrowserList.currentIndex + 1);
						fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
						return;
					}
					if (root.inCommandMode && !root.inCalculatorMode && !root.inAiMode && !root.inChatMode && !root.inOllamaMode)
						root.movePalette(0, 1);
				}
				Keys.onUpPressed: {
					if (root.activeModeView) {
						root.activeModeView.move(-1);
						return;
					}
					if (root.inFileMode) {
						if (root.filteredFileBrowserEntries.length === 0) return;
						fileBrowserList.currentIndex = Math.max(0, fileBrowserList.currentIndex - 1);
						fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
						return;
					}
					if (root.inCommandMode && !root.inCalculatorMode && !root.inAiMode && !root.inChatMode && !root.inOllamaMode)
						root.movePalette(0, -1);
				}
			}

			Row {
				id: trailing

				anchors.right: parent.right
				anchors.rightMargin: 9
				y: root.inChatMode ? parent.height - height - 9 : (parent.height - height) / 2
				spacing: 4

				IconButton {
					visible: root.inChatMode && !AiChat.aiStreaming
					width: 36
					height: 36
					icon: "paperclip"
					iconSize: 18
					checked: root.aiAttachmentPickerOpen
					onClicked: root.aiAttachmentPickerOpen ? root.closeAttachmentPicker() : root.openAttachmentPicker()
				}

				IconButton {
					visible: root.inChatMode && !AiChat.aiStreaming
					width: 36
					height: 36
					icon: "send"
					iconSize: 17
					variant: "filled"
					enabled: root.chatPrompt !== "" || AiChat.aiPendingAttachments.length > 0
					onClicked: root.activateCurrent()
				}

				IconButton {
					visible: (AiChat.aiStreaming && root.inChatMode) || root.commandInputActive || searchField.text !== ""
					width: 36
					height: 36
					icon: AiChat.aiStreaming && root.inChatMode ? "stop" : "close"
					iconSize: 18
					variant: AiChat.aiStreaming && root.inChatMode ? "danger" : "ghost"
					onClicked: {
						if (AiChat.aiStreaming && root.inChatMode) AiChat.cancelAiStream();
						else if (AiChat.editingMessageId !== "") AiChat.cancelMessageEdit();
						else root.leaveCommandInput("");
					}
				}
			}
		}

		// ── body ──────────────────────────────────────────────────────────
		Item {
			id: body

			Layout.fillWidth: true
			Layout.fillHeight: true

			// apps: a dock and shelves while browsing, a spotlight and the results while searching
			ModeLayer {
				current: root.mode === "apps"

				AppsView {
					id: appsView

					anchors.fill: parent
					active: root.mode === "apps"
					query: root.mode === "apps" ? root.searchText : ""
					usage: AppUsage.usageMap
					commands: root.appCommands
					commandPins: root.commandPins
					cursorAtEnd: searchField.cursorPosition === searchField.length
					iconFor: entry => AppIcons.forEntry(entry)
					glyphFor: command => root.commandGlyph(command)
					onLaunchRequested: entry => root.launchApp(entry)
					onActionRequested: (entry, action) => root.launchAppAction(entry, action)
					onCommandRequested: command => root.launchCommand(command)
					onCommandPinRequested: command => root.togglePin(command)
					onWebSearchRequested: text => root.setLauncherSearch(`>w ${text}`)
					onCloseRequested: root.closeRequested()
				}
			}

			// commands
			ModeLayer {
				current: root.mode === "commands"

				CommandPalette {
					id: palette

					anchors.fill: parent
					sections: root.paletteSections
					current: root.paletteIndex
					onPointed: index => root.paletteIndex = index
					onActivated: index => root.launchCommand(root.paletteCells[index].command)
					onPinRequested: index => root.togglePin(root.paletteCells[index].command)
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.paletteCells.length > 0 && !root.paletteCells.some(cell => cell.match)
					icon: "console"
					title: "Unknown command"
				}
			}

			// calculator
			ModeLayer {
				current: root.mode === "calc"

				Clickable {
					anchors.centerIn: parent
					width: Math.min(parent.width, 560)
					height: calcColumn.implicitHeight + 40
					radius: Theme.radius.huge
					color: Theme.layer1
					interactive: root.calculatorEvaluation.valid
					pressedScale: 0.97
					onClicked: root.launchCommand(root.calculatorCommand())

					ColumnLayout {
						id: calcColumn

						anchors.centerIn: parent
						width: parent.width - 40
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							visible: text !== ""
							text: root.calculatorExpression
							horizontalAlignment: Text.AlignHCenter
							tone: Theme.textMuted
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.title
						}

						StyledText {
							Layout.fillWidth: true
							horizontalAlignment: Text.AlignHCenter
							text: root.calculatorEvaluation.valid ? `= ${root.calculatorEvaluation.result}` : "Calculator"
							tone: root.calculatorEvaluation.valid ? Theme.primary : Theme.textSubtle
							elide: Text.ElideMiddle
							tabular: true
							font.pixelSize: 54
							font.weight: Font.Bold
							fontSizeMode: Text.HorizontalFit
							minimumPixelSize: 22
						}

						RowLayout {
							Layout.alignment: Qt.AlignHCenter
							spacing: 8

							Glyph {
								visible: root.calculatorEvaluation.valid
								icon: "content_copy"
								size: 14
								color: Theme.textMuted
							}

							StyledText {
								text: root.calculatorEvaluation.valid ? "Enter copies the result" : root.calculatorEvaluation.message
								tone: root.calculatorEvaluation.valid ? Theme.textMuted : Theme.danger
								font.pixelSize: Theme.size.label
								font.weight: Font.Medium
							}
						}
					}
				}
			}

			// translator
			ModeLayer {
				current: root.mode === "translate"

				TranslateView {
					id: translateView

					anchors.fill: parent
					active: root.mode === "translate"
					argument: root.modeArgument
					onCloseRequested: {
						root.closeRequested();
						root.launchRequested();
					}
					onArgumentRequested: text => root.setLauncherSearch(`>t ${text}`)
				}
			}

			// converter
			ModeLayer {
				current: root.mode === "convert"

				ConvertView {
					id: convertView

					anchors.fill: parent
					active: root.mode === "convert"
					argument: root.modeArgument
					onCloseRequested: {
						root.closeRequested();
						root.launchRequested();
					}
					onArgumentRequested: text => root.setLauncherSearch(`>conv ${text}`)
				}
			}

			// tasks and notes
			ModeLayer {
				current: root.mode === "todo"

				TodoView {
					id: todoView

					anchors.fill: parent
					active: root.mode === "todo"
					argument: root.modeArgument
					onCloseRequested: {
						root.closeRequested();
						root.launchRequested();
					}
					onArgumentRequested: text => root.setLauncherSearch(`>todo ${text}`)
				}
			}

			// web search
			ModeLayer {
				current: root.mode === "web"

				WebSearchView {
					id: webSearchView

					anchors.fill: parent
					active: root.mode === "web"
					argument: root.modeArgument
					onCloseRequested: {
						root.closeRequested();
						root.launchRequested();
					}
				}
			}

			// ollama actions on the clipboard
			ModeLayer {
				current: root.mode === "ai"

				AiActionsView {
					id: aiActionsView

					anchors.fill: parent
					active: root.mode === "ai"
					argument: root.modeArgument
					model: AiChat.selectedAiModel
					models: AiChat.aiModels.map(model => String(model.name || model.model || ""))
					busy: AiChat.aiStreaming
					onRunRequested: (prompt, text) => root.runClipboardAction(prompt, text)
					onChatRequested: prompt => {
						AiChat.startNewChat();
						if (prompt !== "") AiChat.sendChatPrompt(prompt);
					}
					onCommandRequested: query => root.setLauncherSearch(query)
					onFilesRequested: query => {
						if (query !== "") Files.goTo({ kind: "search", path: Files.home, query: query, ai: true });
						else Files.show({ paths: [], kind: "search", query: "", newTab: false });
						root.closeRequested();
					}
				}
			}

			// kde connect
			ModeLayer {
				current: root.mode === "phone"

				PhoneView {
					id: phoneView

					anchors.fill: parent
					active: root.mode === "phone"
					argument: root.modeArgument
					onCloseRequested: {
						root.closeRequested();
						root.launchRequested();
					}
					onPickFileRequested: root.pickFileForPhone()
				}
			}

			// files, with the file manager on
			ModeLayer {
				current: root.mode === "finder"

				FileFinderView {
					id: finderView

					anchors.fill: parent
					active: root.mode === "finder"
					argument: root.modeArgument
					onCloseRequested: root.closeRequested()
				}
			}

			// screenshots of this session
			ModeLayer {
				current: root.mode === "shots"

				ShotsView {
					id: shotsView

					anchors.fill: parent
					active: root.mode === "shots"
					argument: root.modeArgument
					onCloseRequested: root.closeRequested()
				}
			}

			// files
			ModeLayer {
				current: root.mode === "files"

				ColumnLayout {
					anchors.fill: parent
					spacing: 10

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						IconButton {
							icon: "arrow_up"
							variant: "tonal"
							onClicked: root.fileBrowserDirectory = root.attachmentParentDirectory(root.fileBrowserDirectory)
						}

						Flickable {
							id: crumbFlick

							Layout.fillWidth: true
							Layout.preferredHeight: 34
							contentWidth: crumbRow.implicitWidth
							clip: true
							boundsBehavior: Flickable.StopAtBounds
							onContentWidthChanged: contentX = Math.max(0, contentWidth - width)

							Row {
								id: crumbRow

								height: parent.height
								spacing: 2

								Repeater {
									model: root.pathCrumbs(root.fileBrowserDirectory)

									delegate: Row {
										id: crumb

										required property var modelData
										required property int index

										height: crumbRow.height
										spacing: 2

										Glyph {
											visible: crumb.index > 0
											anchors.verticalCenter: parent.verticalCenter
											icon: "chevron_right"
											size: 14
											color: Theme.textSubtle
										}

										Clickable {
											anchors.verticalCenter: parent.verticalCenter
											implicitHeight: 30
											implicitWidth: crumbLabel.implicitWidth + 18
											radius: 15
											pressedScale: 0.92
											onClicked: root.fileBrowserDirectory = crumb.modelData.path

											StyledText {
												id: crumbLabel
												anchors.centerIn: parent
												text: crumb.modelData.label
												font.pixelSize: Theme.size.label
												font.weight: crumb.modelData.path === root.fileBrowserDirectory ? Font.Bold : Font.Medium
												tone: crumb.modelData.path === root.fileBrowserDirectory ? Theme.text : Theme.textMuted
											}
										}
									}
								}
							}
						}

						IconButton {
							icon: "folder_open"
							variant: "tonal"
							onClicked: root.openPathWithDefaultApp(root.fileBrowserDirectory)
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						Repeater {
							model: [
								{ name: "Home", icon: "home", path: Quickshell.env("HOME") },
								{ name: "Downloads", icon: "download", path: `${Quickshell.env("HOME")}/Downloads` },
								{ name: "Documents", icon: "file_document", path: `${Quickshell.env("HOME")}/Documents` },
								{ name: "Pictures", icon: "image", path: `${Quickshell.env("HOME")}/Pictures` }
							]

							delegate: Chip {
								required property var modelData
								text: modelData.name
								icon: modelData.icon
								selected: root.fileBrowserDirectory === String(modelData.path)
								onClicked: root.fileBrowserDirectory = String(modelData.path)
							}
						}

						Item {
							Layout.fillWidth: true
						}

						Meta {
							text: root.fileBrowserSearchQuery === ""
								? `${root.fileBrowserEntries.length} items`
								: `${root.filteredFileBrowserEntries.length} matches`
						}
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						ListView {
							id: fileBrowserList

							anchors.fill: parent
							clip: true
							spacing: 2
							model: root.filteredFileBrowserEntries
							currentIndex: model.length > 0 ? 0 : -1
							boundsBehavior: Flickable.StopAtBounds
							ScrollBar.vertical: ThinScrollBar {}

							populate: Transition {
								Anim {
									property: "opacity"
									from: 0
									to: 1
									duration: Motion.short
								}
							}

							delegate: Clickable {
								id: fileRow

								required property var modelData
								required property int index
								readonly property var file: modelData || ({})
								readonly property bool selected: fileBrowserList.currentIndex === fileRow.index

								width: fileBrowserList.width
								implicitHeight: 48
								radius: Theme.radius.medium
								pressedScale: 0.98
								showHover: false
								color: fileRow.selected ? Theme.primaryContainer : (fileRow.hovered ? Theme.layer1 : "transparent")
								onPointed: fileBrowserList.currentIndex = fileRow.index
								onClicked: root.openFileBrowserEntry(fileRow.file)

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 8
									anchors.rightMargin: 8
									spacing: 12

									ClippingRectangle {
										Layout.preferredWidth: 34
										Layout.preferredHeight: 34
										radius: fileRow.file.isDir ? Theme.radius.small : 17
										color: fileRow.file.isDir ? Qt.alpha(Theme.primary, 0.18) : Theme.layer2

										Image {
											anchors.fill: parent
											visible: Boolean(fileRow.file.isImage)
											source: fileRow.file.isImage ? root.resolveMarkdownImageSource(fileRow.file.path) : ""
											sourceSize: Qt.size(68, 68)
											fillMode: Image.PreserveAspectCrop
											asynchronous: true
											cache: true
										}

										Glyph {
											anchors.centerIn: parent
											visible: !fileRow.file.isImage
											icon: root.fileGlyph(fileRow.file)
											size: 18
											color: fileRow.file.isDir ? Theme.primary : Theme.textMuted
										}
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 0

										StyledText {
											Layout.fillWidth: true
											text: String(fileRow.file.name || "")
											elide: Text.ElideMiddle
											font.pixelSize: Theme.size.body
											font.weight: Font.Medium
										}

										Meta {
											Layout.fillWidth: true
											text: fileRow.file.isDir ? "Folder" : `${fileRow.file.suffix || "file"} · ${Format.bytes(fileRow.file.size)}`
										}
									}

									IconButton {
										visible: Boolean(fileRow.file.isDir)
										Layout.preferredWidth: 30
										Layout.preferredHeight: 30
										icon: "folder_open"
										iconSize: 16
										opacity: fileRow.hovered || fileRow.selected ? 1 : 0
										onClicked: root.openPathWithDefaultApp(fileRow.file.path)

										Behavior on opacity {
											Anim {
												duration: Motion.short
											}
										}
									}

									Glyph {
										visible: Boolean(fileRow.file.isDir)
										icon: "chevron_right"
										size: 16
										color: Theme.textSubtle
									}
								}
							}
						}

						Spinner {
							anchors.centerIn: parent
							width: 26
							height: 26
							visible: fileBrowserList.count === 0 && root.fileBrowserDirectoryLoading
						}

						EmptyState {
							anchors.centerIn: parent
							visible: fileBrowserList.count === 0 && !root.fileBrowserDirectoryLoading
							icon: root.fileBrowserDirectoryError !== "" ? "alert_circle" : "folder"
							title: root.fileBrowserDirectoryError !== ""
								? "Can't read this folder"
								: (root.fileBrowserSearchQuery === "" ? "This folder is empty" : "No matching files")
							subtitle: root.fileBrowserDirectoryError
						}
					}
				}
			}

			// saved chats
			ModeLayer {
				current: root.mode === "chats"

				ColumnLayout {
					anchors.fill: parent
					spacing: 10

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							Layout.fillWidth: true
							text: "Chats"
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}

						TextButton {
							text: "New chat"
							icon: "plus"
							variant: "filled"
							onActivated: AiChat.startNewChat()
						}
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						ListView {
							id: pastChatList

							anchors.fill: parent
							clip: true
							spacing: 2
							model: root.filteredAiChats
							boundsBehavior: Flickable.StopAtBounds
							ScrollBar.vertical: ThinScrollBar {}

							displaced: Transition {
								SpatialAnim {
									property: "y"
									duration: Motion.medium
								}
							}

							delegate: ListItem {
								id: chatRow

								required property var modelData
								readonly property bool streamingHere: AiChat.aiStreaming && String(chatRow.modelData.id || "") === AiChat.aiStreamingChatId

								width: pastChatList.width
								icon: chatRow.streamingHere ? "progress_clock" : "chat"
								title: chatRow.modelData.title || "Untitled chat"
								subtitle: `${chatRow.modelData.model || "Unknown model"} · ${root.formatChatTime(chatRow.modelData.updatedAt)} · ${(chatRow.modelData.messages || []).length} messages`
								selected: String(chatRow.modelData.id || "") === AiChat.activeChatId
								onClicked: AiChat.openPastChat(chatRow.modelData)

								IconButton {
									Layout.preferredWidth: 30
									Layout.preferredHeight: 30
									icon: "delete_outline"
									iconSize: 16
									variant: "danger"
									enabled: !chatRow.streamingHere
									opacity: chatRow.hovered ? 1 : 0
									onClicked: AiChat.deleteChat(chatRow.modelData)

									Behavior on opacity {
										Anim {
											duration: Motion.short
										}
									}
								}
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: root.filteredAiChats.length === 0
							icon: "forum"
							title: root.chatsSearchQuery === "" ? "No saved chats" : "No matching chats"
							subtitle: root.chatsSearchQuery === "" ? "Turn off Temporary in a chat to keep it here." : ""
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: AiChat.aiError !== ""
						text: AiChat.aiError
						tone: Theme.danger
						horizontalAlignment: Text.AlignHCenter
						font.pixelSize: Theme.size.small
					}
				}
			}

			// ollama manager
			ModeLayer {
				current: root.mode === "ollama"

				ColumnLayout {
					anchors.fill: parent
					spacing: 12

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								text: "Ollama"
								font.pixelSize: Theme.size.heading
								font.weight: Font.Bold
							}

							Meta {
								Layout.fillWidth: true
								text: AiChat.ollamaVersion !== "" ? `v${AiChat.ollamaVersion} · ${AiChat.aiModels.length} models installed` : `${AiChat.aiModels.length} models installed`
							}
						}

						IconButton {
							icon: "refresh"
							variant: "tonal"
							onClicked: AiChat.refreshOllamaOverview()

							RotationAnimator on rotation {
								running: AiChat.aiModelsLoading || AiChat.ollamaRunningLoading
								loops: Animation.Infinite
								from: 0
								to: 360
								duration: 900
							}
						}
					}

					Rectangle {
						Layout.fillWidth: true
						implicitHeight: pullColumn.implicitHeight + 24
						radius: Theme.radius.huge
						color: Theme.layer1

						ColumnLayout {
							id: pullColumn

							x: 12
							y: 12
							width: parent.width - 24
							spacing: 10

							RowLayout {
								Layout.fillWidth: true
								spacing: 8

								Field {
									id: ollamaPullField

									Layout.fillWidth: true
									icon: "download"
									placeholder: "Pull a model, e.g. qwen3:4b"
									text: AiChat.ollamaPullModel
									enabled: !AiChat.ollamaPulling
									onEdited: text => AiChat.ollamaPullModel = text
									onAccepted: AiChat.startOllamaPull(ollamaPullField.text)
								}

								TextButton {
									implicitHeight: 40
									text: "Pull"
									variant: "filled"
									enabled: AiChat.ollamaPullModel.trim() !== "" && !AiChat.ollamaPulling
									busy: AiChat.ollamaPulling
									onActivated: AiChat.startOllamaPull(AiChat.ollamaPullModel)
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								visible: AiChat.ollamaPulling
								spacing: 6

								RowLayout {
									Layout.fillWidth: true

									StyledText {
										Layout.fillWidth: true
										text: AiChat.ollamaPullStatus
										font.pixelSize: Theme.size.small
										font.weight: Font.Medium
									}

									Meta {
										text: [
											AiChat.ollamaPullTotal > 0 ? `${Math.round(AiChat.ollamaPullProgress * 100)}%` : "",
											AiChat.formatTransferRate(AiChat.ollamaPullSpeed),
											AiChat.formatDuration(AiChat.ollamaPullEtaSeconds) !== "" ? `${AiChat.formatDuration(AiChat.ollamaPullEtaSeconds)} left` : ""
										].filter(value => value !== "").join(" · ")
										tabular: true
									}
								}

								Rectangle {
									Layout.fillWidth: true
									implicitHeight: 8
									radius: 4
									color: Theme.layer3

									Rectangle {
										height: parent.height
										radius: 4
										width: parent.width * AiChat.ollamaPullProgress
										color: Theme.primary

										Behavior on width {
											Anim {}
										}
									}
								}
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						Rectangle {
							Layout.preferredWidth: 10
							Layout.preferredHeight: 10
							radius: 5
							color: AiChat.ollamaRunningModels.length > 0 ? Theme.success : Theme.textFaint
						}

						StyledText {
							text: "Running"
							font.weight: Font.DemiBold
						}

						Meta {
							Layout.fillWidth: true
							text: AiChat.ollamaRunningSummary()
						}
					}

					SectionLabel {
						text: "Installed"
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						ListView {
							id: ollamaInstalledList

							anchors.fill: parent
							clip: true
							spacing: 2
							model: AiChat.aiModels
							boundsBehavior: Flickable.StopAtBounds
							ScrollBar.vertical: ThinScrollBar {}

							delegate: ListItem {
								id: modelRow

								required property var modelData
								readonly property string modelName: String(modelData?.name || modelData?.model || "")
								readonly property bool running: AiChat.isOllamaModelRunning(modelName)
								readonly property bool removing: AiChat.ollamaRemovingModel === modelName

								width: ollamaInstalledList.width
								icon: "robot"
								iconBackground: modelRow.running ? Qt.alpha(Theme.success, 0.25) : Theme.layer2
								title: modelRow.modelName
								subtitle: [
									modelRow.running ? "running" : "",
									String(modelRow.modelData?.details?.parameter_size || ""),
									String(modelRow.modelData?.details?.quantization_level || ""),
									AiChat.formatModelSize(modelRow.modelData?.size)
								].filter(value => value !== "").join(" · ")
								selected: modelRow.modelName === AiChat.selectedAiModel
								showHover: true

								TextButton {
									implicitHeight: 30
									text: "Chat"
									icon: "chat"
									enabled: !AiChat.aiStreaming
									onActivated: AiChat.startNewChatWithModel(modelRow.modelName)
								}

								TextButton {
									implicitHeight: 30
									text: ""
									icon: "delete_outline"
									variant: "danger"
									confirm: true
									confirmText: "Remove"
									busy: modelRow.removing
									enabled: !AiChat.aiStreaming && AiChat.ollamaRemovingModel === ""
									onActivated: AiChat.removeOllamaModel(modelRow.modelName)
								}
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: !AiChat.aiModelsLoading && AiChat.aiModels.length === 0
							icon: "robot"
							title: "No models installed"
							subtitle: "Pull one above to start chatting."
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: AiChat.ollamaManagerError !== "" || (!AiChat.aiModelsLoading && AiChat.aiModels.length === 0 && AiChat.aiError !== "")
						text: AiChat.ollamaManagerError !== "" ? AiChat.ollamaManagerError : AiChat.aiError
						tone: Theme.danger
						horizontalAlignment: Text.AlignHCenter
						font.pixelSize: Theme.size.small
					}
				}
			}

			// chat
			ModeLayer {
				current: root.mode === "chat"

				ColumnLayout {
					anchors.fill: parent
					spacing: 8

					RowLayout {
						id: chatHeader

						Layout.fillWidth: true
						spacing: 8
						z: 5

						IconButton {
							icon: "arrow_left"
							variant: "tonal"
							onClicked: root.openAiOverview()
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: AiChat.activeChat?.title || (AiChat.aiTemporaryChatEnabled ? "Temporary chat" : "New chat")
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}

							Meta {
								Layout.fillWidth: true
								text: AiChat.aiTemporaryChatEnabled ? "Not saved to history" : "Saved to history"
							}
						}

						Clickable {
							id: modelChip

							implicitHeight: 32
							implicitWidth: Math.min(220, modelChipRow.implicitWidth + 24)
							radius: 16
							color: root.modelMenuOpen ? Theme.primaryContainer : Theme.layer2
							interactive: !AiChat.aiStreaming && AiChat.aiModels.length > 0
							opacity: interactive ? 1 : 0.55
							pressedScale: 0.94
							onClicked: root.modelMenuOpen = !root.modelMenuOpen

							RowLayout {
								id: modelChipRow

								anchors.centerIn: parent
								width: Math.min(implicitWidth, 196)
								spacing: 6

								Glyph {
									icon: "robot"
									size: 15
									color: Theme.primary
								}

								StyledText {
									Layout.fillWidth: true
									text: AiChat.selectedAiModel || "No model"
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}

								Glyph {
									icon: "chevron_down"
									size: 14
									color: Theme.textMuted
									rotation: root.modelMenuOpen ? 180 : 0

									Behavior on rotation {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}
						}

						Chip {
							text: "Think"
							icon: "brain"
							selected: AiChat.effectiveAiThinkingEnabled
							enabled: !AiChat.aiStreaming && AiChat.selectedAiSupportsThinking
							opacity: enabled ? 1 : 0.45
							onClicked: AiChat.toggleAiThinking()
						}

						Chip {
							text: "Short"
							icon: "lightning_bolt"
							selected: AiChat.aiShortResponseEnabled
							enabled: !AiChat.aiStreaming
							opacity: enabled ? 1 : 0.45
							onClicked: AiChat.toggleShortResponse()
						}

						Chip {
							text: "Temporary"
							icon: "ghost"
							selected: AiChat.aiTemporaryChatEnabled
							enabled: !AiChat.aiStreaming
							opacity: enabled ? 1 : 0.45
							onClicked: AiChat.toggleTemporaryChat()
						}
					}

					RowLayout {
						id: chatInfoBar

						Layout.fillWidth: true
						spacing: 10

						Meta {
							text: "Context"
						}

						Rectangle {
							Layout.preferredWidth: 140
							implicitHeight: 6
							radius: 3
							color: Theme.layer3

							Rectangle {
								height: parent.height
								radius: 3
								width: parent.width * AiChat.activeContextProgress
								color: AiChat.activeContextProgress > 0.85 ? Theme.danger : Theme.primary

								Behavior on width {
									Anim {}
								}
							}
						}

						Meta {
							text: `${AiChat.formatTokenCount(AiChat.activeContextUsed)} / ${AiChat.formatTokenCount(AiChat.activeContextLimit)}`
							tabular: true
						}

						Meta {
							visible: AiChat.activeResponseTokens > 0
							text: `${AiChat.activeTokensPerSecond.toFixed(1)} tok/s · ${AiChat.activeResponseTokens} tokens`
							tabular: true
						}

						Item {
							Layout.fillWidth: true
						}

						Rectangle {
							visible: AiChat.chatLoadedTimerText !== ""
							Layout.preferredHeight: 22
							Layout.preferredWidth: loadedRow.implicitWidth + 16
							radius: 11
							color: Theme.layer1

							RowLayout {
								id: loadedRow

								anchors.centerIn: parent
								spacing: 5

								Rectangle {
									Layout.preferredWidth: 7
									Layout.preferredHeight: 7
									radius: 3.5
									color: AiChat.chatLoadedModel ? Theme.success : Theme.textFaint
								}

								Meta {
									text: AiChat.chatLoadedTimerText
									tabular: true
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}

					Item {
						id: chatBody

						Layout.fillWidth: true
						Layout.fillHeight: true

						ListView {
							id: chatList

							anchors.fill: parent
							clip: true
							spacing: 10
							cacheBuffer: 800
							reuseItems: false
							model: chatMessageModel
							boundsBehavior: Flickable.StopAtBounds
							ScrollBar.vertical: ThinScrollBar {}

							onContentHeightChanged: root.followChatImmediately()
							onMovementStarted: root.chatAutoFollow = false
							onMovementEnded: root.chatAutoFollow = root.chatNearEnd()

							add: Transition {
								ParallelAnimation {
									Anim {
										property: "opacity"
										from: 0
										to: 1
									}
									SpatialAnim {
										property: "y"
										from: chatList.contentHeight
									}
								}
							}

							delegate: Item {
								id: messageRow

								required property var entry
								required property int index
								readonly property bool fromUser: entry.role === "user"
								readonly property string responseModelName: !fromUser && String(entry.model || "") !== "" ? String(entry.model) : ""
								readonly property bool hasThinking: entry.role === "assistant"
									&& Boolean(AiChat.activeChat?.thinkingEnabled)
									&& String(entry.thinking || "") !== ""
								readonly property bool loadingModel: entry.role === "assistant"
									&& entry.streaming
									&& String(entry.content || "") === ""
									&& String(entry.thinking || "") === ""
								readonly property string displayText: String(entry.content || "") !== ""
									? String(entry.content)
									: (loadingModel ? "" : (entry.streaming ? "..." : ""))
								readonly property var attachments: AiChat.messageAttachments(entry)
								readonly property var markdownSegments: root.markdownImageSegments(displayText)
								readonly property bool hasMarkdownImages: markdownSegments.some(segment => segment.kind === "image")
								readonly property string markdownTextOnly: markdownSegments
									.filter(segment => segment.kind === "text")
									.map(segment => String(segment.text || ""))
									.join("\n")
								readonly property bool editingThis: AiChat.editingMessageId !== "" && AiChat.editingMessageId === String(entry.id || "")

								width: chatList.width
								height: bubble.height + (messageRow.responseModelName !== "" ? 18 : 0)

								HoverHandler {
									id: rowHover
								}

								StyledText {
									visible: messageRow.responseModelName !== ""
									x: 6
									text: messageRow.responseModelName
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.tiny
									font.weight: Font.Bold
								}

								Rectangle {
									id: bubble

									y: messageRow.responseModelName !== "" ? 18 : 0
									width: messageRow.loadingModel
										? loadingRow.implicitWidth + 32
										: Math.min(
											messageRow.width * 0.8,
											Math.max(
												messageRow.hasMarkdownImages || messageRow.attachments.length > 0 ? messageRow.width * 0.66 : 120,
												Math.max(messageText.implicitWidth, thinkingText.implicitWidth) + 32
											)
										)
									height: messageRow.loadingModel ? 40 : bubbleBody.implicitHeight + 24
									x: messageRow.fromUser ? messageRow.width - width : 0
									radius: 18
									topRightRadius: messageRow.fromUser ? 6 : 18
									topLeftRadius: messageRow.fromUser ? 18 : 6
									color: messageRow.fromUser ? Theme.primaryContainer : Theme.layer1
									border.width: messageRow.editingThis ? 1.5 : 0
									border.color: Theme.warning

									RowLayout {
										id: loadingRow

										visible: messageRow.loadingModel
										anchors.centerIn: parent
										spacing: 8

										Spinner {
											Layout.preferredWidth: 16
											Layout.preferredHeight: 16
										}

										Meta {
											text: messageRow.responseModelName !== "" ? `Loading ${messageRow.responseModelName}…` : "Loading model…"
										}
									}

									Column {
										id: bubbleBody

										visible: !messageRow.loadingModel
										x: 14
										y: 12
										width: parent.width - 28
										spacing: 8

										Clickable {
											id: thinkingHeader

											visible: messageRow.hasThinking
											width: parent.width
											implicitHeight: 28
											radius: 14
											color: Theme.layer2
											pressedScale: 0.98
											onClicked: AiChat.toggleThinkingExpanded(messageRow.entry.id)

											RowLayout {
												anchors.fill: parent
												anchors.leftMargin: 10
												anchors.rightMargin: 10
												spacing: 6

												Glyph {
													icon: "brain"
													size: 14
													color: Theme.secondary
												}

												StyledText {
													Layout.fillWidth: true
													text: messageRow.entry.streaming && String(messageRow.entry.thinking || "") !== ""
														? "Thinking…"
														: (AiChat.thinkingExpanded(messageRow.entry.id) ? "Reasoning" : "Show reasoning")
													tone: Theme.textMuted
													font.pixelSize: Theme.size.small
													font.weight: Font.Medium
												}

												Glyph {
													icon: "chevron_down"
													size: 14
													color: Theme.textMuted
													rotation: AiChat.thinkingExpanded(messageRow.entry.id) ? 180 : 0

													Behavior on rotation {
														SpatialAnim {
															duration: Motion.medium
														}
													}
												}
											}
										}

										Flow {
											visible: messageRow.attachments.length > 0
											width: parent.width
											height: implicitHeight
											spacing: 6

											Repeater {
												model: messageRow.attachments

												delegate: Rectangle {
													id: sentChip

													required property var modelData

													width: Math.min(bubbleBody.width, Math.max(110, sentName.implicitWidth + 42))
													height: 28
													radius: 14
													color: Qt.alpha(Theme.bg, 0.35)
													opacity: String(modelData.status || "") === "unavailable" ? 0.55 : 1

													ClippingRectangle {
														x: 4
														anchors.verticalCenter: parent.verticalCenter
														width: 20
														height: 20
														radius: 10
														color: Theme.layer2

														Image {
															anchors.fill: parent
															visible: sentChip.modelData.kind === "image"
															source: sentChip.modelData.kind === "image" ? root.resolveMarkdownImageSource(sentChip.modelData.path) : ""
															fillMode: Image.PreserveAspectCrop
															cache: true
														}

														Glyph {
															anchors.centerIn: parent
															visible: sentChip.modelData.kind !== "image"
															icon: AiChat.isPrimarySelectionAttachment(sentChip.modelData) ? "text_box" : "paperclip"
															size: 12
														}
													}

													StyledText {
														id: sentName

														x: 30
														width: parent.width - 38
														anchors.verticalCenter: parent.verticalCenter
														text: String(sentChip.modelData.name || "Attachment")
														elide: Text.ElideMiddle
														font.pixelSize: Theme.size.small
														font.weight: Font.Medium
													}
												}
											}
										}

										TextEdit {
											id: thinkingText

											visible: messageRow.hasThinking && AiChat.thinkingExpanded(messageRow.entry.id)
											width: parent.width
											color: Theme.textMuted
											text: String(messageRow.entry.thinking || "")
											textFormat: TextEdit.MarkdownText
											baseUrl: Qt.resolvedUrl(".")
											wrapMode: TextEdit.Wrap
											readOnly: true
											selectByMouse: true
											persistentSelection: true
											selectionColor: Qt.alpha(Theme.primary, 0.35)
											selectedTextColor: Theme.text
											font.family: Theme.fontFamily
											font.pixelSize: Theme.size.small
											onLinkActivated: link => Qt.openUrlExternally(link)
											onSelectedTextChanged: root.updateChatSelection(selectedText)

											HoverHandler {
												cursorShape: thinkingText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
											}
										}

										TextEdit {
											id: messageText

											visible: String(messageRow.displayText || "") !== "" && !messageRow.hasMarkdownImages
											width: parent.width
											color: Theme.text
											text: messageRow.hasMarkdownImages ? messageRow.markdownTextOnly : messageRow.displayText
											textFormat: TextEdit.MarkdownText
											baseUrl: Qt.resolvedUrl(".")
											wrapMode: TextEdit.Wrap
											readOnly: true
											selectByMouse: true
											persistentSelection: true
											selectionColor: Qt.alpha(Theme.primary, 0.45)
											selectedTextColor: Theme.text
											font.family: Theme.fontFamily
											font.pixelSize: Theme.size.body
											onLinkActivated: link => Qt.openUrlExternally(link)
											onSelectedTextChanged: root.updateChatSelection(selectedText)

											HoverHandler {
												cursorShape: messageText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
											}
										}

										Column {
											id: markdownImageContent

											visible: messageRow.hasMarkdownImages
											width: parent.width
											spacing: 8

											Repeater {
												model: messageRow.markdownSegments

												delegate: Item {
													id: segment

													required property var modelData

													width: markdownImageContent.width
													height: modelData.kind === "image" ? imageFrame.height : segmentText.implicitHeight

													TextEdit {
														id: segmentText

														visible: segment.modelData.kind === "text"
														width: parent.width
														color: Theme.text
														text: String(segment.modelData.text || "")
														textFormat: TextEdit.MarkdownText
														baseUrl: Qt.resolvedUrl(".")
														wrapMode: TextEdit.Wrap
														readOnly: true
														selectByMouse: true
														persistentSelection: true
														selectionColor: Qt.alpha(Theme.primary, 0.45)
														selectedTextColor: Theme.text
														font.family: Theme.fontFamily
														font.pixelSize: Theme.size.body
														onLinkActivated: link => Qt.openUrlExternally(link)
														onSelectedTextChanged: root.updateChatSelection(selectedText)

														HoverHandler {
															cursorShape: segmentText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
														}
													}

													ClippingRectangle {
														id: imageFrame

														visible: segment.modelData.kind === "image"
														width: parent.width
														height: !visible
															? 0
															: (markdownImage.status === Image.Ready && markdownImage.sourceSize.width > 0
																? Math.min(280, Math.max(80, width * markdownImage.sourceSize.height / markdownImage.sourceSize.width))
																: (markdownImage.status === Image.Error ? 64 : 96))
														radius: Theme.radius.medium
														color: Theme.layer2

														Image {
															id: markdownImage

															anchors.fill: parent
															source: root.resolveMarkdownImageSource(segment.modelData.source)
															fillMode: Image.PreserveAspectFit
															asynchronous: true
															cache: true
															smooth: true
															mipmap: true
														}

														Spinner {
															anchors.centerIn: parent
															visible: markdownImage.status === Image.Loading
														}

														Meta {
															anchors.centerIn: parent
															width: parent.width - 20
															visible: markdownImage.status === Image.Error
															horizontalAlignment: Text.AlignHCenter
															text: String(segment.modelData.alt || "Image could not be loaded")
														}

														MouseArea {
															anchors.fill: parent
															cursorShape: Qt.PointingHandCursor
															onClicked: Qt.openUrlExternally(root.resolveMarkdownImageSource(segment.modelData.source))
														}
													}
												}
											}
										}
									}
								}

								IconButton {
									visible: messageRow.fromUser
									x: bubble.x - width - 6
									y: bubble.y + (bubble.height - height) / 2
									width: 30
									height: 30
									icon: "pencil"
									iconSize: 15
									enabled: !AiChat.aiStreaming
									opacity: rowHover.hovered || messageRow.editingThis ? 1 : 0
									onClicked: AiChat.beginEditMessage(messageRow.entry)

									Behavior on opacity {
										Anim {
											duration: Motion.short
										}
									}
								}
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: AiChat.activeMessages.length === 0
							icon: "chat"
							title: AiChat.selectedAiModel === "" ? "No model selected" : `Ask ${AiChat.selectedAiModel}`
							subtitle: AiChat.selectedAiModel === ""
								? "Install or pick an Ollama model first (>ollama)."
								: "Type below and press Enter. Selected text is attached automatically."
						}
					}

					ListView {
						id: pendingAttachmentBar

						Layout.fillWidth: true
						Layout.preferredHeight: visible ? 32 : 0
						visible: AiChat.aiPendingAttachments.length > 0
						orientation: ListView.Horizontal
						spacing: 6
						clip: true
						model: AiChat.aiPendingAttachments
						boundsBehavior: Flickable.StopAtBounds

						add: Transition {
							SpatialAnim {
								property: "scale"
								from: 0.4
								to: 1
								duration: Motion.medium
							}
						}

						delegate: Rectangle {
							id: pendingChip

							required property var modelData
							readonly property bool loading: String(modelData.status || "") === "loading"

							width: 170
							height: 32
							radius: 16
							color: Theme.layer2
							border.width: pendingChip.loading ? 1 : 0
							border.color: Qt.alpha(Theme.primary, 0.6)
							opacity: pendingChip.modelData.kind === "image" && !AiChat.selectedAiSupportsVision ? 0.45 : 1

							ClippingRectangle {
								x: 5
								anchors.verticalCenter: parent.verticalCenter
								width: 22
								height: 22
								radius: 11
								color: Theme.layer3

								Image {
									anchors.fill: parent
									visible: pendingChip.modelData.kind === "image"
									source: pendingChip.modelData.kind === "image" ? root.resolveMarkdownImageSource(pendingChip.modelData.path) : ""
									fillMode: Image.PreserveAspectCrop
									cache: true
								}

								Spinner {
									anchors.fill: parent
									anchors.margins: 3
									visible: pendingChip.loading
								}

								Glyph {
									anchors.centerIn: parent
									visible: pendingChip.modelData.kind !== "image" && !pendingChip.loading
									icon: AiChat.isPrimarySelectionAttachment(pendingChip.modelData) ? "text_box" : "paperclip"
									size: 12
								}
							}

							StyledText {
								x: 33
								width: parent.width - 33 - 30
								anchors.verticalCenter: parent.verticalCenter
								text: pendingChip.loading ? `Reading ${pendingChip.modelData.name || "file"}…` : String(pendingChip.modelData.name || "Attachment")
								elide: Text.ElideMiddle
								font.pixelSize: Theme.size.small
								font.weight: Font.Medium
							}

							IconButton {
								anchors.right: parent.right
								anchors.rightMargin: 4
								anchors.verticalCenter: parent.verticalCenter
								width: 24
								height: 24
								icon: "close"
								iconSize: 13
								onClicked: AiChat.removePendingAttachment(pendingChip.modelData.id)
							}
						}
					}

					StyledText {
						id: chatError

						Layout.fillWidth: true
						visible: AiChat.aiError !== ""
						text: AiChat.aiError
						tone: Theme.danger
						horizontalAlignment: Text.AlignHCenter
						font.pixelSize: Theme.size.small
						font.weight: Font.Medium
					}
				}

				// model menu
				Rectangle {
					id: modelMenu

					readonly property point anchorPoint: modelChip.mapToItem(parent, 0, modelChip.height + 6)

					z: 20
					x: Math.min(parent.width - width, anchorPoint.x)
					y: anchorPoint.y
					width: 260
					height: root.modelMenuOpen ? Math.min(modelMenuList.contentHeight + 12, 280) : 0
					radius: Theme.radius.large
					color: Theme.layer2
					clip: true
					opacity: root.modelMenuOpen ? 1 : 0
					visible: opacity > 0.01

					Behavior on height {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					ListView {
						id: modelMenuList

						anchors.fill: parent
						anchors.margins: 6
						clip: true
						spacing: 2
						model: AiChat.aiModels
						boundsBehavior: Flickable.StopAtBounds
						ScrollBar.vertical: ThinScrollBar {}

						delegate: Clickable {
							id: modelOption

							required property var modelData
							readonly property string modelName: String(modelData?.name || modelData?.model || "")
							readonly property bool picked: modelOption.modelName === AiChat.selectedAiModel

							width: modelMenuList.width
							implicitHeight: 36
							radius: Theme.radius.medium
							pressedScale: 0.97
							color: modelOption.picked ? Theme.primaryContainer : (modelOption.hovered ? Theme.layer3 : "transparent")
							onClicked: {
								AiChat.selectAiModel(modelOption.modelName);
								root.modelMenuOpen = false;
								searchField.forceActiveFocus();
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 10
								spacing: 8

								StyledText {
									Layout.fillWidth: true
									text: modelOption.modelName
									font.pixelSize: Theme.size.label
									font.weight: modelOption.picked ? Font.Bold : Font.Medium
								}

								Meta {
									text: AiChat.formatModelSize(modelOption.modelData?.size)
									font.pixelSize: Theme.size.tiny
								}

								Glyph {
									visible: modelOption.picked
									icon: "check"
									size: 14
									color: Theme.primary
								}
							}
						}
					}
				}
			}
		}

		// ── footer: the modes Tab walks, and the keys that matter here ──────
		RowLayout {
			Layout.fillWidth: true
			Layout.preferredHeight: 30
			spacing: 10

			Item {
				id: modeStrip

				readonly property int currentIndex: root.modeCycle.findIndex(entry => entry.mode === root.mode)

				Layout.preferredWidth: modeTabs.width
				Layout.preferredHeight: 30

				// the mark under the mode; it stretches on its way like the shelves' one
				Rectangle {
					id: modeMark

					readonly property Item target: modeStrip.currentIndex >= 0 && modeTabRepeater.count > modeStrip.currentIndex ? modeTabRepeater.itemAt(modeStrip.currentIndex) : null
					property real edgeLeft: modeMark.target ? modeMark.target.x : 0
					property real edgeRight: modeMark.target ? modeMark.target.x + modeMark.target.width : 0
					property bool forward: true

					x: modeMark.edgeLeft
					width: Math.max(0, modeMark.edgeRight - modeMark.edgeLeft)
					height: parent.height
					radius: height / 2
					color: Theme.layer2
					opacity: modeMark.target ? 1 : 0

					onTargetChanged: if (modeMark.target) modeMark.forward = modeMark.target.x >= modeMark.x

					Behavior on edgeLeft {
						SpatialAnim {
							duration: modeMark.forward ? Motion.long : Motion.medium
						}
					}
					Behavior on edgeRight {
						SpatialAnim {
							duration: modeMark.forward ? Motion.medium : Motion.long
						}
					}
					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				Row {
					id: modeTabs

					height: parent.height

					Repeater {
						id: modeTabRepeater

						model: root.modeCycle

						delegate: Item {
							id: modeTab

							required property var modelData
							required property int index
							readonly property bool open: modeStrip.currentIndex === modeTab.index
							readonly property bool wide: modeTab.open || modeTabMouse.containsMouse

							width: modeTabGlyph.width + 20 + (modeTab.wide ? modeTabLabel.implicitWidth + 6 : 0)
							height: modeTabs.height
							clip: true

							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Glyph {
								id: modeTabGlyph

								x: 10
								anchors.verticalCenter: parent.verticalCenter
								icon: modeTab.modelData.glyph
								size: 15
								color: modeTab.open ? Theme.primary : Theme.textSubtle
								animated: false
							}

							StyledText {
								id: modeTabLabel

								x: modeTabGlyph.x + modeTabGlyph.width + 6
								anchors.verticalCenter: parent.verticalCenter
								text: modeTab.modelData.label
								tone: modeTab.open ? Theme.text : Theme.textMuted
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								elide: Text.ElideNone
								opacity: modeTab.wide ? 1 : 0

								Behavior on opacity {
									Anim {
										duration: Motion.short
									}
								}
							}

							MouseArea {
								id: modeTabMouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: {
									root.setLauncherSearch(modeTab.modelData.query);
									Qt.callLater(root.focusSearch);
								}
							}
						}
					}
				}
			}

			// a mode Tab does not reach: where the typed command led
			RowLayout {
				spacing: 4
				opacity: modeStrip.currentIndex < 0 && root.modeLabel !== "" ? 1 : 0
				visible: opacity > 0.01

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Glyph {
					icon: "chevron_right"
					size: 14
					color: Theme.textSubtle
					animated: false
				}

				Rectangle {
					Layout.preferredHeight: 26
					Layout.preferredWidth: modeLabelText.implicitWidth + 22
					radius: 13
					color: Theme.primaryContainer

					StyledText {
						id: modeLabelText

						anchors.centerIn: parent
						text: root.modeLabel
						tone: Theme.primary
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			KeyHint {
				key: "↵"
				label: root.enterHint
			}

			KeyHint {
				visible: root.mode === "apps" && appsView.currentWindows.length > 0 && appsView.zone !== "actions"
				key: "⇧↵"
				label: "go to window"
			}

			KeyHint {
				visible: root.mode === "apps" && appsView.current !== null
				key: appsView.searching ? (appsView.zone === "actions" ? "←" : "→") : "^↵"
				label: appsView.zone === "actions" ? "back" : "actions"
			}

			KeyHint {
				visible: root.mode === "apps" && !appsView.searching && appsView.shelves.length > 1
				key: "^←→"
				label: "shelves"
			}

			KeyHint {
				visible: root.mode === "web"
				key: "^↵"
				label: "results"
			}

			KeyHint {
				visible: root.mode === "todo"
				key: "^N"
				label: todoView.newLabel
			}

			KeyHint {
				visible: root.inChatMode
				key: "⇧↵"
				label: "new line"
			}

			KeyHint {
				visible: root.mode === "commands" && root.paletteCommand !== null && root.paletteCommand.id !== "studio-page"
				key: "^P"
				label: root.commandPins.includes(root.paletteCommand?.command) ? "unpin" : "pin"
			}

			KeyHint {
				visible: root.mode === "chat" && AiChat.aiStreaming
				key: "…"
				label: "generating"
			}
		}
	}

	// ── attachment picker ─────────────────────────────────────────────────
	Rectangle {
		id: attachmentPicker

		property real reveal: root.aiAttachmentPickerOpen ? 1 : 0

		anchors.fill: parent
		z: 100
		visible: reveal > 0.01
		color: Theme.base
		radius: Theme.radius.huge
		focus: root.aiAttachmentPickerOpen
		opacity: Math.min(1, reveal * 1.4)

		transform: Translate {
			x: 60 * (1 - attachmentPicker.reveal)
		}

		Behavior on reveal {
			SpatialAnim {
				duration: root.aiAttachmentPickerOpen ? Motion.long : Motion.short
			}
		}

		Keys.onEscapePressed: root.closeAttachmentPicker()

		MouseArea {
			anchors.fill: parent
		}

		ColumnLayout {
			anchors.fill: parent
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				IconButton {
					icon: "arrow_up"
					variant: "tonal"
					onClicked: root.aiAttachmentDirectory = root.attachmentParentDirectory(root.aiAttachmentDirectory)
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						text: "Attach files"
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					Meta {
						Layout.fillWidth: true
						text: root.aiAttachmentDirectory
						elide: Text.ElideMiddle
					}
				}

				TextButton {
					text: "Done"
					icon: "check"
					variant: "filled"
					onActivated: root.closeAttachmentPicker()
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [
						{ name: "Home", icon: "home", path: Quickshell.env("HOME") },
						{ name: "Downloads", icon: "download", path: `${Quickshell.env("HOME")}/Downloads` },
						{ name: "Pictures", icon: "image", path: `${Quickshell.env("HOME")}/Pictures` }
					]

					delegate: Chip {
						required property var modelData
						text: modelData.name
						icon: modelData.icon
						selected: root.aiAttachmentDirectory === String(modelData.path)
						onClicked: root.aiAttachmentDirectory = String(modelData.path)
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Meta {
					text: AiChat.selectedAiSupportsVision ? "Text, documents, PDF and images" : "Text, documents and PDF · images need a vision model"
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				ListView {
					id: attachmentFileList

					anchors.fill: parent
					clip: true
					spacing: 2
					focus: root.aiAttachmentPickerOpen
					model: root.aiAttachmentEntries
					currentIndex: root.aiAttachmentEntries.length > 0 ? 0 : -1
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					Keys.onEscapePressed: root.closeAttachmentPicker()
					Keys.onReturnPressed: root.openAttachmentEntry(currentItem?.modelData)
					Keys.onEnterPressed: root.openAttachmentEntry(currentItem?.modelData)

					delegate: Clickable {
						id: attachRow

						required property var modelData
						required property int index
						readonly property var file: modelData || ({})
						readonly property bool supported: Boolean(file.isDir) || AiChat.attachmentSupported(file)
						readonly property bool picked: AiChat.isAttachmentSelected(file.path)
						readonly property bool current: attachmentFileList.currentIndex === attachRow.index

						width: attachmentFileList.width
						implicitHeight: 46
						radius: Theme.radius.medium
						pressedScale: 0.98
						showHover: false
						interactive: attachRow.file.isDir || (attachRow.supported && AiChat.aiAttachmentLoadingId === "")
						opacity: attachRow.supported ? 1 : 0.4
						color: attachRow.picked ? Theme.primaryContainer : (attachRow.current || attachRow.hovered ? Theme.layer1 : "transparent")
						onPointed: attachmentFileList.currentIndex = attachRow.index
						onClicked: root.openAttachmentEntry(attachRow.file)

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 8
							anchors.rightMargin: 12
							spacing: 12

							ClippingRectangle {
								Layout.preferredWidth: 32
								Layout.preferredHeight: 32
								radius: attachRow.file.isDir ? Theme.radius.small : 16
								color: attachRow.file.isDir ? Qt.alpha(Theme.primary, 0.18) : Theme.layer2

								Image {
									anchors.fill: parent
									visible: Boolean(attachRow.file.isImage)
									source: attachRow.file.isImage ? root.resolveMarkdownImageSource(attachRow.file.path) : ""
									sourceSize: Qt.size(64, 64)
									fillMode: Image.PreserveAspectCrop
									asynchronous: true
									cache: true
								}

								Glyph {
									anchors.centerIn: parent
									visible: !attachRow.file.isImage
									icon: root.fileGlyph(attachRow.file)
									size: 17
									color: attachRow.file.isDir ? Theme.primary : Theme.textMuted
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: String(attachRow.file.name || "")
									elide: Text.ElideMiddle
									font.weight: Font.Medium
								}

								Meta {
									Layout.fillWidth: true
									text: attachRow.file.isDir
										? "Folder"
										: (attachRow.supported
											? `${attachRow.file.mimeType || AiChat.attachmentKind(attachRow.file)} · ${Format.bytes(attachRow.file.size)}`
											: (attachRow.file.isImage ? "Requires a vision model" : "Unsupported file"))
								}
							}

							Glyph {
								icon: attachRow.file.isDir ? "chevron_right" : (attachRow.picked ? "check_circle" : (attachRow.supported ? "plus" : ""))
								size: 18
								color: attachRow.picked ? Theme.primary : Theme.textMuted
							}
						}
					}
				}

				Spinner {
					anchors.centerIn: parent
					width: 26
					height: 26
					visible: attachmentFileList.count === 0 && root.aiAttachmentDirectoryLoading
				}

				EmptyState {
					anchors.centerIn: parent
					visible: attachmentFileList.count === 0 && !root.aiAttachmentDirectoryLoading
					icon: root.aiAttachmentDirectoryError !== "" ? "alert_circle" : "folder"
					title: root.aiAttachmentDirectoryError !== "" ? "Can't read this folder" : "This folder is empty"
					subtitle: root.aiAttachmentDirectoryError
				}
			}
		}
	}
}
