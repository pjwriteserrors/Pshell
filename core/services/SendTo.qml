pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// "Send to …" in the Pshell menu (docs/browser.md): the people written to
// most, by WhatsApp or by mail (Messages). Picking one shows what would go
// in a toast – the text or link, with the page it came from – and only its
// "Send" sends it on WhatsApp; "Edit" puts it into the chat as a draft. By
// mail it becomes a draft in Messages, sent from there.
//
// Most frequent: the picks of this menu (browser-send.json: key → { count,
// last }, nothing of a private window), then pinned WhatsApp chats and the
// ones written to lately, then the people of the mailbox with the most
// conversations.
Singleton {
	id: root

	readonly property bool whatsappOn: WhatsApp.enabled && WhatsApp.linked
	readonly property bool mailOn: Plugins.on("messages") && Plugins.on("mail") && Mail.accounts.length > 0
	readonly property int count: 6

	// key ("wa:<chat>" | "mail:<address>") → { count, last }
	property var picks: ({})

	readonly property var people: {
		const now = Date.now() / 1000;
		const out = [];
		if (root.whatsappOn) {
			for (const chat of WhatsApp.chats) {
				if (chat.archived || chat.self) continue;
				const key = `wa:${chat.id}`;
				const pick = root.picks[key];
				const age = now - (Number(chat.date) || 0);
				const score = (pick ? 10 + pick.count * 2 : 0) + (chat.pinned ? 3 : 0) + (age < 7 * 86400 ? 2 : age < 30 * 86400 ? 1 : 0) + (chat.mine ? 1 : 0) - (chat.group ? 0.5 : 0);
				if (score > 0) out.push({ key: key, kind: "whatsapp", id: chat.id, name: String(chat.name || chat.phone || ""), score: score, date: Number(chat.date) || 0 });
			}
		}
		if (root.mailOn) {
			const named = new Set(out.map(person => person.name.toLowerCase()));
			const people = {};
			for (const chat of Mail.chats) {
				for (const person of chat.people || []) {
					const email = String(person.email || "").toLowerCase();
					if (email === "" || Mail.own(chat.account, String(person.email))) continue;
					const entry = people[email] ?? (people[email] = { email: email, name: String(person.name || email), chats: 0, account: chat.account });
					entry.chats += 1;
				}
			}
			for (const person of Object.values(people)) {
				if (named.has(person.name.toLowerCase())) continue;
				const key = `mail:${person.email}`;
				const pick = root.picks[key];
				const score = (pick ? 10 + pick.count * 2 : 0) + Math.min(2, person.chats / 5);
				if (person.chats >= 3 || pick) out.push({ key: key, kind: "mail", id: person.email, account: person.account, name: person.name, score: score, date: 0 });
			}
		}
		return out.sort((a, b) => b.score - a.score || b.date - a.date).slice(0, root.count);
	}

	// for WebMenu.entries: the submenu and one entry for each
	function entries(contexts) {
		if (root.people.length === 0) return [];
		const out = [{ id: "send-to", title: "Send to …", contexts: contexts, group: "send" }];
		for (const person of root.people)
			out.push({ id: `send:${person.key}`, title: person.kind === "mail" ? `${person.name} · Mail` : person.name, contexts: contexts, group: "send", parent: "send-to" });
		return out;
	}

	// what goes: the selection with its page, a link, a picture, or the page
	function message(info) {
		const page = String(info.page || "");
		switch (info.kind) {
		case "selection":
			return { subject: String(info.title || ""), text: [String(info.text || "").trim(), page].filter(Boolean).join("\n\n") };
		case "link":
			return { subject: String(info.linkText || info.title || "").trim(), text: String(info.link || "") };
		case "image":
		case "video":
		case "audio":
			return { subject: String(info.title || ""), text: /^https?:/.test(String(info.src || "")) ? String(info.src) : page };
		default:
			return { subject: String(info.title || ""), text: [String(info.title || "").trim(), page].filter(Boolean).join("\n") };
		}
	}

	function run(action, info) {
		if (!action.startsWith("send:")) return;
		const key = action.slice(5);
		const person = root.people.find(item => item.key === key);
		if (!person) return;
		const what = root.message(info);
		if (what.text === "") return;
		if (person.kind === "mail") return root.mail(person, what, info.private);
		Notifs.pushInternal("", `To ${person.name}`, what.text.length > 400 ? what.text.slice(0, 399) + "…" : what.text, {
			icon: "whatsapp",
			duration: 30000,
			actions: [
				{ label: "Send", icon: "send", run: () => {
					WhatsApp.send(person.id, what.text);
					root.picked(person, info.private);
					Notifs.pushInternal("done", `Sent to ${person.name}`, "", { icon: "whatsapp" });
				} },
				{ label: "Edit", icon: "pencil", run: () => {
					WhatsApp.keep(person.id, { text: what.text, reply: null });
					root.picked(person, info.private);
					WhatsApp.show(person.id);
				} }
			]
		});
	}

	// a draft in Messages; from a private window nothing of it is kept on disk
	function mail(person, what, isPrivate) {
		if (isPrivate) {
			Messages.open(`new:${person.id}`);
			return;
		}
		const escape = text => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
		const html = escape(what.text).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1">$1</a>').replace(/\n/g, "<br>");
		Mail.keep("new", { html: html, files: [], to: person.id, cc: "", bcc: "", subject: what.subject });
		root.picked(person, false);
		Messages.open("new");
	}

	function picked(person, isPrivate) {
		if (isPrivate) return;
		const next = Object.assign({}, root.picks);
		const before = next[person.key] ?? { count: 0, last: 0 };
		next[person.key] = { count: before.count + 1, last: Date.now() };
		// the 40 used last
		const keys = Object.keys(next).sort((a, b) => next[b].last - next[a].last);
		for (const old of keys.slice(40)) delete next[old];
		root.picks = next;
		store.setText(JSON.stringify(next, null, 1));
	}

	FileView {
		id: store

		path: Paths.stateFile("browser-send.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.picks = JSON.parse(store.text() || "{}");
			} catch (error) {}
		}
	}

	property bool built: false
	Component.onCompleted: Qt.callLater(() => root.built = true)

	Connections {
		target: root.built ? WebLink : null

		function onMenuClicked(action, info) {
			if (WebMenu.enabled) root.run(action, info || {});
		}
	}
}
