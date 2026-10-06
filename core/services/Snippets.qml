pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Texts that are written again and again, to be put into a message with a
// click (snippets.json). One may belong to a customer: it is then offered
// only in chats with that customer's people. `{name}` in a text becomes the
// first name of who the mail goes to.
Singleton {
	id: root

	// [{ id, name, text, customer }]
	property var list: []

	// the ones offered in a chat with these addresses
	function offered(emails) {
		return root.list.filter(snippet => !snippet.customer || (Customers.find(snippet.customer)?.people ?? []).some(email => emails.includes(email)));
	}

	function add(name, text, customer) {
		root.save(root.list.concat([{ id: `${Date.now()}-${Math.floor(Math.random() * 100000)}`, name: String(name).trim(), text: text, customer: customer || "" }]));
	}

	function remove(id) {
		root.save(root.list.filter(snippet => snippet.id !== id));
	}

	function filled(snippet, name) {
		return String(snippet.text).replace(/\{name\}/g, String(name || "").split(/\s+/)[0]);
	}

	function save(next) {
		root.list = next;
		file.setText(JSON.stringify(next, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Plugins.on("messages") ? Paths.stateFile("snippets.json") : ""
		printErrors: false
		onLoaded: {
			try {
				const parsed = JSON.parse(text() || "[]");
				root.list = Array.isArray(parsed) ? parsed.filter(snippet => snippet && snippet.id) : [];
			} catch (error) {
				console.warn("Snippets: snippets.json is not valid JSON");
			}
		}
	}
}
