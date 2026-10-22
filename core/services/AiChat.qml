pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The launcher's AI chat (>chat, >chats) and its Ollama models (>ollama):
// the chats and what is kept of them, the models and which of them run,
// pulling and removing models, files and the selection attached to a
// prompt, and the answer as it streams in. The launcher shows it; what the
// view has to do (scroll, put text in the search, show a message anew) is
// asked for through the signals.
//
// Nothing is asked of Ollama and the chats are not read until a chat view
// is first opened (wake()).
Singleton {
	id: root

	// the launcher shows a chat now (set by the view)
	property bool chatOpen: false
	// the view's text is being selected: it is left as it is meanwhile
	property bool selecting: false
	// the models and chats were asked for
	property bool awake: false

	signal searchRequested(string text)
	signal messagesReplaced
	signal messageUpdated(int index, var message)
	signal scrollRequested(bool force)
	signal followRequested
	signal pickerClosed

	onChatOpenChanged: if (root.chatOpen) root.wake()

	onSelectedAiModelChanged: {
		root.aiModelInfo = ({});
		root.aiModelCapabilities = [];
		root.aiModelContextWindow = 0;
		root.refreshAiModelInfo();
	}

	function wake() {
		if (root.awake) return;
		root.awake = true;
		root.refreshAiModels();
		ollamaVersionProcess.running = true;
	}

	function refreshVersion() {
		ollamaVersionProcess.running = true;
	}

	readonly property string aiStateFilePath: Paths.stateFile("launcher-ai-state.json")

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
	property string aiAttachmentLoadingId: ""
	property string aiAttachmentReadOutput: ""
	property string aiAttachmentReadError: ""
	property bool aiPrimarySelectionLoading: false
	property string aiPrimarySelectionOutput: ""
	property string aiPrimarySelectionError: ""
	property string aiPrimarySelectionMode: ""
	property string aiLastPrimarySelectionContent: ""
	property string aiRequestPayload: ""
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
		if (!root.chatOpen || root.aiStreaming || root.editingMessageId !== "") return;
		root.readPrimarySelection("chat");
	}
	function primePrimarySelection() {
		if (root.chatOpen || root.aiStreaming || primarySelectionProcess.running) return;
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
		if (!root.chatOpen || root.aiStreaming || root.editingMessageId !== "") return;
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
		return Format.bytes(bytes, "");
	}
	function formatTransferRate(bytesPerSecond) {
		return Format.rate(bytesPerSecond, "");
	}
	function formatDuration(seconds) {
		const value = Math.ceil(Number(seconds || 0));
		return value > 0 ? Format.duration(value, true) : "";
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
	function startNewChat() {
		if (root.aiStreaming) return;
		const wasInChatMode = root.chatOpen;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.pickerClosed();
		root.aiTemporaryChatEnabled = true;
		root.aiTemporaryChat = null;
		root.activeChatId = "";
		root.aiError = "";
		root.searchRequested(">chat ");
		root.messagesReplaced();
		if (wasInChatMode) Qt.callLater(root.capturePrimarySelection);
	}
	function openPastChat(chat) {
		if (!chat) return;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.pickerClosed();
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
		root.searchRequested(">chat ");
		root.messagesReplaced();
		Qt.callLater(function() {
			root.messagesReplaced();
			root.scrollRequested(true);
		});
	}
	function toggleTemporaryChat() {
		if (root.aiStreaming) return;
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.aiTemporaryChatEnabled = !root.aiTemporaryChatEnabled;
		if (!root.aiTemporaryChatEnabled) root.aiTemporaryChat = null;
		root.activeChatId = "";
		root.aiError = "";
		root.messagesReplaced();
		root.scrollRequested(true);
	}
	function deleteChat(chat) {
		if (!chat) return;
		const chatId = String(chat.id || "");
		if (chatId === "") return;
		if (root.aiStreaming && chatId === root.aiStreamingChatId) return;
		root.aiChats = root.aiChats.filter(item => String(item.id || "") !== chatId);
		if (root.activeChatId === chatId) {
			root.activeChatId = "";
			root.messagesReplaced();
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
		root.pickerClosed();
		root.followRequested();
		if (!temporary) root.saveAiState();
		root.searchRequested(">chat ");
		root.messagesReplaced();
		root.scrollRequested(true);
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
		root.searchRequested(`>chat ${String(message.content || "")}`);
	}
	function cancelMessageEdit() {
		root.editingMessageId = "";
		root.clearPendingAttachments();
		root.searchRequested(">chat ");
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
		root.messageUpdated(lastIndex, assistant);
	}
	function finishAiStream(errorMessage, cancelled) {
		const temporary = root.aiStreamingTemporary;
		const index = temporary ? -1 : root.findChatIndex(root.aiStreamingChatId);
		const shouldScroll = root.streamingChatMatchesView();
		const preserveSelection = root.selecting;
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
					root.messageUpdated(lastIndex, assistant);
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
		if (shouldScroll && !preserveSelection && wasCancelled) root.messagesReplaced();
		if (shouldScroll && !preserveSelection) root.scrollRequested();
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
		running: root.chatOpen || root.aiStreaming
		triggeredOnStart: true
		onTriggered: {
			root.modelLoadedNow = Date.now();
			if (root.modelLoadedNow - root.ollamaRunningLastRefresh > 5000)
				root.refreshOllamaRunningModels();
		}
	}
	FileView {
		id: aiStateFile
		path: root.awake ? root.aiStateFilePath : ""
		printErrors: false
		onLoaded: root.parseAiState(text())
		onLoadFailed: {
			root.aiStateLoaded = true;
			root.ensureSelectedAiModel();
			root.saveAiState();
		}
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

	Component.onCompleted: Qt.callLater(root.primePrimarySelection)
}
