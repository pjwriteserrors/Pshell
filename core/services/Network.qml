pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// The connection from NetworkManager (Quickshell.Networking, as it changes):
// a wired link first, else Wi-Fi with its network and signal. The address is
// asked once a link comes up; the throughput is read from /proc/net/dev
// every two seconds while something shows it (`watchers`).
Singleton {
	id: root

	readonly property int historyLength: 30
	readonly property bool enabled: Plugins.on("network")
	readonly property var devices: root.enabled ? Networking.devices.values : []
	readonly property var device: root.devices.find(d => d.connected && d.type === DeviceType.Wired)
		?? root.devices.find(d => d.connected && d.type === DeviceType.Wifi) ?? null
	readonly property var wifi: root.device?.type === DeviceType.Wifi ? (root.device.networks.values.find(n => n.connected) ?? null) : null
	readonly property string type: !root.device ? "offline" : (root.device.type === DeviceType.Wired ? "ethernet" : "wifi")
	readonly property string iface: root.device?.name ?? ""
	property string ip: ""
	readonly property string ssid: root.wifi?.name ?? ""
	readonly property int signal: root.wifi ? Math.round(root.wifi.signalStrength * 100) : -1
	property real upload: 0
	property real download: 0
	property real lastRx: 0
	property real lastTx: 0
	property bool sampleReady: false
	property var uploadHistory: root.zeros()
	property var downloadHistory: root.zeros()
	// views that show the throughput raise this while they are up
	property int watchers: 0

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

	onIfaceChanged: {
		root.resetThroughput();
		root.ip = "";
		root.askAddress();
	}
	// another Wi-Fi on the same device has another address
	onSsidChanged: root.askAddress()

	function askAddress() {
		if (root.iface === "") return;
		addressProc.running = false;
		addressProc.command = ["ip", "-j", "-4", "addr", "show", "dev", root.iface, "scope", "global"];
		addressProc.running = true;
	}

	function zeros() {
		const out = [];
		for (let i = 0; i < 30; i += 1) out.push(0);
		return out;
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

	function disconnect() {
		const device = root.device;
		if (!device) return;
		// a cable would come right back: it stays down until it is asked for
		if (device.type === DeviceType.Wired) device.autoconnect = false;
		device.disconnect();
	}

	Timer {
		running: root.enabled && root.watchers > 0
		repeat: true
		interval: 2000
		triggeredOnStart: true
		onTriggered: netDev.reload()
		onRunningChanged: if (!running) root.resetThroughput()
	}

	Process {
		id: addressProc

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.ip = JSON.parse(text)[0]?.addr_info?.[0]?.local ?? "";
				} catch (error) {
					root.ip = "";
				}
			}
		}
	}

	FileView {
		id: netDev
		path: "/proc/net/dev"
		onLoaded: root.updateThroughput(text())
	}
}
