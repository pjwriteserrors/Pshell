pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth as Bt

// Bluetooth through BlueZ's D-Bus API (Quickshell.Bluetooth): power, scan,
// pair → trust → connect, disconnect, forget and battery levels. Everything
// is live, nothing is parsed or polled.
//
// scripts/bluetooth_agent.py is the default BlueZ agent: codes to compare
// (phones), codes to type (keyboards) and pairing requests coming from other
// devices end up in `request`; the Bluetooth page and a toast let the user
// answer. Services of trusted devices are allowed without asking.
//
// Every step is watched and ends in a visible state (connected, paired, or a
// short failure reason), so a click never ends silently. Calls that BlueZ
// would refuse (connect while connected …) are never made.
Singleton {
	id: root

	readonly property var adapter: Bt.Bluetooth.defaultAdapter
	readonly property bool available: root.adapter !== null
	readonly property bool powered: !!root.adapter?.enabled
	readonly property bool blocked: root.adapter?.state === Bt.BluetoothAdapterState.Blocked
	readonly property bool scanning: !!root.adapter?.discovering
	// kept for panels that raise it while a Bluetooth view is visible
	property int watchers: 0

	// running actions: address → { kind: "pair" | "connect", since }
	property var pending: ({})
	// short-lived results: address → text
	property var results: ({})
	// off: another program (or a test instance) handles pairing questions
	property bool agentEnabled: true
	// the agent's open question: { id, type, address, name, passkey }
	property var request: null
	// a code to type on the device: { address, name, passkey, entered }
	property var display: null

	readonly property var devices: {
		const list = root.adapter?.devices?.values ?? [];
		const out = [];
		for (const d of list) {
			const name = root.cleanName(d);
			// anonymous advertisers are noise unless they are already known
			if (name === "" && !d.paired && !d.connected) continue;
			out.push({
				address: String(d.address),
				name: name || String(d.address),
				icon: String(d.icon || ""),
				connected: !!d.connected,
				paired: !!d.paired,
				trusted: !!d.trusted,
				pairing: !!d.pairing,
				state: d.state,
				battery: d.batteryAvailable ? `${Math.round(d.battery * 100)}%` : ""
			});
		}
		out.sort((a, b) => {
			if (a.connected !== b.connected) return a.connected ? -1 : 1;
			if (a.paired !== b.paired) return a.paired ? -1 : 1;
			return a.name.localeCompare(b.name);
		});
		return out;
	}
	readonly property var connected: root.devices.filter(device => device.connected)
	readonly property string icon: !root.powered ? "bluetooth_off" : (root.connected.length > 0 ? "bluetooth_connect" : "bluetooth")
	readonly property string summary: {
		if (!root.available) return "No adapter";
		if (root.blocked) return "Blocked";
		if (!root.powered) return "Off";
		if (root.connected.length === 1) return root.connected[0].name || "1 device";
		if (root.connected.length > 1) return `${root.connected.length} devices`;
		return "On";
	}

	function cleanName(d) {
		const name = String(d?.name || d?.deviceName || "").trim();
		const address = String(d?.address || "");
		// BlueZ uses the address (with dashes) as the name of unnamed devices
		if (name === "" || name.replace(/-/g, ":").toUpperCase() === address.toUpperCase()) return "";
		return name;
	}

	function find(address) {
		return (root.adapter?.devices?.values ?? []).find(d => String(d.address) === String(address)) ?? null;
	}

	function deviceIcon(name, icon) {
		const hint = String(icon || "");
		if (hint.includes("headset") || hint.includes("headphone")) return "headphones";
		if (hint.includes("phone")) return "cellphone";
		if (hint.includes("mouse")) return "mouse";
		if (hint.includes("keyboard")) return "keyboard";
		if (hint.includes("speaker") || hint.includes("audio-card")) return "speaker_bluetooth";
		const n = String(name || "").toLowerCase();
		if (/bud|head|arctis|wh-|wf-|airpod|soundcore|soundpeats/.test(n)) return "headphones";
		if (/speaker|jbl|boom/.test(n)) return "speaker_bluetooth";
		if (n.includes("mouse") || n.includes("mx ")) return "mouse";
		if (n.includes("keyboard") || n.includes("keychron")) return "keyboard";
		if (/phone|pixel|galaxy|iphone/.test(n)) return "cellphone";
		if (/tv|cast/.test(n)) return "television";
		return "bluetooth";
	}

	// "…" at the end marks a running action (the panel shows a spinner)
	function statusFor(device) {
		if (!device) return "";
		if (device.pairing || root.pending[device.address]?.kind === "pair") return "Pairing...";
		if (device.state === Bt.BluetoothDeviceState.Connecting || (root.pending[device.address]?.kind === "connect" && !device.connected)) return "Connecting...";
		if (device.state === Bt.BluetoothDeviceState.Disconnecting) return "Disconnecting...";
		if (root.results[device.address]) return root.results[device.address];
		if (device.connected) return "Connected";
		return device.paired ? "Paired" : "Available";
	}

	function setPending(address, kind) {
		const next = Object.assign({}, root.pending);
		if (kind) next[address] = { kind: kind, since: Date.now() };
		else delete next[address];
		root.pending = next;
	}

	function setResult(address, text) {
		const next = Object.assign({}, root.results);
		if (text) next[address] = text;
		else delete next[address];
		root.results = next;
		if (text) resultClear.restart();
	}

	function togglePower() {
		if (!root.adapter) return;
		if (root.blocked) {
			// soft-blocked by rfkill: unblock first, then switch on
			Quickshell.execDetached(["rfkill", "unblock", "bluetooth"]);
			powerRetry.restart();
			return;
		}
		const on = !root.adapter.enabled;
		root.adapter.enabled = on;
		if (!on) {
			root.pending = {};
			root.results = {};
		}
	}

	// asked for before BlueZ answered: scan as soon as the adapter shows up
	property bool scanWanted: false

	onAdapterChanged: if (root.adapter && root.scanWanted) root.startScan()

	function startScan() {
		if (!root.adapter) {
			root.scanWanted = true;
			return;
		}
		root.scanWanted = false;
		if (!root.adapter.enabled) root.adapter.enabled = true;
		root.adapter.discovering = true;
		scanStop.restart();
	}

	function stopScan() {
		root.scanWanted = false;
		scanStop.stop();
		if (root.adapter?.discovering) root.adapter.discovering = false;
	}

	function connectDevice(d) {
		if (d.connected || d.state === Bt.BluetoothDeviceState.Connecting) return;
		d.connect();
	}

	function toggleDevice(address) {
		const d = root.find(address);
		if (!d || root.pending[address]) return;
		root.setResult(address, "");
		if (d.connected || d.state === Bt.BluetoothDeviceState.Connecting) {
			if (d.state !== Bt.BluetoothDeviceState.Disconnecting) d.disconnect();
		} else if (d.paired) {
			if (!d.trusted) d.trusted = true;
			root.setPending(address, "connect");
			root.connectDevice(d);
		} else if (!d.pairing) {
			root.setPending(address, "pair");
			d.pair();
		}
	}

	function forget(address) {
		const d = root.find(address);
		if (!d) return;
		if (d.pairing) d.cancelPair();
		root.setPending(address, "");
		root.setResult(address, "");
		d.forget();
	}

	// ── agent ──────────────────────────────────────────────────────────────
	function answer(accept, value) {
		const req = root.request;
		if (!req) return;
		root.request = null;
		const line = !accept ? `${req.id} reject` : (value !== undefined && value !== "" ? `${req.id} value ${value}` : `${req.id} accept`);
		agent.write(`${line}\n`);
	}

	function agentMessage(raw) {
		let msg;
		try {
			msg = JSON.parse(raw);
		} catch (error) {
			return;
		}
		const name = msg.name || msg.address || "Device";
		switch (msg.type) {
		case "confirm":
		case "authorize":
		case "service":
		case "passkey":
		case "pin": {
			// a newer question replaces an unanswered one
			if (root.request) agent.write(`${root.request.id} reject\n`);
			root.request = { id: msg.id, type: msg.type, address: msg.address, name: name, passkey: msg.passkey ?? "" };
			const title = msg.type === "confirm" ? `Pair with ${name}?` : (msg.type === "service" ? `Allow ${name}?` : (msg.type === "authorize" ? `${name} wants to pair` : `Code for ${name}`));
			const detail = msg.type === "confirm" ? msg.passkey : "";
			const reqId = msg.id;
			const answerable = msg.type === "confirm" || msg.type === "authorize" || msg.type === "service";
			Notifs.pushInternal("running", title, detail, {
				icon: "bluetooth",
				duration: 30000,
				actions: answerable ? [
					{ label: "Accept", icon: "check", run: () => { if (root.request?.id === reqId) root.answer(true); } },
					{ label: "Reject", icon: "close", run: () => { if (root.request?.id === reqId) root.answer(false); } }
				] : [
					{ label: "Enter code", icon: "dialpad", run: () => Popups.withFocusedScreen(screen => Popups.open("control", screen, "bluetooth")) }
				]
			});
			Haptics.play("attention");
			break;
		}
		case "display-passkey":
		case "display-pin":
			root.display = { address: msg.address, name: name, passkey: msg.passkey, entered: msg.entered ?? 0 };
			if (!msg.entered) {
				Notifs.pushInternal("running", `Type ${msg.passkey} on ${name}`, "then press Enter", { icon: "keyboard", duration: 30000 });
				Haptics.play("attention");
			}
			break;
		case "cancel":
			root.request = null;
			root.display = null;
			break;
		}
	}

	// keeps the agent alive while an adapter exists; restarts it if it dies
	Process {
		id: agent

		running: root.available && root.agentEnabled
		stdinEnabled: true
		command: ["python3", `${Quickshell.shellDir}/scripts/bluetooth_agent.py`]
		stdout: SplitParser {
			onRead: data => root.agentMessage(data)
		}
		onExited: {
			root.request = null;
			root.display = null;
			if (root.available && root.agentEnabled) agentRestart.restart();
		}
	}

	// a code shown for typing goes away once the device paired (or after a minute)
	Timer {
		running: root.display !== null
		repeat: true
		interval: 1000
		property int ticks: 0
		onRunningChanged: ticks = 0
		onTriggered: {
			ticks += 1;
			if (root.find(root.display?.address)?.paired || ticks > 60) root.display = null;
		}
	}

	Timer {
		id: agentRestart
		interval: 3000
		onTriggered: if (root.available && root.agentEnabled && !agent.running) agent.running = true
	}

	// follows running actions until they end one way or the other
	function checkPending() {
		const now = Date.now();
		for (const address of Object.keys(root.pending)) {
			const job = root.pending[address];
			const d = root.find(address);
			const age = now - job.since;
			if (!d) {
				root.setPending(address, "");
				continue;
			}
			if (job.kind === "pair") {
				if (d.paired) {
					// paired: trust it so it may reconnect by itself, then connect
					// (headsets often connect on their own right after pairing)
					if (!d.trusted) d.trusted = true;
					root.display = null;
					root.setPending(address, "connect");
					root.connectDevice(d);
				} else if ((!d.pairing && age > 2500) || age > 60000) {
					if (d.pairing) d.cancelPair();
					root.display = null;
					root.setPending(address, "");
					root.setResult(address, "Pairing failed");
					Haptics.play("taskFailed");
				}
			} else if (job.kind === "connect") {
				if (d.connected) {
					root.setPending(address, "");
				} else if ((d.state === Bt.BluetoothDeviceState.Disconnected && age > 4000) || age > 30000) {
					root.setPending(address, "");
					root.setResult(address, "Couldn't connect");
					Haptics.play("taskFailed");
				}
			}
		}
	}

	Timer {
		running: Object.keys(root.pending).length > 0
		repeat: true
		interval: 500
		onTriggered: root.checkPending()
	}

	Timer {
		id: resultClear
		interval: 6000
		onTriggered: root.results = {}
	}

	// discovery costs power and radio time: stop on its own
	Timer {
		id: scanStop
		interval: 25000
		onTriggered: root.stopScan()
	}

	// stop scanning once no Bluetooth view is visible any more
	onWatchersChanged: if (root.watchers === 0) root.stopScan()

	Timer {
		id: powerRetry
		interval: 700
		onTriggered: if (root.adapter && !root.adapter.enabled) root.adapter.enabled = true
	}
}
