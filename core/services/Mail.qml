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

	// [{ id, kind, address, name, own: [address], signature, state, error, autoReply }]
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
	// what is wrong with the mailbox, in a few words, or ""
	readonly property string trouble: {
		if (!root.enabled || !root.known) return "";
		const broken = root.accounts.find(account => account.state === "error" || account.state === "signedOut");
		if (!broken) return "";
		return broken.state === "signedOut" ? `${broken.address}: signed out` : (broken.error || `${broken.address}: not reachable`);
	}

	// What is being written, by chat ("new" for a new one), kept across restarts:
	// { html, files } and for a new chat { to, cc, bcc, subject } as well
	property var drafts: ({})

	// Mails on their way. One waits a few seconds first, so it can be taken back;
	// one that could not be sent stays until it is sent again or taken back.
	// [{ id, key, draft, written, text, state: "waiting" | "sending" | "sent" | "failed", error, at, req, mine }]
	property var outbox: []
	readonly property int grace: 8000
	readonly property bool sending: root.outbox.some(entry => entry.state === "sending")
	// ticks while something waits
	property real now: Date.now()

	// Chats put away until later: { id: when they come back, in ms }
	property var snoozed: ({})

	// a mail was taken back: what was written is in drafts[key] again
	signal undone(string key)
	// a mail came in (before the question whether to show it here)
	signal incoming(var mail)
	// an attachment's file, asked for with attachmentPath()
	signal fileReady(int request, string path)
	property bool adding: false
	property string accountError: ""

	// mail: { to, cc, bcc: [{ name, email }], subject, page } – or { error }
	signal previewed(int request, bool ok, var mail)
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
		root.command("close");
	}

	// whether the address is one of the account's own
	function own(id, email) {
		const account = root.account(id);
		return account !== null && (account.address === email || (account.own ?? []).includes(email));
	}

	function nameOf(email) {
		return root.people.find(person => person.email === email)?.name ?? email;
	}

	// from a notification or a command: the panel with the chat in it
	function show(id) {
		root.open(id);
		Messages.open("chat");
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

	// the draft as it would reach who it goes to, drawn and unsent; answered by previewed()
	function preview(draft) {
		root.request += 1;
		root.command("preview", Object.assign({ req: root.request }, draft));
		return root.request;
	}

	// ── drafts ───────────────────────────────────────────────────────────
	function keep(key, written) {
		const next = Object.assign({}, root.drafts);
		if (written) next[key] = written;
		else if (next[key] === undefined) return;
		else delete next[key];
		root.drafts = next;
		save.restart();
	}

	// ── outbox ───────────────────────────────────────────────────────────
	// draft: { account, mode, reply, to, cc, bcc, subject, text, html, files }
	// key: the chat it is written in, or "new"; written: what the field held; text: how it begins
	function post(key, draft, written, text) {
		const id = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
		const mine = key === root.openId ? root.messages.filter(message => message.mine).length : -1;
		root.outbox = root.outbox.concat([{ id: id, key: key, draft: draft, written: written, text: text, state: "waiting", error: "", at: Date.now(), req: 0, mine: mine }]);
		root.keep(key, null);
		root.now = Date.now();
		save.restart();
		return id;
	}

	function change(id, changes) {
		root.outbox = root.outbox.map(entry => entry.id === id ? Object.assign({}, entry, changes) : entry);
		save.restart();
	}

	function forget(id) {
		root.outbox = root.outbox.filter(entry => entry.id !== id);
		save.restart();
	}

	// now, without waiting any longer; also: once more
	function dispatch(id) {
		const entry = root.outbox.find(entry => entry.id === id);
		if (!entry || entry.state === "sending" || entry.state === "sent") return;
		if (!daemon.running) {
			root.change(id, { state: "failed", error: "Mail is not running" });
			return;
		}
		root.request += 1;
		root.change(id, { state: "sending", error: "", req: root.request });
		root.command("send", Object.assign({ req: root.request }, entry.draft));
	}

	// taken back: it is a draft again
	function undo(id) {
		const entry = root.outbox.find(entry => entry.id === id);
		if (!entry || entry.state === "sending" || entry.state === "sent") return;
		root.forget(id);
		root.keep(entry.key, entry.written);
		root.undone(entry.key);
	}

	function delivered(request, ok, error) {
		const entry = root.outbox.find(entry => entry.req === request && entry.state === "sending");
		if (!entry) return;
		if (!ok) root.change(entry.id, { state: "failed", error: error || "Not sent" });
		// in its chat it stays until the mailbox shows it
		else if (entry.key === root.openId && entry.mine >= 0) root.change(entry.id, { state: "sent", at: Date.now() });
		else root.forget(entry.id);
	}

	// ── later ────────────────────────────────────────────────────────────
	function snooze(id, until) {
		const next = Object.assign({}, root.snoozed);
		next[id] = until;
		root.snoozed = next;
		save.restart();
		if (root.openId === id) root.close();
	}

	// back among the chats; `unread`: as something new
	function wake(id, unread) {
		if (root.snoozed[id] === undefined) return;
		const next = Object.assign({}, root.snoozed);
		delete next[id];
		root.snoozed = next;
		save.restart();
		if (unread && root.chats.some(chat => chat.id === id)) root.setRead(id, false);
	}

	function store() {
		kept.setText(JSON.stringify({
			drafts: root.drafts,
			outbox: root.outbox.filter(entry => entry.state !== "sent"),
			snoozed: root.snoozed
		}, null, "\t") + "\n");
	}

	function openAttachment(message, attachment) {
		root.command("attachment", { chat: root.openId, message: message, attachment: attachment, action: "open" });
	}

	function saveAttachment(message, attachment) {
		root.command("attachment", { chat: root.openId, message: message, attachment: attachment, action: "save" });
	}

	// where the attachment lies on disk; the answer comes as fileReady(request, path)
	function attachmentPath(chat, message, attachment, request) {
		root.command("attachment", { chat: chat, message: message, attachment: attachment, action: "path", req: request });
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
			// what was sent from here has arrived in its chat
			const own = root.messages.filter(message => message.mine).length;
			if (root.outbox.some(entry => entry.state === "sent" && entry.key === data.id && own > entry.mine))
				root.outbox = root.outbox.filter(entry => !(entry.state === "sent" && entry.key === data.id && own > entry.mine));
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
			root.delivered(data.req ?? 0, data.ok === true, data.error ?? "");
			break;
		case "preview":
			root.previewed(data.req ?? 0, data.ok === true, data.ok === true ? data : { error: data.error ?? "" });
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
		case "file":
			root.fileReady(Number(data.req) || 0, String(data.path || ""));
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
		root.incoming(mail);
		// an answer brings a chat back at once
		root.wake(mail.chat, false);
		if (!root.notifies || Notifs.dnd) return;
		// the chat on the screen shows it already
		if (Messages.shown && root.openId === mail.chat) return;
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

		interval: 1500
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
			root.outbox = root.outbox.map(entry => entry.state === "sending" ? Object.assign({}, entry, { state: "failed", error: "Not sent" }) : entry);
			root.loading = false;
			if (root.enabled) revive.restart();
		}
	}

	// what waits is sent when its time is up, what was sent leaves after a while
	Timer {
		interval: 200
		repeat: true
		running: root.outbox.some(entry => entry.state === "waiting" || entry.state === "sent")
		onTriggered: {
			root.now = Date.now();
			for (const entry of root.outbox) {
				if (entry.state === "waiting" && root.now - entry.at >= root.grace) root.dispatch(entry.id);
				else if (entry.state === "sent" && root.now - entry.at > 30000) root.forget(entry.id);
			}
		}
	}

	// chats put away come back as unread when their time is up
	Timer {
		interval: 20000
		repeat: true
		running: root.enabled && Object.keys(root.snoozed).length > 0
		triggeredOnStart: true
		onTriggered: {
			if (!root.known || root.chats.length === 0) return;
			for (const id of Object.keys(root.snoozed))
				if (root.snoozed[id] <= Date.now()) root.wake(id, true);
		}
	}

	Timer {
		id: save

		interval: 400
		onTriggered: root.store()
	}

	FileView {
		id: kept

		path: Paths.stateFile("mail-kept.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.drafts = data.drafts ?? {};
				root.snoozed = data.snoozed ?? {};
				// what did not go out before the shell left is not sent behind the user's back
				root.outbox = (data.outbox ?? []).map(entry => Object.assign({}, entry, { state: "failed", error: entry.error || "Not sent" }));
			} catch (error) {}
		}
	}

	// a daemon that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
