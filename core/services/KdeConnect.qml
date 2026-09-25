pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// KDE Connect (kdeconnect-cli + D-Bus): the paired phone, its battery and
// the things the shell can send to it – text, the clipboard, clipboard
// history entries, files and URLs – plus ring and ping.
Singleton {
	id: root

	readonly property string statusScript: `${Quickshell.shellDir}/scripts/kdeconnect_status.py`

	// [{ id, name, type, reachable, battery, charging, network, signal }]
	property var devices: []
	// phone panels raise this while they are visible to poll faster
	property int watchers: 0
	// set by "Send file": the launcher's file browser sends the next file
	// it opens to the phone instead of opening it
	property bool pickingFile: false

	// the phone the shell talks to: reachable phones first, then any phone
	readonly property var device: {
		const phones = root.devices.filter(d => d.type === "phone" || d.type === "tablet");
		return phones.find(d => d.reachable) ?? root.devices.find(d => d.reachable) ?? phones[0] ?? null;
	}
	readonly property bool available: !!root.device
	readonly property bool reachable: !!root.device?.reachable
	readonly property string name: root.device?.name ?? "Phone"
	readonly property int battery: root.device?.battery ?? -1
	readonly property bool charging: !!root.device?.charging

	readonly property string batteryIcon: {
		if (root.battery < 0) return "cellphone";
		if (root.charging) return "battery_charging";
		const step = Math.max(10, Math.min(90, Math.round(root.battery / 10) * 10));
		return root.battery >= 95 ? "battery" : `battery_${step}`;
	}
	readonly property string summary: {
		if (!root.available) return "Not paired";
		if (!root.reachable) return "Not reachable";
		return root.battery >= 0 ? `${root.battery}%${root.charging ? " · charging" : ""}` : "Connected";
	}

	function refresh() {
		if (Host.has("kdeconnect") && !statusProc.running) statusProc.running = true;
	}

	function cli(args, doneLabel, event) {
		if (!root.reachable) {
			Notifs.pushInternal("error", `${root.name} is not reachable`, "", { icon: "cellphone_off" });
			return;
		}
		const proc = sender.createObject(root, { label: doneLabel || "", event: event || "" });
		proc.command = ["kdeconnect-cli", "-d", root.device.id].concat(args);
		proc.running = true;
	}

	function sendText(text) {
		const value = String(text ?? "");
		if (value.trim() === "") return;
		root.cli(["--share-text", value], `Sent to ${root.name}`, "sent");
	}

	function sendClipboard() {
		root.cli(["--send-clipboard"], `Clipboard sent to ${root.name}`, "sent");
	}

	function shareFile(path) {
		const file = String(path || "").replace(/^file:\/\//, "");
		if (file === "") return;
		root.cli(["--share", file], `${file.split("/").pop()} sent to ${root.name}`, "sent");
	}

	function shareUrl(url) {
		if (!url) return;
		root.cli(["--share", String(url)], `Link sent to ${root.name}`, "sent");
	}

	// a cliphist entry: text is shared as text, images as a file
	function sendClipboardEntry(entry) {
		if (!entry?.raw) return;
		const raw = String(entry.raw).replace(/'/g, `'"'"'`);
		const proc = entrySender.createObject(root, { image: !!entry.isImage });
		const tmp = `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/qs-phone-${String(entry.id).replace(/[^0-9]/g, "")}.${entry.extension || "png"}`;
		proc.command = entry.isImage
			? ["sh", "-c", `printf '%s\n' '${raw}' | cliphist decode > '${tmp}' && printf '%s' '${tmp}'`]
			: ["sh", "-c", `printf '%s\n' '${raw}' | cliphist decode`];
		proc.running = true;
	}

	function ring() {
		root.cli(["--ring"], `Ringing ${root.name}`, "");
	}

	function ping() {
		root.cli(["--ping"], "", "");
	}

	Component {
		id: sender

		Process {
			property string label: ""
			property string event: ""

			stderr: StdioCollector {
				id: err
			}
			onExited: exitCode => {
				if (exitCode === 0) {
					if (label !== "") Notifs.pushInternal("done", label, "", { icon: "cellphone_link" });
					if (event !== "") Haptics.play(event);
				} else {
					Notifs.pushInternal("error", "KDE Connect failed", String(err.text || "").trim());
					Haptics.play("taskFailed");
				}
				destroy();
			}
		}
	}

	Component {
		id: entrySender

		Process {
			property bool image: false

			stdout: StdioCollector {
				onStreamFinished: {
					if (image) root.shareFile(text.trim());
					else root.sendText(text);
				}
			}
			onExited: destroy()
		}
	}

	Process {
		id: statusProc

		command: ["python3", root.statusScript]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "[]"));
					if (Array.isArray(parsed)) root.devices = parsed;
				} catch (error) {}
			}
		}
	}

	Timer {
		running: Host.has("kdeconnect")
		repeat: true
		triggeredOnStart: true
		interval: root.watchers > 0 ? 5000 : 60000
		onTriggered: root.refresh()
	}
}
