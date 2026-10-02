pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Active link (sysfs), Wi-Fi SSID/signal (nmcli) and live throughput from
// /proc/net/dev, sampled every two seconds with a short history.
Singleton {
	id: root

	readonly property int historyLength: 30
	property string type: "offline"
	property string iface: ""
	property string ip: ""
	property string ssid: ""
	property int signal: -1
	property real upload: 0
	property real download: 0
	property real lastRx: 0
	property real lastTx: 0
	property bool sampleReady: false
	property var uploadHistory: root.zeros()
	property var downloadHistory: root.zeros()

	readonly property bool online: root.type !== "offline"
	readonly property string icon: {
		if (root.type === "ethernet") return "ethernet";
		if (root.type === "offline") return "wifi_off";
		if (root.signal < 0 || root.signal >= 75) return "wifi_strength_4";
		if (root.signal >= 50) return "wifi_strength_3";
		if (root.signal >= 25) return "wifi_strength_2";
		return "wifi_strength_1";
	}
	readonly property string label: root.type === "offline" ? "Offline" : (root.type === "ethernet" ? "Ethernet" : (root.ssid || "Wi-Fi"))

	function zeros() {
		const out = [];
		for (let i = 0; i < 30; i += 1) out.push(0);
		return out;
	}

	function formatSpeed(bytesPerSecond) {
		const value = Math.max(0, Number(bytesPerSecond) || 0);
		if (value >= 1024 * 1024 * 1024) return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GB/s`;
		if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB/s`;
		if (value >= 1024) return `${(value / 1024).toFixed(1)} KB/s`;
		return `${Math.round(value)} B/s`;
	}

	function push(history, value) {
		const next = history.slice();
		next.push(Math.max(0, Number(value) || 0));
		while (next.length > root.historyLength) next.shift();
		return next;
	}

	function updateThroughput(raw) {
		if (root.iface === "") {
			root.upload = 0;
			root.download = 0;
			root.uploadHistory = root.push(root.uploadHistory, 0);
			root.downloadHistory = root.push(root.downloadHistory, 0);
			root.sampleReady = false;
			return;
		}
		const match = String(raw || "").match(new RegExp(`^\\s*${root.iface}:\\s*(.+)$`, "m"));
		if (!match) return;
		const fields = match[1].trim().split(/\s+/);
		if (fields.length < 16) return;
		const rx = Number(fields[0]) || 0;
		const tx = Number(fields[8]) || 0;
		if (!root.sampleReady) {
			root.lastRx = rx;
			root.lastTx = tx;
			root.sampleReady = true;
			return;
		}
		root.download = Math.max(0, (rx - root.lastRx) / 2);
		root.upload = Math.max(0, (tx - root.lastTx) / 2);
		root.lastRx = rx;
		root.lastTx = tx;
		root.uploadHistory = root.push(root.uploadHistory, root.upload);
		root.downloadHistory = root.push(root.downloadHistory, root.download);
	}

	function resetThroughput() {
		root.upload = 0;
		root.download = 0;
		root.lastRx = 0;
		root.lastTx = 0;
		root.sampleReady = false;
		root.uploadHistory = root.zeros();
		root.downloadHistory = root.zeros();
	}

	function applyStatus(raw) {
		const parsed = {};
		for (const line of String(raw || "").split("\n")) {
			const separator = line.indexOf("=");
			if (separator !== -1) parsed[line.slice(0, separator)] = line.slice(separator + 1);
		}
		const nextType = parsed.type || "offline";
		const nextIface = parsed.iface || "";
		const changed = nextIface !== root.iface;
		root.type = nextType;
		root.iface = nextIface;
		root.ip = parsed.ip || "";
		if (changed || nextType === "offline") root.resetThroughput();
		if (nextType === "wifi") {
			if (!wifiProc.running) wifiProc.running = true;
		} else {
			root.ssid = "";
			root.signal = -1;
		}
	}

	function disconnect() {
		if (!root.iface || root.type === "offline") return;
		if (root.type === "ethernet")
			Quickshell.execDetached(["sh", "-lc", `nmcli device set '${root.iface}' autoconnect no && nmcli device down '${root.iface}' || nmcli device disconnect '${root.iface}'`]);
		else
			Quickshell.execDetached(["sh", "-lc", `nmcli device disconnect '${root.iface}'`]);
		root.type = "offline";
		root.ip = "";
		root.resetThroughput();
	}

	Timer {
		running: Plugins.on("network")
		repeat: true
		interval: 2000
		triggeredOnStart: true
		onTriggered: {
			statusProc.running = true;
			netDev.reload();
		}
	}

	Process {
		id: statusProc
		command: ["sh", "-lc", `for iface in /sys/class/net/*; do
name=$(basename "$iface")
case "$name" in
  lo|docker*|br-*|virbr*|veth*|podman*|zt*|tun*|tap*) continue ;;
esac
state=$(cat "$iface/operstate" 2>/dev/null || printf 'down')
carrier=$(cat "$iface/carrier" 2>/dev/null || printf '0')
if [ -d "$iface/wireless" ]; then
  [ "$state" = "up" ] || [ "$carrier" = "1" ] || continue
  ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
  printf 'type=wifi\\niface=%s\\nip=%s\\n' "$name" "$ip"
  exit 0
fi
[ "$carrier" = "1" ] || [ "$state" = "up" ] || continue
ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
printf 'type=ethernet\\niface=%s\\nip=%s\\n' "$name" "$ip"
exit 0
done
printf 'type=offline\\niface=\\nip=\\n'`]
		stdout: StdioCollector {
			onStreamFinished: root.applyStatus(text)
		}
	}

	Process {
		id: wifiProc
		command: ["sh", "-lc", "nmcli -t -f active,ssid,signal dev wifi 2>/dev/null | grep '^yes' | head -n1"]
		stdout: StdioCollector {
			onStreamFinished: {
				const line = String(text || "").trim();
				if (line === "") return;
				const parts = line.split(":");
				root.signal = Number(parts[parts.length - 1]) || -1;
				root.ssid = parts.slice(1, parts.length - 1).join(":").replace(/\\:/g, ":");
			}
		}
	}

	FileView {
		id: netDev
		path: "/proc/net/dev"
		onLoaded: root.updateThroughput(text())
	}
}
