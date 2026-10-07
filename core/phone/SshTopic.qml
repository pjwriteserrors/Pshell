import QtQuick
import Quickshell
import Quickshell.Io
import qs.core.services

// ssh: the saved logins; one tap opens a session in a terminal on the PC.
// Passwords and keys never leave the PC. The phone can also list a host's
// folders and put files there: it uploads them to the PC first
// (PUT /upload), which copies them over with scp.
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
		switch (action) {
		case "connect":
			Ssh.connect(String(args.id));
			return {};
		// the folders of the host; path "" is the home
		case "browse": {
			const id = String(args.id || "");
			if (id === "") throw new Error("Which login?");
			topic.run(["ls-remote", "--id", id, "--path", String(args.path || ""), "--json"], done, result => ({
				path: String(result.path || ""),
				entries: (result.entries || []).map(entry => ({ name: String(entry.name || ""), dir: !!entry.dir, size: Number(entry.size) || 0 }))
			}));
			return topic.link.later;
		}
		// files that lie on the PC (uploaded by the phone) go to a folder of the host
		case "send": {
			const id = String(args.id || "");
			const paths = (Array.isArray(args.paths) ? args.paths : []).map(path => String(path)).filter(path => path !== "");
			if (id === "" || paths.length === 0) throw new Error("A login and files are needed");
			topic.run(["send", "--id", id, "--dest", String(args.dest || "~"), "--json", "--"].concat(paths), done, result => ({ message: String(result.message || "") }));
			return topic.link.later;
		}
		}
		throw new Error("unknown-action");
	}

	// runs ssh-manager and answers with what shape() makes of its JSON
	function run(args, done, shape) {
		const proc = runner.createObject(topic, { done: done, shape: shape });
		proc.command = ["python3", Ssh.cliPath].concat(args);
		proc.running = true;
	}

	Component {
		id: runner

		Process {
			id: proc

			property var done
			property var shape
			property string output: ""
			property string errors: ""

			stdout: StdioCollector {
				onStreamFinished: proc.output = text
			}
			stderr: StdioCollector {
				onStreamFinished: proc.errors = text
			}
			onExited: (code, status) => {
				let result = null;
				try {
					result = JSON.parse(proc.output);
				} catch (error) {}
				if (result && result.ok !== false && code === 0) proc.done(proc.shape(result));
				else proc.done.fail("failed", String(result?.error || result?.message || proc.errors.trim() || "ssh-manager failed"));
				proc.destroy();
			}
		}
	}
}
