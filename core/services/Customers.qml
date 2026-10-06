pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Customers: people put together under a name, to keep the Messages panel
// to the chats with them. They exist only here (customers.json); no
// provider knows about them.
Singleton {
	id: root

	// [{ id, name, people: [address], declined: [address] }]
	property var list: []
	// where everybody has an address: no sign of who someone belongs to
	readonly property var common: ["gmail.com", "googlemail.com", "outlook.com", "outlook.de", "hotmail.com", "hotmail.de", "live.com", "live.de", "yahoo.com", "yahoo.de",
		"icloud.com", "me.com", "gmx.de", "gmx.net", "gmx.at", "gmx.ch", "web.de", "t-online.de", "freenet.de", "posteo.de", "mailbox.org", "proton.me", "protonmail.com", "aol.com"]

	function find(id) {
		return root.list.find(customer => customer.id === id) ?? null;
	}

	function has(id, email) {
		return root.find(id)?.people.includes(email) ?? false;
	}

	// The customer someone with this address most likely belongs to: the only one with
	// people at the same domain, unless it was said no to. `own`: domains that are the user's.
	function suggest(email, own) {
		const domain = String(email).split("@")[1] ?? "";
		if (domain === "" || root.common.includes(domain) || (own ?? []).includes(domain)) return null;
		if (root.list.some(customer => customer.people.includes(email))) return null;
		const fitting = root.list.filter(customer => customer.people.some(entry => entry.endsWith(`@${domain}`)));
		if (fitting.length !== 1 || (fitting[0].declined ?? []).includes(email)) return null;
		return fitting[0];
	}

	function decline(id, email) {
		root.save(root.list.map(customer => customer.id === id ? Object.assign({}, customer, { declined: (customer.declined ?? []).concat([email]) }) : customer));
	}

	function create(name) {
		const id = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
		root.save(root.list.concat([{ id: id, name: String(name || "").trim(), people: [] }]));
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
