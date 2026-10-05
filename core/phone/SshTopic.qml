import QtQuick
import Quickshell
import qs.core.services

// ssh: the saved logins; one tap opens a session in a terminal on the PC.
// Passwords and keys never leave the PC.
Topic {
	id: topic

	name: "ssh"

	onWantedChanged: if (topic.wanted) Ssh.refresh(false)

	data: topic.wanted ? ({
		entries: Ssh.entries.map(entry => ({
			id: String(entry.id),
			name: String(entry.name || entry.host || ""),
			host: String(entry.host || ""),
			user: String(entry.user || ""),
			used: Number(entry.last_used_at) || 0
		}))
	}) : null

	function call(action, args, done) {
		if (action !== "connect") throw new Error("unknown-action");
		Ssh.connect(String(args.id));
		return {};
	}
}
