pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Customers: people put together under a name, to keep the Messages panel
// to the chats with them. Each mailbox has its own; outside the mailbox of
// work they are called groups. They exist only here (customers.json); no
// provider knows about them.
Singleton {
	id: root

	// [{ id, name, account, people: [address], declined: [address] }]
	property var list: []
	// the mailbox of the ones made before each had one: that of work
	readonly property string first: (Mail.accounts.find(account => account.kind === "outlook") ?? Mail.accounts[0])?.id ?? ""

	// the ones of a mailbox
	function of(account) {
		return root.list.filter(customer => (customer.account || root.first) === account);
	}
	// where everybody has an address: no sign of who someone belongs to
	readonly property var common: ["gmail.com", "googlemail.com", "outlook.com", "outlook.de", "hotmail.com", "hotmail.de", "live.com", "live.de", "yahoo.com", "yahoo.de",
		"icloud.com", "me.com", "gmx.de", "gmx.net", "gmx.at", "gmx.ch", "web.de", "t-online.de", "freenet.de", "posteo.de", "mailbox.org", "proton.me", "protonmail.com", "aol.com"]

	function find(id) {
		return root.list.find(customer => customer.id === id) ?? null;
	}

	function has(id, email) {
		return root.find(id)?.people.includes(email) ?? false;
	}

	// The customer of the mailbox someone with this address most likely belongs to: the only one with
	// people at the same domain, unless it was said no to. `own`: domains that are the user's.
	function suggest(email, own, account) {
		const domain = String(email).split("@")[1] ?? "";
		if (domain === "" || root.common.includes(domain) || (own ?? []).includes(domain)) return null;
		const list = root.of(account);
		if (list.some(customer => customer.people.includes(email))) return null;
		const fitting = list.filter(customer => customer.people.some(entry => entry.endsWith(`@${domain}`)));
		if (fitting.length !== 1 || (fitting[0].declined ?? []).includes(email)) return null;
		return fitting[0];
	}

	function decline(id, email) {
		root.save(root.list.map(customer => customer.id === id ? Object.assign({}, customer, { declined: (customer.declined ?? []).concat([email]) }) : customer));
	}

	function create(name, account) {
		const id = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
		root.save(root.list.concat([{ id: id, name: String(name || "").trim(), account: account || root.first, people: [] }]));
		return id;
	}

	function rename(id, name) {
		root.save(root.list.map(customer => customer.id === id ? Object.assign({}, customer, { name: String(name).trim() }) : customer));
	}

	function toggle(id, email) {
		root.save(root.list.map(customer => {
			if (customer.id !== id) return customer;
			const people = customer.people.includes(email) ? customer.people.filter(entry => entry !== email) : customer.people.concat([email]);
			return Object.assign({}, customer, { people: people });
		}));
	}

	function remove(id) {
		root.save(root.list.filter(customer => customer.id !== id));
	}

	function save(next) {
		root.list = next;
		file.setText(JSON.stringify(next, null, "\t") + "\n");
	}

	function load(text) {
		try {
			const parsed = JSON.parse(text || "[]");
			root.list = Array.isArray(parsed) ? parsed.filter(customer => customer && customer.id && Array.isArray(customer.people)) : [];
		} catch (error) {
			console.warn("Customers: customers.json is not valid JSON");
		}
	}

	FileView {
		id: file

		path: Plugins.on("messages") ? Paths.stateFile("customers.json") : ""
		printErrors: false
		onLoaded: root.load(text())
	}
}
