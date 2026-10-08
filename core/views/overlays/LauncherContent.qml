pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.launcher
import "../../lib/fuzzysort.js" as Fuzzy

// Launcher content: apps, commands (>), calculator (>c), files (>file),
// Ollama chats (>chat, >chats), model manager (>ollama), display setup
// (>setup), niri settings (>niri, >keys), translator (>t), converter (>conv), todo lists (>todo), web
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
	property var usageMap: ({})
	property var aiModels: []
	property string selectedAiModel: ""
	property bool aiThinkingEnabled: false
	property bool aiShortResponseEnabled: false
	property var aiChats: []
	property string activeChatId: ""
	property bool aiStreaming: false
	property string aiStreamingChatId: ""
	property bool aiStreamingTemporary: false
	property string aiStreamingModel: ""
	property string aiPendingUnloadModel: ""
	property bool chatAutoFollow: true
	property bool chatSelectionActive: false
	property string aiError: ""
	property string aiProcessError: ""
	property bool aiModelsLoading: false
	property bool aiModelsFallbackRunning: false
	property bool aiStateLoaded: false
	property bool aiInlineThinking: false
	property string aiSuppressedThinkingBuffer: ""
	property string aiInlineProbeBuffer: ""
	property bool aiTemporaryChatEnabled: true
	property var aiTemporaryChat: null
	property var aiThinkingExpandedMap: ({})
	property var aiModelInfo: ({})
	property var aiModelCapabilities: []
	property int aiModelContextWindow: 0
	property bool aiModelInfoLoading: false
	property string aiModelInfoTarget: ""
	property string editingMessageId: ""
	property string ollamaVersion: ""
	property var ollamaRunningModels: []
	property bool ollamaRunningLoading: false
	property string ollamaManagerError: ""
	property string ollamaPsProcessError: ""
	property bool ollamaPsFallbackRunning: false
	property real ollamaRunningLastRefresh: 0
	property real modelLoadedNow: Date.now()
	property string ollamaRemovingModel: ""
	property string ollamaPullModel: ""
	property bool ollamaPulling: false
	property string ollamaPullStatus: ""
	property string ollamaPullDigest: ""
	property real ollamaPullProgress: 0
	property real ollamaPullCompleted: 0
	property real ollamaPullTotal: 0
	property real ollamaPullSpeed: 0
	property real ollamaPullEtaSeconds: 0
	property real ollamaPullStartedAt: 0
	property bool commandInputActive: false
	property bool commandInputHasSeparator: false
	property bool commandInputSyncing: false
	property var aiPendingAttachments: []
	property bool aiAttachmentPickerOpen: false
	property string aiAttachmentDirectory: Quickshell.env("HOME")
	property string aiAttachmentLoadingId: ""
	property string aiAttachmentReadOutput: ""
	property string aiAttachmentReadError: ""
	property bool aiPrimarySelectionLoading: false
	property string aiPrimarySelectionOutput: ""
	property string aiPrimarySelectionError: ""
	property string aiPrimarySelectionMode: ""
	property string aiLastPrimarySelectionContent: ""
	property string aiRequestPayload: ""
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
		{ id: "file-browser", plugin: "files", group: "tools", command: "file", name: "Files", aliases: ["files"], keywords: "browse open folder" },
		{ id: "todo", plugin: "todos", group: "tools", command: "todo", name: "Todo", aliases: ["todos"], keywords: "lists tasks" },
		{ id: "shelf", plugin: "shelves", group: "tools", command: "shelf", name: "Shelf", keywords: "stash files text", status: Shelf.shelves.length > 0 ? String(Shelf.shelves.length) : "" },
		{ id: "shelf-clipboard", plugin: "shelves", group: "tools", command: "shelfclip", name: "Shelf from Clipboard", aliases: ["clipshelf"], keywords: "stash copied" },
		{ id: "identity", plugin: "identities", group: "tools", command: "identity", name: "Fake Identity", aliases: ["fake", "account"], keywords: "new person sign up mail sms phone temporary" },
		{ id: "identities", plugin: "identities", group: "tools", command: "identities", name: "Identities", keywords: "saved fake accounts", status: Identities.saved.length > 0 ? String(Identities.saved.length) : "" },
		{ id: "phone", plugin: Phone.plugin, group: "tools", command: "phone", name: "Phone", keywords: `send ${Phone.name}` },
		{ id: "chat", plugin: "chat", group: "ai", command: "chat", name: "Chat", keywords: "ai assistant" },
		{ id: "chats", plugin: "chat", group: "ai", command: "chats", name: "Chats", keywords: "saved history" },
		{ id: "ai-actions", plugin: "ai-actions", group: "ai", command: "ai", name: "AI Actions", aliases: ["actions"], keywords: "explain summarize translate clipboard" },
		{ id: "ollama", plugin: "ollama", group: "ai", command: "ollama", name: "Ollama", aliases: ["models"], keywords: "installed running" },
		{ id: "messages", plugin: "messages", group: "panels", command: "messages", name: "Messages", aliases: ["msg"], keywords: "mail chats inbox", status: Messages.unread > 0 ? String(Messages.unread) : "" },
		{ id: "mail", plugin: "mail", group: "panels", command: "mail", name: "New Mail", aliases: ["compose"], keywords: "write" },
		{ id: "updates", plugin: "updates", group: "panels", command: "updates", name: "Updates", aliases: ["update"], keywords: "arch packages", status: Updates.count > 0 ? String(Updates.count) : "" },
		{ id: "screentime", plugin: "screentime", group: "panels", command: "screentime", name: "Screen Time", aliases: ["time", "usage"], keywords: "statistics", status: Screentime.clock(Screentime.total(Screentime.today)) },
		{ id: "lyrics", plugin: "lyrics", group: "panels", command: "lyrics", name: "Lyrics", keywords: "song words" },
		{ id: "song", plugin: "song-detection", group: "panels", command: "song", name: "Song Detection", aliases: ["detect"], keywords: "name music" },
		{ id: "plugins", group: "system", command: "plugins", name: "Plugins", keywords: "switch features", status: `${Plugins.list.filter(plugin => Plugins.on(plugin.id)).length}/${Plugins.list.length}` },
		{
			id: "studio", shown: Popups.studioPages.length > 0, group: "system", command: "studio", name: "Studio", aliases: ["theme"],
			// its pages are what it leads to
			children: Popups.studioPages.map(page => ({ id: "studio-page", page: page.id, command: `studio ${page.id}`, name: page.label, glyph: page.icon, keywords: "" }))
		},
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "niri", page: "", name: "niri Settings", aliases: ["settings"], keywords: "layout borders input rules workspaces" },
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "keys", page: "keys", name: "Key Binds", aliases: ["binds", "keybinds", "shortcuts"], keywords: "niri" },
		{ id: "niri-settings", plugin: "niri-settings", group: "system", command: "setup", page: "displays", name: "Display Setup", aliases: ["display", "displays", "monitors"], keywords: "arrange" },
		{ id: "dnd", plugin: "dnd", group: "system", command: "dnd", name: "Do Not Disturb", aliases: ["quiet", "silent"], keywords: "notifications", status: Notifs.dnd ? "On" : "" },
		{ id: "rpg", plugin: "rpg", group: "system", command: "rpg", prefix: "/", name: "Productivity RPG", keywords: "game" }
	]

	// ── the palette ─────────────────────────────────────────────────────────
	// commands kept on top, by what is typed for them (launcher-commands.json)
	property var commandPins: []
	// the tile that is picked, an index into `paletteCells`
	property int paletteIndex: 0
	// a command picked from the app search: an index into `appCommands`, -1 for the apps
	property int commandFocus: -1

	// every command once, those of a group behind it
	readonly property var flatCommands: root.commands.filter(command => !command.parent).reduce((all, command) => all.concat(command.children ? [command].concat(command.children.filter(child => child.id !== "studio-page")) : [command]), [])
	// the group whose commands are shown: ">shot", ">studio wall"
	readonly property var openGroup: {
		if (!root.inCommandMode) return null;
		const token = root.commandQuery.split(/\s+/)[0];
		return root.commands.find(command => command.children && command.command === token) || null;
	}
	readonly property string paletteFilter: root.openGroup ? root.commandQuery.slice(root.openGroup.command.length).trim() : root.commandQuery

	function commandUsage(command) {
		return Number(root.usageMap[`>${command.command}`] || 0);
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

	// a command is picked ahead of the apps when a word of it starts with
	// what is typed and no app's name does
	function pickSearchResult() {
		const query = root.searchText.trim().toLowerCase();
		const best = root.appCommands[0];
		const app = root.filteredApps[0];
		root.commandFocus = best && best.score >= 60 && !(app && String(app.name || "").toLowerCase().startsWith(query)) ? 0 : -1;
		appList.currentIndex = root.filteredApps.length > 0 ? 0 : -1;
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

	readonly property string usageFilePath: Paths.stateFile("launcher-usage.json")
	readonly property string aiStateFilePath: Paths.stateFile("launcher-ai-state.json")
	readonly property bool inCommandMode: root.searchText.trim().startsWith(">") || root.searchText.trim().startsWith("/")
	readonly property string commandQuery: root.searchText.trim().slice(1).trim().toLowerCase()
	readonly property bool inCalculatorMode: Plugins.on("calculator") && root.isCalculatorQuery(root.commandQuery)
	readonly property bool inAiMode: Plugins.on("chat") && (root.commandQuery === "chats" || root.commandQuery.startsWith("chats "))
	readonly property bool inChatMode: Plugins.on("chat") && (root.commandQuery === "chat" || root.commandQuery.startsWith("chat "))
	readonly property bool inOllamaMode: Plugins.on("ollama") && root.commandQuery === "ollama"
	// the phone and the chat pick their files here as well
	readonly property bool inFileMode: (Plugins.on("files") || Phone.pickingFile) && (root.commandQuery === "file" || root.commandQuery.startsWith("file "))
	readonly property bool inTranslateMode: Plugins.on("translate") && (root.commandQuery === "t" || root.commandQuery.startsWith("t "))
	readonly property bool inConvertMode: Plugins.on("converter") && (root.commandQuery === "conv" || root.commandQuery.startsWith("conv "))
	readonly property bool inTodoMode: Plugins.on("todos") && (root.commandQuery === "todo" || root.commandQuery.startsWith("todo "))
	readonly property bool inWebMode: Plugins.on("web-search") && (root.commandQuery === "w" || root.commandQuery.startsWith("w "))
	readonly property bool inAiActionsMode: Plugins.on("ai-actions") && (root.commandQuery === "ai" || root.commandQuery.startsWith("ai "))
	readonly property bool inPhoneMode: Phone.offered && (root.commandQuery === "phone" || root.commandQuery.startsWith("phone "))
	readonly property bool inShotsMode: Plugins.on("screenshot-history") && (root.commandQuery === "shots" || root.commandQuery.startsWith("shots "))
	readonly property bool inViewMode: root.inTranslateMode || root.inConvertMode || root.inTodoMode || root.inWebMode || root.inAiActionsMode || root.inPhoneMode || root.inShotsMode
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
		if (query === "") return root.aiChats;
		const words = query.split(/\s+/).filter(word => word !== "");
		return root.aiChats.filter(chat => {
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
	readonly property int activeChatIndex: root.findChatIndex(root.activeChatId)
	readonly property var activeChat: root.aiTemporaryChatEnabled
		? root.aiTemporaryChat
		: (root.activeChatIndex >= 0 ? root.aiChats[root.activeChatIndex] : null)
	readonly property var activeMessages: root.activeChat ? (root.activeChat.messages || []) : []
	readonly property bool selectedAiSupportsThinking: root.aiModelCapabilities.includes("thinking")
	readonly property bool selectedAiSupportsVision: root.aiModelCapabilities.includes("vision")
	readonly property bool effectiveAiThinkingEnabled: root.selectedAiSupportsThinking && root.aiThinkingEnabled
	readonly property bool pendingAttachmentsReady: root.aiPendingAttachments.every(
		attachment => String(attachment?.status || "") === "ready"
	)
	readonly property bool pendingAttachmentsCompatible: root.aiPendingAttachments.every(
		attachment => String(attachment?.kind || "") !== "image" || root.selectedAiSupportsVision
	)
	readonly property int aiRequestContextWindow: Math.min(
		root.aiModelContextWindow > 0 ? root.aiModelContextWindow : 4096,
		8192
	)
	readonly property int activeContextUsed: Number(root.activeChat?.contextUsed || 0)
	readonly property int activeContextLimit: Number(root.activeChat?.contextLimit || root.aiRequestContextWindow)
	readonly property real activeContextProgress: root.activeContextLimit > 0
		? Math.min(1, root.activeContextUsed / root.activeContextLimit)
		: 0
	readonly property real activeTokensPerSecond: Number(root.activeChat?.tokensPerSecond || 0)
	readonly property int activeResponseTokens: Number(root.activeChat?.responseTokens || 0)
	readonly property string chatLoadedModelName: String(
		root.aiStreaming
			? root.aiStreamingModel
			: (root.activeChat?.model || root.selectedAiModel || "")
	)
	readonly property var chatLoadedModel: root.ollamaRunningModels.find(model =>
		String(model?.name || model?.model || "") === root.chatLoadedModelName
	)
	readonly property real chatLoadedExpiresAtMs: Date.parse(String(root.chatLoadedModel?.expires_at || ""))
	readonly property real chatLoadedSecondsRemaining: Number.isFinite(root.chatLoadedExpiresAtMs)
		? Math.max(0, Math.ceil((root.chatLoadedExpiresAtMs - root.modelLoadedNow) / 1000))
		: 0
	readonly property string chatLoadedTimerText: {
		if (root.chatLoadedModelName === "") return "";
		if (!root.chatLoadedModel) return root.ollamaRunningLoading ? "Checking model" : "Model not loaded";
		if (!Number.isFinite(root.chatLoadedExpiresAtMs)) return "Model loaded";
		if (root.chatLoadedSecondsRemaining <= 0) return "Unload soon";
		return `Loaded ${root.formatDuration(root.chatLoadedSecondsRemaining)}`;
	}
	readonly property real ollamaRunningVram: root.ollamaRunningModels.reduce(
		(total, model) => total + Number(model?.size_vram || 0),
		0
	)
	readonly property bool legacyQwenThinkingWorkaround: root.ollamaVersion === ""
		|| root.versionBefore(root.ollamaVersion, 0, 12, 0)
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

	Timer {
		id: aiUnloadTimer
		interval: 150
		repeat: false
		onTriggered: root.unloadPendingAiModel()
	}

	Timer {
		id: modelLoadedTimer
		interval: 1000
		repeat: true
		running: root.inChatMode || root.aiStreaming
		triggeredOnStart: true
		onTriggered: {
			root.modelLoadedNow = Date.now();
			if (root.modelLoadedNow - root.ollamaRunningLastRefresh > 5000)
				root.refreshOllamaRunningModels();
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

	function fileNameFromPath(path) {
		const parts = String(path || "").split("/").filter(part => part !== "");
		return parts.length > 0 ? parts[parts.length - 1] : String(path || "");
	}

	function attachmentKind(entry) {
		const mimeType = String(entry?.mimeType || "").toLowerCase();
		const suffix = String(entry?.suffix || root.fileNameFromPath(entry?.path).split(".").pop() || "").toLowerCase();
		if (Boolean(entry?.isImage) || mimeType.startsWith("image/")) return "image";
		if (mimeType === "application/pdf" || suffix === "pdf") return "pdf";
		if (["docx", "odt", "epub", "rtf"].includes(suffix)) return "document";
		if (
			mimeType.startsWith("text/")
			|| [
				"application/json",
				"application/ld+json",
				"application/xml",
				"application/x-yaml",
				"application/toml",
				"application/javascript"
			].includes(mimeType)
			|| [
				"txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonl",
				"yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "sass",
				"js", "jsx", "ts", "tsx", "qml", "py", "rb", "php", "go", "rs",
				"c", "h", "cc", "cpp", "hpp", "java", "kt", "kts", "swift", "sh",
				"bash", "zsh", "fish", "sql", "ini", "conf", "cfg", "env", "diff",
				"patch", "dockerfile", "makefile"
			].includes(suffix)
		) return "text";
		return "";
	}

	function attachmentSupported(entry) {
		if (!entry || Boolean(entry.isDir)) return false;
		const kind = root.attachmentKind(entry);
		return kind === "text"
			|| kind === "pdf"
			|| kind === "document"
			|| (kind === "image" && root.selectedAiSupportsVision);
	}

	function formatAttachmentSize(bytes) {
		const value = Number(bytes || 0);
		if (value < 1000) return `${value} B`;
		if (value < 1000000) return `${(value / 1000).toFixed(value < 10000 ? 1 : 0)} KB`;
		return `${(value / 1000000).toFixed(1)} MB`;
	}

	function updatePendingAttachment(attachmentId, changes) {
		root.aiPendingAttachments = root.aiPendingAttachments.map(attachment =>
			String(attachment?.id || "") === String(attachmentId || "")
				? Object.assign({}, attachment, changes)
				: attachment
		);
	}

	function isAttachmentSelected(path) {
		return root.aiPendingAttachments.some(attachment => String(attachment?.path || "") === String(path || ""));
	}

	function isPrimarySelectionAttachment(attachment) {
		return String(attachment?.source || "") === "primary-selection";
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
		if (!root.inChatMode || root.aiStreaming) return;
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
		root.addPendingAttachment(entry);
	}

	function addPendingAttachment(entry) {
		if (!entry || Boolean(entry.isDir) || root.aiAttachmentLoadingId !== "") return;
		const path = String(entry.path || "");
		const name = String(entry.name || root.fileNameFromPath(path));
		const mimeType = String(entry.mimeType || "");
		const size = Number(entry.size || 0);
		const kind = root.attachmentKind(entry);
		if (path === "" || root.isAttachmentSelected(path)) return;
		if (root.aiPendingAttachments.length >= 6) {
			root.aiError = "A maximum of 6 files can be attached";
			return;
		}
		if (kind === "") {
			root.aiError = "Only text, code, document, PDF, and image files are supported";
			return;
		}
		if (kind === "image" && !root.selectedAiSupportsVision) {
			root.aiError = "The selected model does not support images";
			return;
		}
		const maximumBytes = kind === "image"
			? 20000000
			: ((kind === "pdf" || kind === "document") ? 10000000 : 2000000);
		if (size > maximumBytes) {
			root.aiError = `${name} is too large`;
			return;
		}
		const totalBytes = root.aiPendingAttachments.reduce(
			(total, attachment) => total + Number(attachment?.size || 0),
			0
		);
		if (totalBytes + size > 30000000) {
			root.aiError = "Attached files exceed the 30 MB limit";
			return;
		}

		const attachmentId = root.makeId("attachment");
		root.aiPendingAttachments = root.aiPendingAttachments.concat([{
			id: attachmentId,
			path,
			name,
			mimeType,
			size,
			kind,
			status: "loading",
			content: "",
			data: ""
		}]);
		root.aiAttachmentLoadingId = attachmentId;
		root.aiAttachmentReadOutput = "";
		root.aiAttachmentReadError = "";
		root.aiError = "";
		if (kind === "image") attachmentReadProcess.exec(["base64", "-w", "0", path]);
		else if (kind === "pdf") attachmentReadProcess.exec(["pdftotext", "-layout", path, "-"]);
		else if (kind === "document") attachmentReadProcess.exec(["pandoc", "-t", "plain", path]);
		else attachmentReadProcess.exec(["cat", "--", path]);
	}

	function finishPendingAttachmentRead(exitCode) {
		const attachmentId = root.aiAttachmentLoadingId;
		if (attachmentId === "") return;
		const attachment = root.aiPendingAttachments.find(item => String(item?.id || "") === attachmentId);
		const output = String(root.aiAttachmentReadOutput || "");
		const error = String(root.aiAttachmentReadError || "").trim();
		root.aiAttachmentLoadingId = "";
		root.aiAttachmentReadOutput = "";
		root.aiAttachmentReadError = "";
		if (!attachment) return;
		if (exitCode !== 0 || output === "") {
			root.aiPendingAttachments = root.aiPendingAttachments.filter(item => String(item?.id || "") !== attachmentId);
			root.aiError = error || `Could not read ${attachment.name}`;
			return;
		}
		if (attachment.kind !== "image" && output.length > 500000) {
			root.aiPendingAttachments = root.aiPendingAttachments.filter(item => String(item?.id || "") !== attachmentId);
			root.aiError = `${attachment.name} contains too much text`;
			return;
		}
		root.updatePendingAttachment(attachmentId, attachment.kind === "image"
			? { status: "ready", data: output }
			: { status: "ready", content: output });
	}

	function capturePrimarySelection() {
		if (!root.inChatMode || root.aiStreaming || root.editingMessageId !== "") return;
		root.readPrimarySelection("chat");
	}

	function primePrimarySelection() {
		if (root.inChatMode || root.aiStreaming || primarySelectionProcess.running) return;
		root.readPrimarySelection("prime");
	}

	function readPrimarySelection(mode) {
		if (primarySelectionProcess.running) primarySelectionProcess.running = false;
		if (mode === "chat") root.clearPrimarySelectionAttachment();
		root.aiPrimarySelectionLoading = true;
		root.aiPrimarySelectionOutput = "";
		root.aiPrimarySelectionError = "";
		root.aiPrimarySelectionMode = String(mode || "chat");
		primarySelectionProcess.exec([
			"timeout",
			"2s",
			"wl-paste",
			"--primary",
			"--no-newline",
			"--type",
			"text/plain"
		]);
	}

	function finishPrimarySelectionRead(exitCode) {
		const output = String(root.aiPrimarySelectionOutput || "").replace(/\r\n/g, "\n").trim();
		const error = String(root.aiPrimarySelectionError || "").trim();
		const mode = root.aiPrimarySelectionMode;
		root.aiPrimarySelectionLoading = false;
		root.aiPrimarySelectionOutput = "";
		root.aiPrimarySelectionError = "";
		root.aiPrimarySelectionMode = "";
		if (mode === "prime") {
			root.aiLastPrimarySelectionContent = output;
			return;
		}
		if (!root.inChatMode || root.aiStreaming || root.editingMessageId !== "") return;
		if (exitCode !== 0 || output === "") return;
		if (output === root.aiLastPrimarySelectionContent) return;
		if (output.length > 500000) {
			root.aiError = "Selected text is too long";
			return;
		}
		root.clearPrimarySelectionAttachment();
		root.aiPendingAttachments = root.aiPendingAttachments.concat([{
			id: root.makeId("selection"),
			path: "",
			name: "Selected text",
			mimeType: "text/plain",
			size: output.length,
			kind: "text",
			status: "ready",
			content: output,
			data: "",
			source: "primary-selection"
		}]);
		root.aiLastPrimarySelectionContent = output;
		root.aiError = error === "" ? "" : root.aiError;
	}

	function removePendingAttachment(attachmentId) {
		if (String(attachmentId || "") === root.aiAttachmentLoadingId) attachmentReadProcess.running = false;
		root.aiPendingAttachments = root.aiPendingAttachments.filter(
			attachment => String(attachment?.id || "") !== String(attachmentId || "")
		);
		if (String(attachmentId || "") === root.aiAttachmentLoadingId) {
			root.aiAttachmentLoadingId = "";
			root.aiAttachmentReadOutput = "";
			root.aiAttachmentReadError = "";
		}
	}

	function clearPrimarySelectionAttachment() {
		root.aiPendingAttachments = root.aiPendingAttachments.filter(
			attachment => !root.isPrimarySelectionAttachment(attachment)
		);
	}

	function clearPendingAttachments() {
		if (attachmentReadProcess.running) attachmentReadProcess.running = false;
		if (primarySelectionProcess.running) primarySelectionProcess.running = false;
		root.aiPendingAttachments = [];
		root.aiAttachmentLoadingId = "";
		root.aiAttachmentReadOutput = "";
		root.aiAttachmentReadError = "";
		root.aiPrimarySelectionLoading = false;
		root.aiPrimarySelectionOutput = "";
		root.aiPrimarySelectionError = "";
		root.aiPrimarySelectionMode = "";
	}

	function messageAttachments(message) {
		const attachments = message?.attachments;
		if (Array.isArray(attachments)) return attachments;
		if (!attachments || typeof attachments.length !== "number") return [];
		const result = [];
		for (let index = 0; index < attachments.length; index += 1)
			result.push(attachments[index]);
		return result;
	}

	function attachmentApiContent(attachment) {
		if (!attachment || !["text", "pdf", "document"].includes(attachment.kind)) return "";
		const content = String(attachment.content || "");
		if (content === "") return "";
		if (root.isPrimarySelectionAttachment(attachment))
			return `<selected_text>\n${content}\n</selected_text>`;
		return `<attached_file name="${String(attachment.name || "file").replace(/"/g, "'")}">\n${content}\n</attached_file>`;
	}

	function stateAttachment(attachment) {
		const copy = Object.assign({}, attachment);
		copy.data = "";
		copy.status = copy.kind === "image" ? "unavailable" : String(copy.content || "") !== "" ? "ready" : "unavailable";
		return copy;
	}

	function stateChat(chat) {
		const copy = Object.assign({}, chat);
		copy.messages = (chat?.messages || []).map(message => {
			const messageCopy = Object.assign({}, message);
			messageCopy.attachments = root.messageAttachments(message).map(root.stateAttachment);
			return messageCopy;
		});
		return copy;
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

	function normalizeCalculatorExpression(expression) {
		return String(expression || "")
			.trim()
			.replace(/,/g, ".")
			.replace(/[×·]/g, "*")
			.replace(/[÷:]/g, "/")
			.replace(/\^/g, "**");
	}

	function formatCalculatorResult(value) {
		if (!Number.isFinite(value)) return "";
		if (Number.isInteger(value)) return String(value);
		return String(Number(value.toPrecision(12)));
	}

	function evaluateCalculatorExpression(expression) {
		const raw = String(expression || "").trim();
		if (raw === "") {
			return {
				valid: false,
				result: "",
				message: "Type an expression, for example >c 5+5"
			};
		}

		const normalized = root.normalizeCalculatorExpression(raw);
		if (!/^[0-9+\-*/%().\sEe]+$/.test(normalized)) {
			return {
				valid: false,
				result: "",
				message: "Only numbers and + - * / % ^ ( ) are supported"
			};
		}

		try {
			const value = Function(`"use strict"; return (${normalized});`)();
			const result = root.formatCalculatorResult(Number(value));
			if (result === "") {
				return {
					valid: false,
					result: "",
					message: "Calculation has no finite result"
				};
			}
			return {
				valid: true,
				result,
				message: `${raw} = ${result}`
			};
		} catch (error) {
			return {
				valid: false,
				result: "",
				message: "Invalid expression"
			};
		}
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

	function makeId(prefix) {
		return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
	}

	function versionBefore(version, major, minor, patch) {
		const parts = String(version || "").replace(/^v/, "").split(".").map(value => Number(value) || 0);
		const current = [parts[0] || 0, parts[1] || 0, parts[2] || 0];
		const target = [major, minor, patch];
		for (let i = 0; i < target.length; i += 1) {
			if (current[i] !== target[i]) return current[i] < target[i];
		}
		return false;
	}

	function findChatIndex(chatId) {
		if (!chatId) return -1;
		for (let i = 0; i < root.aiChats.length; i += 1) {
			if (String(root.aiChats[i]?.id || "") === String(chatId)) return i;
		}
		return -1;
	}

	function parseAiState(raw) {
		try {
			const parsed = JSON.parse(raw);
			root.selectedAiModel = String(parsed?.selectedModel || "");
			root.aiThinkingEnabled = Boolean(parsed?.thinkingEnabled);
			root.aiShortResponseEnabled = Boolean(parsed?.shortResponseEnabled);
			root.aiThinkingExpandedMap = ({});
			const chats = [];
			for (const candidate of (Array.isArray(parsed?.chats) ? parsed.chats : [])) {
				if (!candidate || !candidate.id || !Array.isArray(candidate.messages)) continue;
				const messages = candidate.messages.map(message => Object.assign({}, message, {
					streaming: false,
					thinking: Boolean(candidate.thinkingEnabled) ? String(message.thinking || "") : "",
					attachments: root.messageAttachments(message).map(attachment => Object.assign({}, attachment, {
						data: "",
						status: attachment.kind === "image"
							? "unavailable"
							: (String(attachment.content || "") !== "" ? "ready" : "unavailable")
					}))
				}));
				if (
					messages.length > 0
					&& messages[messages.length - 1].role === "assistant"
					&& String(messages[messages.length - 1].content || "") === ""
				) {
					messages.pop();
				}
				chats.push(Object.assign({}, candidate, {
					messages
				}));
			}
			root.aiChats = chats.slice(0, 100);
		} catch (error) {
			root.selectedAiModel = "";
			root.aiThinkingEnabled = false;
			root.aiShortResponseEnabled = false;
			root.aiChats = [];
		}

		root.aiStateLoaded = true;
		root.ensureSelectedAiModel();
		root.saveAiState();
	}

	function saveAiState() {
		if (!root.aiStateLoaded) return;
		aiStateFile.setText(JSON.stringify({
			version: 1,
			selectedModel: root.selectedAiModel,
			thinkingEnabled: root.aiThinkingEnabled,
			shortResponseEnabled: root.aiShortResponseEnabled,
			chats: root.aiChats.slice(0, 100).map(root.stateChat)
		}, null, 2));
	}

	function ensureSelectedAiModel() {
		if (root.aiModels.length === 0) {
			root.selectedAiModel = "";
			root.saveAiState();
			return;
		}
		const exists = root.aiModels.some(model => String(model.name || model.model || "") === root.selectedAiModel);
		if (exists) return;
		root.selectedAiModel = String(root.aiModels[0].name || root.aiModels[0].model || "");
		root.saveAiState();
	}

	function refreshAiModels() {
		if (aiModelsProcess.running || root.aiModelsFallbackRunning) return;
		root.aiModelsLoading = true;
		root.aiError = "";
		aiModelsProcess.exec(["curl", "-fsS", "http://127.0.0.1:11434/api/tags"]);
	}

	function parseAiModels(raw) {
		try {
			const parsed = JSON.parse(raw);
			root.aiModels = Array.isArray(parsed?.models) ? parsed.models : [];
			root.aiError = root.aiModels.length === 0 ? "No Ollama models installed" : "";
			root.ensureSelectedAiModel();
		} catch (error) {
			root.aiModels = [];
			root.aiError = "Could not read Ollama models";
		}
	}

	function parseOllamaModelList(raw) {
		const models = [];
		const sizeMultipliers = {
			KB: 1000,
			MB: 1000000,
			GB: 1000000000,
			TB: 1000000000000
		};
		const lines = String(raw || "").split("\n").map(line => line.trim()).filter(line => line !== "");
		for (let index = 1; index < lines.length; index += 1) {
			const match = /^(\S+)\s+(\S+)\s+([\d.]+)\s+(KB|MB|GB|TB)(?:\s+.*)?$/i.exec(lines[index]);
			if (!match) continue;
			const name = String(match[1] || "");
			const unit = String(match[4] || "").toUpperCase();
			models.push({
				name,
				model: name,
				digest: String(match[2] || ""),
				size: Number(match[3] || 0) * Number(sizeMultipliers[unit] || 0),
				details: ({})
			});
		}
		root.aiModels = models;
		root.aiError = models.length === 0 ? "No Ollama models installed" : "";
		root.ensureSelectedAiModel();
	}

	function refreshOllamaOverview(clearError) {
		if (clearError !== false) root.ollamaManagerError = "";
		root.ollamaPsProcessError = "";
		root.refreshAiModels();
		root.refreshOllamaRunningModels();
	}

	function refreshOllamaRunningModels() {
		if (ollamaPsProcess.running || root.ollamaPsFallbackRunning) return;
		root.ollamaPsProcessError = "";
		root.ollamaRunningLoading = true;
		ollamaPsProcess.exec(["curl", "-fsS", "http://127.0.0.1:11434/api/ps"]);
	}

	function parseOllamaRunningModels(raw) {
		try {
			const parsed = JSON.parse(raw);
			root.ollamaRunningModels = Array.isArray(parsed?.models) ? parsed.models : [];
			root.ollamaRunningLastRefresh = Date.now();
		} catch (error) {
			root.ollamaRunningModels = [];
			root.ollamaManagerError = "Could not read running Ollama models";
		}
	}

	function parseOllamaRunningList(raw) {
		const models = [];
		const lines = String(raw || "").split("\n").map(line => line.trim()).filter(line => line !== "");
		for (let index = 1; index < lines.length; index += 1) {
			const name = String(lines[index].split(/\s+/)[0] || "");
			if (name !== "") models.push({ name, model: name });
		}
		root.ollamaRunningModels = models;
		root.ollamaRunningLastRefresh = Date.now();
	}

	function isOllamaModelRunning(modelName) {
		const name = String(modelName || "");
		return root.ollamaRunningModels.some(model => String(model?.name || model?.model || "") === name);
	}

	function startNewChatWithModel(modelName) {
		const name = String(modelName || "");
		if (name === "" || root.aiStreaming) return;
		root.selectedAiModel = name;
		root.saveAiState();
		root.startNewChat();
	}

	function removeOllamaModel(modelName) {
		const name = String(modelName || "");
		if (name === "" || root.aiStreaming || ollamaRemoveProcess.running) return;
		root.ollamaManagerError = "";
		root.ollamaRemovingModel = name;
		ollamaRemoveProcess.exec(["ollama", "rm", name]);
	}

	function startOllamaPull(modelName) {
		const name = String(modelName || "").trim();
		if (name === "" || root.ollamaPulling) return;
		root.ollamaManagerError = "";
		root.ollamaPullModel = name;
		root.ollamaPulling = true;
		root.ollamaPullStatus = "Preparing download";
		root.ollamaPullDigest = "";
		root.ollamaPullProgress = 0;
		root.ollamaPullCompleted = 0;
		root.ollamaPullTotal = 0;
		root.ollamaPullSpeed = 0;
		root.ollamaPullEtaSeconds = 0;
		root.ollamaPullStartedAt = Date.now();
		ollamaPullProcess.exec([
			"curl",
			"-sS",
			"--no-buffer",
			"--fail-with-body",
			"-H",
			"Content-Type: application/json",
			"-d",
			JSON.stringify({
				model: name,
				stream: true
			}),
			"http://127.0.0.1:11434/api/pull"
		]);
	}

	function handleOllamaPullData(data) {
		for (const rawLine of String(data || "").split("\n")) {
			const line = rawLine.trim();
			if (line === "") continue;
			try {
				const chunk = JSON.parse(line);
				if (chunk.error) {
					root.ollamaManagerError = String(chunk.error);
					continue;
				}

				root.ollamaPullStatus = String(chunk.status || root.ollamaPullStatus);
				const digest = String(chunk.digest || "");
				if (digest !== "" && digest !== root.ollamaPullDigest) {
					root.ollamaPullDigest = digest;
					root.ollamaPullStartedAt = Date.now();
					root.ollamaPullSpeed = 0;
					root.ollamaPullEtaSeconds = 0;
				}

				const total = Number(chunk.total || 0);
				const completed = Number(chunk.completed || 0);
				if (total > 0) {
					root.ollamaPullTotal = total;
					root.ollamaPullCompleted = completed;
					root.ollamaPullProgress = Math.max(0, Math.min(1, completed / total));
					const elapsed = Math.max(0.1, (Date.now() - root.ollamaPullStartedAt) / 1000);
					root.ollamaPullSpeed = completed / elapsed;
					root.ollamaPullEtaSeconds = root.ollamaPullSpeed > 0
						? Math.max(0, (total - completed) / root.ollamaPullSpeed)
						: 0;
				}
				if (chunk.status === "success") {
					root.ollamaPullProgress = 1;
					root.ollamaPullEtaSeconds = 0;
				}
			} catch (error) {
				root.ollamaManagerError = "Invalid response while pulling model";
			}
		}
	}

	function refreshAiModelInfo() {
		if (root.selectedAiModel === "") {
			root.aiModelInfo = ({});
			root.aiModelCapabilities = [];
			root.aiModelContextWindow = 0;
			return;
		}
		if (aiModelInfoProcess.running) return;
		root.aiModelInfoLoading = true;
		root.aiModelInfoTarget = root.selectedAiModel;
		aiModelInfoProcess.exec([
			"curl",
			"-fsS",
			"-H",
			"Content-Type: application/json",
			"-d",
			JSON.stringify({
				model: root.aiModelInfoTarget
			}),
			"http://127.0.0.1:11434/api/show"
		]);
	}

	function parseAiModelInfo(raw) {
		if (root.aiModelInfoTarget !== root.selectedAiModel) return;
		try {
			const parsed = JSON.parse(raw);
			const info = parsed?.model_info || {};
			let contextWindow = 0;
			for (const key of Object.keys(info)) {
				if (!key.endsWith(".context_length")) continue;
				contextWindow = Math.max(contextWindow, Number(info[key] || 0));
			}
			root.aiModelInfo = parsed;
			root.aiModelCapabilities = Array.isArray(parsed?.capabilities) ? parsed.capabilities : [];
			root.aiModelContextWindow = contextWindow;
		} catch (error) {
			root.aiModelInfo = ({});
			root.aiModelCapabilities = [];
			root.aiModelContextWindow = 0;
		}
	}

	function formatModelSize(bytes) {
		const value = Number(bytes || 0);
		if (value <= 0) return "";
		return `${(value / 1000000000).toFixed(1)} GB`;
	}

	function formatTransferRate(bytesPerSecond) {
		const value = Number(bytesPerSecond || 0);
		if (value <= 0) return "";
		if (value >= 1000000000) return `${(value / 1000000000).toFixed(1)} GB/s`;
		if (value >= 1000000) return `${(value / 1000000).toFixed(1)} MB/s`;
		return `${(value / 1000).toFixed(0)} KB/s`;
	}

	function formatDuration(seconds) {
		const value = Math.max(0, Math.ceil(Number(seconds || 0)));
		if (value <= 0) return "";
		if (value < 60) return `${value}s`;
		const minutes = Math.floor(value / 60);
		const remainingSeconds = value % 60;
		if (minutes < 60) return `${minutes}m ${remainingSeconds}s`;
		const hours = Math.floor(minutes / 60);
		return `${hours}h ${minutes % 60}m`;
	}

	function ollamaRunningSummary() {
		if (root.ollamaRunningLoading) return "Loading...";
		if (root.ollamaRunningModels.length === 0) return "No models loaded";
		const names = root.ollamaRunningModels
			.map(model => String(model?.name || model?.model || ""))
			.filter(name => name !== "")
			.join(", ");
		const vram = root.formatModelSize(root.ollamaRunningVram);
		return vram !== "" ? `${names} · ${vram} VRAM` : names;
	}

	function formatTokenCount(count) {
		const value = Number(count || 0);
		if (value < 1000) return String(Math.round(value));
		if (value < 1000000) return `${(value / 1000).toFixed(value < 10000 ? 1 : 0)}K`;
		return `${(value / 1000000).toFixed(1)}M`;
	}

	function selectAiModel(modelName) {
		if (!modelName || root.aiStreaming) return;
		root.selectedAiModel = String(modelName);
		root.aiError = "";
		root.saveAiState();
	}

	function toggleAiThinking() {
		if (root.aiStreaming) return;
		root.aiThinkingEnabled = !root.aiThinkingEnabled;
		root.saveAiState();
	}

	function toggleShortResponse() {
		if (root.aiStreaming) return;
		root.aiShortResponseEnabled = !root.aiShortResponseEnabled;
		root.saveAiState();
	}

	function syncLauncherSearch() {
		if (root.commandInputSyncing) return;
		root.searchText = root.commandInputActive
			? `${commandTokenField.text}${root.commandInputHasSeparator ? ` ${searchField.text}` : ""}`
			: searchField.text;
		if (root.inCommandMode)
			root.pickPaletteCell();
		else
			root.pickSearchResult();
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

	// Tab / Shift+Tab: apps → calculator → files → chat → chats → ollama
	readonly property var modeCycle: [
		{ mode: "apps", query: "" },
		{ mode: "calc", query: ">c " },
		{ mode: "files", query: ">file " },
		{ mode: "chat", query: ">chat " },
		{ mode: "chats", query: ">chats " },
		{ mode: "ollama", query: ">ollama " }
	]

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
		for (const message of root.activeMessages)
			chatMessageModel.append({ entry: message });
	}

	function updateVisibleChatMessage(index, message) {
		if (!root.streamingChatMatchesView() || root.chatSelectionActive) return;
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

	function startNewChat() {
		if (root.aiStreaming) return;
		const wasInChatMode = root.inChatMode;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiAttachmentPickerOpen = false;
		root.aiTemporaryChatEnabled = true;
		root.aiTemporaryChat = null;
		root.activeChatId = "";
		root.aiError = "";
		root.setLauncherSearch(">chat ");
		root.syncChatMessageModel();
		if (wasInChatMode) Qt.callLater(root.capturePrimarySelection);
	}

	function openPastChat(chat) {
		if (!chat) return;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiAttachmentPickerOpen = false;
		const preserveTemporaryChat = root.aiStreaming && root.aiStreamingTemporary && root.aiTemporaryChat;
		root.aiTemporaryChatEnabled = false;
		if (!preserveTemporaryChat) root.aiTemporaryChat = null;
		root.activeChatId = String(chat.id || "");
		if (chat.model && root.aiModels.some(model => String(model.name || model.model || "") === String(chat.model)))
			root.selectedAiModel = String(chat.model);
		root.aiThinkingEnabled = Boolean(chat.thinkingEnabled);
		root.aiShortResponseEnabled = Boolean(chat.shortResponseEnabled);
		root.aiError = "";
		root.saveAiState();
		root.setLauncherSearch(">chat ");
		root.syncChatMessageModel();
		Qt.callLater(function() {
			root.syncChatMessageModel();
			root.scrollChatToEnd(true);
		});
	}

	function openAiOverview() {
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiAttachmentPickerOpen = false;
		root.setLauncherSearch(">chats ");
	}

	function toggleTemporaryChat() {
		if (root.aiStreaming) return;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiTemporaryChatEnabled = !root.aiTemporaryChatEnabled;
		if (!root.aiTemporaryChatEnabled) root.aiTemporaryChat = null;
		root.activeChatId = "";
		root.aiError = "";
		root.syncChatMessageModel();
		root.scrollChatToEnd(true);
	}

	function deleteChat(chat) {
		if (!chat) return;
		const chatId = String(chat.id || "");
		if (chatId === "") return;
		if (root.aiStreaming && chatId === root.aiStreamingChatId) return;
		root.aiChats = root.aiChats.filter(item => String(item.id || "") !== chatId);
		if (root.activeChatId === chatId) {
			root.activeChatId = "";
			root.syncChatMessageModel();
		}
		const expanded = Object.assign({}, root.aiThinkingExpandedMap);
		delete expanded[chatId];
		root.aiThinkingExpandedMap = expanded;
		root.saveAiState();
	}

	function thinkingExpanded(messageId) {
		return Boolean(root.aiThinkingExpandedMap[String(messageId || "")]);
	}

	function toggleThinkingExpanded(messageId) {
		const key = String(messageId || "");
		if (key === "") return;
		const expanded = Object.assign({}, root.aiThinkingExpandedMap);
		expanded[key] = !Boolean(expanded[key]);
		root.aiThinkingExpandedMap = expanded;
	}

	function streamingChatMatchesView() {
		if (!root.aiStreaming) return true;
		if (root.aiStreamingTemporary) return root.aiTemporaryChatEnabled && root.activeChat === root.aiTemporaryChat;
		return String(root.activeChat?.id || "") === root.aiStreamingChatId;
	}

	function chatTitle(message) {
		const compact = String(message || "").replace(/\s+/g, " ").trim();
		if (compact.length <= 54) return compact;
		return `${compact.slice(0, 51)}...`;
	}

	function apiMessages(messages, shortResponseEnabled) {
		const apiMessages = messages
			.filter(message => {
				if (message.role !== "user" && message.role !== "assistant") return false;
				if (String(message.content || "") !== "") return true;
				return root.messageAttachments(message).some(attachment =>
					String(root.attachmentApiContent(attachment)) !== ""
					|| (attachment.kind === "image" && String(attachment.data || "") !== "")
				);
			})
			.map(message => {
				const attachments = root.messageAttachments(message);
				const fileBlocks = attachments.map(root.attachmentApiContent).filter(content => content !== "");
				const apiMessage = {
					role: message.role,
					content: [String(message.content || ""), ...fileBlocks].filter(content => content !== "").join("\n\n")
				};
				const images = attachments
					.filter(attachment => attachment.kind === "image" && String(attachment.data || "") !== "")
					.map(attachment => String(attachment.data));
				if (images.length > 0) apiMessage.images = images;
					if (root.effectiveAiThinkingEnabled && message.role === "assistant" && String(message.thinking || "") !== "")
						apiMessage.thinking = String(message.thinking);
					return apiMessage;
				});
		if (shortResponseEnabled) {
			apiMessages.unshift({
				role: "system",
				content: "Answer briefly and directly. Keep the response short, usually 1-3 concise sentences, unless the user explicitly asks for detail."
			});
		}
		return apiMessages;
	}

	function storeChat(chat, chats, index, temporary) {
		if (temporary) {
			root.aiTemporaryChat = chat;
		} else {
			chats[index] = chat;
			root.aiChats = chats;
		}
	}

	function startAiRequest(chat, chats, index, temporary) {
		const requestModel = String(root.selectedAiModel || "");
		chat.model = requestModel;
		chat.thinkingEnabled = root.effectiveAiThinkingEnabled;
		chat.shortResponseEnabled = root.aiShortResponseEnabled;
		const requestMessages = root.apiMessages(chat.messages || [], chat.shortResponseEnabled);
		const assistantMessage = {
			id: root.makeId("assistant"),
			role: "assistant",
			model: requestModel,
			content: "",
			thinking: "",
			streaming: true
		};
		chat.contextLimit = root.aiRequestContextWindow;
		chat.updatedAt = Date.now();
		chat.messages = (chat.messages || []).concat([assistantMessage]);
		root.storeChat(chat, chats, index, temporary);
		root.aiStreaming = true;
		root.aiStreamingChatId = String(chat.id || "");
		root.aiStreamingTemporary = Boolean(temporary);
		root.aiStreamingModel = requestModel;
		root.aiInlineThinking = false;
		root.aiSuppressedThinkingBuffer = "";
		root.aiInlineProbeBuffer = "";
		root.aiError = "";
		root.aiProcessError = "";
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiAttachmentPickerOpen = false;
		root.chatAutoFollow = true;
		root.chatSelectionActive = false;
		if (!temporary) root.saveAiState();
		root.setLauncherSearch(">chat ");
		root.syncChatMessageModel();
		root.scrollChatToEnd(true);
		root.refreshOllamaRunningModels();

		const payload = {
			model: requestModel,
			messages: requestMessages,
			stream: true,
			keep_alive: "10m",
			options: {
				num_ctx: root.aiRequestContextWindow
			}
		};
		payload.think = root.effectiveAiThinkingEnabled;

		root.aiRequestPayload = JSON.stringify(payload);
		aiChatProcess.stdinEnabled = true;
		aiChatProcess.exec([
			"curl",
			"-sS",
			"--no-buffer",
			"--fail-with-body",
			"-H",
			"Content-Type: application/json",
			"--data-binary",
			"@-",
			"http://127.0.0.1:11434/api/chat"
		]);
	}

	function cancelAiStream() {
		if (!root.aiStreaming) return;
		const modelName = String(root.aiStreamingModel || root.activeChat?.model || root.selectedAiModel || "");
		root.finishAiStream("", true);
		aiChatProcess.running = false;
		root.aiPendingUnloadModel = modelName;
		aiUnloadTimer.restart();
	}

	function unloadPendingAiModel() {
		const modelName = String(root.aiPendingUnloadModel || "");
		root.aiPendingUnloadModel = "";
		if (modelName === "") return;
		aiUnloadProcess.exec([
			"curl",
			"-sS",
			"--fail-with-body",
			"-H",
			"Content-Type: application/json",
			"-d",
			JSON.stringify({
				model: modelName,
				keep_alive: 0
			}),
			"http://127.0.0.1:11434/api/generate"
		]);
	}

	function sendChatPrompt(prompt) {
		const pendingAttachments = root.aiPendingAttachments.map(attachment => Object.assign({}, attachment));
		let text = String(prompt || "").trim();
		if ((text === "" && pendingAttachments.length === 0) || root.aiStreaming) return;
		if (root.selectedAiModel === "") {
			root.aiError = "Select an Ollama model first";
			return;
		}
		if (root.aiPrimarySelectionLoading) {
			root.aiError = "Wait until selected text is ready";
			return;
		}
		if (!root.pendingAttachmentsReady) {
			root.aiError = "Wait until all attached files are ready";
			return;
		}
		if (!root.pendingAttachmentsCompatible) {
			root.aiError = "The selected model does not support the attached images";
			return;
		}
		if (text === "") text = "Analyze the attached files.";

		const now = Date.now();
		const chats = root.aiChats.slice();
		let index = root.findChatIndex(root.activeChatId);
		let chat;

		if (root.aiTemporaryChatEnabled) {
			chat = root.aiTemporaryChat
				? Object.assign({}, root.aiTemporaryChat, {
					model: root.selectedAiModel,
					thinkingEnabled: root.aiThinkingEnabled,
					updatedAt: now,
					messages: (root.aiTemporaryChat.messages || []).slice()
				})
				: {
					id: root.makeId("temporary-chat"),
					title: root.chatTitle(text),
					model: root.selectedAiModel,
					thinkingEnabled: root.aiThinkingEnabled,
					createdAt: now,
					updatedAt: now,
					messages: []
				};
		} else if (index < 0) {
			chat = {
				id: root.makeId("chat"),
				title: root.chatTitle(text),
				model: root.selectedAiModel,
				thinkingEnabled: root.aiThinkingEnabled,
				createdAt: now,
				updatedAt: now,
				messages: []
			};
			chats.unshift(chat);
			index = 0;
			root.activeChatId = chat.id;
		} else {
			chat = Object.assign({}, chats[index], {
				model: root.selectedAiModel,
				thinkingEnabled: root.aiThinkingEnabled,
				updatedAt: now,
				messages: (chats[index].messages || []).slice()
			});
			chats[index] = chat;
		}

		const userMessage = {
			id: root.makeId("user"),
			role: "user",
			content: text,
			attachments: pendingAttachments,
			thinking: "",
			streaming: false
		};
		chat.messages = (chat.messages || []).concat([userMessage]);
		root.startAiRequest(chat, chats, index, root.aiTemporaryChatEnabled);
	}

	function beginEditMessage(message) {
		if (root.aiStreaming || !message || message.role !== "user") return;
		root.editingMessageId = String(message.id || "");
		root.aiPendingAttachments = root.messageAttachments(message).map(attachment => Object.assign({}, attachment));
		root.setLauncherSearch(`>chat ${String(message.content || "")}`);
	}

	function cancelMessageEdit() {
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.setLauncherSearch(">chat ");
	}

	function submitEditedMessage(prompt) {
		const pendingAttachments = root.aiPendingAttachments.map(attachment => Object.assign({}, attachment));
		let text = String(prompt || "").trim();
		if ((text === "" && pendingAttachments.length === 0) || root.aiStreaming || root.editingMessageId === "") return;
		if (root.selectedAiModel === "") {
			root.aiError = "Select an Ollama model first";
			return;
		}
		if (!root.pendingAttachmentsReady) {
			root.aiError = "Wait until all attached files are ready";
			return;
		}
		if (!root.pendingAttachmentsCompatible) {
			root.aiError = "The selected model does not support the attached images";
			return;
		}
		if (text === "") text = "Analyze the attached files.";

		const temporary = root.aiTemporaryChatEnabled;
		const chats = temporary ? [] : root.aiChats.slice();
		const index = temporary ? -1 : root.findChatIndex(root.activeChatId);
		if ((temporary && !root.aiTemporaryChat) || (!temporary && index < 0)) return;
		const chat = Object.assign({}, temporary ? root.aiTemporaryChat : chats[index]);
		const messages = (chat.messages || []).slice();
		let messageIndex = -1;
		for (let i = 0; i < messages.length; i += 1) {
			if (String(messages[i]?.id || "") === root.editingMessageId) {
				messageIndex = i;
				break;
			}
		}
		if (messageIndex < 0 || messages[messageIndex]?.role !== "user") return;

		const editedMessage = Object.assign({}, messages[messageIndex], {
			content: text,
			attachments: pendingAttachments,
			thinking: "",
			streaming: false
		});
		chat.messages = messages.slice(0, messageIndex).concat([editedMessage]);
		chat.model = root.selectedAiModel;
		chat.thinkingEnabled = root.effectiveAiThinkingEnabled;
		chat.updatedAt = Date.now();
		if (messageIndex === 0) chat.title = root.chatTitle(text);
		root.startAiRequest(chat, chats, index, temporary);
	}

	function updateStreamingAssistant(contentDelta, thinkingDelta) {
		const temporary = root.aiStreamingTemporary;
		const index = temporary ? -1 : root.findChatIndex(root.aiStreamingChatId);
		if ((!temporary && index < 0) || (temporary && !root.aiTemporaryChat)) return;
		const chats = temporary ? [] : root.aiChats.slice();
		const chat = Object.assign({}, temporary ? root.aiTemporaryChat : chats[index]);
		const messages = (chat.messages || []).slice();
		if (messages.length === 0) return;
		const lastIndex = messages.length - 1;
		const assistant = Object.assign({}, messages[lastIndex]);
		if (assistant.role !== "assistant") return;
		let content = String(assistant.content || "");
		let thinking = String(assistant.thinking || "");
		const incomingContent = String(contentDelta || "");
		const incomingThinking = String(thinkingDelta || "");
		const thinkingEnabled = Boolean(chat.thinkingEnabled);
		const streamModelName = String(root.aiStreamingModel || chat.model || root.selectedAiModel || "").toLowerCase();

		if (incomingThinking !== "") {
			if (thinkingEnabled) thinking += incomingThinking;
			else root.aiSuppressedThinkingBuffer += incomingThinking;
		}

		if (
			!thinkingEnabled
			&& root.legacyQwenThinkingWorkaround
			&& streamModelName.startsWith("qwen3")
			&& content === ""
		) {
			const combined = root.aiInlineProbeBuffer + incomingContent;
			const trimmed = combined.replace(/^\s+/, "");
			if (root.aiInlineThinking || trimmed.startsWith("<think>")) {
				root.aiInlineThinking = true;
				root.aiInlineProbeBuffer = combined;
				const closeIndex = combined.indexOf("</think>");
				if (closeIndex >= 0) {
					content += combined.slice(closeIndex + 8).replace(/^\s+/, "");
					root.aiInlineThinking = false;
					root.aiInlineProbeBuffer = "";
				}
			} else if (trimmed === "" || "<think>".startsWith(trimmed)) {
				root.aiInlineProbeBuffer = combined;
			} else {
				content += combined.replace(/^\s+/, "");
				root.aiInlineProbeBuffer = "";
			}
		} else {
			content += content === "" ? incomingContent.replace(/^\s+/, "") : incomingContent;
		}

		assistant.content = content;
		assistant.thinking = thinkingEnabled ? thinking : "";
		messages[lastIndex] = assistant;
		chat.messages = messages;
		chat.updatedAt = Date.now();
		if (temporary) {
			root.aiTemporaryChat = chat;
		} else {
			chats[index] = chat;
			root.aiChats = chats;
		}
		root.updateVisibleChatMessage(lastIndex, assistant);
	}

	function finishAiStream(errorMessage, cancelled) {
		const temporary = root.aiStreamingTemporary;
		const index = temporary ? -1 : root.findChatIndex(root.aiStreamingChatId);
		const shouldScroll = root.streamingChatMatchesView();
		const preserveSelection = root.chatSelectionActive;
		const wasCancelled = Boolean(cancelled);
		if ((temporary && root.aiTemporaryChat) || (!temporary && index >= 0)) {
			const chats = temporary ? [] : root.aiChats.slice();
			const chat = Object.assign({}, temporary ? root.aiTemporaryChat : chats[index]);
			const messages = (chat.messages || []).slice();
			if (messages.length > 0) {
				const lastIndex = messages.length - 1;
				const assistant = Object.assign({}, messages[lastIndex]);
				if (assistant.role === "assistant") {
					const removeCancelledPlaceholder = wasCancelled
						&& String(assistant.content || "") === ""
						&& String(assistant.thinking || "") === "";
					if (removeCancelledPlaceholder) {
						messages.pop();
					} else {
					if (!Boolean(chat.thinkingEnabled) && String(assistant.content || "") === "" && !errorMessage) {
						const fallbackContent = String(root.aiInlineProbeBuffer || root.aiSuppressedThinkingBuffer || "")
							.replace(/^\s*<think>\s*/, "")
							.replace(/\s*<\/think>\s*$/, "")
							.trim();
						if (fallbackContent !== "") assistant.content = fallbackContent;
						assistant.thinking = "";
					}
					assistant.streaming = false;
					if (String(assistant.content || "") === "" && errorMessage)
						assistant.content = errorMessage;
					if (!Boolean(chat.thinkingEnabled)) assistant.thinking = "";
					messages[lastIndex] = assistant;
					root.updateVisibleChatMessage(lastIndex, assistant);
					}
				}
			}
			chat.messages = messages;
			chat.updatedAt = Date.now();
			if (temporary) {
				root.aiTemporaryChat = chat;
			} else {
				chats[index] = chat;
				root.aiChats = chats;
			}
		}

		root.aiStreaming = false;
		root.aiStreamingChatId = "";
		root.aiStreamingTemporary = false;
		root.aiStreamingModel = "";
		root.aiInlineThinking = false;
		root.aiSuppressedThinkingBuffer = "";
		root.aiInlineProbeBuffer = "";
		if (errorMessage) root.aiError = errorMessage;
		if (!temporary) root.saveAiState();
		if (shouldScroll && !preserveSelection && wasCancelled) root.syncChatMessageModel();
		if (shouldScroll && !preserveSelection) root.scrollChatToEnd();
	}

	function updateAiStreamStats(chunk) {
		const temporary = root.aiStreamingTemporary;
		const index = temporary ? -1 : root.findChatIndex(root.aiStreamingChatId);
		if ((temporary && !root.aiTemporaryChat) || (!temporary && index < 0)) return;
		const chats = temporary ? [] : root.aiChats.slice();
		const chat = Object.assign({}, temporary ? root.aiTemporaryChat : chats[index]);
		const promptTokens = Number(chunk?.prompt_eval_count || 0);
		const responseTokens = Number(chunk?.eval_count || 0);
		const evalDuration = Number(chunk?.eval_duration || 0);
		chat.contextUsed = promptTokens + responseTokens;
		chat.contextLimit = Number(chat.contextLimit || root.aiRequestContextWindow);
		chat.responseTokens = responseTokens;
		chat.tokensPerSecond = evalDuration > 0 ? responseTokens / (evalDuration / 1000000000) : 0;
		root.storeChat(chat, chats, index, temporary);
	}

	function handleAiStreamData(data) {
		const lines = String(data || "").split("\n");
		for (const rawLine of lines) {
			const line = rawLine.trim();
			if (line === "") continue;
			try {
				const chunk = JSON.parse(line);
				if (chunk.error) {
					root.finishAiStream(String(chunk.error));
					continue;
				}
				const message = chunk.message || {};
				root.updateStreamingAssistant(message.content || "", message.thinking || "");
				if (chunk.done) {
					root.updateAiStreamStats(chunk);
					root.finishAiStream("");
				}
			} catch (error) {
				root.aiProcessError = "Invalid response from Ollama";
			}
		}
	}

	function scrollChatToEnd(force) {
		if (root.aiStreaming && !root.streamingChatMatchesView()) return;
		if (force) root.chatAutoFollow = true;
		if (!root.chatAutoFollow || root.chatSelectionActive) return;
		chatScrollTimer.restart();
	}

	function followChatImmediately() {
		if (!root.aiStreaming || !root.streamingChatMatchesView()) return;
		if (!root.chatAutoFollow || root.chatSelectionActive) return;
		chatList.contentY = Math.max(0, chatList.contentHeight - chatList.height);
	}

	function chatNearEnd() {
		return chatList.contentY >= Math.max(0, chatList.contentHeight - chatList.height) - 36;
	}

	function formatChatTime(timestamp) {
		return Qt.formatDateTime(new Date(Number(timestamp || Date.now())), "dd.MM. HH:mm");
	}

	function usageKey(entry) {
		return String(entry?.id || entry?.name || "");
	}

	function appUsage(entry) {
		const key = root.usageKey(entry);
		return key !== "" ? Number(root.usageMap[key] || 0) : 0;
	}

	function compareApps(left, right) {
		const usageDelta = root.appUsage(right) - root.appUsage(left);
		if (usageDelta !== 0) return usageDelta;
		return String(left.name || left.id || "").localeCompare(String(right.name || right.id || ""));
	}

	function parseUsageJson(raw) {
		try {
			const parsed = JSON.parse(raw);
			root.usageMap = parsed && typeof parsed === "object" ? parsed : ({});
		} catch (error) {
			root.usageMap = ({});
		}
	}

	function shellEscape(value) {
		return String(value).replace(/'/g, `'\"'\"'`);
	}

	function saveUsageMap() {
		const payload = JSON.stringify(root.usageMap);
		saveUsageProcess.exec([
			"sh",
			"-lc",
			`printf '%s' '${root.shellEscape(payload)}' > '${root.shellEscape(root.usageFilePath)}'`
		]);
	}

	function recordLaunch(entry) {
		const key = root.usageKey(entry);
		if (key === "") return;
		const next = Object.assign({}, root.usageMap);
		next[key] = Number(next[key] || 0) + 1;
		root.usageMap = next;
		root.saveUsageMap();
	}

	readonly property var allApps: {
		const entries = [];
		for (const entry of DesktopEntries.applications.values) {
			if (!entry) continue;
			if (entry.noDisplay || entry.hidden) continue;
			entries.push(entry);
		}

		entries.sort((left, right) =>
			String(left.name || left.id || "").localeCompare(String(right.name || right.id || ""))
		);
		return entries;
	}

	readonly property var filteredApps: {
		if (!Plugins.on("apps")) return [];
		const query = root.searchText.trim().toLowerCase();
		const entries = root.allApps.slice();
		if (query === "") {
			entries.sort((left, right) => root.compareApps(left, right));
			return entries.slice(0, 80);
		}

		const prepared = entries.map(entry => ({
			_item: entry,
			name: Fuzzy.prepare(String(entry.name || "")),
			genericName: Fuzzy.prepare(String(entry.genericName || "")),
			comment: Fuzzy.prepare(String(entry.comment || "")),
			id: Fuzzy.prepare(String(entry.id || ""))
		}));

		return Fuzzy.go(query, prepared, {
			all: true,
			keys: ["name", "genericName", "comment", "id"],
			scoreFn: result => {
				const weights = [1.4, 0.5, 0.35, 0.6];
				let score = 0;
				for (let i = 0; i < weights.length; i += 1) score += result[i].score * weights[i];
				score += root.appUsage(result.obj._item) * 100;
				return score;
			}
		}).slice(0, 80).map(result => result.obj._item);
	}

	function iconSource(entry) {
		if (!entry) return "";
		const iconName = String(entry.icon || "");
		const entryId = String(entry.id || "");

		if (iconName.toLowerCase() === "alacritty" || entryId.toLowerCase().includes("alacritty"))
			return "/usr/share/icons/Adwaita/symbolic/actions/system-run-symbolic.svg";
		if (iconName.toLowerCase() === "btop" || entryId.toLowerCase().includes("btop"))
			return "/usr/share/icons/hicolor/48x48/apps/btop.png";

		const papirusIcon = root.papirusAppIcon(iconName) || root.papirusAppIcon(entryId);
		if (papirusIcon !== "") return papirusIcon;

		if (entry.icon) {
			const direct = Quickshell.iconPath(entry.icon, true);
			if (direct !== "") return direct;

			const normalizedIcon = iconName.replace(/\.(png|svg|xpm)$/i, "");
			if (normalizedIcon !== iconName) {
				const normalizedDirect = Quickshell.iconPath(normalizedIcon, true);
				if (normalizedDirect !== "") return normalizedDirect;
			}
		}

		if (entry.id) {
			const desktopPath = Quickshell.iconPath(entry.id, true);
			if (desktopPath !== "") return desktopPath;
		}

		return Quickshell.iconPath("application-x-executable", true);
	}

	function papirusAppIcon(icon) {
		if (!icon) return "";
		const raw = String(icon);
		if (raw.startsWith("/") || raw.startsWith("file:") || raw.startsWith("image:") || raw.startsWith("qrc:")) return "";
		const lower = raw.toLowerCase();
		const noDesktop = lower.endsWith(".desktop") ? lower.slice(0, -8) : lower;
		const noExtension = noDesktop.replace(/\.(png|svg|xpm)$/i, "");
		return AppIcons.map[lower] || AppIcons.map[noDesktop] || AppIcons.map[noExtension] || AppIcons.map[`${noExtension}.desktop`] || "";
	}

	function activateCurrent(modifiers) {
		if (root.activeModeView) {
			root.activeModeView.activate(modifiers || 0);
			return;
		}

		if (root.inChatMode) {
			if (root.editingMessageId !== "") root.submitEditedMessage(root.chatPrompt);
			else root.sendChatPrompt(root.chatPrompt);
			return;
		}

		if (root.inFileMode) {
			root.openSelectedFileBrowserEntry();
			return;
		}

		if (root.inCalculatorMode) {
			root.launchCommand(root.calculatorCommand());
			return;
		}

		if (root.inCommandMode) {
			root.launchCommand(root.paletteCommand);
			return;
		}

		if (root.commandFocus >= 0 && root.commandFocus < root.appCommands.length) {
			root.launchCommand(root.appCommands[root.commandFocus].command);
			return;
		}

		if (appList.currentIndex < 0 || appList.currentIndex >= root.filteredApps.length) return;
		root.launchApp(root.filteredApps[appList.currentIndex]);
	}

	function launchApp(entry) {
		if (!entry) return;

		root.recordLaunch(entry);
		root.closeRequested();
		Quickshell.execDetached({
			command: entry.runInTerminal ? ["app2unit", "--", "kitty", "-e", ...entry.command] : ["app2unit", "--", ...entry.command],
			workingDirectory: entry.workingDirectory
		});
		root.launchRequested();
	}

	function launchCommand(command) {
		if (!command) return;
		if (command.id !== "calculator-result" && command.id !== "studio-page") root.recordLaunch({ id: `>${command.command}` });
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
		case "niri-settings":
			root.closeRequested();
			root.runAfterClose(["qs", "ipc", "-p", Quickshell.shellDir, "call", "niri", "open", command.page || ""]);
			break;
		case "calculator":
			root.setLauncherSearch(">c ");
			break;
		case "file-browser":
			root.setLauncherSearch(">file ");
			root.refreshFileBrowserDirectory();
			break;
		case "chats":
			root.setLauncherSearch(">chats ");
			break;
		case "ollama":
			root.setLauncherSearch(">ollama");
			break;
		case "chat":
			root.startNewChat();
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
		case "dnd":
			Notifs.toggleDnd();
			root.closeRequested();
			break;
		case "calculator-result":
			if (!command.valid) return;
			Quickshell.execDetached(["sh", "-lc", `printf '%s' '${root.shellEscape(command.result)}' | wl-copy`]);
			root.closeRequested();
			root.launchRequested();
			break;
		}
	}

	function reset() {
		root.editingMessageId = "";
		root.aiAttachmentPickerOpen = false;
		root.resetting = true;
		root.leaveCommandInput("");
		root.resetting = false;
		appList.currentIndex = root.filteredApps.length > 0 ? 0 : -1;
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
		if (content.trim() === "" || root.aiStreaming) return;
		if (content.length > 500000) {
			root.aiError = "Clipboard text is too long";
			return;
		}
		root.startNewChat();
		root.aiPendingAttachments = [{
			id: root.makeId("clipboard"),
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
		root.sendChatPrompt(prompt);
	}

	function pickFileForPhone() {
		Phone.pickingFile = true;
		root.setLauncherSearch(">file ");
	}

	onFilteredAppsChanged: {
		if (root.inCommandMode) return;
		if (filteredApps.length === 0 && root.commandFocus < 0 && root.appCommands.length > 0) root.commandFocus = 0;
		if (filteredApps.length === 0) appList.currentIndex = -1;
		else if (appList.currentIndex < 0 || appList.currentIndex >= filteredApps.length) appList.currentIndex = 0;
	}

	// a tile that went (a plugin switched off) takes the pick with it
	onPaletteCellsChanged: if (root.paletteIndex >= root.paletteCells.length) root.pickPaletteCell()
	onAppCommandsChanged: if (root.commandFocus >= root.appCommands.length) root.commandFocus = root.appCommands.length - 1

	onFilteredFileBrowserEntriesChanged: {
		if (!root.inFileMode) return;
		if (filteredFileBrowserEntries.length === 0) fileBrowserList.currentIndex = -1;
		else if (fileBrowserList.currentIndex < 0 || fileBrowserList.currentIndex >= filteredFileBrowserEntries.length)
			fileBrowserList.currentIndex = 0;
	}

	onInAiModeChanged: {
		if (!inAiMode) return;
		if (root.commandInputHasSeparator)
			Qt.callLater(function() {
				searchField.forceActiveFocus();
			});
	}

	onInChatModeChanged: {
		if (inChatMode) {
			root.syncChatMessageModel();
			root.scrollChatToEnd(true);
			root.refreshOllamaRunningModels();
			Qt.callLater(root.capturePrimarySelection);
		} else {
			root.editingMessageId = "";
			Qt.callLater(root.primePrimarySelection);
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
		root.refreshOllamaOverview();
		if (root.commandInputHasSeparator)
			Qt.callLater(function() {
				searchField.forceActiveFocus();
			});
	}

	onSelectedAiModelChanged: {
		root.aiModelInfo = ({});
		root.aiModelCapabilities = [];
		root.aiModelContextWindow = 0;
		root.refreshAiModelInfo();
	}

	onAiAttachmentDirectoryChanged: {
		if (root.aiAttachmentPickerOpen) root.refreshAttachmentDirectory();
	}

	onFileBrowserDirectoryChanged: {
		if (root.inFileMode) root.refreshFileBrowserDirectory();
	}

	FileView {
		id: usageFile
		path: root.usageFilePath
		onLoaded: root.parseUsageJson(text())
		onLoadFailed: root.usageMap = ({})
	}

	FileView {
		id: aiStateFile
		path: root.aiStateFilePath
		printErrors: false
		onLoaded: root.parseAiState(text())
		onLoadFailed: {
			root.aiStateLoaded = true;
			root.ensureSelectedAiModel();
			root.saveAiState();
		}
	}

	Process {
		id: saveUsageProcess
		command: ["sh", "-lc", ":"]
	}

	Process {
		id: aiModelsProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseAiModels(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.aiError = message;
			}
		}

		onExited: function(exitCode) {
			if (exitCode !== 0) {
				if (!root.aiModelsFallbackRunning) {
					root.aiModelsFallbackRunning = true;
					aiModelsFallbackProcess.exec(["ollama", "list"]);
				}
				return;
			}
			root.aiModelsLoading = false;
		}
	}

	Process {
		id: aiModelsFallbackProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseOllamaModelList(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.aiError = message;
			}
		}

		onExited: function(exitCode) {
			root.aiModelsFallbackRunning = false;
			root.aiModelsLoading = false;
			if (exitCode !== 0 && root.aiModels.length === 0 && root.aiError === "")
				root.aiError = "Could not read Ollama models";
		}
	}

	Process {
		id: aiModelInfoProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseAiModelInfo(text)
		}

		onExited: function() {
			root.aiModelInfoLoading = false;
			if (root.aiModelInfoTarget !== root.selectedAiModel)
				root.refreshAiModelInfo();
		}
	}

	Process {
		id: ollamaVersionProcess

		command: ["curl", "-fsS", "http://127.0.0.1:11434/api/version"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.ollamaVersion = String(JSON.parse(text)?.version || "");
				} catch (error) {
					root.ollamaVersion = "";
				}
			}
		}
	}

	Process {
		id: ollamaPsProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseOllamaRunningModels(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.ollamaPsProcessError = message;
			}
		}

		onExited: function(exitCode) {
			if (exitCode !== 0) {
				if (!root.ollamaPsFallbackRunning) {
					root.ollamaPsFallbackRunning = true;
					ollamaPsFallbackProcess.exec(["ollama", "ps"]);
				}
				return;
			}
			root.ollamaRunningLoading = false;
			root.ollamaPsProcessError = "";
		}
	}

	Process {
		id: ollamaPsFallbackProcess

		stdout: StdioCollector {
			onStreamFinished: root.parseOllamaRunningList(text)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.ollamaPsProcessError = message;
			}
		}

		onExited: function(exitCode) {
			root.ollamaPsFallbackRunning = false;
			root.ollamaRunningLoading = false;
			if (exitCode !== 0 && root.ollamaManagerError === "")
				root.ollamaManagerError = root.ollamaPsProcessError || "Could not read running Ollama models";
			root.ollamaPsProcessError = "";
		}
	}

	Process {
		id: ollamaRemoveProcess

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.ollamaManagerError = message;
			}
		}

		onExited: function(exitCode) {
			root.ollamaRemovingModel = "";
			if (exitCode !== 0 && root.ollamaManagerError === "")
				root.ollamaManagerError = "Could not remove model";
			root.refreshOllamaOverview(false);
		}
	}

	Process {
		id: ollamaPullProcess

		stdout: SplitParser {
			onRead: data => root.handleOllamaPullData(data)
		}

		stderr: StdioCollector {
			onStreamFinished: {
				const message = String(text || "").trim();
				if (message !== "") root.ollamaManagerError = message;
			}
		}

		onExited: function(exitCode) {
			root.ollamaPulling = false;
			if (exitCode !== 0 && root.ollamaManagerError === "")
				root.ollamaManagerError = "Could not pull model";
			root.refreshOllamaOverview(false);
		}
	}

	Process {
		id: aiChatProcess
		stdinEnabled: true

		onStarted: {
			aiChatProcess.write(root.aiRequestPayload);
			aiChatProcess.stdinEnabled = false;
			root.aiRequestPayload = "";
		}

		stdout: SplitParser {
			onRead: data => root.handleAiStreamData(data)
		}

		stderr: StdioCollector {
			onStreamFinished: root.aiProcessError = String(text || "").trim()
		}

		onExited: function(exitCode) {
			aiChatProcess.stdinEnabled = true;
			if (!root.aiStreaming) return;
			if (exitCode === 0) root.finishAiStream(root.aiProcessError);
			else root.finishAiStream(root.aiProcessError || "Could not reach Ollama");
		}
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

	Process {
		id: attachmentReadProcess

		stdout: StdioCollector {
			onStreamFinished: root.aiAttachmentReadOutput = String(text || "")
		}

		stderr: StdioCollector {
			onStreamFinished: root.aiAttachmentReadError = String(text || "")
		}

		onExited: exitCode => root.finishPendingAttachmentRead(exitCode)
	}

	Process {
		id: primarySelectionProcess

		stdout: StdioCollector {
			onStreamFinished: root.aiPrimarySelectionOutput = String(text || "")
		}

		stderr: StdioCollector {
			onStreamFinished: root.aiPrimarySelectionError = String(text || "")
		}

		onExited: exitCode => root.finishPrimarySelectionRead(exitCode)
	}

	Process {
		id: aiUnloadProcess
	}

	Component.onCompleted: {
		root.refreshAiModels();
		Qt.callLater(root.primePrimarySelection);
		ollamaVersionProcess.running = true;
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
		if (root.inChatMode) return "chat";
		if (root.inAiMode) return "chats";
		if (root.inOllamaMode) return "ollama";
		if (root.inFileMode) return "files";
		if (root.inCalculatorMode) return "calc";
		if (root.inCommandMode) return "commands";
		return "apps";
	}
	readonly property bool browsingApps: root.mode === "apps" && root.searchText.trim() === ""
	readonly property string inputGlyph: {
		if (root.editingMessageId !== "") return "pencil";
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
		case "niri-settings": return command.page === "keys" ? "keyboard" : (command.page === "displays" ? "monitor_multiple" : "tune_variant");
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
		}
		return "console";
	}

	// the view of the current mode when it handles keys itself
	readonly property var activeModeView: {
		switch (root.mode) {
		case "translate": return translateView;
		case "convert": return convertView;
		case "todo": return todoView;
		case "web": return webSearchView;
		case "ai": return aiActionsView;
		case "phone": return phoneView;
		case "shots": return shotsView;
		default: return null;
		}
	}
	readonly property string modePlaceholder: {
		switch (root.mode) {
		case "translate": return "Text";
		case "convert": return "5 kg in lb";
		case "todo": return todoView.naming ? "List name" : "New task";
		case "web": return "Search the web";
		case "ai": return "Instruction";
		case "phone": return "Text to send";
		default: return "";
		}
	}
	readonly property string enterHint: {
		switch (root.mode) {
		case "chat": return root.editingMessageId !== "" ? "resend" : "send";
		case "calc":
		case "convert":
		case "translate": return "copy";
		case "todo": return todoView.naming ? "create" : "add";
		case "web": return webSearchView.showingResults ? "open" : "search";
		case "ai": return "run";
		case "phone": return "send";
		case "shots": return "copy";
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
		const kind = root.attachmentKind(file);
		if (kind === "pdf" || kind === "document") return "file_document";
		if (kind === "text") return "text_box";
		return "file";
	}

	function focusSearch() {
		searchField.cursorPosition = searchField.text.length;
		searchField.forceActiveFocus();
	}

	onModeChanged: root.modelMenuOpen = false

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

			readonly property bool lit: searchField.activeFocus || commandTokenField.activeFocus || root.editingMessageId !== ""

			Layout.fillWidth: true
			implicitHeight: root.inChatMode
				? Math.min(168, Math.max(54, searchField.contentHeight + 26))
				: 54
			radius: root.inChatMode ? 22 : 27
			color: searchBox.lit ? Theme.layer2 : Theme.layer1
			border.width: searchBox.lit ? 1.5 : 0
			border.color: root.editingMessageId !== "" ? Theme.warning : Qt.alpha(Theme.primary, 0.85)

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

			Glyph {
				id: lead

				x: 18
				y: root.inChatMode ? 17 : (parent.height - height) / 2
				icon: root.inputGlyph
				size: 21
				color: searchBox.lit ? Theme.primary : Theme.textMuted
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
					? (root.editingMessageId !== "" ? "Edit your message" : "Message  ·  Shift+Enter for a new line")
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
					if (root.mode === "commands") {
						root.movePalette(-1, 0);
						return;
					}
					if (root.mode === "apps" && root.commandFocus >= 0) {
						root.commandFocus = Math.max(0, root.commandFocus - 1);
						return;
					}
					if (root.mode !== "apps" || root.filteredApps.length === 0 || appList.columns === 1) {
						event.accepted = false;
						return;
					}
					appList.currentIndex = Math.max(0, appList.currentIndex - 1);
					appList.positionViewAtIndex(appList.currentIndex, GridView.Contain);
					event.accepted = true;
				}
				Keys.onRightPressed: event => {
					if (root.mode === "commands") {
						root.movePalette(1, 0);
						return;
					}
					if (root.mode === "apps" && root.commandFocus >= 0) {
						root.commandFocus = Math.min(root.appCommands.length - 1, root.commandFocus + 1);
						return;
					}
					if (root.mode !== "apps" || root.filteredApps.length === 0 || appList.columns === 1) {
						event.accepted = false;
						return;
					}
					appList.currentIndex = Math.min(root.filteredApps.length - 1, appList.currentIndex + 1);
					appList.positionViewAtIndex(appList.currentIndex, GridView.Contain);
					event.accepted = true;
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
					if (root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode) return;
					if (root.inCommandMode) {
						root.movePalette(0, 1);
						return;
					}
					if (root.filteredApps.length === 0) return;
					// from the commands above the list back into it
					if (root.commandFocus >= 0) {
						root.commandFocus = -1;
						return;
					}
					appList.currentIndex = Math.min(root.filteredApps.length - 1, appList.currentIndex + appList.columns);
					appList.positionViewAtIndex(appList.currentIndex, GridView.Contain);
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
					if (root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode) return;
					if (root.inCommandMode) {
						root.movePalette(0, -1);
						return;
					}
					if (root.commandFocus < 0 && root.appCommands.length > 0 && appList.currentIndex < appList.columns) {
						root.commandFocus = 0;
						return;
					}
					if (root.filteredApps.length === 0 || root.commandFocus >= 0) return;
					appList.currentIndex = Math.max(0, appList.currentIndex - appList.columns);
					appList.positionViewAtIndex(appList.currentIndex, GridView.Contain);
				}
			}

			Row {
				id: trailing

				anchors.right: parent.right
				anchors.rightMargin: 9
				y: root.inChatMode ? parent.height - height - 9 : (parent.height - height) / 2
				spacing: 4

				IconButton {
					visible: root.inChatMode && !root.aiStreaming
					width: 36
					height: 36
					icon: "paperclip"
					iconSize: 18
					checked: root.aiAttachmentPickerOpen
					onClicked: root.aiAttachmentPickerOpen ? root.closeAttachmentPicker() : root.openAttachmentPicker()
				}

				IconButton {
					visible: root.inChatMode && !root.aiStreaming
					width: 36
					height: 36
					icon: "send"
					iconSize: 17
					variant: "filled"
					enabled: root.chatPrompt !== "" || root.aiPendingAttachments.length > 0
					onClicked: root.activateCurrent()
				}

				IconButton {
					visible: (root.aiStreaming && root.inChatMode) || root.commandInputActive || searchField.text !== ""
					width: 36
					height: 36
					icon: root.aiStreaming && root.inChatMode ? "stop" : "close"
					iconSize: 18
					variant: root.aiStreaming && root.inChatMode ? "danger" : "ghost"
					onClicked: {
						if (root.aiStreaming && root.inChatMode) root.cancelAiStream();
						else if (root.editingMessageId !== "") root.cancelMessageEdit();
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

			// apps: grid while browsing, ranked list while searching
			ModeLayer {
				current: root.mode === "apps"

				// commands that answer the search, ahead of the apps
				Row {
					id: commandStrip

					width: parent.width
					spacing: 6
					visible: root.appCommands.length > 0

					Repeater {
						model: root.appCommands.length

						delegate: CommandTile {
							id: found

							required property int index

							readonly property var entry: root.appCommands[found.index] || null

							width: (commandStrip.width - 3 * commandStrip.spacing) / 4
							command: found.entry?.command ?? null
							glyph: root.commandGlyph(found.entry?.command)
							selected: root.commandFocus === found.index
							onPointed: root.commandFocus = found.index
							onClicked: if (found.entry) root.launchCommand(found.entry.command)
						}
					}
				}

				GridView {
					id: appList

					readonly property int columns: root.browsingApps ? 6 : 1

					anchors.fill: parent
					anchors.topMargin: commandStrip.visible ? commandStrip.height + 8 : 0
					clip: true
					cellWidth: Math.floor(width / columns)
					cellHeight: root.browsingApps ? 112 : 58
					model: root.filteredApps
					currentIndex: model.length > 0 ? 0 : -1
					boundsBehavior: Flickable.StopAtBounds
					highlightFollowsCurrentItem: false
					ScrollBar.vertical: ThinScrollBar {}

					populate: Transition {
						Anim {
							property: "opacity"
							from: 0
							to: 1
							duration: Motion.short
						}
					}

					delegate: Item {
						id: app

						required property DesktopEntry modelData
						required property int index
						readonly property bool selected: appList.currentIndex === app.index && root.commandFocus < 0
						readonly property string subtitle: String(app.modelData.genericName || app.modelData.comment || "")

						function point() {
							root.commandFocus = -1;
							appList.currentIndex = app.index;
						}

						width: appList.cellWidth
						height: appList.cellHeight

						Rectangle {
							id: plate

							anchors.fill: parent
							anchors.margins: root.browsingApps ? 5 : 2
							radius: root.browsingApps ? (app.selected ? Theme.radius.large : 26) : Theme.radius.medium
							color: app.selected ? Theme.primaryContainer : (hover.containsMouse ? Theme.layer1 : "transparent")
							scale: hover.pressed ? 0.94 : (app.selected && root.browsingApps ? 1.03 : 1)

							Behavior on color {
								ColorAnim {}
							}
							Behavior on radius {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							// grid tile
							Column {
								visible: root.browsingApps
								anchors.centerIn: parent
								width: parent.width - 14
								spacing: 9

								Image {
									anchors.horizontalCenter: parent.horizontalCenter
									width: 44
									height: 44
									source: root.iconSource(app.modelData)
									sourceSize: Qt.size(88, 88)
									fillMode: Image.PreserveAspectFit
									smooth: true
									mipmap: true
									asynchronous: true
									scale: app.selected ? 1.1 : 1

									Behavior on scale {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}

								StyledText {
									width: parent.width
									horizontalAlignment: Text.AlignHCenter
									text: app.modelData.name || app.modelData.id || "App"
									font.pixelSize: Theme.size.label
									font.weight: app.selected ? Font.DemiBold : Font.Medium
								}
							}

							// list row
							RowLayout {
								visible: !root.browsingApps
								anchors.fill: parent
								anchors.leftMargin: 12
								anchors.rightMargin: 14
								spacing: 14

								Image {
									Layout.preferredWidth: 34
									Layout.preferredHeight: 34
									source: root.iconSource(app.modelData)
									sourceSize: Qt.size(68, 68)
									fillMode: Image.PreserveAspectFit
									smooth: true
									mipmap: true
									asynchronous: true
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 0

									StyledText {
										Layout.fillWidth: true
										text: app.modelData.name || app.modelData.id || "App"
										font.pixelSize: Theme.size.body
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										visible: app.subtitle !== ""
										text: app.subtitle
										tone: Theme.textMuted
										font.pixelSize: Theme.size.small
									}
								}

								Glyph {
									icon: "keyboard_return"
									size: 16
									color: Theme.primary
									opacity: app.selected ? 1 : 0
									scale: app.selected ? 1 : 0.5

									Behavior on opacity {
										Anim {
											duration: Motion.short
										}
									}
									Behavior on scale {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}

							MouseArea {
								id: hover

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onEntered: if (Pointer.moved(hover, mouseX, mouseY)) app.point()
								onPositionChanged: if (Pointer.moved(hover, mouseX, mouseY)) app.point()
								onClicked: root.launchApp(app.modelData)
							}
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.filteredApps.length === 0 && root.appCommands.length === 0
					icon: "magnify"
					title: "No apps match"
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

			// todo lists
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
					model: root.selectedAiModel
					busy: root.aiStreaming
					onRunRequested: (prompt, text) => root.runClipboardAction(prompt, text)
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
											text: fileRow.file.isDir ? "Folder" : `${fileRow.file.suffix || "file"} · ${root.formatAttachmentSize(fileRow.file.size)}`
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
							onActivated: root.startNewChat()
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
								readonly property bool streamingHere: root.aiStreaming && String(chatRow.modelData.id || "") === root.aiStreamingChatId

								width: pastChatList.width
								icon: chatRow.streamingHere ? "progress_clock" : "chat"
								title: chatRow.modelData.title || "Untitled chat"
								subtitle: `${chatRow.modelData.model || "Unknown model"} · ${root.formatChatTime(chatRow.modelData.updatedAt)} · ${(chatRow.modelData.messages || []).length} messages`
								selected: String(chatRow.modelData.id || "") === root.activeChatId
								onClicked: root.openPastChat(chatRow.modelData)

								IconButton {
									Layout.preferredWidth: 30
									Layout.preferredHeight: 30
									icon: "delete_outline"
									iconSize: 16
									variant: "danger"
									enabled: !chatRow.streamingHere
									opacity: chatRow.hovered ? 1 : 0
									onClicked: root.deleteChat(chatRow.modelData)

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
						visible: root.aiError !== ""
						text: root.aiError
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
								text: root.ollamaVersion !== "" ? `v${root.ollamaVersion} · ${root.aiModels.length} models installed` : `${root.aiModels.length} models installed`
							}
						}

						IconButton {
							icon: "refresh"
							variant: "tonal"
							onClicked: root.refreshOllamaOverview()

							RotationAnimator on rotation {
								running: root.aiModelsLoading || root.ollamaRunningLoading
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
									text: root.ollamaPullModel
									enabled: !root.ollamaPulling
									onEdited: text => root.ollamaPullModel = text
									onAccepted: root.startOllamaPull(ollamaPullField.text)
								}

								TextButton {
									implicitHeight: 40
									text: "Pull"
									variant: "filled"
									enabled: root.ollamaPullModel.trim() !== "" && !root.ollamaPulling
									busy: root.ollamaPulling
									onActivated: root.startOllamaPull(root.ollamaPullModel)
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								visible: root.ollamaPulling
								spacing: 6

								RowLayout {
									Layout.fillWidth: true

									StyledText {
										Layout.fillWidth: true
										text: root.ollamaPullStatus
										font.pixelSize: Theme.size.small
										font.weight: Font.Medium
									}

									Meta {
										text: [
											root.ollamaPullTotal > 0 ? `${Math.round(root.ollamaPullProgress * 100)}%` : "",
											root.formatTransferRate(root.ollamaPullSpeed),
											root.formatDuration(root.ollamaPullEtaSeconds) !== "" ? `${root.formatDuration(root.ollamaPullEtaSeconds)} left` : ""
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
										width: parent.width * root.ollamaPullProgress
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
							color: root.ollamaRunningModels.length > 0 ? Theme.success : Theme.textFaint
						}

						StyledText {
							text: "Running"
							font.weight: Font.DemiBold
						}

						Meta {
							Layout.fillWidth: true
							text: root.ollamaRunningSummary()
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
							model: root.aiModels
							boundsBehavior: Flickable.StopAtBounds
							ScrollBar.vertical: ThinScrollBar {}

							delegate: ListItem {
								id: modelRow

								required property var modelData
								readonly property string modelName: String(modelData?.name || modelData?.model || "")
								readonly property bool running: root.isOllamaModelRunning(modelName)
								readonly property bool removing: root.ollamaRemovingModel === modelName

								width: ollamaInstalledList.width
								icon: "robot"
								iconBackground: modelRow.running ? Qt.alpha(Theme.success, 0.25) : Theme.layer2
								title: modelRow.modelName
								subtitle: [
									modelRow.running ? "running" : "",
									String(modelRow.modelData?.details?.parameter_size || ""),
									String(modelRow.modelData?.details?.quantization_level || ""),
									root.formatModelSize(modelRow.modelData?.size)
								].filter(value => value !== "").join(" · ")
								selected: modelRow.modelName === root.selectedAiModel
								showHover: true

								TextButton {
									implicitHeight: 30
									text: "Chat"
									icon: "chat"
									enabled: !root.aiStreaming
									onActivated: root.startNewChatWithModel(modelRow.modelName)
								}

								TextButton {
									implicitHeight: 30
									text: ""
									icon: "delete_outline"
									variant: "danger"
									confirm: true
									confirmText: "Remove"
									busy: modelRow.removing
									enabled: !root.aiStreaming && !ollamaRemoveProcess.running
									onActivated: root.removeOllamaModel(modelRow.modelName)
								}
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: !root.aiModelsLoading && root.aiModels.length === 0
							icon: "robot"
							title: "No models installed"
							subtitle: "Pull one above to start chatting."
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: root.ollamaManagerError !== "" || (!root.aiModelsLoading && root.aiModels.length === 0 && root.aiError !== "")
						text: root.ollamaManagerError !== "" ? root.ollamaManagerError : root.aiError
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
								text: root.activeChat?.title || (root.aiTemporaryChatEnabled ? "Temporary chat" : "New chat")
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}

							Meta {
								Layout.fillWidth: true
								text: root.aiTemporaryChatEnabled ? "Not saved to history" : "Saved to history"
							}
						}

						Clickable {
							id: modelChip

							implicitHeight: 32
							implicitWidth: Math.min(220, modelChipRow.implicitWidth + 24)
							radius: 16
							color: root.modelMenuOpen ? Theme.primaryContainer : Theme.layer2
							interactive: !root.aiStreaming && root.aiModels.length > 0
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
									text: root.selectedAiModel || "No model"
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
							selected: root.effectiveAiThinkingEnabled
							enabled: !root.aiStreaming && root.selectedAiSupportsThinking
							opacity: enabled ? 1 : 0.45
							onClicked: root.toggleAiThinking()
						}

						Chip {
							text: "Short"
							icon: "lightning_bolt"
							selected: root.aiShortResponseEnabled
							enabled: !root.aiStreaming
							opacity: enabled ? 1 : 0.45
							onClicked: root.toggleShortResponse()
						}

						Chip {
							text: "Temporary"
							icon: "ghost"
							selected: root.aiTemporaryChatEnabled
							enabled: !root.aiStreaming
							opacity: enabled ? 1 : 0.45
							onClicked: root.toggleTemporaryChat()
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
								width: parent.width * root.activeContextProgress
								color: root.activeContextProgress > 0.85 ? Theme.danger : Theme.primary

								Behavior on width {
									Anim {}
								}
							}
						}

						Meta {
							text: `${root.formatTokenCount(root.activeContextUsed)} / ${root.formatTokenCount(root.activeContextLimit)}`
							tabular: true
						}

						Meta {
							visible: root.activeResponseTokens > 0
							text: `${root.activeTokensPerSecond.toFixed(1)} tok/s · ${root.activeResponseTokens} tokens`
							tabular: true
						}

						Item {
							Layout.fillWidth: true
						}

						Rectangle {
							visible: root.chatLoadedTimerText !== ""
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
									color: root.chatLoadedModel ? Theme.success : Theme.textFaint
								}

								Meta {
									text: root.chatLoadedTimerText
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
									&& Boolean(root.activeChat?.thinkingEnabled)
									&& String(entry.thinking || "") !== ""
								readonly property bool loadingModel: entry.role === "assistant"
									&& entry.streaming
									&& String(entry.content || "") === ""
									&& String(entry.thinking || "") === ""
								readonly property string displayText: String(entry.content || "") !== ""
									? String(entry.content)
									: (loadingModel ? "" : (entry.streaming ? "..." : ""))
								readonly property var attachments: root.messageAttachments(entry)
								readonly property var markdownSegments: root.markdownImageSegments(displayText)
								readonly property bool hasMarkdownImages: markdownSegments.some(segment => segment.kind === "image")
								readonly property string markdownTextOnly: markdownSegments
									.filter(segment => segment.kind === "text")
									.map(segment => String(segment.text || ""))
									.join("\n")
								readonly property bool editingThis: root.editingMessageId !== "" && root.editingMessageId === String(entry.id || "")

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
											onClicked: root.toggleThinkingExpanded(messageRow.entry.id)

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
														: (root.thinkingExpanded(messageRow.entry.id) ? "Reasoning" : "Show reasoning")
													tone: Theme.textMuted
													font.pixelSize: Theme.size.small
													font.weight: Font.Medium
												}

												Glyph {
													icon: "chevron_down"
													size: 14
													color: Theme.textMuted
													rotation: root.thinkingExpanded(messageRow.entry.id) ? 180 : 0

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
															icon: root.isPrimarySelectionAttachment(sentChip.modelData) ? "text_box" : "paperclip"
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

											visible: messageRow.hasThinking && root.thinkingExpanded(messageRow.entry.id)
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
									enabled: !root.aiStreaming
									opacity: rowHover.hovered || messageRow.editingThis ? 1 : 0
									onClicked: root.beginEditMessage(messageRow.entry)

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
							visible: root.activeMessages.length === 0
							icon: "chat"
							title: root.selectedAiModel === "" ? "No model selected" : `Ask ${root.selectedAiModel}`
							subtitle: root.selectedAiModel === ""
								? "Install or pick an Ollama model first (>ollama)."
								: "Type below and press Enter. Selected text is attached automatically."
						}
					}

					ListView {
						id: pendingAttachmentBar

						Layout.fillWidth: true
						Layout.preferredHeight: visible ? 32 : 0
						visible: root.aiPendingAttachments.length > 0
						orientation: ListView.Horizontal
						spacing: 6
						clip: true
						model: root.aiPendingAttachments
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
							opacity: pendingChip.modelData.kind === "image" && !root.selectedAiSupportsVision ? 0.45 : 1

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
									icon: root.isPrimarySelectionAttachment(pendingChip.modelData) ? "text_box" : "paperclip"
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
								onClicked: root.removePendingAttachment(pendingChip.modelData.id)
							}
						}
					}

					StyledText {
						id: chatError

						Layout.fillWidth: true
						visible: root.aiError !== ""
						text: root.aiError
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
						model: root.aiModels
						boundsBehavior: Flickable.StopAtBounds
						ScrollBar.vertical: ThinScrollBar {}

						delegate: Clickable {
							id: modelOption

							required property var modelData
							readonly property string modelName: String(modelData?.name || modelData?.model || "")
							readonly property bool picked: modelOption.modelName === root.selectedAiModel

							width: modelMenuList.width
							implicitHeight: 36
							radius: Theme.radius.medium
							pressedScale: 0.97
							color: modelOption.picked ? Theme.primaryContainer : (modelOption.hovered ? Theme.layer3 : "transparent")
							onClicked: {
								root.selectAiModel(modelOption.modelName);
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
									text: root.formatModelSize(modelOption.modelData?.size)
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

		// ── footer ────────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 14

			KeyHint {
				key: "↵"
				label: root.enterHint
			}

			KeyHint {
				visible: root.mode === "web"
				key: "^↵"
				label: "results"
			}

			KeyHint {
				visible: root.mode === "todo"
				key: "^N"
				label: "new list"
			}

			KeyHint {
				visible: !root.inChatMode && !root.inCalculatorMode && root.mode !== "translate"
				key: root.browsingApps || root.mode === "commands" ? "←↑↓→" : "↑↓"
				label: root.mode === "todo" ? "lists" : "move"
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
				visible: !root.inCommandMode
				key: ">"
				label: "commands"
			}

			KeyHint {
				key: "esc"
				label: "close"
			}

			Item {
				Layout.fillWidth: true
			}

			Meta {
				text: {
					switch (root.mode) {
					case "apps": return root.browsingApps ? "Most used" : `${root.filteredApps.length} results`;
					case "commands": return root.paletteCommand ? `${root.paletteCommand.prefix || ">"}${root.paletteCommand.command}` : "";
					case "chat": return root.aiStreaming ? "Generating…" : "";
					default: return "";
					}
				}
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
					text: root.selectedAiSupportsVision ? "Text, documents, PDF and images" : "Text, documents and PDF · images need a vision model"
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
						readonly property bool supported: Boolean(file.isDir) || root.attachmentSupported(file)
						readonly property bool picked: root.isAttachmentSelected(file.path)
						readonly property bool current: attachmentFileList.currentIndex === attachRow.index

						width: attachmentFileList.width
						implicitHeight: 46
						radius: Theme.radius.medium
						pressedScale: 0.98
						showHover: false
						interactive: attachRow.file.isDir || (attachRow.supported && root.aiAttachmentLoadingId === "")
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
											? `${attachRow.file.mimeType || root.attachmentKind(attachRow.file)} · ${root.formatAttachmentSize(attachRow.file.size)}`
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
