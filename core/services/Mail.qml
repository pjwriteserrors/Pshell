pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// Mail as chats (scripts/messages/daemon.py). A chat is a conversation: a
// mail and everything that answers it; who it is with decides whether it is
// a chat or a group. The daemon keeps the mailboxes in step – Outlook through
// Microsoft Graph with the calendar's sign-in, Gmail and any other mailbox
// through IMAP – and carries out what is done here.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("messages") && Plugins.on("mail")
	readonly property bool notifies: Plugins.on("mail-notifications")
	readonly property bool running: daemon.running

	// [{ id, kind, address, name, signature, state, error, autoReply }]
	// state: "connecting" | "syncing" | "ok" | "error" | "signedOut"
	property var accounts: []
	property bool known: false
	// [{ id, account, subject, people: [{ name, email }], group, date, preview, sender, mine, unread, count, flagged, attachments }]
	property var chats: []
	// [{ email, name, chats, unread }]
	property var people: []
	property int unread: 0
	// { email: path } of the pictures that are known
	property var avatars: ({})
	readonly property bool syncing: root.accounts.some(account => account.state === "syncing" || account.state === "connecting")

	// the chat that is looked at
	property string openId: ""
	readonly property var openChat: root.chats.find(chat => chat.id === root.openId) ?? null
	property var messages: []
	// { email: what their automatic reply says }
	property var tips: ({})
	property bool loading: false

	// what the mailbox itself found for a search: chat ids, or null
	property var hits: null
	property string searched: ""
	property bool searching: false
	property bool loadingOlder: false

	// Microsoft's device code sign-in
	property string loginCode: ""
	property string loginUrl: ""
	property string loginError: ""

	property int request: 0
	property bool sending: false
	property bool adding: false
	property string accountError: ""

	signal sent(int request, bool ok, string error)
	signal accountAdded(string id)
	// what the account's last sent mails end with; `rich` when it has a layout of its own
	// rich: { rich, page } – what Qt draws of it, and its picture
	signal signatureFound(string account, string text, var rich)

	function command(name, fields) {
		if (!daemon.running) return;
		daemon.write(JSON.stringify(Object.assign({ cmd: name }, fields || {})) + "\n");
	}

	function account(id) {
		return root.accounts.find(account => account.id === id) ?? null;
	}

	// ── chats ────────────────────────────────────────────────────────────
	function open(id) {
		if (root.openId !== id) {
			root.messages = [];
			root.tips = {};
		}
		root.openId = id;
		root.loading = true;
		root.command("open", { chat: id, read: true });
	}

	function close() {
		root.openId = "";
		root.messages = [];
		root.tips = {};
	}

	// from a notification or a command: the panel with the chat in it
	function show(id) {
		root.open(id);
		Popups.withFocusedScreen(screen => Popups.open("messages", screen));
	}

	function setRead(id, value) {
		root.command("read", { chat: id, value: value });
	}

	function setFlag(id, value) {
		root.command("flag", { chat: id, value: value });
	}

	function archive(id) {
		if (root.openId === id) root.close();
		root.command("archive", { chat: id });
	}

	function remove(id) {
		if (root.openId === id) root.close();
		root.command("delete", { chat: id });
	}

	function removeMessage(id) {
		root.command("deleteMessage", { chat: root.openId, id: id });
	}

	// draft: { account, mode, reply, to, cc, bcc, subject, text, files }
	function send(draft) {
		root.request += 1;
		root.sending = true;
		root.command("send", Object.assign({ req: root.request }, draft));
		return root.request;
	}

	function openAttachment(message, attachment) {
		root.command("attachment", { chat: root.openId, message: message, attachment: attachment, action: "open" });
	}

	function saveAttachment(message, attachment) {
		root.command("attachment", { chat: root.openId, message: message, attachment: attachment, action: "save" });
	}

	// the mail as its sender laid it out, as a picture
	function draw(message) {
		root.command("draw", { chat: root.openId, message: message });
	}

	function original(message) {
		root.command("original", { chat: root.openId, message: message });
	}

	function search(query) {
		const text = String(query || "").trim();
		root.searched = text;
		root.hits = null;
		root.searching = text !== "";
		if (text !== "") root.command("search", { query: text });
	}

	function older() {
		if (root.loadingOlder) return;
		root.loadingOlder = true;
		root.command("older");
	}

	function refresh() {
		root.command("refresh");
	}

	// ── accounts ─────────────────────────────────────────────────────────
	function addAccount(fields) {
		root.accountError = "";
		root.adding = true;
		root.command("addAccount", fields);
	}

	function removeAccount(id) {
		if (root.openId.startsWith(id + "|")) root.close();
		root.command("removeAccount", { id: id });
	}

	function cancelSignIn() {
		root.command("cancelLogin");
		root.loginCode = "";
		root.adding = false;
	}

	// the code goes to the clipboard, the browser to the sign-in page
	function openSignInPage() {
		Quickshell.execDetached(["wl-copy", "--", root.loginCode]);
		Quickshell.execDetached(["xdg-open", root.loginUrl]);
	}

	// rich: "found" keeps the layout suggestSignature came back with, "none" drops it, "" leaves it
	function setSignature(id, text, rich) {
		root.command("signature", { account: id, text: text, rich: rich ?? "" });
	}

	function suggestSignature(id) {
		root.command("suggestSignature", { account: id });
	}

	function setAutoReply(id, enabled, text) {
		root.command("autoReply", { account: id, enabled: enabled, text: text });
	}

	function loadSettings() {
		root.command("settings");
	}

	// ── what the daemon says ─────────────────────────────────────────────
	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "accounts":
			root.accounts = data.accounts ?? [];
			root.known = true;
			break;
		case "chats":
			root.chats = data.chats ?? [];
			root.people = data.people ?? [];
			root.unread = data.unread ?? 0;
			break;
		case "chat":
			if (data.id !== root.openId) break;
			root.messages = data.messages ?? [];
			if (data.tips !== undefined) {
				root.tips = data.tips;
				root.loading = false;
			}
			break;
		case "avatars":
			root.avatars = Object.assign({}, root.avatars, data.avatars);
			break;
		case "incoming":
			root.arrived(data);
			break;
		case "sent":
			root.sending = false;
			root.sent(data.req ?? 0, data.ok === true, data.error ?? "");
			break;
		case "search":
			if (data.query !== root.searched) break;
			root.hits = (root.hits ?? []).concat(data.chats ?? []);
			root.searching = false;
			break;
		case "older":
			root.loadingOlder = false;
			break;
		case "login":
			if (data.code) {
				root.loginCode = data.code;
				root.loginUrl = data.url;
				root.loginError = "";
			} else {
				root.loginCode = "";
				root.loginError = data.error ?? "";
				if (!data.done) root.adding = false;
			}
			break;
		case "added":
			root.adding = false;
			root.accountAdded(data.id);
			break;
		case "signature":
			root.signatureFound(data.account, data.text ?? "", data.rich ?? { rich: "", page: null });
			break;
		case "saved":
			Notifs.pushInternal("success", String(data.path).split("/").pop(), "Downloads", {
				icon: "download",
				actions: [{ label: "Open", icon: "open_in_new", run: () => Quickshell.execDetached(["xdg-open", data.path]) }]
			});
			break;
		case "error":
			root.loading = false;
			if (data.where === "account") {
				root.adding = false;
				root.accountError = data.text ?? "";
			} else {
				Notifs.pushInternal("error", "Mail", data.text ?? "", { icon: "email_outline" });
			}
			break;
		}
	}

	function arrived(mail) {
		if (!root.notifies || Notifs.dnd) return;
		// the chat on the screen shows it already
		if (Popups.current === "messages" && root.openId === mail.chat) return;
		Notifs.pushInternal("running", mail.name, mail.preview ? `${mail.subject}\n${mail.preview}` : mail.subject, {
			icon: "email_outline",
			image: root.avatars[mail.email] ?? "",
			duration: 9000,
			actions: [{ label: "Open", icon: "forum", run: () => root.show(mail.chat) }]
		});
	}

	// mails drawn as they were laid out wear the shell's colours
	function dress() {
		// … at the sharpness of the sharpest screen
		const scale = Quickshell.screens.reduce((most, screen) => Math.max(most, screen.devicePixelRatio || 1), 1);
		root.command("theme", { bg: String(Theme.bg), fg: String(Theme.fg), primary: String(Theme.primary), scale: scale });
	}

	Connections {
		target: Theme
		function onBgChanged() {
			palette.restart();
		}
		function onFgChanged() {
			palette.restart();
		}
		function onPrimaryChanged() {
			palette.restart();
		}
	}

	// a new palette arrives colour by colour
	Timer {
		id: palette

		interval: 400
		onTriggered: root.dress()
	}

	onEnabledChanged: if (!root.enabled) {
		root.chats = [];
		root.people = [];
		root.unread = 0;
		root.close();
	}

	Process {
		id: daemon

		running: root.enabled
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/messages/daemon.py`]
		onStarted: root.dress()
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: {
			root.sending = false;
			root.loading = false;
			if (root.enabled) revive.restart();
		}
	}

	// a daemon that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
