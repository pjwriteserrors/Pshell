pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl as QQCImpl
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "components"
import "caelestia/utils/scripts/fuzzysort.js" as Fuzzy

Item {
	id: root

	signal closeRequested
	signal launchRequested
	// "wallpaper", "motion" or "styles"
	signal openStudioRequested(string page)

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property color danger: "#d95c5c"

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
			icon: Quickshell.shellDir + "/ollama-symbolic.png"
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
		if (root.inFileMode) return "file-browser";
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
		case "file-browser":
			return root.folderIconPath;
		case "chat-symbolic":
			return "/usr/share/icons/Gruvbox-Plus-Dark/actions/symbolic/comment-symbolic.svg";
		case "view-list-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-list-symbolic.svg";
		case "ollama":
			return Quickshell.shellDir + "/ollama-symbolic.png";
		default:
			return "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg";
		}
	}
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
		const muted = root.blendedColorHex(root.foreground, root.secondaryBoxColor, 0.48);
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
			commandList.currentIndex = root.filteredCommands.length > 0 ? 0 : -1;
		else
			appList.currentIndex = root.filteredApps.length > 0 ? 0 : -1;
	}

	function enterCommandInput(text, focusArgument) {
		const value = String(text || "");
		const match = /^(>[^\s]*)(?:\s([\s\S]*))?$/.exec(value);
		if (!match) return;
		root.commandInputSyncing = true;
		root.commandInputActive = true;
		root.commandInputHasSeparator = Boolean(focusArgument) || /\s/.test(value);
		commandTokenField.text = String(match[1] || ">");
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

		if (root.inCommandMode) {
			if (commandList.currentIndex < 0 || commandList.currentIndex >= root.filteredCommands.length) return;
			root.launchCommand(root.filteredCommands[commandList.currentIndex]);
			return;
		}

		if (appList.currentIndex < 0 || appList.currentIndex >= root.filteredApps.length) return;
		root.launchApp(root.filteredApps[appList.currentIndex]);
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
			return Quickshell.shellDir + "/ollama-symbolic.png";
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
		case "studio-style":
		case "style":
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
		root.leaveCommandInput("");
		appList.currentIndex = root.filteredApps.length > 0 ? 0 : -1;
	}

	onFilteredAppsChanged: {
		if (root.inCommandMode) return;
		if (filteredApps.length === 0) appList.currentIndex = -1;
		else if (appList.currentIndex < 0 || appList.currentIndex >= filteredApps.length) appList.currentIndex = 0;
	}

	onFilteredCommandsChanged: {
		if (!root.inCommandMode || root.inAiMode || root.inChatMode || root.inOllamaMode || root.inFileMode) return;
		if (filteredCommands.length === 0) commandList.currentIndex = -1;
		else if (commandList.currentIndex < 0 || commandList.currentIndex >= filteredCommands.length) commandList.currentIndex = 0;
	}

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
		if (!inFileMode) return;
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

	// The bench. The launcher is not a card floating in the middle of the
	// screen: it takes the whole working surface, and what you type is the
	// largest thing on it. The probe runs across the top in the specimen hand,
	// the mode and the count are engraved under it, and everything being
	// cultured lies below that with nothing drawn around it.
	Item {
		anchors.fill: parent

		Column {
			id: dish
			anchors.fill: parent
			spacing: Bio.s4

			// How much room the cultures get once the probe and the plate have
			// taken theirs.
			readonly property real viewHeight: height - plate.height - searchBox.height - spacing * 2

			// The probe line. Not a search box — there is no box: a ring holds
			// the mode's mark, what you type is cut at specimen size straight
			// onto the bench, and the bone under it lights along its whole
			// length while the keyboard is in it.
			Item {
				id: searchBox
				width: parent.width
				height: root.inChatMode
					? Math.min(190, Math.max(58, searchField.contentHeight + 24))
					: 58

				Rectangle {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: Bio.ribThin
					color: Bio.boneFaint
				}

				Rectangle {
					anchors.left: parent.left
					anchors.bottom: parent.bottom
					width: searchField.activeFocus || root.editingMessageId !== "" ? parent.width : 0
					height: Bio.rib
					color: Bio.organ

					Behavior on width {
						NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
					}
				}

				BioRing {
					id: probeRing
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 36
					height: 36
					seed: 1
					lineColor: Bio.boneFaint
					intensity: searchField.activeFocus ? 0.85 : 0

					QQCImpl.IconImage {
						id: inputCommandIcon
						anchors.centerIn: parent
						width: 17
						height: 17
						source: root.inputIconPath
						sourceSize: Qt.size(width, height)
						color: searchField.activeFocus ? Bio.organ : Bio.text
					}
				}

				Item {
					id: commandTokenBox
					anchors.left: probeRing.right
					anchors.leftMargin: Bio.s3
					anchors.verticalCenter: parent.verticalCenter
					width: visible ? Math.min(140, Math.max(30, commandTokenField.contentWidth + 14)) : 0
					height: 24
					visible: root.commandInputActive

					BioFrame {
						anchors.fill: parent
						variant: "capsule"
						beading: false
						weight: Bio.ribThin
						inset: 1
						lineColor: Bio.boneFaint
						liveColor: Bio.organ
						fillTop: Bio.cavity
						fillBottom: Bio.cavity
						intensity: commandTokenField.activeFocus ? 1 : 0
					}

					TextInput {
						id: commandTokenField
						anchors.fill: parent
						anchors.leftMargin: 7
						anchors.rightMargin: 7
						text: ">"
						color: commandTokenField.activeFocus ? Bio.organ : Bio.textMuted
						selectionColor: Qt.alpha(Bio.organ, 0.35)
						selectedTextColor: Bio.text
						cursorVisible: activeFocus
						verticalAlignment: Text.AlignVCenter
						clip: true
						font.family: Bio.mono
						font.pixelSize: 12

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

						Keys.onEscapePressed: root.closeRequested()
						Keys.onPressed: event => {
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
							if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
								root.activateCurrent();
								event.accepted = true;
							}
						}
						Keys.onDownPressed: {
							if (root.inFileMode) {
								if (root.filteredFileBrowserEntries.length === 0) return;
								fileBrowserList.currentIndex = Math.min(root.filteredFileBrowserEntries.length - 1, fileBrowserList.currentIndex + 1);
								fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
								return;
							}
							if (root.filteredCommands.length === 0) return;
							commandList.currentIndex = Math.min(root.filteredCommands.length - 1, commandList.currentIndex + 1);
							commandList.positionViewAtIndex(commandList.currentIndex, ListView.Contain);
						}
						Keys.onUpPressed: {
							if (root.inFileMode) {
								if (root.filteredFileBrowserEntries.length === 0) return;
								fileBrowserList.currentIndex = Math.max(0, fileBrowserList.currentIndex - 1);
								fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
								return;
							}
							if (root.filteredCommands.length === 0) return;
							commandList.currentIndex = Math.max(0, commandList.currentIndex - 1);
							commandList.positionViewAtIndex(commandList.currentIndex, ListView.Contain);
						}
					}
				}

				TextArea {
					id: searchField
					z: 1
					anchors.left: root.commandInputActive ? commandTokenBox.right : probeRing.right
					anchors.leftMargin: Bio.s3
					anchors.right: attachButton.visible ? attachButton.left : clearButton.left
					anchors.rightMargin: Bio.s3
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					anchors.bottomMargin: Bio.s2
					font.family: root.inChatMode ? Bio.sans : Bio.serif
					font.pixelSize: root.inChatMode ? Bio.sizeBody : 27
					color: Bio.text
					placeholderText: root.inChatMode
						? "Message"
						: (root.inAiMode
							? "Search chats"
							: (root.inFileMode
								? "Search files"
								: (root.inCalculatorMode
									? "Expression"
									: (root.commandInputActive ? "Options" : "Search apps or type >c 5+5"))))
					placeholderTextColor: Bio.textFaint
					selectedTextColor: Bio.text
					selectionColor: Qt.alpha(Bio.organ, 0.3)
					selectByMouse: true
					focus: true
					cursorVisible: activeFocus
					clip: true
					wrapMode: root.inChatMode ? TextEdit.Wrap : TextEdit.NoWrap
					horizontalAlignment: Text.AlignLeft
					verticalAlignment: Text.AlignVCenter
					background: Item {}
					cursorDelegate: ThemedRectangle {
						visible: searchField.activeFocus
						width: root.inChatMode ? 1 : 2
						height: searchField.font.pixelSize + 3
						color: Bio.organ
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

					Keys.onEscapePressed: root.closeRequested()
					Keys.onPressed: event => {
						if (
							event.key === Qt.Key_Backspace
							&& root.commandInputActive
							&& searchField.text === ""
							&& searchField.cursorPosition === 0
						) {
							event.accepted = root.focusCommandTokenFromEmptyArgument();
							if (event.accepted) return;
						}
						if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;
						if (root.inChatMode && (event.modifiers & Qt.ShiftModifier)) {
							searchField.insert(searchField.cursorPosition, "\n");
							event.accepted = true;
							return;
						}
						root.activateCurrent();
						event.accepted = true;
					}
					Keys.onLeftPressed: event => {
						if (root.inFileMode || root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode || root.inCommandMode || root.filteredApps.length === 0) {
							event.accepted = false;
							return;
						}
						appList.currentIndex = Math.max(0, appList.currentIndex - 8);
						appList.positionViewAtIndex(appList.currentIndex, ListView.Contain);
						event.accepted = true;
					}
					Keys.onRightPressed: event => {
						if (root.inFileMode || root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode || root.inCommandMode || root.filteredApps.length === 0) {
							event.accepted = false;
							return;
						}
						appList.currentIndex = Math.min(root.filteredApps.length - 1, appList.currentIndex + 8);
						appList.positionViewAtIndex(appList.currentIndex, ListView.Contain);
						event.accepted = true;
					}
					Keys.onDownPressed: {
						if (root.inFileMode) {
							if (root.filteredFileBrowserEntries.length === 0) return;
							fileBrowserList.currentIndex = Math.min(root.filteredFileBrowserEntries.length - 1, fileBrowserList.currentIndex + 1);
							fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
							return;
						}
						if (root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode) return;
						if (root.inCommandMode) {
							if (root.filteredCommands.length === 0) return;
							commandList.currentIndex = Math.min(root.filteredCommands.length - 1, commandList.currentIndex + 1);
							commandList.positionViewAtIndex(commandList.currentIndex, ListView.Contain);
							return;
						}

						if (root.filteredApps.length === 0) return;
						appList.currentIndex = Math.min(root.filteredApps.length - 1, appList.currentIndex + appList.columns);
						appList.positionViewAtIndex(appList.currentIndex, ListView.Contain);
					}
					Keys.onUpPressed: {
						if (root.inFileMode) {
							if (root.filteredFileBrowserEntries.length === 0) return;
							fileBrowserList.currentIndex = Math.max(0, fileBrowserList.currentIndex - 1);
							fileBrowserList.positionViewAtIndex(fileBrowserList.currentIndex, ListView.Contain);
							return;
						}
						if (root.inCalculatorMode || root.inAiMode || root.inChatMode || root.inOllamaMode) return;
						if (root.inCommandMode) {
							if (root.filteredCommands.length === 0) return;
							commandList.currentIndex = Math.max(0, commandList.currentIndex - 1);
							commandList.positionViewAtIndex(commandList.currentIndex, ListView.Contain);
							return;
						}

						if (root.filteredApps.length === 0) return;
						appList.currentIndex = Math.max(0, appList.currentIndex - appList.columns);
						appList.positionViewAtIndex(appList.currentIndex, ListView.Contain);
					}
				}

				Item {
					id: attachButton
					anchors.right: clearButton.left
					anchors.rightMargin: 4
					anchors.verticalCenter: parent.verticalCenter
					width: 22
					height: 22
					visible: root.inChatMode && !root.aiStreaming

					MouseArea {
						id: attachMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.aiAttachmentPickerOpen
							? root.closeAttachmentPicker()
							: root.openAttachmentPicker()
					}

					QQCImpl.IconImage {
						anchors.centerIn: parent
						width: 14
						height: 14
						source: root.attachmentIconPath
						sourceSize: Qt.size(width, height)
						color: attachMouse.containsMouse || root.aiAttachmentPickerOpen ? Bio.organ : Bio.textMuted
					}

					ToolTip.visible: attachMouse.containsMouse
					ToolTip.delay: 500
					ToolTip.text: root.selectedAiSupportsVision
						? "Attach text, document, PDF, or image"
						: "Attach text, document, or PDF"
				}

				Item {
					id: clearButton
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					width: 22
					height: 22
					visible: (root.aiStreaming && root.inChatMode) || root.commandInputActive || searchField.text !== ""

					MouseArea {
						id: clearMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							if (root.aiStreaming && root.inChatMode) root.cancelAiStream();
							else if (root.editingMessageId !== "") root.cancelMessageEdit();
							else root.leaveCommandInput("");
						}
					}

					BioText {
						anchors.centerIn: parent
						role: "body"
						tone: clearMouse.containsMouse ? "organ" : "faint"
						text: root.aiStreaming && root.inChatMode ? "■" : "×"
					}

					ToolTip.visible: clearMouse.containsMouse && root.aiStreaming && root.inChatMode
					ToolTip.delay: 500
					ToolTip.text: "Stop and unload model"
				}
			}

			Item {
				id: plate
				width: parent.width
				height: 16

				BioText {
					id: plateTitle
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					role: "label"
					tone: "organ"
					text: root.inChatMode ? "Discourse"
						: root.inOllamaMode ? "Strains"
						: root.inAiMode ? "Culture"
						: root.inFileMode ? "Specimens"
						: root.inCalculatorMode ? "Calculus"
						: root.inCommandMode ? "Verbs"
						: "Colony"
				}

				BioTendon {
					anchors.left: plateTitle.right
					anchors.right: plateCount.left
					anchors.leftMargin: Bio.s3
					anchors.rightMargin: Bio.s3
					anchors.verticalCenter: parent.verticalCenter
					height: 12
					facing: Qt.LeftToRight
					lineColor: Bio.boneFaint
					visible: width > 30
				}

				BioText {
					id: plateCount
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					role: "label"
					tone: "faint"
					text: root.inCommandMode ? "" : `${root.filteredApps.length} held`
				}
			}

			// The colony, read as an index and a specimen. On the left a plain
			// list of names with nothing in it but the names — that is what you
			// scan. On the right, whatever the index is pointing at, blown up
			// to the size of the thing you are about to open: its mark, its
			// name cut large, what it is, and the command that will run.
			Item {
				id: colony

				width: parent.width
				height: dish.viewHeight
				visible: !root.inCommandMode

				readonly property var current: appList.currentIndex >= 0 && appList.currentIndex < root.filteredApps.length
					? root.filteredApps[appList.currentIndex]
					: null

				ListView {
					id: appList

					// Kept so the key handlers have something to step by; the
					// index is one column now, so a step is one row.
					readonly property int columns: 1

					anchors.left: parent.left
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					width: Math.round(parent.width * 0.36)
					clip: true
					model: root.filteredApps
					currentIndex: model.length > 0 ? 0 : -1
					boundsBehavior: Flickable.StopAtBounds
					spacing: 0

					delegate: Item {
						id: appTile

						required property DesktopEntry modelData
						required property int index
						readonly property bool selected: appList.currentIndex === index

						width: appList.width
						height: 32

						// The vein: the whole selection state in one stroke,
						// the same one a row uses everywhere else in this style.
						Rectangle {
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							width: Bio.rib * 1.6
							height: parent.height * (appTile.selected ? 0.66 : 0)
							radius: width / 2
							color: Bio.organ
							opacity: appTile.selected ? 1 : 0

							Behavior on opacity {
								NumberAnimation { duration: Bio.twitch }
							}
							Behavior on height {
								NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
							}
						}

						BioText {
							id: appRank
							anchors.left: parent.left
							anchors.leftMargin: Bio.s4
							anchors.verticalCenter: parent.verticalCenter
							role: "mono"
							tone: appTile.selected ? "organ" : "faint"
							font.pixelSize: 10
							text: String(appTile.index + 1).padStart(2, "0")
						}

						BioText {
							anchors.left: appRank.right
							anchors.leftMargin: Bio.s3
							anchors.right: parent.right
							anchors.rightMargin: Bio.s4
							anchors.verticalCenter: parent.verticalCenter
							role: "heading"
							font.pixelSize: 14
							tone: appTile.selected ? "default" : "muted"
							text: appTile.modelData.name || appTile.modelData.id || "App"
						}

						BioTouch {
							id: tileHover
							onEntered: appList.currentIndex = appTile.index
							onClicked: root.launchApp(appTile.modelData)
						}
					}
				}

				// The bone the index is written against.
				Rectangle {
					id: colonySpine
					anchors.left: appList.right
					anchors.leftMargin: Bio.s6
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					anchors.topMargin: Bio.s3
					anchors.bottomMargin: Bio.s3
					width: Bio.ribThin
					color: Bio.boneGhost
				}

				// The specimen itself.
				Item {
					id: specimen

					anchors.left: colonySpine.right
					anchors.leftMargin: Bio.s7
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.bottom: parent.bottom
					opacity: colony.current ? 1 : 0

					Behavior on opacity {
						NumberAnimation { duration: Bio.grow }
					}

					BioGlow {
						anchors.centerIn: specimenMark
						width: 220
						height: 220
						color: Bio.organ
						strength: 0.24
						spread: 0.4
					}

					BioRing {
						id: specimenMark
						anchors.left: parent.left
						anchors.bottom: specimenBody.top
						anchors.bottomMargin: Bio.s5
						width: 84
						height: 84
						seed: appList.currentIndex % 4
						weight: Bio.rib * 1.2
						lineColor: Bio.boneDim
						intensity: 1

						Image {
							anchors.centerIn: parent
							width: 44
							height: 44
							source: colony.current ? root.iconSource(colony.current) : ""
							sourceSize: Qt.size(width, height)
							fillMode: Image.PreserveAspectFit
							smooth: true
							mipmap: true
						}
					}

					Column {
						id: specimenBody
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.rightMargin: Bio.s6
						anchors.verticalCenter: parent.verticalCenter
						anchors.verticalCenterOffset: Bio.s4
						spacing: Bio.s2

						BioText {
							width: parent.width
							role: "specimen"
							font.pixelSize: 34
							wrapMode: Text.NoWrap
							text: colony.current ? (colony.current.name || colony.current.id || "") : ""
						}

						BioText {
							width: parent.width
							role: "body"
							tone: "muted"
							wrapMode: Text.WordWrap
							maximumLineCount: 3
							visible: text !== ""
							text: colony.current
								? (colony.current.comment || colony.current.genericName || "")
								: ""
						}

						Item {
							width: 1
							height: Bio.s3
						}

						BioTendon {
							width: Math.min(parent.width, 220)
							height: 12
							facing: Qt.LeftToRight
							lineColor: Bio.boneFaint
						}

						BioText {
							width: parent.width
							role: "mono"
							tone: "faint"
							font.pixelSize: 11
							visible: text !== ""
							text: colony.current
								? String((colony.current.command || []).join(" ")).slice(0, 120)
								: ""
						}
					}

					// What pressing return will do to it.
					Row {
						anchors.left: parent.left
						anchors.bottom: parent.bottom
						anchors.bottomMargin: Bio.s3
						spacing: Bio.s3

						BioText {
							role: "label"
							tone: "organ"
							text: "Return"
						}

						BioText {
							role: "label"
							tone: "faint"
							text: "to grow it"
						}
					}
				}
			}

			ListView {
				id: commandList
				width: parent.width
				height: dish.viewHeight
				visible: root.inCommandMode
					&& !root.inCalculatorMode
					&& !root.inAiMode
					&& !root.inChatMode
					&& !root.inOllamaMode
					&& !root.inFileMode
				clip: true
				spacing: 6
				model: root.filteredCommands
				currentIndex: model.length > 0 ? 0 : -1
				boundsBehavior: Flickable.StopAtBounds

				// A verb: the word you type in mono, what it does underneath,
				// and a ring that lights when it is the one under the cursor.
				delegate: BioRow {
					id: commandRow

					required property var modelData
					required property int index

					width: commandList.width
					implicitHeight: 48
					inset: Bio.s3
					selected: commandList.currentIndex === commandRow.index
					onClicked: root.launchCommand(commandRow.modelData)
					onContainsMouseChanged: {
						if (containsMouse) commandList.currentIndex = commandRow.index;
					}

					BioRing {
						id: commandRing
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						width: 30
						height: 30
						seed: commandRow.index % 4
						lineColor: Bio.boneGhost
						intensity: commandRow.selected ? 1 : 0

						QQCImpl.IconImage {
							anchors.centerIn: parent
							width: 15
							height: 15
							source: root.commandIconSource(commandRow.modelData)
							sourceSize: Qt.size(width, height)
							color: commandRow.selected ? Bio.organ : Bio.text
						}
					}

					Column {
						anchors.left: commandRing.right
						anchors.leftMargin: Bio.s3
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						spacing: -1

						BioText {
							width: parent.width
							role: "mono"
							font.pixelSize: 13
							color: commandRow.selected ? Bio.organ : Bio.text
							text: `>${commandRow.modelData.command || commandRow.modelData.id || "command"}`
						}

						BioText {
							width: parent.width
							role: "caption"
							tone: "faint"
							text: `${commandRow.modelData.name || "Command"} · ${commandRow.modelData.description || ""}`
						}
					}
				}

				ScrollBar.vertical: ScrollBar {
					policy: ScrollBar.AsNeeded
				}
			}

			Item {
				id: calculatorPanel
				width: parent.width
				height: dish.viewHeight
				visible: root.inCalculatorMode

				MouseArea {
					anchors.fill: parent
					enabled: root.calculatorEvaluation.valid
					cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
					onClicked: root.launchCommand(root.calculatorCommand())
				}

				// The result is the specimen here: it is engraved at the size
				// of the thing you came for, with the expression above it as a
				// label and the outcome of the reaction underneath.
				BioGlow {
					anchors.centerIn: parent
					width: parent.width * 0.9
					height: parent.height * 0.7
					color: root.calculatorEvaluation.valid ? Bio.organ : Bio.necrosis
					strength: 0.14
					spread: 0.4
				}

				Column {
					width: parent.width
					anchors.centerIn: parent
					spacing: Bio.s3

					BioText {
						width: parent.width
						role: "label"
						tone: "muted"
						text: root.calculatorExpression
						visible: text !== ""
						horizontalAlignment: Text.AlignHCenter
					}

					BioText {
						width: parent.width
						role: "specimen"
						tone: root.calculatorEvaluation.valid ? "default" : "muted"
						text: root.calculatorEvaluation.valid ? root.calculatorEvaluation.result : "Calculus"
						horizontalAlignment: Text.AlignHCenter
						elide: Text.ElideMiddle
						font.pixelSize: 56
						fontSizeMode: Text.Fit
						minimumPixelSize: 24
					}

					BioTendon {
						width: parent.width * 0.5
						anchors.horizontalCenter: parent.horizontalCenter
						height: 12
						facing: Qt.LeftToRight
						lineColor: root.calculatorEvaluation.valid ? Qt.alpha(Bio.organ, 0.6) : Bio.boneGhost
					}

					BioText {
						width: parent.width
						role: "label"
						tone: root.calculatorEvaluation.valid ? "faint" : "alert"
						text: root.calculatorEvaluation.valid ? "Enter to extract" : root.calculatorEvaluation.message
						horizontalAlignment: Text.AlignHCenter
						wrapMode: Text.WordWrap
					}
				}
			}

			Item {
				id: filePanel
				width: parent.width
				height: dish.viewHeight
				visible: root.inFileMode

				Column {
					anchors.fill: parent
					spacing: 8

					Item {
						id: fileHeader
						width: parent.width
						height: 32

						BioNode {
							id: fileUpButton
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							size: 26
							seed: 1
							onClicked: root.fileBrowserDirectory = root.attachmentParentDirectory(root.fileBrowserDirectory)

							BioText {
								anchors.centerIn: parent
								role: "heading"
								text: "↑"
							}
						}

						BioText {
							anchors.left: fileUpButton.right
							anchors.leftMargin: Bio.s3
							anchors.right: fileOpenCurrentButton.left
							anchors.rightMargin: Bio.s3
							anchors.verticalCenter: parent.verticalCenter
							role: "mono"
							tone: "muted"
							font.pixelSize: 11
							text: root.fileBrowserDirectory
							elide: Text.ElideMiddle
						}

						BioNode {
							id: fileOpenCurrentButton
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							size: 26
							seed: 3

							MouseArea {
								id: fileOpenCurrentMouse
								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: root.openPathWithDefaultApp(root.fileBrowserDirectory)
							}

							QQCImpl.IconImage {
								anchors.centerIn: parent
								width: 16
								height: 16
								source: root.folderOpenIconPath
								sourceSize: Qt.size(width, height)
								color: root.foreground
							}

							ToolTip.visible: fileOpenCurrentMouse.containsMouse
							ToolTip.delay: 500
							ToolTip.text: "Open folder"
						}
					}

					Row {
						id: fileShortcutRow
						width: parent.width
						height: 26
						spacing: 6

						Repeater {
							model: [
								{ name: "Home", path: Quickshell.env("HOME") },
								{ name: "Downloads", path: `${Quickshell.env("HOME")}/Downloads` },
								{ name: "Documents", path: `${Quickshell.env("HOME")}/Documents` },
								{ name: "Pictures", path: `${Quickshell.env("HOME")}/Pictures` }
							]

							delegate: BioButton {
								id: fileShortcut

								required property var modelData

								implicitHeight: 26
								lit: root.fileBrowserDirectory === String(fileShortcut.modelData.path)
								text: String(fileShortcut.modelData.name)
								onClicked: root.fileBrowserDirectory = String(fileShortcut.modelData.path)
							}
						}

						BioText {
							anchors.verticalCenter: parent.verticalCenter
							width: Math.max(0, parent.width - x)
							role: "label"
							tone: "faint"
							text: root.fileBrowserSearchQuery === ""
								? `${root.fileBrowserEntries.length} specimens`
								: `${root.filteredFileBrowserEntries.length} matches`
							horizontalAlignment: Text.AlignRight
							elide: Text.ElideLeft
						}
					}

					Item {
						width: parent.width
						height: parent.height - fileHeader.height - fileShortcutRow.height - parent.spacing * 2

						ListView {
							id: fileBrowserList
							anchors.fill: parent
							anchors.topMargin: Bio.s2
							clip: true
							spacing: 4
							model: root.filteredFileBrowserEntries
							currentIndex: model.length > 0 ? 0 : -1
							boundsBehavior: Flickable.StopAtBounds

							delegate: BioRow {
								id: fileRow

								required property var modelData
								required property int index
								readonly property var file: modelData || ({})

								width: fileBrowserList.width
								implicitHeight: 40
								inset: Bio.s2
								selected: fileBrowserList.currentIndex === fileRow.index
								onClicked: root.openFileBrowserEntry(fileRow.file)
								onContainsMouseChanged: {
									if (containsMouse) fileBrowserList.currentIndex = fileRow.index;
								}

								Item {
									id: fileMark
									anchors.left: parent.left
									anchors.verticalCenter: parent.verticalCenter
									width: 28
									height: 28

									BioRing {
										anchors.fill: parent
										seed: fileRow.index % 4
										lineColor: Bio.boneGhost
										intensity: fileRow.selected ? 1 : 0
									}

									Image {
										visible: Boolean(fileRow.file.isImage)
										anchors.centerIn: parent
										width: 20
										height: 20
										source: fileRow.file.isImage
											? root.resolveMarkdownImageSource(fileRow.file.path)
											: ""
										fillMode: Image.PreserveAspectCrop
										smooth: true
										cache: true
										asynchronous: true
									}

									QQCImpl.IconImage {
										visible: !fileRow.file.isImage
										anchors.centerIn: parent
										width: 14
										height: 14
										source: fileRow.file.isDir ? root.folderIconPath : root.attachmentIconPath
										sourceSize: Qt.size(width, height)
										color: fileRow.selected ? Bio.organ : Bio.text
									}
								}

								Column {
									anchors.left: fileMark.right
									anchors.leftMargin: Bio.s3
									anchors.right: fileFolderOpenButton.left
									anchors.rightMargin: Bio.s2
									anchors.verticalCenter: parent.verticalCenter
									spacing: -1

									BioText {
										width: parent.width
										role: "bodyStrong"
										tone: fileRow.selected ? "organ" : "default"
										text: String(fileRow.file.name || "")
										elide: Text.ElideMiddle
									}

									BioText {
										width: parent.width
										role: "caption"
										tone: "faint"
										text: fileRow.file.isDir
											? "Colony"
											: `${fileRow.file.suffix || "file"} · ${root.formatAttachmentSize(fileRow.file.size)}`
									}
								}

								ThemedRectangle {
									id: fileFolderOpenButton
									anchors.right: parent.right
									anchors.rightMargin: 7
									anchors.verticalCenter: parent.verticalCenter
									width: 26
									height: 26
									radius: ThemeEngine.radiusMedium
									z: 2
									visible: Boolean(fileRow.file.isDir)
									color: fileFolderOpenMouse.containsMouse ? root.secondaryBoxStrongColor : "transparent"

									MouseArea {
										id: fileFolderOpenMouse
										anchors.fill: parent
										hoverEnabled: true
										cursorShape: Qt.PointingHandCursor
										onClicked: root.openPathWithDefaultApp(fileRow.file.path)
									}

									QQCImpl.IconImage {
										anchors.centerIn: parent
										width: 16
										height: 16
										source: root.folderOpenIconPath
										sourceSize: Qt.size(width, height)
										color: root.foreground
									}

									ToolTip.visible: fileFolderOpenMouse.containsMouse
									ToolTip.delay: 500
									ToolTip.text: "Open folder"
								}
							}

							ScrollBar.vertical: ScrollBar {
								policy: ScrollBar.AsNeeded
							}
						}

						BioText {
							role: "body"
							anchors.centerIn: parent
							width: parent.width - 40
							visible: fileBrowserList.count === 0
							color: Qt.alpha(root.foreground, 0.5)
							text: root.fileBrowserDirectoryLoading
								? "Loading..."
								: (root.fileBrowserDirectoryError !== ""
									? root.fileBrowserDirectoryError
									: (root.fileBrowserSearchQuery === "" ? "This folder is empty" : "No matching files"))
							horizontalAlignment: Text.AlignHCenter
							wrapMode: Text.WordWrap
							font.pixelSize: 12
							font.weight: Font.Medium
						}
					}
				}
			}

			Item {
				id: aiPanel
				width: parent.width
				height: dish.viewHeight
				visible: root.inAiMode

				Column {
					anchors.fill: parent
					spacing: 10

					Item {
						width: parent.width
						height: 24

						BioText {
							id: chatsHeading
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							role: "label"
							tone: "muted"
							text: "Cultures"
						}

						BioTendon {
							anchors.left: chatsHeading.right
							anchors.right: newChatButton.left
							anchors.leftMargin: Bio.s3
							anchors.rightMargin: Bio.s3
							anchors.verticalCenter: parent.verticalCenter
							height: 12
							facing: Qt.LeftToRight
							lineColor: Bio.boneFaint
							visible: width > 24
						}

						BioButton {
							id: newChatButton
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							implicitHeight: 24
							text: "Inoculate"
							onClicked: root.startNewChat()
						}
					}

					Item {
						width: parent.width
						height: parent.height - 34 - (aiPanelError.visible ? aiPanelError.implicitHeight + 10 : 0)

						ListView {
							id: pastChatList
							anchors.fill: parent
							clip: true
							spacing: 4
							model: root.filteredAiChats
							boundsBehavior: Flickable.StopAtBounds

							delegate: BioRow {
								id: pastChatRow

								required property var modelData
								required property int index
								readonly property bool active: String(pastChatRow.modelData.id || "") === root.activeChatId

								width: pastChatList.width
								implicitHeight: 46
								inset: Bio.s3
								selected: pastChatRow.active
								onClicked: root.openPastChat(pastChatRow.modelData)

								Column {
									anchors.left: parent.left
									anchors.right: deleteChatButton.left
									anchors.rightMargin: Bio.s3
									anchors.verticalCenter: parent.verticalCenter
									spacing: -1

									BioText {
										width: parent.width
										role: "bodyStrong"
										tone: pastChatRow.active ? "organ" : "default"
										text: pastChatRow.modelData.title || "Untitled culture"
									}

									BioText {
										width: parent.width
										role: "caption"
										tone: "faint"
										text: `${pastChatRow.modelData.model || "Unknown strain"} · ${root.formatChatTime(pastChatRow.modelData.updatedAt)}`
									}
								}

								Item {
									id: deleteChatButton
									anchors.right: parent.right
									anchors.verticalCenter: parent.verticalCenter
									width: 22
									height: 22
									z: 2
									opacity: root.aiStreaming && String(pastChatRow.modelData.id || "") === root.aiStreamingChatId ? 0.4 : 1

									BioText {
										anchors.centerIn: parent
										role: "body"
										tone: deleteChatMouse.containsMouse ? "alert" : "faint"
										text: "×"
									}

									BioTouch {
										id: deleteChatMouse
										enabled: !(root.aiStreaming && String(pastChatRow.modelData.id || "") === root.aiStreamingChatId)
										onClicked: root.deleteChat(pastChatRow.modelData)
									}
								}
							}
						}

						Column {
							anchors.centerIn: parent
							spacing: Bio.s3
							visible: root.filteredAiChats.length === 0

							BioSigil {
								anchors.horizontalCenter: parent.horizontalCenter
								width: 48
								height: 48
								seed: 31
								lineColor: Bio.boneGhost
							}

							BioText {
								anchors.horizontalCenter: parent.horizontalCenter
								role: "label"
								tone: "faint"
								text: root.chatsSearchQuery === "" ? "No cultures kept" : "No matches"
							}
						}
					}

					BioText {
						id: aiPanelError
						width: parent.width
						visible: root.aiError !== ""
						role: "caption"
						tone: "alert"
						text: root.aiError
						horizontalAlignment: Text.AlignHCenter
						wrapMode: Text.WordWrap
					}
				}
			}

			Item {
				id: ollamaPanel
				width: parent.width
				height: dish.viewHeight
				visible: root.inOllamaMode

				Row {
					id: ollamaTitleRow
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					height: 26
					spacing: 8

					BioText {
						role: "label"
						tone: "muted"
						width: parent.width - ollamaRefreshButton.width - parent.spacing
						anchors.verticalCenter: parent.verticalCenter
						text: "Strains held"
					}

					BioNode {
						id: ollamaRefreshButton
						anchors.verticalCenter: parent.verticalCenter
						size: 26
						seed: 2
						onClicked: root.refreshOllamaOverview()

						BioText {
							anchors.centerIn: parent
							role: "heading"
							text: "↻"
						}

						MouseArea {
							id: ollamaRefreshMouse
							anchors.fill: parent
							acceptedButtons: Qt.NoButton
							hoverEnabled: true
						}

						ToolTip.visible: ollamaRefreshMouse.containsMouse
						ToolTip.delay: 500
						ToolTip.text: "Refresh models"
					}
				}

				Item {
					id: ollamaPullBox
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: ollamaTitleRow.bottom
					anchors.topMargin: 8
					height: root.ollamaPulling ? 76 : 42

					Behavior on height {
						NumberAnimation {
							duration: ThemeEngine.duration(120)
							easing.type: ThemeEngine.standardEasing
						}
					}

					// A strain to bring in: typed on a bone line, grafted with
					// the verb beside it.
					TextField {
						id: ollamaPullField
						anchors.left: parent.left
						anchors.right: ollamaPullButton.left
						anchors.rightMargin: Bio.s3
						anchors.top: parent.top
						height: 30
						text: root.ollamaPullModel
						font.family: Bio.sans
						font.pixelSize: Bio.sizeCaption
						color: Bio.text
						placeholderText: "Strain to bring in, for example qwen3:4b"
						placeholderTextColor: Bio.textFaint
						selectedTextColor: Bio.text
						selectionColor: Qt.alpha(Bio.organ, 0.3)
						enabled: !root.ollamaPulling
						onTextChanged: root.ollamaPullModel = text
						onAccepted: root.startOllamaPull(text)

						background: Item {
							Rectangle {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								height: Bio.ribThin
								color: Bio.boneFaint
							}

							Rectangle {
								anchors.left: parent.left
								anchors.bottom: parent.bottom
								width: ollamaPullField.activeFocus ? parent.width : 0
								height: Bio.rib
								color: Bio.organ

								Behavior on width {
									NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
								}
							}
						}
					}

					Item {
						id: ollamaPullButton
						anchors.right: parent.right
						anchors.top: parent.top
						width: 62
						height: 30
						opacity: root.ollamaPullModel.trim() !== "" && !root.ollamaPulling ? 1 : 0.45

						BioTouch {
							id: ollamaPullMouse
							enabled: root.ollamaPullModel.trim() !== "" && !root.ollamaPulling
							cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
							onClicked: root.startOllamaPull(root.ollamaPullModel)
						}

						BioText {
							role: "label"
							anchors.centerIn: parent
							tone: ollamaPullMouse.containsMouse ? "organ" : "muted"
							text: "Pull"
							font.pixelSize: 11
							font.weight: Font.DemiBold
						}
					}

					Item {
						anchors.left: parent.left
						anchors.leftMargin: 8
						anchors.right: parent.right
						anchors.rightMargin: 8
						anchors.top: ollamaPullField.bottom
						anchors.topMargin: 6
						height: 26
						visible: root.ollamaPulling

						BioText {
							role: "label"
							anchors.left: parent.left
							anchors.right: ollamaPullDetails.left
							anchors.rightMargin: 8
							anchors.top: parent.top
							color: Qt.alpha(root.foreground, 0.68)
							text: root.ollamaPullStatus
							elide: Text.ElideRight
							font.pixelSize: 9
							font.weight: Font.Medium
						}

						BioText {
							role: "label"
							id: ollamaPullDetails
							anchors.right: parent.right
							anchors.top: parent.top
							color: Qt.alpha(root.foreground, 0.52)
							text: [
								root.ollamaPullTotal > 0 ? `${Math.round(root.ollamaPullProgress * 100)}%` : "",
								root.formatTransferRate(root.ollamaPullSpeed),
								root.formatDuration(root.ollamaPullEtaSeconds) !== ""
									? `${root.formatDuration(root.ollamaPullEtaSeconds)} left`
									: ""
							].filter(value => value !== "").join(" · ")
							font.pixelSize: 9
							font.weight: Font.Medium
						}

						ThemedRectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: 5
							radius: ThemeEngine.radiusMedium
							color: root.secondaryBoxStrongColor

							ThemedRectangle {
								width: parent.width * root.ollamaPullProgress
								height: parent.height
								radius: parent.radius
								color: root.barColor
							}
						}
					}
				}

				ThemedRectangle {
					id: ollamaRunningBox
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: ollamaPullBox.bottom
					anchors.topMargin: 8
					height: 30

					BioText {
						id: ollamaRunningLabel
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						role: "label"
						tone: "muted"
						text: "Awake"
					}

					BioTendon {
						anchors.left: ollamaRunningLabel.right
						anchors.right: ollamaRunningSummary.left
						anchors.leftMargin: Bio.s3
						anchors.rightMargin: Bio.s3
						anchors.verticalCenter: parent.verticalCenter
						height: 12
						facing: Qt.LeftToRight
						lineColor: Bio.boneFaint
						visible: width > 24
					}

					BioText {
						id: ollamaRunningSummary
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						width: Math.min(implicitWidth, parent.width * 0.6)
						horizontalAlignment: Text.AlignRight
						role: "caption"
						tone: "faint"
						text: root.ollamaRunningSummary()
					}
				}

				Item {
					id: ollamaInstalledBox
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: ollamaRunningBox.bottom
					anchors.topMargin: 8
					anchors.bottom: ollamaManagerErrorText.top
					anchors.bottomMargin: ollamaManagerErrorText.visible ? 6 : 0

					BioText {
						anchors.left: parent.left
						anchors.top: parent.top
						role: "label"
						tone: "muted"
						text: `Held · ${root.aiModels.length}`
					}

					ListView {
						id: ollamaInstalledList
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.topMargin: 27
						anchors.bottom: parent.bottom
						anchors.margins: 6
						clip: true
						spacing: 4
						model: root.aiModels
						boundsBehavior: Flickable.StopAtBounds

						delegate: BioRow {
							id: ollamaModelRow

							required property var modelData
							required property int index
							readonly property string modelName: String(modelData?.name || modelData?.model || "")
							readonly property bool running: root.isOllamaModelRunning(modelName)
							readonly property bool removing: root.ollamaRemovingModel === modelName

							width: ollamaInstalledList.width
							implicitHeight: 44
							inset: Bio.s2
							selected: ollamaModelRow.running
							interactive: false

							MouseArea {
								id: ollamaModelMouse
								anchors.fill: parent
								hoverEnabled: true
								acceptedButtons: Qt.NoButton
							}

							Column {
								anchors.left: parent.left
								anchors.right: ollamaModelChatButton.left
								anchors.rightMargin: Bio.s3
								anchors.verticalCenter: parent.verticalCenter
								spacing: -1

								BioText {
									role: "bodyStrong"
									tone: ollamaModelRow.running ? "organ" : "default"
									width: parent.width
									text: ollamaModelRow.modelName
								}

								BioText {
									role: "caption"
									tone: "faint"
									width: parent.width
									text: [
										ollamaModelRow.running ? "Awake" : "",
										String(ollamaModelRow.modelData?.details?.parameter_size || ""),
										String(ollamaModelRow.modelData?.details?.quantization_level || ""),
										root.formatModelSize(ollamaModelRow.modelData?.size)
									].filter(value => value !== "").join(" · ")
									elide: Text.ElideRight
									font.pixelSize: 9
									font.weight: Font.Medium
								}
							}

							BioButton {
								id: ollamaModelChatButton
								anchors.right: ollamaModelRemoveButton.left
								anchors.rightMargin: Bio.s2
								anchors.verticalCenter: parent.verticalCenter
								implicitHeight: 26
								minimumWidth: 70
								enabled: !root.aiStreaming
								text: "Culture"
								onClicked: root.startNewChatWithModel(ollamaModelRow.modelName)

								MouseArea {
									id: ollamaModelChatMouse
									anchors.fill: parent
									acceptedButtons: Qt.NoButton
									hoverEnabled: true
								}
							}

							Item {
								id: ollamaModelRemoveButton
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: 22
								height: 22
								opacity: root.aiStreaming || ollamaRemoveProcess.running ? 0.45 : 1

								BioTouch {
									id: ollamaModelRemoveMouse
									enabled: !root.aiStreaming && !ollamaRemoveProcess.running
									cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
									onClicked: root.removeOllamaModel(ollamaModelRow.modelName)
								}

								BioText {
									anchors.centerIn: parent
									role: "body"
									tone: ollamaModelRemoveMouse.containsMouse ? "alert" : "faint"
									text: ollamaModelRow.removing ? "…" : "×"
								}

								ToolTip.visible: ollamaModelRemoveMouse.containsMouse
								ToolTip.delay: 500
								ToolTip.text: "Remove model"
							}
						}

						ScrollBar.vertical: ScrollBar {
							policy: ScrollBar.AsNeeded
						}
					}

					BioText {
						role: "caption"
						anchors.centerIn: parent
						visible: !root.aiModelsLoading && root.aiModels.length === 0
						color: Qt.alpha(root.foreground, 0.5)
						text: "No models installed"
						font.pixelSize: 11
						font.weight: Font.Medium
					}
				}

				BioText {
					role: "label"
					id: ollamaManagerErrorText
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: visible ? 16 : 0
					visible: root.ollamaManagerError !== ""
						|| (!root.aiModelsLoading && root.aiModels.length === 0 && root.aiError !== "")
					color: root.danger
					text: root.ollamaManagerError !== "" ? root.ollamaManagerError : root.aiError
					horizontalAlignment: Text.AlignHCenter
					elide: Text.ElideRight
					font.pixelSize: 10
					font.weight: Font.Medium
				}
			}

			Item {
				id: chatPanel
				width: parent.width
				height: dish.viewHeight
				visible: root.inChatMode

				Item {
					id: chatHeader
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					height: 34
					z: 2

					Rectangle {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: Bio.ribThin
						color: Bio.boneGhost
					}

					BioNode {
						id: chatBackButton
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						size: 26
						seed: 0
						onClicked: root.openAiOverview()

						BioText {
							anchors.centerIn: parent
							role: "heading"
							text: "←"
						}

						MouseArea {
							id: chatBackMouse
							anchors.fill: parent
							acceptedButtons: Qt.NoButton
							hoverEnabled: true
						}
					}

					BioText {
						anchors.left: chatBackButton.right
						anchors.leftMargin: Bio.s3
						anchors.right: chatControls.left
						anchors.rightMargin: Bio.s3
						anchors.verticalCenter: parent.verticalCenter
						role: "heading"
						font.pixelSize: 13
						text: root.activeChat?.title || (root.aiTemporaryChatEnabled ? "Transient culture" : "New culture")
					}

						Row {
							id: chatControls
						anchors.right: parent.right
						anchors.rightMargin: 6
						anchors.verticalCenter: parent.verticalCenter
						height: 28
							spacing: 8

							ComboBox {
							id: chatModelCombo
							anchors.verticalCenter: parent.verticalCenter
							width: 132
							height: 26
							enabled: !root.aiStreaming && root.aiModels.length > 0
							model: root.aiModels.map(model => String(model.name || model.model || ""))
							currentIndex: Math.max(0, model.indexOf(root.selectedAiModel))
							onActivated: root.selectAiModel(String(currentText))
							leftPadding: 8
							rightPadding: 22

							delegate: ItemDelegate {
								required property int index
								required property var modelData
								width: chatModelCombo.width
								height: 30
								highlighted: chatModelCombo.highlightedIndex === index
								contentItem: Text {
									text: String(modelData)
									color: root.foreground
									font.pixelSize: 10
									font.weight: highlighted ? Font.DemiBold : Font.Medium
									verticalAlignment: Text.AlignVCenter
									elide: Text.ElideRight
								}
								background: ThemedRectangle {
									radius: ThemeEngine.radiusMedium
									color: highlighted ? root.secondaryBoxStrongColor : "transparent"
								}
							}

							indicator: Text {
								x: chatModelCombo.width - width - 7
								y: (chatModelCombo.height - height) / 2
								text: chatModelCombo.popup.visible ? "▴" : "▾"
								color: root.foreground
								font.pixelSize: 9
							}

							contentItem: Text {
								text: chatModelCombo.displayText || "No model"
								color: root.foreground
								font.pixelSize: 10
								font.weight: Font.DemiBold
								verticalAlignment: Text.AlignVCenter
								elide: Text.ElideRight
							}

							background: ThemedRectangle {
								radius: ThemeEngine.radiusMedium
								color: root.secondaryBoxColor
								border.width: chatModelCombo.visualFocus ? 1 : 0
								border.color: Qt.alpha(root.barColor, 0.65)
							}

							popup: Popup {
								y: chatModelCombo.height + 4
								width: chatModelCombo.width
								padding: 4
								background: ThemedRectangle {
									radius: ThemeEngine.radiusMedium
									color: root.background
									border.width: 1
									border.color: Qt.alpha(root.barColor, 0.3)
								}
								contentItem: ListView {
									clip: true
									implicitHeight: Math.min(contentHeight, 220)
									model: chatModelCombo.popup.visible ? chatModelCombo.delegateModel : null
									currentIndex: chatModelCombo.highlightedIndex
									ScrollBar.vertical: ScrollBar {}
								}
							}
						}

						Row {
							anchors.verticalCenter: parent.verticalCenter
							height: parent.height
							spacing: 5
							opacity: root.aiStreaming || !root.selectedAiSupportsThinking ? 0.5 : 1

							BioText {
								role: "label"
								anchors.verticalCenter: parent.verticalCenter
								color: Qt.alpha(root.foreground, 0.68)
								text: "Think"
								font.pixelSize: 10
								font.weight: Font.Medium
							}

							ThemedRectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: 32
								height: 18
								radius: ThemeEngine.radiusMedium
								color: root.effectiveAiThinkingEnabled ? Qt.alpha(root.barColor, 0.72) : root.secondaryBoxStrongColor

								ThemedRectangle {
									width: 12
									height: 12
									radius: width / 2
									x: root.effectiveAiThinkingEnabled ? parent.width - width - 3 : 3
									anchors.verticalCenter: parent.verticalCenter
									color: root.foreground

									Behavior on x {
										NumberAnimation {
											duration: ThemeEngine.duration(120)
											easing.type: ThemeEngine.standardEasing
										}
									}
								}

								MouseArea {
									anchors.fill: parent
									enabled: !root.aiStreaming && root.selectedAiSupportsThinking
									cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
									onClicked: root.toggleAiThinking()
								}
							}
							}

							Row {
								anchors.verticalCenter: parent.verticalCenter
								height: parent.height
								spacing: 5
								opacity: root.aiStreaming ? 0.5 : 1

								BioText {
									role: "label"
									anchors.verticalCenter: parent.verticalCenter
									color: Qt.alpha(root.foreground, 0.68)
									text: "Short"
									font.pixelSize: 10
									font.weight: Font.Medium
								}

								ThemedRectangle {
									anchors.verticalCenter: parent.verticalCenter
									width: 32
									height: 18
									radius: ThemeEngine.radiusMedium
									color: root.aiShortResponseEnabled ? Qt.alpha(root.barColor, 0.72) : root.secondaryBoxStrongColor

									ThemedRectangle {
										width: 12
										height: 12
										radius: width / 2
										x: root.aiShortResponseEnabled ? parent.width - width - 3 : 3
										anchors.verticalCenter: parent.verticalCenter
										color: root.foreground

										Behavior on x {
											NumberAnimation {
												duration: ThemeEngine.duration(120)
												easing.type: ThemeEngine.standardEasing
											}
										}
									}

									MouseArea {
										anchors.fill: parent
										enabled: !root.aiStreaming
										cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
										onClicked: root.toggleShortResponse()
									}
								}
							}

							Row {
								anchors.verticalCenter: parent.verticalCenter
								height: parent.height
								spacing: 5
								opacity: root.aiStreaming ? 0.5 : 1

								BioText {
									role: "label"
									anchors.verticalCenter: parent.verticalCenter
									color: Qt.alpha(root.foreground, 0.68)
									text: "Temporary"
								font.pixelSize: 10
								font.weight: Font.Medium
							}

							ThemedRectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: 32
								height: 18
								radius: ThemeEngine.radiusMedium
								color: root.aiTemporaryChatEnabled ? Qt.alpha(root.barColor, 0.72) : root.secondaryBoxStrongColor

								ThemedRectangle {
									width: 12
									height: 12
									radius: width / 2
									x: root.aiTemporaryChatEnabled ? parent.width - width - 3 : 3
									anchors.verticalCenter: parent.verticalCenter
									color: root.foreground

									Behavior on x {
										NumberAnimation {
											duration: ThemeEngine.duration(120)
											easing.type: ThemeEngine.standardEasing
										}
									}
								}

								MouseArea {
									anchors.fill: parent
									enabled: !root.aiStreaming
									cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
									onClicked: root.toggleTemporaryChat()
								}
							}
						}
					}
				}

				Row {
					id: chatInfoBar
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: chatHeader.bottom
					anchors.topMargin: 6
					height: 20
					spacing: 8

					BioText {
						role: "label"
						anchors.verticalCenter: parent.verticalCenter
						color: Qt.alpha(root.foreground, 0.58)
						text: "Context"
						font.pixelSize: 9
						font.weight: Font.Medium
					}

					ThemedRectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 150
						height: 5
						radius: ThemeEngine.radiusMedium
						color: root.secondaryBoxStrongColor

						ThemedRectangle {
							width: parent.width * root.activeContextProgress
							height: parent.height
							radius: parent.radius
							color: root.activeContextProgress > 0.85 ? root.danger : root.barColor
						}
					}

					BioText {
						role: "label"
						anchors.verticalCenter: parent.verticalCenter
						color: Qt.alpha(root.foreground, 0.58)
						text: `${root.formatTokenCount(root.activeContextUsed)} / ${root.formatTokenCount(root.activeContextLimit)}`
						font.pixelSize: 9
						font.weight: Font.Medium
					}

					BioText {
						role: "label"
						anchors.verticalCenter: parent.verticalCenter
						visible: root.activeResponseTokens > 0
						color: Qt.alpha(root.foreground, 0.58)
						text: `${root.activeTokensPerSecond.toFixed(1)} tok/s · ${root.activeResponseTokens} tokens`
						font.pixelSize: 9
						font.weight: Font.Medium
					}

					BioText {
						role: "label"
						anchors.verticalCenter: parent.verticalCenter
						visible: root.chatLoadedTimerText !== ""
						color: root.chatLoadedModel
							? Qt.alpha(root.foreground, 0.58)
							: Qt.alpha(root.foreground, 0.42)
						text: root.chatLoadedTimerText
						elide: Text.ElideRight
						font.pixelSize: 9
						font.weight: Font.Medium
					}
				}

				Item {
					id: chatBody
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: chatInfoBar.bottom
					anchors.topMargin: 6
					anchors.bottom: pendingAttachmentBar.top
					anchors.bottomMargin: pendingAttachmentBar.visible ? 6 : (chatError.visible ? 6 : 0)

					ListView {
						id: chatList
						anchors.fill: parent
						clip: true
						spacing: 4
						cacheBuffer: 800
						reuseItems: false
						model: chatMessageModel
						boundsBehavior: Flickable.StopAtBounds

						onContentHeightChanged: root.followChatImmediately()
						onMovementStarted: root.chatAutoFollow = false
						onMovementEnded: root.chatAutoFollow = root.chatNearEnd()

						ScrollBar.vertical: ScrollBar {
							policy: ScrollBar.AsNeeded
						}

						delegate: Item {
							id: messageRow

							required property var entry
							required property int index
							readonly property bool fromUser: entry.role === "user"
							readonly property string responseModelName: !fromUser && String(entry.model || "") !== ""
								? String(entry.model)
								: ""
							readonly property bool hasThinking:
								entry.role === "assistant"
								&& Boolean(root.activeChat?.thinkingEnabled)
								&& String(entry.thinking || "") !== ""
							readonly property bool loadingModel:
								entry.role === "assistant"
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

							width: chatList.width
							height: messageBubble.height + 6

								// An utterance is a specimen record: what you said is
								// washed in the organ colour, what answered is bone
								// on tissue, and the two never share an edge.
								BioSurface {
									id: messageBubble
									width: Math.min(
										messageRow.width * 0.78,
										Math.max(
											messageRow.hasMarkdownImages || messageRow.attachments.length > 0 ? messageRow.width * 0.66 : 140,
											Math.max(messageText.implicitWidth, thinkingText.implicitWidth, responseModelLabel.implicitWidth) + 48
										)
								)
								height: messageRow.loadingModel
									? 38
									: messageBubbleBody.implicitHeight + 26
								x: messageRow.fromUser ? messageRow.width - width : 0
								variant: "plate"
								padding: Bio.s4
								haloStrength: messageRow.fromUser ? 0.14 : 0.06
								intensity: messageRow.fromUser ? 0.55 : 0
								lineColor: messageRow.fromUser ? Qt.alpha(Bio.organ, 0.5) : Bio.boneFaint
								washTop: messageRow.fromUser ? Qt.alpha(Bio.organ, 0.12) : Bio.tissue2
								washBottom: messageRow.fromUser ? Bio.membraneDeep : Bio.tissue1

									BioText {
										visible: messageRow.loadingModel
										anchors.centerIn: parent
										width: parent.width
										role: "label"
										tone: "faint"
										text: messageRow.responseModelName !== ""
											? "Waking " + messageRow.responseModelName
											: "Waking strain"
										horizontalAlignment: Text.AlignHCenter
									}

								Column {
									id: messageBubbleBody
									visible: !messageRow.loadingModel
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.top: parent.top
										spacing: Bio.s2

										BioText {
											role: "label"
											id: responseModelLabel
											visible: messageRow.responseModelName !== ""
											width: parent.width
											color: Qt.alpha(root.foreground, 0.55)
											text: messageRow.responseModelName
											elide: Text.ElideRight
											font.pixelSize: 10
											font.weight: Font.DemiBold
										}

										ThemedRectangle {
											id: thinkingHeader
											visible: messageRow.hasThinking
										width: parent.width
										height: 18
										radius: ThemeEngine.radiusSmall
										color: root.secondaryInsetColor

										MouseArea {
											anchors.fill: parent
											enabled: messageRow.hasThinking
											cursorShape: Qt.PointingHandCursor
											onClicked: root.toggleThinkingExpanded(messageRow.entry.id)
										}

										BioText {
											role: "label"
											anchors.left: parent.left
											anchors.leftMargin: 6
											anchors.verticalCenter: parent.verticalCenter
											color: Qt.alpha(root.foreground, 0.55)
											text: messageRow.entry.streaming && String(messageRow.entry.thinking || "") !== ""
												? "Thinking..."
												: (root.thinkingExpanded(messageRow.entry.id) ? "Thinking" : "Thinking hidden")
											font.pixelSize: 10
											font.weight: Font.Medium
										}

										BioText {
											role: "label"
											anchors.right: parent.right
											anchors.rightMargin: 6
											anchors.verticalCenter: parent.verticalCenter
											color: Qt.alpha(root.foreground, 0.45)
											text: root.thinkingExpanded(messageRow.entry.id) ? "▾" : "▸"
											font.pixelSize: 10
											font.weight: Font.DemiBold
											}
										}

										Flow {
											visible: messageRow.attachments.length > 0
											width: parent.width
											height: implicitHeight
											spacing: 5

											Repeater {
												model: messageRow.attachments

												delegate: ThemedRectangle {
													id: sentAttachmentChip

													required property var modelData

													width: Math.min(messageBubbleBody.width, Math.max(112, sentAttachmentName.implicitWidth + 42))
													height: 28
													radius: ThemeEngine.radiusSmall
													color: root.secondaryInsetColor
													opacity: String(modelData.status || "") === "unavailable" ? 0.58 : 1

													Image {
														visible: sentAttachmentChip.modelData.kind === "image"
														anchors.left: parent.left
														anchors.leftMargin: 4
														anchors.verticalCenter: parent.verticalCenter
														width: 20
														height: 20
														source: sentAttachmentChip.modelData.kind === "image"
															? root.resolveMarkdownImageSource(sentAttachmentChip.modelData.path)
															: ""
														fillMode: Image.PreserveAspectCrop
														smooth: true
														cache: true
													}

													QQCImpl.IconImage {
														visible: sentAttachmentChip.modelData.kind !== "image"
														anchors.left: parent.left
														anchors.leftMargin: 6
														anchors.verticalCenter: parent.verticalCenter
														width: 16
														height: 16
														source: root.attachmentIconPath
														sourceSize: Qt.size(width, height)
														color: root.foreground
													}

													BioText {
														role: "label"
														id: sentAttachmentName
														anchors.left: parent.left
														anchors.leftMargin: 30
														anchors.right: parent.right
														anchors.rightMargin: 7
														anchors.verticalCenter: parent.verticalCenter
														color: root.foreground
														text: String(sentAttachmentChip.modelData.name || "Attachment")
														elide: Text.ElideMiddle
														font.pixelSize: 10
														font.weight: Font.Medium
													}

													ToolTip.visible: sentAttachmentHover.containsMouse
													ToolTip.delay: 500
													ToolTip.text: String(sentAttachmentChip.modelData.status || "") === "unavailable"
														? "Attachment content is not available after restart"
														: String(sentAttachmentChip.modelData.name || "Attachment")

													MouseArea {
														id: sentAttachmentHover
														anchors.fill: parent
														hoverEnabled: true
														acceptedButtons: Qt.NoButton
													}
												}
											}
										}

										TextEdit {
											id: thinkingText
										visible: messageRow.hasThinking && root.thinkingExpanded(messageRow.entry.id)
										width: parent.width
										color: Qt.alpha(root.foreground, 0.62)
										text: String(messageRow.entry.thinking || "")
										textFormat: TextEdit.MarkdownText
										baseUrl: Qt.resolvedUrl(".")
										wrapMode: TextEdit.Wrap
										readOnly: true
										selectByMouse: true
										persistentSelection: true
										selectionColor: Qt.alpha(root.barColor, 0.35)
										selectedTextColor: root.foreground
										font.pixelSize: 11
										onLinkActivated: link => Qt.openUrlExternally(link)
										onSelectedTextChanged: root.updateChatSelection(selectedText)

										HoverHandler {
											cursorShape: thinkingText.hoveredLink !== ""
												? Qt.PointingHandCursor
												: Qt.IBeamCursor
										}
									}

									TextEdit {
										id: messageText
										visible: String(messageRow.displayText || "") !== "" && !messageRow.hasMarkdownImages
										width: parent.width
										color: root.foreground
										text: messageRow.hasMarkdownImages ? messageRow.markdownTextOnly : messageRow.displayText
										textFormat: TextEdit.MarkdownText
										baseUrl: Qt.resolvedUrl(".")
										wrapMode: TextEdit.Wrap
										readOnly: true
										selectByMouse: true
										persistentSelection: true
										selectionColor: Qt.alpha(root.barColor, 0.55)
										selectedTextColor: root.foreground
										font.pixelSize: 12
										onLinkActivated: link => Qt.openUrlExternally(link)
										onSelectedTextChanged: root.updateChatSelection(selectedText)

										HoverHandler {
											cursorShape: messageText.hoveredLink !== ""
												? Qt.PointingHandCursor
												: Qt.IBeamCursor
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
												id: markdownSegment

												required property var modelData

												width: markdownImageContent.width
												height: modelData.kind === "image"
													? markdownImageFrame.height
													: markdownSegmentText.implicitHeight

												TextEdit {
													id: markdownSegmentText
													visible: markdownSegment.modelData.kind === "text"
													width: parent.width
													color: root.foreground
													text: String(markdownSegment.modelData.text || "")
													textFormat: TextEdit.MarkdownText
													baseUrl: Qt.resolvedUrl(".")
													wrapMode: TextEdit.Wrap
													readOnly: true
													selectByMouse: true
													persistentSelection: true
													selectionColor: Qt.alpha(root.barColor, 0.55)
													selectedTextColor: root.foreground
													font.pixelSize: 12
													onLinkActivated: link => Qt.openUrlExternally(link)
													onSelectedTextChanged: root.updateChatSelection(selectedText)

													HoverHandler {
														cursorShape: markdownSegmentText.hoveredLink !== ""
															? Qt.PointingHandCursor
															: Qt.IBeamCursor
													}
												}

												ThemedRectangle {
													id: markdownImageFrame
													visible: markdownSegment.modelData.kind === "image"
													width: parent.width
													height: !visible
														? 0
														: (markdownImage.status === Image.Ready && markdownImage.sourceSize.width > 0
															? Math.min(280, Math.max(80, width * markdownImage.sourceSize.height / markdownImage.sourceSize.width))
															: (markdownImage.status === Image.Error ? 64 : 96))
													radius: ThemeEngine.radiusSmall
													color: root.secondaryInsetColor
													clip: true

													Image {
														id: markdownImage
														anchors.fill: parent
														anchors.margins: 4
														source: root.resolveMarkdownImageSource(markdownSegment.modelData.source)
														fillMode: Image.PreserveAspectFit
														asynchronous: true
														cache: true
														smooth: true
														mipmap: true
													}

													BioText {
														role: "caption"
														anchors.centerIn: parent
														width: parent.width - 20
														visible: markdownImage.status === Image.Loading
														color: Qt.alpha(root.foreground, 0.5)
														text: "Loading image..."
														horizontalAlignment: Text.AlignHCenter
														font.pixelSize: 11
													}

													BioText {
														role: "caption"
														anchors.centerIn: parent
														width: parent.width - 20
														visible: markdownImage.status === Image.Error
														color: Qt.alpha(root.foreground, 0.58)
														text: String(markdownSegment.modelData.alt || "Image could not be loaded")
														horizontalAlignment: Text.AlignHCenter
														elide: Text.ElideRight
														font.pixelSize: 11
													}

													MouseArea {
														anchors.fill: parent
														hoverEnabled: true
														cursorShape: Qt.PointingHandCursor
														onClicked: Qt.openUrlExternally(root.resolveMarkdownImageSource(markdownSegment.modelData.source))
													}
												}
											}
										}
									}
								}
							}

							ThemedRectangle {
								id: editMessageButton
								x: messageBubble.x - width - 6
								anchors.verticalCenter: messageBubble.verticalCenter
								width: 24
								height: 24
								radius: ThemeEngine.radiusMedium
								visible: messageRow.fromUser
								opacity: root.aiStreaming ? 0.45 : 1
								color: editMessageMouse.containsMouse ? root.secondaryBoxStrongColor : "transparent"

								MouseArea {
									id: editMessageMouse
									anchors.fill: parent
									enabled: !root.aiStreaming
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: root.beginEditMessage(messageRow.entry)
								}

								BioText {
									role: "title"
									anchors.centerIn: parent
									color: root.foreground
									text: "✎"
									font.pixelSize: 16
									font.weight: Font.DemiBold
								}
							}
						}
					}

					BioText {
						role: "body"
						anchors.centerIn: parent
						width: parent.width - 40
						visible: root.activeMessages.length === 0
						color: Qt.alpha(root.foreground, 0.5)
						text: root.selectedAiModel === ""
							? "Type >chat to start a new chat"
							: "Type >chat followed by a message"
						horizontalAlignment: Text.AlignHCenter
						wrapMode: Text.WordWrap
						font.pixelSize: 13
						font.weight: Font.Medium
					}
				}

				ThemedRectangle {
					id: pendingAttachmentBar
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: chatError.top
					anchors.bottomMargin: chatError.visible ? 5 : 0
					height: visible ? 38 : 0
					visible: root.aiPendingAttachments.length > 0
					radius: ThemeEngine.radiusMedium
					color: root.secondaryInsetColor

					ListView {
						anchors.fill: parent
						anchors.margins: 5
						orientation: ListView.Horizontal
						spacing: 5
						clip: true
						model: root.aiPendingAttachments
						boundsBehavior: Flickable.StopAtBounds

						delegate: ThemedRectangle {
							id: pendingAttachmentChip

							required property var modelData

							width: 148
							height: 28
							radius: ThemeEngine.radiusSmall
							color: root.secondaryBoxColor
							border.width: String(modelData.status || "") === "loading" ? 1 : 0
							border.color: Qt.alpha(root.barColor, 0.55)
							opacity: pendingAttachmentChip.modelData.kind === "image" && !root.selectedAiSupportsVision ? 0.48 : 1

							Image {
								visible: pendingAttachmentChip.modelData.kind === "image"
								anchors.left: parent.left
								anchors.leftMargin: 4
								anchors.verticalCenter: parent.verticalCenter
								width: 20
								height: 20
								source: pendingAttachmentChip.modelData.kind === "image"
									? root.resolveMarkdownImageSource(pendingAttachmentChip.modelData.path)
									: ""
								fillMode: Image.PreserveAspectCrop
								smooth: true
								cache: true
							}

							QQCImpl.IconImage {
								visible: pendingAttachmentChip.modelData.kind !== "image"
								anchors.left: parent.left
								anchors.leftMargin: 6
								anchors.verticalCenter: parent.verticalCenter
								width: 16
								height: 16
								source: root.attachmentIconPath
								sourceSize: Qt.size(width, height)
								color: root.foreground
							}

							BioText {
								role: "label"
								anchors.left: parent.left
								anchors.leftMargin: 29
								anchors.right: pendingAttachmentRemove.left
								anchors.rightMargin: 4
								anchors.verticalCenter: parent.verticalCenter
								color: root.foreground
								text: String(pendingAttachmentChip.modelData.status || "") === "loading"
									? `Reading ${pendingAttachmentChip.modelData.name || "file"}...`
									: String(pendingAttachmentChip.modelData.name || "Attachment")
								elide: Text.ElideMiddle
								font.pixelSize: 10
								font.weight: Font.Medium
							}

							ThemedRectangle {
								id: pendingAttachmentRemove
								anchors.right: parent.right
								anchors.rightMargin: 3
								anchors.verticalCenter: parent.verticalCenter
								width: 21
								height: 21
								radius: ThemeEngine.radiusSmall
								color: pendingAttachmentRemoveMouse.containsMouse ? root.secondaryBoxStrongColor : "transparent"

								MouseArea {
									id: pendingAttachmentRemoveMouse
									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: root.removePendingAttachment(pendingAttachmentChip.modelData.id)
								}

								BioText {
									role: "caption"
									anchors.centerIn: parent
									color: root.foreground
									text: "x"
									font.pixelSize: 11
									font.weight: Font.DemiBold
								}
							}
						}
					}
				}

				BioText {
					role: "caption"
					id: chatError
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: visible ? 18 : 0
					visible: root.aiError !== ""
					color: root.danger
					text: root.aiError
					horizontalAlignment: Text.AlignHCenter
					elide: Text.ElideRight
					font.pixelSize: 11
					font.weight: Font.Medium
				}
			}

		}
	}

	ThemedRectangle {
		id: attachmentPicker

		anchors.fill: parent
		z: 100
		visible: root.aiAttachmentPickerOpen
		color: root.background
		radius: ThemeEngine.radiusMedium
		focus: visible

		Keys.onEscapePressed: root.closeAttachmentPicker()

		ThemedRectangle {
			id: attachmentPickerHeader
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 10
			height: 36
			radius: ThemeEngine.radiusMedium
			color: root.secondaryInsetColor

			ThemedRectangle {
				id: attachmentUpButton
				anchors.left: parent.left
				anchors.leftMargin: 5
				anchors.verticalCenter: parent.verticalCenter
				width: 26
				height: 26
				radius: ThemeEngine.radiusMedium
				color: attachmentUpMouse.containsMouse ? root.secondaryBoxStrongColor : "transparent"

				MouseArea {
					id: attachmentUpMouse
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.aiAttachmentDirectory = root.attachmentParentDirectory(root.aiAttachmentDirectory)
				}

				BioText {
					role: "title"
					anchors.centerIn: parent
					color: root.foreground
					text: "↑"
					font.pixelSize: 16
					font.weight: Font.DemiBold
				}
			}

			BioText {
				role: "caption"
				anchors.left: attachmentUpButton.right
				anchors.leftMargin: 7
				anchors.right: attachmentDoneButton.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				color: root.foreground
				text: root.aiAttachmentDirectory
				elide: Text.ElideMiddle
				font.pixelSize: 11
				font.weight: Font.Medium
			}

			ThemedRectangle {
				id: attachmentDoneButton
				anchors.right: parent.right
				anchors.rightMargin: 5
				anchors.verticalCenter: parent.verticalCenter
				width: 54
				height: 26
				radius: ThemeEngine.radiusMedium
				color: attachmentDoneMouse.containsMouse ? root.secondaryBoxStrongColor : root.secondaryBoxColor

				MouseArea {
					id: attachmentDoneMouse
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.closeAttachmentPicker()
				}

				BioText {
					role: "label"
					anchors.centerIn: parent
					color: root.foreground
					text: "Done"
					font.pixelSize: 10
					font.weight: Font.DemiBold
				}
			}
		}

		Row {
			id: attachmentShortcutRow
			anchors.left: parent.left
			anchors.leftMargin: 10
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.top: attachmentPickerHeader.bottom
			anchors.topMargin: 7
			height: 26
			spacing: 6

			Repeater {
				model: [
					{ name: "Home", path: Quickshell.env("HOME") },
					{ name: "Downloads", path: `${Quickshell.env("HOME")}/Downloads` },
					{ name: "Pictures", path: `${Quickshell.env("HOME")}/Pictures` }
				]

				delegate: ThemedRectangle {
					id: attachmentShortcut

					required property var modelData

					width: attachmentShortcutText.implicitWidth + 20
					height: 26
					radius: ThemeEngine.radiusMedium
					color: root.aiAttachmentDirectory === String(modelData.path)
						? root.secondaryBoxStrongColor
						: (attachmentShortcutMouse.containsMouse ? root.secondaryBoxColor : "transparent")

					MouseArea {
						id: attachmentShortcutMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.aiAttachmentDirectory = String(attachmentShortcut.modelData.path)
					}

					BioText {
						role: "label"
						id: attachmentShortcutText
						anchors.centerIn: parent
						color: root.foreground
						text: String(attachmentShortcut.modelData.name)
						font.pixelSize: 10
						font.weight: Font.Medium
					}
				}
			}

			BioText {
				role: "label"
				anchors.verticalCenter: parent.verticalCenter
				width: Math.max(0, parent.width - x)
				color: Qt.alpha(root.foreground, 0.5)
				text: root.selectedAiSupportsVision
					? "Text, documents, PDF, and images"
					: "Text, documents, and PDF · images require a vision model"
				horizontalAlignment: Text.AlignRight
				elide: Text.ElideLeft
				font.pixelSize: 9
				font.weight: Font.Medium
			}
		}

		ListView {
			id: attachmentFileList
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: attachmentShortcutRow.bottom
			anchors.bottom: parent.bottom
			anchors.margins: 10
			anchors.topMargin: 7
			clip: true
			spacing: 4
			focus: root.aiAttachmentPickerOpen
			model: root.aiAttachmentEntries
			currentIndex: root.aiAttachmentEntries.length > 0 ? 0 : -1
			boundsBehavior: Flickable.StopAtBounds

			Keys.onEscapePressed: root.closeAttachmentPicker()
			Keys.onReturnPressed: root.openAttachmentEntry(currentItem?.modelData)
			Keys.onEnterPressed: root.openAttachmentEntry(currentItem?.modelData)

			delegate: ThemedRectangle {
				id: attachmentFileRow

				required property var modelData
				required property int index
				readonly property var file: modelData || ({})
				readonly property bool supported: Boolean(file.isDir) || root.attachmentSupported(file)
				readonly property bool selected: root.isAttachmentSelected(file.path)

				width: attachmentFileList.width
				height: 42
				radius: ThemeEngine.radiusMedium
				color: attachmentFileList.currentIndex === index
					? root.secondaryBoxStrongColor
					: (attachmentFileMouse.containsMouse ? root.secondaryBoxColor : "transparent")
				opacity: supported ? 1 : 0.4

				MouseArea {
					id: attachmentFileMouse
					anchors.fill: parent
					enabled: attachmentFileRow.file.isDir
						|| (attachmentFileRow.supported && root.aiAttachmentLoadingId === "")
					hoverEnabled: true
					cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
					onEntered: attachmentFileList.currentIndex = attachmentFileRow.index
					onClicked: root.openAttachmentEntry(attachmentFileRow.file)
				}

				Image {
					visible: Boolean(attachmentFileRow.file.isImage)
					anchors.left: parent.left
					anchors.leftMargin: 7
					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28
					source: attachmentFileRow.file.isImage
						? root.resolveMarkdownImageSource(attachmentFileRow.file.path)
						: ""
					fillMode: Image.PreserveAspectCrop
					smooth: true
					cache: true
					asynchronous: true
				}

				QQCImpl.IconImage {
					visible: !attachmentFileRow.file.isImage
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					width: 20
					height: 20
					source: attachmentFileRow.file.isDir ? root.folderIconPath : root.attachmentIconPath
					sourceSize: Qt.size(width, height)
					color: root.foreground
				}

				Column {
					anchors.left: parent.left
					anchors.leftMargin: 44
					anchors.right: attachmentFileState.left
					anchors.rightMargin: 8
					anchors.verticalCenter: parent.verticalCenter
					spacing: 1

					BioText {
						role: "caption"
						width: parent.width
						color: root.foreground
						text: String(attachmentFileRow.file.name || "")
						elide: Text.ElideMiddle
						font.pixelSize: 11
						font.weight: Font.Medium
					}

					BioText {
						role: "label"
						width: parent.width
						color: Qt.alpha(root.foreground, 0.5)
						text: attachmentFileRow.file.isDir
							? "Folder"
							: (attachmentFileRow.supported
								? `${attachmentFileRow.file.mimeType || root.attachmentKind(attachmentFileRow.file)} · ${root.formatAttachmentSize(attachmentFileRow.file.size)}`
								: (attachmentFileRow.file.isImage ? "Requires a vision model" : "Unsupported file"))
						elide: Text.ElideRight
						font.pixelSize: 9
					}
				}

				BioText {
					role: "title"
					id: attachmentFileState
					anchors.right: parent.right
					anchors.rightMargin: 12
					anchors.verticalCenter: parent.verticalCenter
					color: root.foreground
					text: attachmentFileRow.file.isDir
						? "›"
						: (attachmentFileRow.selected ? "✓" : (attachmentFileRow.supported ? "+" : ""))
					font.pixelSize: 16
					font.weight: Font.DemiBold
				}
			}

			ScrollBar.vertical: ScrollBar {
				policy: ScrollBar.AsNeeded
			}
		}

		BioText {
			role: "body"
			anchors.centerIn: attachmentFileList
			visible: attachmentFileList.count === 0
			color: Qt.alpha(root.foreground, 0.5)
			text: root.aiAttachmentDirectoryLoading
				? "Loading..."
				: (root.aiAttachmentDirectoryError !== "" ? root.aiAttachmentDirectoryError : "This folder is empty")
			font.pixelSize: 12
			font.weight: Font.Medium
		}
	}
}
