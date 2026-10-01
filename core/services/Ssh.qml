pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Saved SSH logins (scripts/ssh-manager). Connecting opens kitty.
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
}
