import QtQuick
import Quickshell
import qs.core.services

// identities: the made-up people to sign up with, and what the mailbox and
// number of the one the phone looks at received. Looking from the phone
// counts as looking (Identities.remote), so the inboxes are read although
// the surface on the PC is closed; that surface is left alone. A mail's
// whole text is not part of the snapshot, it is asked for (`read`).
Topic {
	id: topic

	name: "identities"
	throttle: 300

	// the identity the phone has open
	property string seen: ""
	// mails whose whole text is on its way: "<id>:<mail>" → { id, mail, done, until }
	property var waiting: ({})

	Binding {
		target: Identities
		property: "remote"
		value: 1
		when: topic.wanted
		restoreMode: Binding.RestoreValue
	}

	Binding {
		target: Identities
		property: "remoteId"
		value: topic.seen
		when: topic.wanted
		restoreMode: Binding.RestoreValue
	}

	function find(id) {
		return Identities.identities.find(identity => identity.id === id) ?? null;
	}

	function card(identity) {
		const making = Identities.creatingId === identity.id;
		return {
			id: String(identity.id),
			title: String(identity.title || ""),
			label: Identities.label(identity),
			name: Identities.name(identity),
			saved: identity.saved === true,
			created: Number(identity.created) || 0,
			first: String(identity.first || ""),
			last: String(identity.last || ""),
			username: String(identity.username || ""),
			password: String(identity.password || ""),
			birthday: identity.birthday ? Qt.formatDate(new Date(identity.birthday), "dd.MM.yyyy") : "",
			street: String(identity.street || ""),
			postcode: String(identity.postcode || ""),
			city: String(identity.city || ""),
			state: String(identity.state || ""),
			country: String(identity.country || ""),
			picture: String(identity.picture || ""),
			mail: identity.mail ? {
				address: String(identity.mail.address || ""),
				gone: identity.mail.gone === true,
				renewing: Identities.renewing[`${identity.id}:mail`] === true
			} : null,
			phone: identity.phone ? {
				number: String(identity.phone.number || ""),
				gone: identity.phone.gone === true,
				renewing: Identities.renewing[`${identity.id}:phone`] === true
			} : null,
			unread: Identities.unread(identity),
			// which of its parts are still on their way
			pending: making ? Object.keys(Identities.pending).filter(part => Identities.pending[part] === true) : []
		};
	}

	function inbox(identity) {
		if (!identity) return null;
		return {
			id: String(identity.id),
			mails: (identity.mail?.messages ?? []).map(message => ({
				id: String(message.id),
				from: String(message.from || message.address || ""),
				subject: String(message.subject || ""),
				text: String(message.text || ""),
				at: Number(message.at) || 0,
				seen: message.seen === true,
				code: Identities.code(`${message.subject} ${message.text}`)
			})),
			sms: (identity.phone?.messages ?? []).map(message => ({
				id: String(message.id),
				from: String(message.from || ""),
				text: String(message.text || ""),
				at: Number(message.at) || 0,
				code: Identities.code(String(message.text || ""))
			}))
		};
	}

	data: topic.wanted ? ({
		creating: Identities.creating,
		failed: Identities.failed,
		// the identity whose inboxes are being read right now
		reading: Identities.reading,
		identities: Identities.identities.map(topic.card),
		inbox: topic.inbox(topic.find(topic.seen))
	}) : null

	// a phone that is gone looks at nobody
	onWantedChanged: if (!topic.wanted) topic.seen = ""

	// answers the mails whose text came, and the ones it will not come for
	function settle() {
		const left = {};
		for (const key in topic.waiting) {
			const entry = topic.waiting[key];
			const message = topic.find(entry.id)?.mail?.messages.find(candidate => candidate.id === entry.mail);
			if (message?.body) entry.done({ body: String(message.body) });
			else if (!message || Date.now() > entry.until) entry.done.fail("failed", "The mail could not be fetched");
			else left[key] = entry;
		}
		topic.waiting = left;
	}

	Connections {
		target: Identities
		function onIdentitiesChanged() {
			if (Object.keys(topic.waiting).length > 0) topic.settle();
		}
	}

	Timer {
		running: Object.keys(topic.waiting).length > 0
		repeat: true
		interval: 1000
		onTriggered: topic.settle()
	}

	function call(action, args, done) {
		const id = String(args.id || "");
		switch (action) {
		// which identity the phone has open ("" for none)
		case "look":
			topic.seen = id;
			return {};
		// the draft before it makes room, as on the PC; its surface stays as it is
		case "create":
			if (Identities.creating) throw new Error("An identity is being made");
			Identities.create(true);
			return { id: Identities.creatingId };
		case "save":
			if (!topic.find(id)) throw new Error("No such identity");
			if (args.title !== undefined) Identities.setTitle(id, String(args.title));
			Identities.setSaved(id, args.on !== false);
			return {};
		case "remove":
			if (!topic.find(id)) throw new Error("No such identity");
			if (Identities.creatingId === id) throw new Error("The identity is being made");
			if (topic.seen === id) topic.seen = "";
			Identities.remove(id);
			return {};
		case "renew": {
			const kind = String(args.kind || "");
			if (kind !== "mail" && kind !== "phone") throw new Error("Nothing to renew");
			if (!topic.find(id)) throw new Error("No such identity");
			Identities.renew(id, kind);
			return {};
		}
		// mailbox and number of one identity now; without one, the saved ones that are due
		case "check":
			if (id === "") Identities.check();
			else if (!Identities.creating) Identities.ask(id, true);
			return {};
		// a mail is read, and its whole text comes
		case "read": {
			const mail = String(args.mail || "");
			const before = topic.find(id)?.mail;
			if (!before?.messages.some(message => message.id === mail)) throw new Error("No such mail");
			Identities.read(id, mail);
			const message = topic.find(id).mail.messages.find(candidate => candidate.id === mail);
			if (message.body) return { body: String(message.body) };
			// a mail whose text cannot be had is what its first lines say
			if (before.gone || !before.token) return { body: String(message.text || "") };
			const next = Object.assign({}, topic.waiting);
			const key = `${id}:${mail}`;
			// asked twice: the first one will not hear of it any more
			if (next[key]) next[key].done.fail("failed", "Asked again");
			next[key] = { id: id, mail: mail, done: done, until: Date.now() + 12000 };
			topic.waiting = next;
			return topic.link.later;
		}
		}
		throw new Error("unknown-action");
	}
}
