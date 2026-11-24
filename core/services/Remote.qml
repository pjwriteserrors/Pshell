pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Remote PCs (plugin `remote-pcs`, docs/core.md "Remote power"): the PCs and
// laptops pshell-core knows, on or off, and waking one all the way into a
// stream: magic packet → it powers up → it signs its user in (its boot
// helper takes core's ticket) → Sunshine starts there → Moonlight connects
// here. Each PC plays both parts: this service also reports its own session
// to core, starts Sunshine when a wake asked for it, takes a pairing PIN and
// a shutdown relayed by core. Everything goes through Netcore (the NAS daemon).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("remote-pcs") && Netcore.enabled
	readonly property bool active: root.enabled && Netcore.active
	readonly property string script: `${Paths.scripts}/remote/remote.py`

	// [{ id, name, kind, mac, ip, online, since, last_seen, session, user, stream, host, waking, ticket }]
	property var devices: []
	property bool loaded: false
	property string error: ""
	// someone looks: the popup is up
	property bool watched: false

	readonly property string selfId: String(Netcore.me?.device?.id ?? "")
	readonly property var others: root.devices.filter(device => device.id !== root.selfId)
	readonly property var self: root.devices.find(device => device.id === root.selfId) ?? null

	// what this PC has: { host, moonlight: [cmd…] | null, sunshine, sunshine_running, creds }
	property var local: ({})
	readonly property bool hasMoonlight: Array.isArray(root.local?.moonlight) && root.local.moonlight.length > 0

	// ── the journey ────────────────────────────────────────────────────────
	// the PC being woken, "" while none is
	property string target: ""
	// what the wake should lead to
	property bool wantLogin: true
	property bool wantStream: true
	property bool wantConnect: true
	// "packet" | "power" | "login" | "sunshine" | "moonlight" | "done" | "failed"
	property string phase: ""
	property string failedPhase: ""
	property string failure: ""
	// "moonlight" (not installed), "creds" (Sunshine's login on the other PC)
	property string remedy: ""
	property real phaseAt: 0
	property bool pairing: false
	property string pin: ""
	readonly property var phases: ["packet", "power", "login", "sunshine", "moonlight"]
	readonly property bool travelling: root.target !== "" && root.phase !== "" && root.phase !== "done" && root.phase !== "failed"
	readonly property var targetDevice: root.devices.find(device => device.id === root.target) ?? null
	// a moonlight window of ours is up
	readonly property var moonWindow: Niri.windows.find(window => /moonlight/i.test(String(window.app_id ?? ""))) ?? null

	signal arrived(string id)

	function device(id) {
		return root.devices.find(each => each.id === id) ?? null;
	}

	function phaseIndex(phase) {
		if (phase === "done") return root.phases.length;
		return root.phases.indexOf(phase);
	}

	// which steps this wake walks
	function walks(phase) {
		switch (phase) {
		case "login": return root.wantLogin;
		case "sunshine": return root.wantStream;
		case "moonlight": return root.wantConnect;
		}
		return true;
	}

	function refresh() {
		if (!root.active) return;
		Netcore.call("GET", "/api/power", null, (data, error) => {
			if (error) {
				root.error = error;
				return;
			}
			root.error = "";
			root.take(data.devices ?? []);
		});
	}

	function take(devices) {
		if (JSON.stringify(devices) !== JSON.stringify(root.devices)) root.devices = devices;
		root.loaded = true;
		root.follow();
		root.serveSelf();
	}

	function readLocal() {
		if (!localReader.running) localReader.running = true;
	}

	// ── waking ─────────────────────────────────────────────────────────────
	function wake(id) {
		const d = root.device(id);
		if (!d || root.travelling) return;
		root.target = id;
		root.failure = "";
		root.failedPhase = "";
		root.remedy = "";
		root.pin = "";
		// a stream needs a session, a connection needs a stream
		if (root.wantConnect) root.wantStream = true;
		if (root.wantStream) root.wantLogin = true;
		if (d.online && d.session && (!root.wantStream || d.stream)) {
			root.go(root.wantConnect ? "moonlight" : "done");
			return;
		}
		root.go("packet");
		Netcore.call("POST", `/api/power/${id}/wake`, { login: root.wantLogin, stream: root.wantStream }, (data, error) => {
			if (error) {
				root.fail("packet", error);
				return;
			}
			if (data?.device) root.take(root.devices.map(each => each.id === id ? data.device : each));
			// the packet's flight is worth seeing even when it is quicker
			packetFlight.restart();
		});
	}

	function connect(id) {
		const d = root.device(id);
		if (!d || root.travelling) return;
		root.target = id;
		root.failure = "";
		root.failedPhase = "";
		root.remedy = "";
		root.go("moonlight");
	}

	function retry() {
		if (root.phase !== "failed" || root.target === "") return;
		const from = root.failedPhase || "packet";
		root.failure = "";
		root.remedy = "";
		root.failedPhase = "";
		if (from === "packet" || from === "power") root.wake(root.target);
		else root.go(from);
	}

	function cancel() {
		if (root.target !== "" && root.travelling) Netcore.call("DELETE", `/api/power/${root.target}/wake`, null, null);
		moonProc.running = false;
		pairProc.running = false;
		root.dismiss(true);
	}

	function dismiss(force) {
		if (root.travelling && !force) return;
		root.target = "";
		root.phase = "";
		root.failure = "";
		root.failedPhase = "";
		root.remedy = "";
		root.pairing = false;
	}

	function fail(phase, message, remedy) {
		root.failedPhase = phase;
		root.failure = message || "Something went wrong";
		root.remedy = remedy || "";
		root.phase = "failed";
		Sounds.play("error");
	}

	function go(phase) {
		root.phase = phase;
		root.phaseAt = Date.now();
		if (phase === "moonlight") root.stream();
		if (phase === "done") {
			Sounds.play("taskDone");
			root.arrived(root.target);
		}
	}

	// the next step once the PC says it is there
	function follow() {
		if (!root.travelling || packetFlight.running) return;
		const d = root.targetDevice;
		if (!d) return;
		const next = () => {
			for (let i = root.phaseIndex(root.phase) + 1; i < root.phases.length; i++) {
				if (root.walks(root.phases[i])) return root.phases[i];
			}
			return "done";
		};
		const reached = {
			"packet": true,
			"power": d.online,
			"login": d.session,
			"sunshine": d.stream
		};
		if (root.phase in reached && reached[root.phase]) {
			root.go(next());
			root.follow();
		}
	}

	// a step that takes too long
	readonly property var patience: ({ "power": 240, "login": 120, "sunshine": 90 })

	Timer {
		interval: 1000
		repeat: true
		running: root.travelling
		onTriggered: {
			const limit = root.patience[root.phase];
			if (!limit || Date.now() - root.phaseAt < limit * 1000) return;
			const d = root.targetDevice;
			const name = d?.name ?? "The PC";
			switch (root.phase) {
			case "power":
				root.fail("power", `${name} did not wake up – wake-on-LAN off, or ErP on in its BIOS?`);
				break;
			case "login":
				root.fail("login", `${name} is on but nobody signed in – is its remote login installed (system/install-remote-login.sh)?`);
				break;
			case "sunshine":
				root.fail("sunshine", `Sunshine did not start on ${name}`);
				break;
			}
		}
	}

	Timer {
		id: packetFlight

		interval: 1400
		onTriggered: {
			if (root.phase !== "packet") return;
			root.go("power");
			root.follow();
		}
	}

	// ── Moonlight, here ────────────────────────────────────────────────────
	function stream() {
		const d = root.targetDevice;
		if (!d) return;
		if (!root.hasMoonlight) {
			root.fail("moonlight", "Moonlight is not installed here", "moonlight");
			return;
		}
		if (root.moonWindow) {
			Niri.focusWindow(root.moonWindow.id);
			root.go("done");
			return;
		}
		if (!d.ip) {
			root.fail("moonlight", `No address of ${d.name} is known`);
			return;
		}
		moonProc.command = root.local.moonlight.concat(["stream", d.ip, "Desktop"]);
		moonProc.running = true;
	}

	function pair() {
		const d = root.targetDevice;
		if (!d) return;
		root.pairing = true;
		root.pin = String(1000 + Math.floor(Math.random() * 9000));
		Netcore.call("POST", `/api/power/${d.id}/pair`, { pin: root.pin, name: String(root.local?.host || "Pshell") }, (data, error) => {
			if (error) {
				root.pairing = false;
				root.fail("moonlight", error);
				return;
			}
			pairProc.command = root.local.moonlight.concat(["pair", d.ip, "--pin", root.pin]);
			pairProc.running = true;
		});
	}

	function installMoonlight() {
		Quickshell.execDetached(Terminal.command({ appId: "pshell-remote-install", title: "Pshell · Moonlight", columns: 80, rows: 16 },
			["sh", "-c", "sudo pacman -S --needed moonlight-qt; printf '\\n  Press Enter to close.'; read _"]));
		installWatch.restart();
	}

	Timer {
		id: installWatch

		interval: 3000
		repeat: true
		property int left: 60
		onTriggered: {
			root.readLocal();
			if (root.hasMoonlight || --left <= 0) {
				stop();
				left = 60;
				if (root.hasMoonlight && root.phase === "failed" && root.remedy === "moonlight") root.retry();
			}
		}
	}

	Process {
		id: moonProc

		property real startedAt: 0

		onRunningChanged: if (running) startedAt = Date.now()
		stdout: StdioCollector {
			id: moonOut
		}
		stderr: StdioCollector {
			id: moonErr
		}
		onExited: code => {
			const text = `${moonOut.text}\n${moonErr.text}`;
			if (root.phase !== "moonlight") return;
			if (/not.{0,20}pair|pair.{0,20}first|unpaired/i.test(text) && !root.pairing) {
				root.pair();
				return;
			}
			// a stream that ran a while and ended is a stream that was used
			if (Date.now() - moonProc.startedAt > 15000) {
				root.dismiss(true);
				return;
			}
			const line = text.split("\n").map(l => l.trim()).filter(l => l).pop() ?? "";
			root.fail("moonlight", line || `Moonlight stopped (${code})`);
		}
	}

	Process {
		id: pairProc

		stdout: StdioCollector {
			id: pairOut
		}
		stderr: StdioCollector {
			id: pairErr
		}
		onExited: code => {
			root.pairing = false;
			if (root.phase !== "moonlight") return;
			if (code === 0 && !/fail|error/i.test(pairErr.text)) {
				root.stream();
				return;
			}
			root.fail("moonlight", "Pairing failed – Sunshine's login may be unknown over there", "creds");
		}
	}

	// the stream window is up: arrived
	onMoonWindowChanged: if (root.moonWindow && root.phase === "moonlight") root.go("done")

	// ── this PC's own part ────────────────────────────────────────────────
	property bool sunshineStarting: false
	property bool reportAfterRead: false
	property var seenNonces: ({})

	function report(extra) {
		if (!root.active || root.selfId === "") return;
		const body = Object.assign({ user: Quickshell.env("USER") || "", host: String(root.local?.host || ""), stream: !!root.local?.sunshine_running }, extra || {});
		Netcore.call("PUT", "/api/power/self", body, (data, error) => {
			if (!error && data?.stream && !root.local?.sunshine_running) root.startSunshine(true);
		});
	}

	// a wake asked for a stream: Sunshine starts here
	function serveSelf() {
		const me = root.self;
		if (me?.ticket?.stream && me.session && !root.local?.sunshine_running) root.startSunshine(true);
	}

	function startSunshine(fromTicket) {
		if (root.sunshineStarting) return;
		root.sunshineStarting = true;
		sunshineProc.fromTicket = !!fromTicket;
		sunshineProc.command = ["python3", root.script, "sunshine", "start"];
		sunshineProc.running = true;
	}

	Process {
		id: sunshineProc

		property bool fromTicket: false

		stdout: StdioCollector {
			id: sunshineOut
		}
		onExited: code => {
			root.sunshineStarting = false;
			root.readLocal();
			if (code === 0) root.report({ stream: true, stream_taken: sunshineProc.fromTicket });
			else console.warn(`Remote: Sunshine: ${sunshineOut.text}`);
		}
	}

	function once(message) {
		const nonce = String(message.nonce ?? "");
		if (!nonce || root.seenNonces[nonce]) return false;
		const next = Object.assign({}, root.seenNonces);
		next[nonce] = true;
		root.seenNonces = next;
		return true;
	}

	Process {
		id: pinProc

		stdout: StdioCollector {
			id: pinOut
		}
		onExited: code => {
			if (code === 3) Notifs.pushInternal("error", "Moonlight pairing", "Sunshine's login is not known here – set it in Remote PCs", { icon: "weather_night", app: "remote" });
			else if (code !== 0) console.warn(`Remote: pin: ${pinOut.text}`);
		}
	}

	Connections {
		target: Nas
		enabled: root.enabled

		function onCoreEvent(message) {
			switch (message.type) {
			case "power":
				root.take(message.devices ?? []);
				break;
			case "power_pair":
				if (message.device !== root.selfId || !root.once(message)) return;
				pinProc.command = ["python3", root.script, "pin", String(message.pin), String(message.name || "Moonlight")];
				pinProc.running = true;
				break;
			case "power_command":
				if (message.device !== root.selfId || !root.once(message)) return;
				switch (message.action) {
				case "shutdown":
					Quickshell.execDetached(["systemctl", "poweroff"]);
					break;
				case "reboot":
					Quickshell.execDetached(["systemctl", "reboot"]);
					break;
				case "lock":
					Session.lock();
					break;
				case "sunshine":
					root.startSunshine(false);
					break;
				}
				break;
			}
		}
	}

	// Sunshine's web login on this PC, for pairing without anyone here
	function setCreds(user, password, done) {
		credsProc.done = done ?? null;
		credsProc.password = String(password);
		credsProc.command = ["python3", root.script, "creds", String(user)];
		credsProc.running = true;
	}

	Process {
		id: credsProc

		property var done: null
		property string password: ""

		stdinEnabled: true
		onStarted: {
			credsProc.write(credsProc.password + "\n");
			credsProc.password = "";
		}
		stdout: StdioCollector {
			id: credsOut
		}
		onExited: code => {
			let error = "";
			if (code !== 0) {
				try {
					error = JSON.parse(credsOut.text).error ?? "Failed";
				} catch (e) {
					error = "Failed";
				}
			}
			root.readLocal();
			if (credsProc.done) credsProc.done(error);
		}
	}

	function command(id, action) {
		Netcore.call("POST", `/api/power/${id}/command`, { action: action }, (data, error) => {
			if (error) Notifs.pushInternal("error", "Remote PCs", error, { icon: "power", app: "remote" });
		});
	}

	Process {
		id: localReader

		command: ["python3", root.script, "status"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(text);
					if (JSON.stringify(data) !== JSON.stringify(root.local)) root.local = data;
				} catch (e) {}
				if (root.reportAfterRead) {
					root.reportAfterRead = false;
					root.report();
				}
			}
		}
	}

	// the session report, also a heartbeat
	Timer {
		interval: 60000
		repeat: true
		triggeredOnStart: true
		running: root.active && root.selfId !== ""
		onTriggered: {
			root.reportAfterRead = true;
			root.readLocal();
		}
	}

	// while someone looks or a wake runs, a steady look (events may be late)
	Timer {
		interval: root.travelling ? 2500 : 6000
		repeat: true
		triggeredOnStart: true
		running: root.active && (root.watched || root.travelling)
		onTriggered: root.refresh()
	}

	onWatchedChanged: if (root.watched) root.readLocal()
}
