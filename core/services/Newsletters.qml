pragma Singleton

import QtQuick
import Quickshell

// The newsletters of the private mailboxes (scripts/messages/newsletters.py,
// inside the mail daemon): who sends them, and leaving the ones that are
// ticked. The mailbox of work (Outlook) is not looked at. Nothing is left
// without being asked for, and no mail is deleted, moved or marked.
Singleton {
	id: root

	readonly property bool enabled: Mail.enabled && Plugins.on("mail-unsubscribe")
	// the mailboxes that are looked at
	readonly property var accounts: Mail.accounts.filter(account => account.kind !== "outlook")

	// [{ id, account, name, domain, count, last, subject, method: "one-click" | "email" | "page" }], who sends most first
	property var senders: []
	// who was left, last first: [{ id, account, name, domain, status: "done" | "needs-you", method, url, at }]
	property var left: []
	// when the mailboxes were last looked at, in seconds
	property real at: 0
	property bool scanning: false
	// senders being left, the first of them right now
	property var working: []
	property string error: ""
	// the tab came up: mailboxes not looked at for a day are looked at again
	property bool stale: false

	function load() {
		root.stale = true;
		Mail.command("newsletters");
	}

	function scan() {
		Mail.command("scanNewsletters");
	}

	function unsubscribe(ids) {
		Mail.command("unsubscribe", { ids: ids });
	}

	// back on the list; the browser shows where to sign up again
	function resubscribe(id) {
		Mail.command("resubscribe", { id: id });
	}

	// the page a sender is left on by hand
	function openPage(id) {
		Mail.command("newsletterPage", { id: id });
	}

	Connections {
		target: Mail
		function onNewsletters(data) {
			root.senders = data.senders ?? [];
			root.left = data.left ?? [];
			root.at = data.at ?? 0;
			root.scanning = data.scanning === true;
			root.working = data.working ?? [];
			root.error = data.error ?? "";
			if (!root.stale) return;
			root.stale = false;
			if (!root.scanning && root.working.length === 0 && Date.now() / 1000 - root.at > 86400) root.scan();
		}
	}
}
