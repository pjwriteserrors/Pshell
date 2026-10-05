pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.core.phone

// The shell's end of the phone link (docs/mobile.md). The daemon
// (scripts/phone) holds the connection to the Android app; this service
// talks to it over a unix socket. The topics in core/phone publish what
// the shell knows and run what the phone asks for; nothing else in the
// shell learns about the phone.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("phone")
	// the daemon answered; Socket.connected only says that connecting was asked for
	property bool connected: false
	// shell topics somebody is looking at right now
	property var wanted: []
	// returned by a topic's call() that answers later through done()
	readonly property var later: ({})

	// a file caught half-written (a checkout, an editor) keeps the last good one
	property var catalogue: ({})

	function loadCatalogue() {
		try {
			root.catalogue = JSON.parse(protocolFile.text()).topics;
		} catch (error) {
			console.warn("Phone: mobile/protocol/protocol.json is not valid JSON (yet)");
		}
	}

	// ── what the daemon tells the shell ────────────────────────────────────
	// [{ id, name, model, paired, seen, connected, address }]
	property var devices: []
	// { active, uri, qr, expires }
	property var pairing: ({ active: false })
	// device id → the phone's own topics: { "phone.status": { battery, … }, … }
	property var remote: ({})

	readonly property var device: root.devices.find(d => d.connected) ?? root.devices[0] ?? null
	readonly property bool paired: root.devices.length > 0

	// ── what the views show ────────────────────────────────────────────────
	// Without the phone app's plugin, a KDE Connect setup still works: the
	// views ask this service either way.
	readonly property bool legacy: !root.enabled && Plugins.on("kdeconnect")
	readonly property bool offered: root.enabled || root.legacy
	readonly property string plugin: root.enabled ? "phone" : "kdeconnect"
	readonly property bool available: root.legacy ? KdeConnect.available : root.enabled
	readonly property bool reachable: root.legacy ? KdeConnect.reachable : !!root.device?.connected
	readonly property string name: root.legacy ? KdeConnect.name : (root.device?.name ?? "Phone")
	readonly property var status: root.of("phone.status")
	readonly property int battery: root.legacy ? KdeConnect.battery : (root.reachable ? (root.status?.battery ?? -1) : -1)
	readonly property bool charging: root.legacy ? KdeConnect.charging : !!root.status?.charging
	readonly property string network: root.legacy ? String(KdeConnect.device?.network ?? "") : String(root.status?.network ?? "")
	readonly property string batteryIcon: {
		if (root.battery < 0) return "cellphone";
		if (root.charging) return "battery_charging";
		const step = Math.max(10, Math.min(90, Math.round(root.battery / 10) * 10));
		return root.battery >= 95 ? "battery" : `battery_${step}`;
	}
	readonly property string summary: {
		if (root.legacy) return KdeConnect.summary;
		if (!root.paired) return "Not paired";
		if (!root.reachable) return "Not reachable";
		return root.battery >= 0 ? `${root.battery}%${root.charging ? " · charging" : ""}` : "Connected";
	}
	// set by "Send file": the launcher's file browser sends the next file
	// it opens to the phone instead of opening it
	property bool pickingFile: false
	// phone panels raise this while they are visible
	property int watchers: 0

	Binding {
		target: KdeConnect
		property: "watchers"
		value: root.watchers
		when: root.legacy
	}

	function refresh() {
		if (root.legacy) KdeConnect.refresh();
	}

	// an event of a phone: (topic, name, data, device id)
	signal event(string topic, string name, var data, string device)

	function of(topic, device) {
		return root.remote[device ?? root.device?.id ?? ""]?.[topic] ?? null;
	}

	function allowed(topic) {
		const spec = root.catalogue[topic];
		return !!spec && root.enabled && (spec.plugins || []).every(plugin => Plugins.on(plugin));
	}

	// ── sending ────────────────────────────────────────────────────────────
	function sendRaw(text) {
		if (!root.connected) return false;
		socket.write(text + "\n");
		socket.flush();
		return true;
	}

	function send(message) {
		return root.sendRaw(JSON.stringify(message));
	}

	function emit(topic, name, data, device) {
		const message = { type: "event", topic: topic, name: name, data: data || {} };
		if (device) message.device = device;
		return root.send(message);
	}

	// calls a topic of the daemon or the phone; done(data, error) is optional
	property int callCount: 0
	property var callbacks: ({})
	function call(topic, action, args, done, options) {
		root.callCount += 1;
		const id = `s${root.callCount}`;
		if (done) root.callbacks[id] = done;
		const message = Object.assign({ type: "call", id: id, topic: topic, action: action, args: args || {} }, options || {});
		if (!root.send(message) && done) {
			delete root.callbacks[id];
			done(null, { code: "unreachable", message: "The phone daemon is not running" });
		}
	}

	// ── pairing ────────────────────────────────────────────────────────────
	function startPairing() {
		root.call("pairing", "start");
	}

	function stopPairing() {
		root.call("pairing", "stop");
	}

	function unpair(id) {
		root.call("devices", "remove", { id: id });
	}

	// ── what the shell sends to the phone ──────────────────────────────────
	function report(error, done) {
		if (error) Notifs.pushInternal("error", "Phone", error.code === "unreachable" ? "Not connected" : String(error.message || error.code));
		else if (done) Notifs.pushInternal("done", done, root.name, { icon: "cellphone" });
	}

	function shareFile(path) {
		if (root.legacy) KdeConnect.shareFile(path);
		else root.sendFiles([path]);
	}

	function shareUrl(url) {
		if (root.legacy) KdeConnect.shareUrl(url);
		else root.sendUrl(url);
	}

	// the PC's clipboard, said out loud: it reaches the phone by itself, this
	// also tells the phone to show it
	function sendClipboard() {
		if (root.legacy) return KdeConnect.sendClipboard();
		clipboardReader.running = true;
	}

	function sendClipboardEntry(entry) {
		if (root.legacy) return KdeConnect.sendClipboardEntry(entry);
		if (!entry?.id) return;
		const sender = entrySender.createObject(root, { image: !!entry.isImage });
		const id = String(entry.id).replace(/[^0-9]/g, "");
		const file = `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/qs-phone-${id}.${entry.extension || "png"}`;
		sender.command = entry.isImage ? ["sh", "-c", 'cliphist decode "$1" > "$2" && printf %s "$2"', "sh", id, file] : ["cliphist", "decode", id];
		sender.running = true;
	}

	Process {
		id: clipboardReader

		command: ["wl-paste", "--no-newline", "--type", "text"]
		stdout: StdioCollector {
			onStreamFinished: root.sendText(text)
		}
	}

	Component {
		id: entrySender

		Process {
			id: sender

			property bool image: false

			stdout: StdioCollector {
				onStreamFinished: {
					if (sender.image) root.sendFiles([String(text).trim()]);
					else root.sendText(text);
				}
			}
			onExited: sender.destroy()
		}
	}

	function sendFiles(paths) {
		root.call("files", "send", { paths: paths.map(path => String(path)) }, (data, error) => root.report(error, paths.length === 1 ? "File sent" : `${paths.length} files sent`), { timeout: 60 });
	}

	function sendUrl(url, position, title) {
		const args = { url: String(url) };
		if (position > 0) args.position = Math.floor(position);
		if (title) args.title = String(title);
		root.call("handoff", "send", args, (data, error) => {
			if (!error && data?.opened === false)
				Notifs.pushInternal("done", "Link waits on the phone", "In a notification: the app may not open things from the background yet (Continue, in the app)", { icon: "cellphone", duration: 8000 });
			else root.report(error, "Opened on the phone");
		}, { timeout: 20 });
	}

	function sendText(text) {
		const value = String(text || "").trim();
		if (value === "") return;
		if (root.legacy) return KdeConnect.sendText(value);
		if (/^https?:\/\/\S+$/.test(value)) root.sendUrl(value);
		else root.call("handoff", "send", { text: value }, (data, error) => root.report(error, "Text sent"), { timeout: 20 });
	}

	// Bluetooth headphones connected to the PC are let go, so the phone can
	// take them; returns who they were, or null
	function releaseHeadset() {
		if (!Plugins.on("bluetooth")) return null;
		const headset = Bluetooth.devices.find(device => device.connected && /audio|headset|headphone/i.test(`${device.icon} ${device.name}`));
		if (!headset) return null;
		Bluetooth.toggleDevice(headset.address);
		return { address: headset.address, name: headset.name };
	}

	// what plays on the PC continues on the phone, where it is now
	function handoffMedia() {
		const url = String(Media.player?.metadata?.["xesam:url"] ?? "");
		if (!/^https?:/.test(url)) return root.report({ code: "no-url", message: "The player does not say what it plays" });
		const args = { url: url, position: Math.floor(Media.position), title: Media.title };
		const headset = root.releaseHeadset();
		if (headset) args.headset = headset;
		root.call("handoff", "send", args, (data, error) => {
			if (!error && data?.opened === false)
				Notifs.pushInternal("done", "Link waits on the phone", "In a notification: the app may not open things from the background yet (Continue, in the app)", { icon: "cellphone", duration: 8000 });
			else root.report(error, headset ? `Opened on the phone, ${headset.name} let go` : "Opened on the phone");
		}, { timeout: 20 });
		if (Media.player?.canPause) Media.player.pause();
	}

	function ring() {
		if (root.legacy) return KdeConnect.ring();
		root.call("phone.find", "ring", {}, (data, error) => root.report(error, "Ringing"));
	}

	// ── topics (core/phone) ────────────────────────────────────────────────
	property var topics: ({})

	function register(topic) {
		root.topics[topic.name] = topic;
	}

	function answer(message) {
		const reply = (ok, payload) => {
			if (message.id === undefined) return;
			root.send(ok ? { type: "result", id: message.id, ok: true, data: payload ?? {} }
				: { type: "result", id: message.id, ok: false, error: payload });
		};
		const topic = root.topics[message.topic];
		if (!topic) return reply(false, { code: "unknown-topic", message: String(message.topic) });
		if (!topic.allowed) return reply(false, { code: "plugin-off", message: String(message.topic) });
		const done = data => reply(true, data);
		done.fail = (code, text) => reply(false, { code: code, message: text || code });
		done.device = message.device || "";
		try {
			const result = topic.call(String(message.action), message.args || {}, done);
			if (result !== root.later) reply(true, result);
		} catch (error) {
			const text = String(error?.message ?? error);
			reply(false, { code: text === "unknown-action" ? text : "failed", message: text });
		}
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (message.type) {
		case "want":
			root.connected = true;
			root.wanted = message.topics || [];
			break;
		case "call":
			root.answer(message);
			break;
		case "result": {
			const done = root.callbacks[message.id];
			if (!done) break;
			delete root.callbacks[message.id];
			done(message.ok ? message.data : null, message.ok ? null : message.error);
			break;
		}
		case "state":
			if (message.device) {
				const next = Object.assign({}, root.remote);
				next[message.device] = Object.assign({}, next[message.device], { [message.topic]: message.data });
				root.remote = next;
			} else if (message.topic === "devices") {
				root.devices = message.data || [];
			} else if (message.topic === "pairing") {
				root.pairing = message.data || { active: false };
			}
			break;
		case "event":
			root.event(String(message.topic), String(message.name), message.data || {}, String(message.device || ""));
			break;
		}
	}

	Topics {
		link: root
	}

	Socket {
		id: socket

		path: `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/pshell/phone.sock`
		parser: SplitParser {
			onRead: line => root.receive(line)
		}
		onConnectionStateChanged: {
			if (!socket.connected) return root.dropped();
			// the daemon answers the hello with what is wanted; that is the sign it is there
			socket.write(JSON.stringify({ type: "hello", role: "shell" }) + "\n");
			const remoteTopics = Object.keys(root.catalogue).filter(name => root.catalogue[name].owner !== "shell");
			socket.write(JSON.stringify({ type: "sub", topics: remoteTopics }) + "\n");
			socket.flush();
		}
		onError: root.dropped()
	}

	function dropped() {
		root.connected = false;
		root.wanted = [];
		root.callbacks = {};
	}

	// the daemon may start after the shell, or restart
	// The daemon may start after the shell, or restart. Rather than trust
	// that every loss is announced, this looks every tick: without an
	// answering daemon it asks again, and asking again only works once the
	// failed attempt was taken back, which takes a turn of the event loop.
	Timer {
		running: root.enabled
		repeat: true
		interval: 1500
		triggeredOnStart: true
		property bool ask: true
		onTriggered: {
			if (socket.connected && root.connected) return;
			if (!socket.connected && root.connected) root.dropped();
			socket.connected = ask;
			ask = !ask;
		}
	}

	onEnabledChanged: if (!root.enabled) socket.connected = false

	FileView {
		id: protocolFile

		path: `${Quickshell.shellDir}/mobile/protocol/protocol.json`
		blockLoading: true
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.loadCatalogue()
	}
}
