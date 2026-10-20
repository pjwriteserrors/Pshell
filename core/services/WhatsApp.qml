pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// WhatsApp as a provider of Messages (scripts/whatsapp). The bridge is a
// linked device like WhatsApp Web: the phone scans its QR code once, and it
// stays signed in – it runs with the shell, whether Messages is shown or not –
// until it is unlinked. It keeps chats and messages itself and carries out
// what is done here.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("messages") && Plugins.on("whatsapp")
	readonly property bool notifies: Plugins.on("whatsapp-notifications")

	// "starting" | "building" | "missing" | "signedOut" | "qr" | "connecting" | "online" | "offline"
	property string state: "starting"
	property string error: ""
	// the QR code the phone scans, as a picture; or the code typed on the phone instead
	property string qr: ""
	property string code: ""
	// { id, name, phone }
	property var me: null
	// the phone hands over the past
	property bool syncing: false
	// a key for the GIF search is set
	property bool gifsReady: false
	readonly property bool linked: root.me !== null && root.state !== "signedOut" && root.state !== "qr"

	// [{ id, name, group, avatar, unread, marked, pinned, muted, archived, ephemeral, date, preview, kind, mine, status, sender, typing, phone, self }]
	property var chats: []
	property int unread: 0

	// the chat that is looked at
	property string openId: ""
	// a chat nothing was written in yet is not among the chats: { id: name }
	property var fresh: ({})
	readonly property var openChat: root.chats.find(chat => chat.id === root.openId)
		?? (root.openId !== "" ? { id: root.openId, name: root.fresh[root.openId] ?? root.contacts.find(contact => contact.id === root.openId)?.name ?? `+${root.openId.split("@")[0]}`,
			group: root.openId.endsWith("@g.us"), avatar: "", unread: 0, marked: false, pinned: false, muted: false, archived: false, ephemeral: 0, phone: `+${root.openId.split("@")[0]}` } : null)
	// [{ id, sender, name, mine, date, kind, text, html, status, big, media, quote, reactions, poll, place, cards, link, edited, forwarded, starred, error }]
	// status: -1 failed, 0 on its way, 1 sent, 2 delivered, 3 read, 4 played
	property var messages: []
	// { id: { name, avatar } } of who wrote in it
	property var people: ({})
	property bool more: false
	property bool loadingOlder: false
	property var typing: []
	property bool online: false
	property real seen: 0
	// the message a search led to
	property string target: ""

	// what is being written, by chat: { text, reply }
	property var drafts: ({})

	// { id, name, avatar, group, people, admin, description, about, phone, blocked, groups, invite, ephemeral, … } of the chat asked about
	property var info: null
	// [{ id, name, saved, phone, avatar }]
	property var contacts: []
	// [{ key, file, path, animated, favorite, used }]
	property var stickers: []
	// what a search for GIFs or stickers found: { query, kind, results: [{ id, preview, width, height, url }], error }
	property var gifs: ({ query: "", kind: "gif", results: [] })
	property bool gifsLoading: false
	// messages found: { query, hits: [{ chat, chatName, id, name, text, date, mine }] }
	property var found: ({ query: "", hits: [] })
	property bool recording: false
	// the voice message or GIF that plays: one at a time
	property string playing: ""
	// the emoji used last, newest first
	property var recentEmoji: []
	// the number a chat is to be started with, while it is looked up
	property string starting: ""
	property real recordingSince: 0

	// a number was looked up: { phone, ok, id, name }
	signal checked(var result)
	// a group was made or joined
	signal made(string chat)

	function command(name, fields) {
		if (!bridge.running) return;
		bridge.write(JSON.stringify(Object.assign({ cmd: name }, fields || {})) + "\n");
	}

	// ── how things are written ───────────────────────────────────────────
	// ── signing in ───────────────────────────────────────────────────────
	function signIn() {
		root.command("login");
	}

	function cancelSignIn() {
		root.command("cancelLogin");
	}

	function pairWith(phone) {
		root.command("pairCode", { phone: phone });
	}

	function signOut() {
		root.close();
		root.command("logout");
	}

	// ── chats ────────────────────────────────────────────────────────────
	function open(id, message) {
		if (root.openId !== id) {
			root.messages = [];
			root.people = {};
			root.typing = [];
			root.info = null;
		}
		root.openId = id;
		root.playing = "";
		root.target = message ?? "";
		root.command("open", message ? { chat: id, id: message } : { chat: id });
	}

	function close() {
		if (root.openId === "") return;
		root.openId = "";
		root.messages = [];
		root.command("close");
	}

	// from a notification or a command: the panel with the chat in it
	function show(id) {
		Messages.current = "whatsapp";
		root.open(id);
		root.read(id);
		Messages.open("whatsapp");
	}

	function older() {
		if (root.loadingOlder || !root.more) return;
		root.loadingOlder = true;
		olderDone.restart();
		root.command("older");
	}

	function read(id) {
		root.command("read", { chat: id });
	}

	function chatName(id) {
		return root.chats.find(chat => chat.id === id)?.name ?? "";
	}

	function keep(id, draft) {
		const next = Object.assign({}, root.drafts);
		if (draft && (draft.text !== "" || draft.reply)) next[id] = draft;
		else if (next[id] === undefined) return;
		else delete next[id];
		root.drafts = next;
	}

	// a chat with a number, once WhatsApp said whose it is
	function startChat(phone) {
		root.starting = String(phone);
		root.command("check", { phone: root.starting });
	}

	function usedEmoji(sign) {
		root.recentEmoji = [sign].concat(root.recentEmoji.filter(other => other !== sign)).slice(0, 40);
		kept.setText(JSON.stringify({ emoji: root.recentEmoji }, null, "\t") + "\n");
	}

	// ── sending ──────────────────────────────────────────────────────────
	// files: [{ path, as }] – as: "" (what the file is) | "document" | "voice" | "sticker" | "gif"
	function send(chat, text, reply, files, mentions) {
		root.command("send", { chat: chat, text: text, reply: reply ?? "", files: files ?? [], mentions: mentions ?? [] });
	}

	function sendFound(chat, url, kind, reply) {
		root.command("sendFrom", { chat: chat, url: url, kind: kind, reply: reply ?? "" });
	}

	function typingIn(chat, on) {
		root.command("typing", { chat: chat, value: on });
	}

	function record(action, chat, reply) {
		if (action === "start") root.recordingSince = Date.now();
		root.command("record", { action: action, chat: chat ?? "", reply: reply ?? "" });
	}

	// ── messages ─────────────────────────────────────────────────────────
	function act(name, id, fields) {
		root.command(name, Object.assign({ chat: root.openId, id: id }, fields || {}));
	}

	// action: "" (fetch it) | "open" | "save"
	function fetch(id, action) {
		root.act("fetch", id, { action: action ?? "" });
	}

	// ── chat settings ────────────────────────────────────────────────────
	function chatDo(name, chat, fields) {
		root.command(name, Object.assign({ chat: chat }, fields || {}));
	}

	function askInfo(chat) {
		root.info = null;
		root.command("info", { chat: chat });
	}

	function search(query) {
		root.command("search", { query: query });
	}

	function searchGifs(query, kind) {
		root.gifsLoading = true;
		root.command("gifs", { query: query, kind: kind });
	}

	// ── what the bridge says ─────────────────────────────────────────────
	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "state":
			root.state = data.state ?? "offline";
			root.error = data.error ?? "";
			root.qr = data.qr ?? "";
			root.code = data.code ?? "";
			root.me = data.me ?? null;
			root.syncing = data.syncing === true;
			root.gifsReady = data.gifs === true;
			if (root.state === "online") root.command("active", { value: Messages.shown });
			break;
		case "chats":
			root.chats = data.chats ?? [];
			root.unread = data.unread ?? 0;
			break;
		case "chat":
			if (data.id !== root.openId) break;
			root.messages = data.messages ?? [];
			root.people = data.people ?? {};
			root.more = data.more === true;
			root.typing = data.typing ?? [];
			root.online = data.online === true;
			root.seen = data.seen ?? 0;
			root.loadingOlder = false;
			break;
		case "incoming":
			root.arrived(data);
			break;
		case "info":
			if (data.id === root.openId || root.info === null) root.info = data;
			break;
		case "contacts":
			root.contacts = data.contacts ?? [];
			break;
		case "stickers":
			root.stickers = data.stickers ?? [];
			break;
		case "gifs":
			root.gifs = data;
			root.gifsLoading = false;
			break;
		case "found":
			root.found = data;
			break;
		case "checked":
			if (data.phone === root.starting) {
				root.starting = "";
				if (data.ok) {
					const fresh = Object.assign({}, root.fresh);
					fresh[data.id] = data.name;
					root.fresh = fresh;
					root.show(data.id);
				} else {
					Notifs.pushInternal("error", "WhatsApp", `${data.phone} is not on WhatsApp`, { icon: "whatsapp" });
				}
			}
			root.checked(data);
			break;
		case "made":
			root.made(data.chat);
			break;
		case "recording":
			root.recording = data.on === true;
			break;
		case "saved":
			Notifs.pushInternal("success", String(data.path).split("/").pop(), "Downloads", {
				icon: "download",
				actions: [{ label: "Open", icon: "open_in_new", run: () => Quickshell.execDetached(["xdg-open", data.path]) }]
			});
			break;
		case "error":
			Notifs.pushInternal("error", "WhatsApp", data.text ?? "", { icon: "whatsapp" });
			break;
		}
	}

	function arrived(message) {
		if (!root.notifies || Notifs.dnd) return;
		// the chat on the screen shows it already
		if (Messages.shown && Messages.provider?.id === "whatsapp" && root.openId === message.chat) return;
		Notifs.pushInternal("running", message.name, message.text, {
			icon: message.call ? "phone" : "whatsapp",
			app: "WhatsApp",
			avatar: message.avatar ?? "",
			duration: 9000,
			actions: [{ label: "Open", icon: "forum", run: () => root.show(message.chat) }],
			// answered from the toast: it was read then
			reply: message.call ? null : {
				placeholder: "Reply",
				send: text => {
					root.send(message.chat, text, "", [], []);
					root.read(message.chat);
				}
			}
		});
	}

	onEnabledChanged: if (!root.enabled) {
		root.chats = [];
		root.unread = 0;
		root.openId = "";
		root.messages = [];
		root.me = null;
		root.state = "starting";
	}

	// the phone keeps its own notifications to itself only while the panel is looked at
	Connections {
		target: Messages
		function onShownChanged() {
			root.command("active", { value: Messages.shown });
			if (!Messages.shown && root.recording) root.record("cancel");
		}
	}

	Process {
		id: bridge

		running: root.enabled
		stdinEnabled: true
		command: ["sh", `${Paths.scripts}/whatsapp/run.sh`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: {
			root.recording = false;
			if (root.enabled) {
				if (root.state !== "missing") root.state = "starting";
				revive.restart();
			}
		}
	}

	FileView {
		id: kept

		path: Paths.stateFile("whatsapp.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.recentEmoji = JSON.parse(String(text() || "{}")).emoji ?? [];
			} catch (error) {}
		}
	}

	// a phone that has nothing older does not answer
	Timer {
		id: olderDone

		interval: 6000
		onTriggered: root.loadingOlder = false
	}

	// a bridge that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.enabled && !bridge.running) bridge.running = true
	}
}
