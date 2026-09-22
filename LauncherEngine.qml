pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "caelestia/utils/scripts/fuzzysort.js" as Fuzzy

// The launcher's mind, kept apart from its face. Everything the launcher
// knows — the apps and how often they were opened, the verbs, the
// calculator, the directory listings, every Ollama process and the chats —
// lives here, and nothing here draws. AppLauncherPopup and its panels bind
// to these properties, call these functions and listen for the few signals
// that ask the view to do something only a view can do (take focus, scroll).
Item {
	id: root
	visible: false
	width: 0
	height: 0

	signal closeRequested
	signal launchRequested
	// "wallpaper", "motion", "dress", "combinations" or "styles"
	signal openStudioRequested(string page)
	// The view puts the caret at the end of the query and takes focus.
	signal focusRequested
	// The chat timeline scrolls to its end (debounced through chatScrollTimer).
	signal scrollToEnd
	// The chat timeline jumps to its end right now (content grew while streaming).
	signal followNow

	// Set by the view: whether the chat timeline is within a few rows of its end.
	property bool chatViewNearEnd: true

	// Selection in every list the launcher can show. The light on each
	// thread follows these.
	property int appIndex: -1
	property int commandIndex: -1
	property int fileIndex: -1
	property int chatIndex: -1
	property int ollamaIndex: -1
	property int attachmentIndex: -1

	readonly property string ollamaIconPath: String(Qt.resolvedUrl("ollama-symbolic.png"))

	// The chat timeline's model: one row per message of the active chat, so
	// a streaming reply updates one delegate instead of rebuilding the list.
	readonly property alias chatMessageModel: chatMessageModel

	// What the launcher is, right now, from the text alone.
	readonly property string mode: {
		if (!root.inCommandMode) return "apps";
		if (root.inCalculatorMode) return "calc";
		if (root.inFileMode) return "files";
		if (root.inChatMode) return "chat";
		if (root.inAiMode) return "chats";
		if (root.inOllamaMode) return "ollama";
		return "verbs";
	}

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
	property var commands: [
		// One command for everything that changes how the desktop looks.
		// `studio` lands on wallpaper and colours; the two suffixed forms jump
		// straight to another page of the same window.
		{
			id: "studio",
			command: "studio",
			name: "Studio",
			description: "Wallpaper and colours, window motion, style branch",
			icon: "preferences-desktop-wallpaper-symbolic",
			studioPage: "wallpaper"
		},
		{
			id: "studio-motion",
			command: "studio motion",
			name: "Studio: Motion",
			description: "Niri window animations",
			icon: "preferences-desktop-effects-symbolic",
			studioPage: "motion"
		},
		{
			id: "studio-dress",
			command: "studio icons",
			name: "Studio: Icons & Pointer",
			description: "Icon theme and cursor theme",
			icon: "preferences-desktop-theme-symbolic",
			studioPage: "dress"
		},
		{
			id: "studio-combinations",
			command: "studio combinations",
			name: "Studio: Combinations",
			description: "Whole looks, saved under a name",
			icon: "bookmark-new-symbolic",
			studioPage: "combinations"
		},
		{
			id: "combinations",
			command: "combinations",
			name: "Combinations",
			description: "Wear a saved look, or keep the one that is on",
			icon: "bookmark-new-symbolic",
			studioPage: "combinations"
		},
		{
			id: "style",
			command: "style",
			name: "Style",
			description: "Switch the whole shell to another style branch",
			icon: "view-grid-symbolic",
			studioPage: "styles"
		},
		{
			id: "studio-style",
			command: "studio style",
			name: "Studio: Style",
			description: "Switch the whole setup to another style branch",
			icon: "view-grid-symbolic",
			studioPage: "styles"
		},
		{
			id: "calculator",
			command: "c",
			name: "Calculator",
			description: "Type >c 5+5",
			icon: "accessories-calculator-symbolic"
		},
		{
			id: "file-browser",
			command: "file",
			name: "Files",
			description: "Browse and open files",
			icon: "folder-symbolic"
		},
		{
			id: "chat",
			command: "chat",
			name: "Chat",
			description: "Start or continue an AI chat",
			icon: "chat-symbolic"
		},
		{
			id: "chats",
			command: "chats",
			name: "Chats",
			description: "Browse saved chats",
			icon: "view-list-symbolic"
		},
		{
			id: "ollama",
			command: "ollama",
			name: "Ollama",
			description: "Manage installed and running models",
			icon: root.ollamaIconPath
		}
	]

	readonly property string usageFilePath: `${Quickshell.shellDir}/launcher-usage.json`
	readonly property string aiStateFilePath: `${Quickshell.shellDir}/launcher-ai-state.json`
	readonly property bool inCommandMode: root.searchText.trim().startsWith(">")
	readonly property string commandQuery: root.searchText.trim().slice(1).trim().toLowerCase()
	readonly property bool inCalculatorMode: root.isCalculatorQuery(root.commandQuery)
	readonly property bool inAiMode: root.commandQuery === "chats" || root.commandQuery.startsWith("chats ")
	readonly property bool inChatMode: root.commandQuery === "chat" || root.commandQuery.startsWith("chat ")
	readonly property bool inOllamaMode: root.commandQuery === "ollama"
	readonly property bool inFileMode: root.commandQuery === "file" || root.commandQuery.startsWith("file ")
	readonly property string inputIconName: {
		if (root.editingMessageId !== "") return "document-edit-symbolic";
		if (root.inCalculatorMode) return "accessories-calculator-symbolic";
		if (root.inFileMode) return "folder-symbolic";
		if (root.inChatMode) return "chat-symbolic";
		if (root.inAiMode) return "view-list-symbolic";
		if (root.inOllamaMode) return "ollama";
		return "system-search-symbolic";
	}
	readonly property string inputIconPath: {
		switch (root.inputIconName) {
		case "document-edit-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/document-edit-symbolic.svg";
		case "accessories-calculator-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg";
		case "folder-symbolic":
			return root.folderIconPath;
		case "chat-symbolic":
			return "/usr/share/icons/Gruvbox-Plus-Dark/actions/symbolic/comment-symbolic.svg";
		case "view-list-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg";
		case "ollama":
			return root.ollamaIconPath;
		default:
			return "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg";
		}
	}
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
	readonly property string attachmentIconPath: "/usr/share/icons/breeze-dark/actions/16/mail-attachment-symbolic.svg"
	readonly property string folderIconPath: "/usr/share/icons/breeze-dark/places/16/folder-symbolic.svg"
	readonly property string folderOpenIconPath: "/usr/share/icons/breeze-dark/actions/16/document-open-folder-symbolic.svg"
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
	readonly property var filteredCommands: {
		if (!root.inCommandMode) return [];
		if (root.inAiMode || root.inChatMode || root.inOllamaMode || root.inFileMode) return [];
		if (root.inCalculatorMode) return [root.calculatorCommand()];
		if (root.commandQuery === "") return root.commands;

		return root.commands.filter(command => {
			const haystack = [
				String(command.command || ""),
				String(command.name || ""),
				String(command.description || ""),
				String(command.id || "")
			].join(" ").toLowerCase();
			return haystack.includes(root.commandQuery);
		});
	}

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
			root.scrollToEnd();
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
		root.attachmentIndex = root.aiAttachmentEntries.length > 0 ? 0 : -1;
		root.refreshAttachmentDirectory();
	}

	function closeAttachmentPicker() {
		root.aiAttachmentPickerOpen = false;
		root.focusRequested();
	}

	function openSelectedAttachmentEntry() {
		if (!root.aiAttachmentPickerOpen) return;
		const entries = root.aiAttachmentEntries;
		if (root.attachmentIndex < 0 || root.attachmentIndex >= entries.length) return;
		root.openAttachmentEntry(entries[root.attachmentIndex]);
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
		root.openPathWithDefaultApp(entry.path);
	}

	function openSelectedFileBrowserEntry() {
		if (!root.inFileMode) return;
		if (root.fileIndex < 0 || root.fileIndex >= root.filteredFileBrowserEntries.length)
			return;
		root.openFileBrowserEntry(root.filteredFileBrowserEntries[root.fileIndex]);
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

	// One text is the whole query. Setting it programmatically also hands the
	// caret back to the field (the view listens for focusRequested).
	function setLauncherSearch(text) {
		root.searchText = String(text || "");
		root.resetSelection();
		root.focusRequested();
	}

	function resetSelection() {
		root.appIndex = root.filteredApps.length > 0 ? 0 : -1;
		root.commandIndex = root.filteredCommands.length > 0 ? 0 : -1;
		root.fileIndex = root.filteredFileBrowserEntries.length > 0 ? 0 : -1;
		root.chatIndex = root.filteredAiChats.length > 0 ? Math.max(0, root.findChatIndexIn(root.filteredAiChats, root.activeChatId)) : -1;
		root.ollamaIndex = root.aiModels.length > 0 ? 0 : -1;
	}

	function findChatIndexIn(list, chatId) {
		for (let i = 0; i < list.length; i += 1)
			if (String(list[i]?.id || "") === String(chatId || "")) return i;
		return -1;
	}

	// Up/Down in whatever list the mode shows.
	function moveSelection(delta) {
		const step = (index, length) => length === 0 ? -1 : Math.max(0, Math.min(length - 1, (index < 0 ? 0 : index) + delta));
		if (root.aiAttachmentPickerOpen) { root.attachmentIndex = step(root.attachmentIndex, root.aiAttachmentEntries.length); return; }
		switch (root.mode) {
		case "apps": root.appIndex = step(root.appIndex, root.filteredApps.length); break;
		case "verbs": root.commandIndex = step(root.commandIndex, root.filteredCommands.length); break;
		case "files": root.fileIndex = step(root.fileIndex, root.filteredFileBrowserEntries.length); break;
		case "chats": root.chatIndex = step(root.chatIndex, root.filteredAiChats.length); break;
		case "ollama": root.ollamaIndex = step(root.ollamaIndex, root.aiModels.length); break;
		}
	}

	// The mode beads. Clicking one types the verb for you.
	function setMode(name) {
		switch (String(name || "")) {
		case "apps": root.setLauncherSearch(""); break;
		case "calc": root.setLauncherSearch(">c "); break;
		case "files": root.setLauncherSearch(">file "); root.refreshFileBrowserDirectory(); break;
		case "chat": if (!root.inChatMode) root.startNewChat(); else root.focusRequested(); break;
		case "chats": root.setLauncherSearch(">chats "); break;
		case "ollama": root.setLauncherSearch(">ollama"); break;
		}
	}

	function cycleMode(delta) {
		const order = ["apps", "calc", "files", "chat", "chats", "ollama"];
		const current = Math.max(0, order.indexOf(root.mode === "verbs" ? "apps" : root.mode));
		root.setMode(order[(current + delta + order.length) % order.length]);
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
		root.followNow();
	}

	function chatNearEnd() {
		return root.chatViewNearEnd;
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

		if (entry.icon) {
			const direct = Quickshell.iconPath(entry.icon, true);
			if (direct !== "") return direct;
		}

		if (entry.id) {
			const desktopPath = Quickshell.iconPath(entry.id, true);
			if (desktopPath !== "") return desktopPath;
		}

		return Quickshell.iconPath("application-x-executable", true);
	}

	function activateCurrent() {
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

		if (root.inAiMode) {
			if (root.chatIndex < 0 || root.chatIndex >= root.filteredAiChats.length) return;
			root.openPastChat(root.filteredAiChats[root.chatIndex]);
			return;
		}

		if (root.inOllamaMode) {
			if (root.ollamaIndex < 0 || root.ollamaIndex >= root.aiModels.length) return;
			root.startNewChatWithModel(String(root.aiModels[root.ollamaIndex]?.name || root.aiModels[root.ollamaIndex]?.model || ""));
			return;
		}

		if (root.inCommandMode) {
			if (root.commandIndex < 0 || root.commandIndex >= root.filteredCommands.length) return;
			root.launchCommand(root.filteredCommands[root.commandIndex]);
			return;
		}

		if (root.appIndex < 0 || root.appIndex >= root.filteredApps.length) return;
		root.launchApp(root.filteredApps[root.appIndex]);
	}

	function launchApp(entry) {
		if (!entry) return;

		root.recordLaunch(entry);
		root.closeRequested();
		if (entry.runInTerminal) {
			Quickshell.execDetached({
				command: ["app2unit", "--", ...entry.command],
				workingDirectory: entry.workingDirectory
			});
		} else {
			Quickshell.execDetached({
				command: ["app2unit", "--", ...entry.command],
				workingDirectory: entry.workingDirectory
			});
		}
		root.launchRequested();
	}

	function commandIconSource(command) {
		switch (String(command?.id || "")) {
		case "style-presets":
			return "/usr/share/icons/Adwaita/symbolic/actions/bookmark-new-symbolic.svg";
		case "theme-picker":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-desktop-wallpaper-symbolic.svg";
		case "animation-picker":
			return "/usr/share/icons/Adwaita/symbolic/categories/applications-graphics-symbolic.svg";
		case "calculator":
		case "calculator-result":
			return "/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg";
		case "file-browser":
			return root.folderIconPath;
		case "chat":
			return "/usr/share/icons/Gruvbox-Plus-Dark/actions/symbolic/comment-symbolic.svg";
		case "chats":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg";
		case "ollama":
			return root.ollamaIconPath;
		}
		const iconName = String(command?.icon || "");
		if (iconName.startsWith("/")) return iconName;
		if (iconName !== "") {
			const resolved = Quickshell.iconPath(iconName, true);
			if (resolved !== "") return resolved;
		}

		return "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg";
	}

	function launchCommand(command) {
		if (!command) return;

		switch (String(command.id || "")) {
		case "studio":
		case "studio-motion":
		case "studio-dress":
		case "studio-combinations":
		case "combinations":
		case "style":
		case "studio-style":
			root.closeRequested();
			root.openStudioRequested(String(command.studioPage || "wallpaper"));
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
		root.setLauncherSearch("");
		root.appIndex = root.filteredApps.length > 0 ? 0 : -1;
	}

	onSearchTextChanged: root.resetSelection()

	onFilteredAppsChanged: {
		if (filteredApps.length === 0) root.appIndex = -1;
		else if (root.appIndex < 0 || root.appIndex >= filteredApps.length) root.appIndex = 0;
	}

	onFilteredCommandsChanged: {
		if (filteredCommands.length === 0) root.commandIndex = -1;
		else if (root.commandIndex < 0 || root.commandIndex >= filteredCommands.length) root.commandIndex = 0;
	}

	onFilteredFileBrowserEntriesChanged: {
		if (filteredFileBrowserEntries.length === 0) root.fileIndex = -1;
		else if (root.fileIndex < 0 || root.fileIndex >= filteredFileBrowserEntries.length) root.fileIndex = 0;
	}

	onFilteredAiChatsChanged: {
		if (filteredAiChats.length === 0) root.chatIndex = -1;
		else if (root.chatIndex < 0 || root.chatIndex >= filteredAiChats.length) root.chatIndex = 0;
	}

	onAiModelsChanged: {
		if (aiModels.length === 0) root.ollamaIndex = -1;
		else if (root.ollamaIndex < 0 || root.ollamaIndex >= aiModels.length) root.ollamaIndex = 0;
	}

	onAiAttachmentEntriesChanged: {
		if (aiAttachmentEntries.length === 0) root.attachmentIndex = -1;
		else if (root.attachmentIndex < 0 || root.attachmentIndex >= aiAttachmentEntries.length) root.attachmentIndex = 0;
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
		if (!inFileMode) return;
		root.aiAttachmentPickerOpen = false;
		root.refreshFileBrowserDirectory();
	}

	onInOllamaModeChanged: {
		if (!inOllamaMode) return;
		root.refreshOllamaOverview();
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
		printErrors: false
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
}
