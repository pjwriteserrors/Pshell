import QtQuick
import Quickshell
import qs.core.services

// newsletters: who sends them to the private mailboxes, and who was left.
// Only what is ticked on the phone is left; looking loads the list the way
// the tab on the PC does.
Topic {
	id: topic

	name: "newsletters"
	throttle: 200

	function mailbox(id) {
		const account = Newsletters.accounts.length > 1 ? Mail.account(id ?? "") : null;
		return account ? Mail.label(account) : "";
	}

	data: topic.wanted ? ({
		running: Mail.running,
		accounts: Newsletters.accounts.length,
		senders: Newsletters.senders.map(sender => ({
			id: String(sender.id),
			mailbox: topic.mailbox(sender.account),
			name: String(sender.name || ""),
			domain: String(sender.domain || ""),
			count: Number(sender.count) || 0,
			last: Number(sender.last) || 0,
			subject: String(sender.subject || ""),
			method: String(sender.method || "")
		})),
		left: Newsletters.left.map(sender => ({
			id: String(sender.id),
			mailbox: topic.mailbox(sender.account),
			name: String(sender.name || ""),
			domain: String(sender.domain || ""),
			status: String(sender.status || ""),
			method: String(sender.method || ""),
			at: Number(sender.at) || 0
		})),
		at: Newsletters.at,
		scanning: Newsletters.scanning,
		working: Newsletters.working.map(id => String(id)),
		error: Newsletters.error,
		stale: Newsletters.stale
	}) : null

	onWantedChanged: if (topic.wanted) Newsletters.load()

	function call(action, args, done) {
		switch (action) {
		case "load":
			Newsletters.load();
			return {};
		case "scan":
			Newsletters.scan();
			return {};
		case "unsubscribe": {
			// only senders that are on the list
			const asked = (Array.isArray(args.ids) ? args.ids : []).map(id => String(id));
			const ids = Newsletters.senders.map(sender => String(sender.id)).filter(id => asked.includes(id));
			if (ids.length === 0) throw new Error("Nothing to unsubscribe from");
			Newsletters.unsubscribe(ids);
			return { count: ids.length };
		}
		// back on the list; the browser on the PC shows where to sign up again
		case "resubscribe":
			Newsletters.resubscribe(String(args.id || ""));
			return {};
		}
		throw new Error("unknown-action");
	}
}
