import QtQuick
import Quickshell
import qs.core.services

// messages: mail as chats, the way the Messages panel shows it. The open
// chat is the shell's (Mail.openId), so opening one here marks it read on
// the PC too. Bodies travel as plain text; an attachment is fetched on
// request and sent as a file.
Topic {
	id: topic

	name: "messages"
	throttle: 150

	// attachment requests under way: request number → done
	property var waiting: ({})
	property int request: 0

	function avatar(email) {
		const path = Mail.avatars[email];
		return path ? { "$blob": String(path) } : null;
	}

	function person(entry) {
		return { name: String(entry?.name || ""), email: String(entry?.email || "") };
	}

	data: topic.wanted ? ({
		known: Mail.known,
		running: Mail.running,
		trouble: Mail.trouble,
		unread: Mail.unread,
		accounts: Mail.accounts.map(account => ({
			id: String(account.id),
			kind: String(account.kind || ""),
			address: String(account.address || ""),
			name: String(account.name || ""),
			state: String(account.state || ""),
			error: String(account.error || "")
		})),
		chats: Mail.chats.slice(0, 200).map(chat => ({
			id: String(chat.id),
			account: String(chat.account || ""),
			subject: String(chat.subject || ""),
			people: (chat.people || []).map(topic.person),
			group: !!chat.group,
			date: Number(chat.date) || 0,
			preview: String(chat.preview || ""),
			sender: String(chat.sender || ""),
			mine: !!chat.mine,
			unread: Number(chat.unread) || 0,
			count: Number(chat.count) || 0,
			flagged: !!chat.flagged,
			attachments: !!chat.attachments,
			snoozed: Mail.snoozed[chat.id] !== undefined,
			avatar: topic.avatar(chat.people?.[0]?.email)
		})),
		open: Mail.openId === "" ? null : {
			id: Mail.openId,
			loading: Mail.loading,
			messages: Mail.messages.map(message => ({
				id: String(message.id),
				from: topic.person(message.from),
				to: (message.to || []).map(topic.person),
				cc: (message.cc || []).map(topic.person),
				date: Number(message.date) || 0,
				mine: !!message.mine,
				read: message.read !== false,
				flagged: !!message.flagged,
				subject: String(message.subject || ""),
				text: String(message.text || ""),
				signature: String(message.signature || ""),
				quote: String(message.quote || ""),
				importance: String(message.importance || ""),
				invite: !!message.invite,
				forward: !!message.forward,
				attachments: (message.attachments || []).map(attachment => ({
					id: String(attachment.id),
					name: String(attachment.name || ""),
					size: Number(attachment.size) || 0,
					type: String(attachment.type || ""),
					preview: attachment.preview ? { "$blob": String(attachment.preview) } : null
				})),
				avatar: topic.avatar(message.from?.email)
			})),
			assistant: MailAssist.enabled ? {
				said: MailAssist.said(Mail.openId),
				writing: MailAssist.writing === Mail.openId,
				error: MailAssist.error
			} : null
		},
		outbox: Mail.outbox.map(entry => ({
			id: String(entry.id),
			key: String(entry.key),
			state: String(entry.state),
			error: String(entry.error || ""),
			text: String(entry.text || ""),
			at: Number(entry.at) || 0,
			grace: Mail.grace
		})),
		searched: Mail.searched,
		searching: Mail.searching,
		hits: Mail.hits,
		snippets: Snippets.list.map(snippet => ({ id: String(snippet.id), name: String(snippet.name || ""), text: String(snippet.text || "") })),
		assistant: MailAssist.enabled
	}) : null

	onWantedChanged: if (topic.wanted) Mail.refresh()

	Connections {
		target: Mail
		function onFileReady(request, path) {
			const done = topic.waiting[request];
			if (!done) return;
			const next = Object.assign({}, topic.waiting);
			delete next[request];
			topic.waiting = next;
			if (path === "") return done.fail("failed", "The attachment is not there");
			topic.link.sendFiles([path]);
			done({ path: path });
		}
	}

	function markup(text) {
		return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "<br>");
	}

	function addresses(value) {
		return (Array.isArray(value) ? value : String(value || "").split(/[,;\s]+/)).map(entry => String(entry).trim()).filter(entry => entry !== "");
	}

	function context() {
		const chat = Mail.chats.find(entry => entry.id === Mail.openId);
		const account = Mail.account(chat?.account) ?? Mail.accounts[0] ?? null;
		return {
			me: account ? { name: account.name, email: account.address } : {},
			to: (chat?.people || []).map(topic.person),
			thread: Mail.messages.slice(-12).map(message => ({
				from: String(message.from?.name || ""),
				email: String(message.from?.email || ""),
				mine: !!message.mine,
				date: Number(message.date) || 0,
				text: String(message.text || ""),
				signature: String(message.signature || "")
			})),
			draft: ""
		};
	}

	function call(action, args, done) {
		switch (action) {
		case "open":
			Mail.open(String(args.id));
			return {};
		case "close":
			Mail.close();
			return {};
		case "read":
			Mail.setRead(String(args.id), args.value !== false);
			return {};
		case "flag":
			Mail.setFlag(String(args.id), args.value !== false);
			return {};
		case "archive":
			Mail.archive(String(args.id));
			return {};
		case "remove":
			Mail.remove(String(args.id));
			return {};
		case "snooze":
			Mail.snooze(String(args.id), Number(args.until) || (Date.now() + 3600000));
			return {};
		case "wake":
			Mail.wake(String(args.id), true);
			return {};
		case "refresh":
			Mail.refresh();
			return {};
		case "search":
			Mail.search(String(args.query || ""));
			return {};
		case "older":
			Mail.older();
			return {};
		// a mail written on the phone: plain text, sent after the same grace as on the PC
		case "send": {
			const text = String(args.text || "").trim();
			if (text === "") throw new Error("Nothing to send");
			const mode = String(args.mode || "new");
			const key = String(args.key || "new");
			const chat = Mail.chats.find(entry => entry.id === key);
			const accountId = String(args.account || chat?.account || Mail.accounts[0]?.id || "");
			if (accountId === "") throw new Error("No mail account");
			const to = topic.addresses(args.to);
			if (to.length === 0) throw new Error("Nobody to send it to");
			const draft = {
				account: accountId,
				mode: mode,
				reply: String(args.reply || ""),
				to: to,
				cc: topic.addresses(args.cc),
				bcc: topic.addresses(args.bcc),
				subject: String(args.subject || ""),
				text: text,
				html: topic.markup(text),
				files: []
			};
			return { id: Mail.post(key, draft, draft.html, text.split("\n")[0].slice(0, 120)) };
		}
		case "undo":
			Mail.undo(String(args.id));
			return {};
		case "dispatch":
			Mail.dispatch(String(args.id));
			return {};
		case "forget":
			Mail.forget(String(args.id));
			return {};
		case "openAttachment":
			if (Mail.openId !== String(args.chat)) throw new Error("The chat is not open");
			Mail.openAttachment(String(args.message), String(args.attachment));
			return {};
		// the attachment comes to the phone as a file
		case "attachment": {
			topic.request += 1;
			const next = Object.assign({}, topic.waiting);
			next[topic.request] = done;
			topic.waiting = next;
			Mail.attachmentPath(String(args.chat || Mail.openId), String(args.message), String(args.attachment), topic.request);
			return topic.link.later;
		}
		case "ask":
			if (!MailAssist.enabled) throw new Error("The mail assistant is off");
			if (Mail.openId === "") throw new Error("No chat is open");
			MailAssist.ask(Mail.openId, topic.context(), String(args.text || ""));
			return {};
		case "forgetAssistant":
			MailAssist.forget(Mail.openId);
			return {};
		case "stopAssistant":
			MailAssist.stop();
			return {};
		}
		throw new Error("unknown-action");
	}
}
