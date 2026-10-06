pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Saved SSH logins (scripts/ssh-manager). Connecting opens kitty; files go
// to a login with scp.
Singleton {
	id: root

	readonly property string cliPath: `${Paths.scripts}/ssh-manager`

	property var entries: []
	property string draftHost: ""
	property string draftUser: ""
	property string draftPassword: ""
	property string draftKeyPath: ""
	property string draftAuthMode: "password"
	property string draftName: ""
	property string searchText: ""
	property string statusMessage: ""
	property string actionMessage: ""
	property string actionError: ""
	property string actionMode: ""
	readonly property bool actionRunning: actionProcess.running
	// a copy started away from the panel reports as a toast
	property bool actionToast: false
	// most recently used first; logins never used keep their place at the end
	readonly property var recent: root.entries.filter(entry => Number(entry.last_used_at) > 0)
		.sort((a, b) => Number(b.last_used_at) - Number(a.last_used_at))
		.concat(root.entries.filter(entry => !(Number(entry.last_used_at) > 0)))
	readonly property bool loading: listProcess.running

	// sending files: the login they go to, a folder of this machine with the
	// files picked from it, and the folder on the server they land in
	property var transferEntry: null
	property string localPath: ""
	property var localEntries: []
	property string localError: ""
	property string remotePath: ""
	property var remoteEntries: []
	property string remoteError: ""
	property var picked: []
	property bool showHidden: false
	property string transferMessage: ""
	property bool transferFailed: false
	// the folder last open per login
	property var remotePaths: ({})
	readonly property bool localLoading: localProcess.running
	readonly property bool remoteLoading: remoteProcess.running
	readonly property bool sending: sendProcess.running
	readonly property bool canSend: root.transferEntry !== null && root.picked.length > 0 && root.remotePath !== ""
		&& root.remoteError === "" && !root.remoteLoading && !root.sending
	// a picked file is already in the server's folder
	readonly property bool overwrites: {
		const there = root.remoteEntries.filter(entry => !entry.dir).map(entry => String(entry.name));
		return root.picked.some(path => there.includes(root.baseName(path)));
	}

	readonly property bool canAdd: root.draftHost.trim() !== ""
		&& root.draftUser.trim() !== ""
		&& (root.draftAuthMode === "key" ? root.draftKeyPath.trim() !== "" : root.draftPassword !== "")
		&& !root.actionRunning

	readonly property var filtered: {
		const query = root.searchText.trim().toLowerCase();
		if (query === "") return root.entries;
		return root.entries.filter(entry => [entry.name, entry.display_name, entry.target, entry.user, entry.host, entry.identity_file]
			.map(value => String(value || "").toLowerCase()).join(" ").includes(query));
	}

	function stripAnsi(value) {
		return String(value || "").replace(/\u001b\[[0-9;]*[A-Za-z]/g, "");
	}

	function parseEntries(raw) {
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { parsed = {}; }
		root.entries = Array.isArray(parsed.entries) ? parsed.entries : [];
		if (root.statusMessage === "" || root.statusMessage === "Loading SSH logins...")
			root.statusMessage = root.entries.length > 0 ? "Ready" : "No saved SSH logins";
	}

	function refresh(showLoading = true) {
		if (listProcess.running) return;
		if (showLoading) root.statusMessage = "Loading SSH logins...";
		listProcess.running = true;
	}

	function add() {
		if (actionProcess.running) return;
		const cleanName = root.draftName.trim();
		const cleanHost = root.draftHost.trim();
		const cleanUser = root.draftUser.trim();
		const secret = root.draftAuthMode === "key" ? "" : root.draftPassword;
		const cleanKeyPath = root.draftAuthMode === "key" ? root.draftKeyPath.trim() : "";
		if (cleanHost === "" || cleanUser === "" || (secret === "" && cleanKeyPath === "")) return;
		root.actionMode = "add";
		root.actionMessage = "";
		root.actionError = "";
		root.statusMessage = "Saving SSH login...";
		const credentialArgs = cleanKeyPath !== "" ? ["--identity-file", cleanKeyPath] : ["--password", secret];
		actionProcess.command = ["python3", root.cliPath, "add", "--name", cleanName, "--host", cleanHost, "--user", cleanUser].concat(credentialArgs, ["--json"]);
		actionProcess.running = true;
	}

	function remove(entryId) {
		const id = String(entryId || "");
		if (id === "" || actionProcess.running) return;
		root.actionMode = "delete";
		root.actionMessage = "";
		root.actionError = "";
		root.statusMessage = "Deleting SSH login...";
		actionProcess.command = ["python3", root.cliPath, "delete", "--id", id, "--json"];
		actionProcess.running = true;
	}

	function copyPassword(entryId, toast = false) {
		const id = String(entryId || "");
		if (id === "" || actionProcess.running) return;
		root.actionToast = toast;
		root.actionMode = "copy";
		root.actionMessage = "";
		root.actionError = "";
		actionProcess.command = ["python3", root.cliPath, "copy-password", "--id", id, "--json"];
		actionProcess.running = true;
	}

	function connect(entryId) {
		const id = String(entryId || "");
		if (id === "") return;
		root.statusMessage = "Opening kitty...";
		Quickshell.execDetached(["python3", root.cliPath, "connect", "--id", id]);
		Popups.close();
	}

	function baseName(path) {
		return String(path || "").replace(/\/+$/, "").split("/").pop();
	}

	function openTransfer(entry) {
		if (!entry) return;
		root.transferEntry = entry;
		root.picked = [];
		root.transferMessage = "";
		root.transferFailed = false;
		root.remotePath = "";
		root.remoteEntries = [];
		root.remoteError = "";
		root.browseLocal(root.localPath);
		root.browseRemote(root.remotePaths[String(entry.id)] || "");
	}

	function closeTransfer() {
		root.transferEntry = null;
		root.picked = [];
	}

	// a folder, or a file: then its folder opens and the file is picked
	function browseLocal(path) {
		localProcess.wanted = String(path || "");
		localProcess.queued = true;
		if (!localProcess.running) localProcess.start();
	}

	function browseRemote(path) {
		if (root.transferEntry === null) return;
		remoteProcess.wanted = String(path || "");
		remoteProcess.queued = true;
		if (!remoteProcess.running) remoteProcess.start();
	}

	function togglePicked(path) {
		root.picked = root.picked.includes(path) ? root.picked.filter(item => item !== path) : root.picked.concat([path]);
	}

	function send() {
		if (!root.canSend) return;
		root.transferMessage = "";
		root.transferFailed = false;
		sendProcess.entryId = String(root.transferEntry.id);
		sendProcess.command = ["python3", root.cliPath, "send", "--id", sendProcess.entryId, "--dest", root.remotePath, "--json", "--"].concat(root.picked);
		sendProcess.running = true;
	}

	function parseListing(raw) {
		try {
			const parsed = JSON.parse(String(raw || ""));
			return parsed && parsed.ok ? parsed : null;
		} catch (error) {
			return null;
		}
	}

	function finishAction(exitCode) {
		if (exitCode === 0) {
			root.statusMessage = root.actionMessage || "SSH login updated.";
			if (root.actionMode === "add") {
				root.draftName = "";
				root.draftPassword = "";
				root.draftKeyPath = "";
			}
			if (root.actionMode !== "copy") root.refresh(false);
		} else {
			root.statusMessage = root.actionError.trim() || "SSH manager action failed.";
		}
		if (root.actionToast) Notifs.pushInternal(exitCode === 0 ? "done" : "error", root.statusMessage, "", { icon: "key_variant" });
		root.actionToast = false;
		root.actionMode = "";
		root.actionMessage = "";
		root.actionError = "";
		actionProcess.command = ["sh", "-lc", ":"];
	}

	Process {
		id: listProcess
		command: ["python3", root.cliPath, "list", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseEntries(text) }
		stderr: StdioCollector {
			onStreamFinished: {
				const detail = root.stripAnsi(text).trim();
				if (detail !== "") root.statusMessage = detail;
			}
		}
	}

	Process {
		id: actionProcess
		command: ["sh", "-lc", ":"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.actionMessage = String(JSON.parse(String(text || "")).message || "").trim();
				} catch (error) {
					root.actionMessage = "";
				}
			}
		}
		stderr: StdioCollector { onStreamFinished: root.actionError = root.stripAnsi(text) }
		onExited: exitCode => root.finishAction(exitCode)
	}

	Process {
		id: localProcess

		property string wanted: ""
		property bool queued: false
		property string output: ""
		property string failure: ""

		function start() {
			localProcess.queued = false;
			localProcess.command = ["python3", root.cliPath, "ls-local", "--path", localProcess.wanted, "--json"];
			localProcess.running = true;
		}

		stdout: StdioCollector { onStreamFinished: localProcess.output = text }
		stderr: StdioCollector { onStreamFinished: localProcess.failure = root.stripAnsi(text).trim() }
		onExited: {
			// asked for another folder meanwhile
			if (localProcess.queued) {
				localProcess.start();
				return;
			}
			const listing = root.parseListing(localProcess.output);
			if (listing === null) {
				root.localError = localProcess.failure || "Could not open the folder.";
				return;
			}
			root.localError = "";
			root.localPath = String(listing.path);
			root.localEntries = listing.entries;
			const file = String(listing.selected || "");
			if (file !== "" && !root.picked.includes(file)) root.picked = root.picked.concat([file]);
		}
	}

	Process {
		id: remoteProcess

		property string wanted: ""
		property bool queued: false
		property string entryId: ""
		property string output: ""
		property string failure: ""

		function start() {
			remoteProcess.queued = false;
			remoteProcess.entryId = String(root.transferEntry.id);
			remoteProcess.command = ["python3", root.cliPath, "ls-remote", "--id", remoteProcess.entryId, "--path", remoteProcess.wanted, "--json"];
			remoteProcess.running = true;
		}

		stdout: StdioCollector { onStreamFinished: remoteProcess.output = text }
		stderr: StdioCollector { onStreamFinished: remoteProcess.failure = root.stripAnsi(text).trim() }
		onExited: {
			if (root.transferEntry === null) return;
			if (remoteProcess.queued) {
				remoteProcess.start();
				return;
			}
			const listing = root.parseListing(remoteProcess.output);
			if (listing === null) {
				root.remoteError = remoteProcess.failure || "Could not open the folder.";
				return;
			}
			root.remoteError = "";
			root.remotePath = String(listing.path);
			root.remoteEntries = listing.entries;
			const paths = Object.assign({}, root.remotePaths);
			paths[remoteProcess.entryId] = root.remotePath;
			root.remotePaths = paths;
		}
	}

	Process {
		id: sendProcess

		property string entryId: ""
		property string output: ""
		property string failure: ""

		stdout: StdioCollector { onStreamFinished: sendProcess.output = text }
		stderr: StdioCollector { onStreamFinished: sendProcess.failure = root.stripAnsi(text).trim() }
		onExited: exitCode => {
			let message = "";
			try { message = String(JSON.parse(sendProcess.output).message || ""); } catch (error) { message = ""; }
			root.transferFailed = exitCode !== 0;
			root.transferMessage = root.transferFailed ? (sendProcess.failure || "Could not send the files.") : (message || "Sent.");
			const watching = Popups.current === "ssh" && root.transferEntry !== null && String(root.transferEntry.id) === sendProcess.entryId;
			if (!watching) Notifs.pushInternal(root.transferFailed ? "error" : "done", root.transferMessage, "", { icon: "upload" });
			if (root.transferFailed || root.transferEntry === null || String(root.transferEntry.id) !== sendProcess.entryId) return;
			root.picked = [];
			root.browseRemote(root.remotePath);
		}
	}
}
