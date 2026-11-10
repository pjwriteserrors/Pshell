pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The fingerprint reader (plugin `fingerprint`; made on the ELAN 04f3:0c5e,
// a match-on-chip sensor that fprintd drives). scripts/fingerprint/
// fingerprint.py speaks to fprintd: the enrolled fingers, enrolling, testing
// and deleting them, the finger on the sensor; it reads where PAM asks for a
// finger and changes that through system.py under pkexec. The lock screen
// (views/overlays/LockScreen.qml) takes `lockScreen` and `lockTries` from
// here. fingerprint.json:
//
//   options: { lockScreen, lockTries, pamTries, pamTimeout, unlockAnimation }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("fingerprint")
	readonly property string script: `${Paths.scripts}/fingerprint/fingerprint.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var device: ({ online: false })
	property bool scanned: false
	property var pam: []
	property string busy: ""
	property string error: ""
	property bool fingerPresent: false
	property bool fingerNeeded: false
	// the running or last enrollment / test: { status, done, finger, stage, stages }
	property var enrollment: ({})
	property var test: ({})
	signal enrolled(string finger)
	// a finger unlocked something (any program's check): FingerprintUnlock plays
	property int unlocks: 0
	property string unlockOutput: ""
	signal matched(string finger, bool ok)

	readonly property bool online: root.device.online === true
	readonly property bool present: root.device.present === true
	readonly property var usb: root.device.usb ?? null
	readonly property var fingers: root.device.fingers ?? []
	readonly property var allFingers: root.device.all ?? []
	readonly property int stages: root.device.stages ?? 0
	readonly property bool wake: root.usb?.wakeup === "enabled"
	readonly property bool wakeRule: root.device.wakeRule === true

	readonly property var fingerNames: ({
		"left-little-finger": "Left little finger",
		"left-ring-finger": "Left ring finger",
		"left-middle-finger": "Left middle finger",
		"left-index-finger": "Left index finger",
		"left-thumb": "Left thumb",
		"right-thumb": "Right thumb",
		"right-index-finger": "Right index finger",
		"right-middle-finger": "Right middle finger",
		"right-ring-finger": "Right ring finger",
		"right-little-finger": "Right little finger",
		"any": "Any finger"
	})

	function nameOf(finger) {
		return root.fingerNames[finger] ?? finger;
	}

	// fprintd's results, as said to the user
	readonly property var statusText: ({
		"started": "Place your finger on the sensor",
		"enroll-stage-passed": "Lift and place it again",
		"enroll-retry-scan": "Again, please",
		"enroll-swipe-too-short": "Again, please",
		"enroll-finger-not-centered": "Move it a little – the middle of the finger on the sensor",
		"enroll-remove-and-retry": "Lift the finger and try again",
		"enroll-finish": "Once more to finish",
		"enroll-completed": "Enrolled",
		"enroll-failed": "Did not work",
		"enroll-data-full": "The sensor is full",
		"enroll-duplicate": "Already on the sensor from before – enroll once more to replace it",
		"enroll-disconnected": "The reader went away",
		"enroll-unknown-error": "The reader reported an error",
		"enroll-timeout": "No finger came",
		"verify-match": "Recognised",
		"verify-no-match": "Not recognised",
		"verify-retry-scan": "Again, please",
		"verify-swipe-too-short": "Again, please",
		"verify-finger-not-centered": "Move it a little – the middle of the finger on the sensor",
		"verify-remove-and-retry": "Lift the finger and try again",
		"verify-disconnected": "The reader went away",
		"verify-unknown-error": "The reader reported an error",
		"verify-timeout": "No finger came",
		"stopped": ""
	})

	function says(status) {
		return root.statusText[status] ?? status;
	}

	function enroll(finger) {
		root.enrollment = { status: "waiting", done: false, finger, stage: 0, stages: root.stages };
		root.send({ op: "enroll", finger });
	}

	function verify(finger) {
		root.test = { status: "waiting", done: false, finger };
		root.send({ op: "verify", finger });
	}

	function stop() {
		root.send({ op: "stop" });
	}

	function remove(finger) {
		root.send({ op: "delete", finger });
	}

	function removeAll() {
		root.send({ op: "delete-all" });
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	// PAM: one service on or off, the others as they are – one password
	function setPam(id, on) {
		root.send({ op: "system", args: ["pam", "--tries", root.pamTries, "--timeout", root.pamTimeout, `${id}=${on ? "on" : "off"}`] });
	}

	// tries and waiting time go to every service that takes the finger
	function applyPamOptions() {
		const on = root.pam.filter(s => s.state === "on" && s.id !== "lock" && s.id !== "sddm").map(s => `${s.id}=on`);
		if (on.length) root.send({ op: "system", args: ["pam", "--tries", root.pamTries, "--timeout", root.pamTimeout].concat(on) });
	}

	function setWake(on) {
		root.send({ op: "system", args: ["wake", on ? "on" : "off"] });
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ options: {} })
	property bool loaded: false
	readonly property var options: root.config.options ?? ({})
	readonly property bool lockScreen: root.option("lockScreen", true)
	readonly property int lockTries: root.option("lockTries", 5)
	readonly property int pamTries: root.option("pamTries", 3)
	readonly property int pamTimeout: root.option("pamTimeout", 30)
	readonly property bool unlockAnimation: root.option("unlockAnimation", true)

	function playUnlock() {
		root.unlockOutput = String(Popups.focusedScreen()?.name ?? "");
		root.unlocks++;
	}

	property bool watching: false
	onWatchingChanged: {
		if (root.watching) root.refresh();
		else root.stop();
	}

	function option(key, fallback) {
		return root.options[key] ?? fallback;
	}

	function setOption(key, value) {
		const options = Object.assign({}, root.options);
		options[key] = value;
		root.config = Object.assign({}, root.config, { options });
		saving.restart();
	}

	Timer {
		id: saving

		interval: 400
		onTriggered: file.setText(JSON.stringify(root.config, null, "\t") + "\n")
	}

	FileView {
		id: file

		path: Paths.stateFile("fingerprint.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = { options: data.options && typeof data.options === "object" ? data.options : {} };
			} catch (error) {
				console.warn("Fingerprint: fingerprint.json is not valid JSON");
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// ── the daemon ────────────────────────────────────────────────────────
	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "device":
			root.device = data;
			root.scanned = true;
			root.fingerPresent = data.fingerPresent === true;
			root.fingerNeeded = data.fingerNeeded === true;
			break;
		case "pam":
			root.pam = data.services ?? [];
			break;
		case "busy":
			root.busy = data.what ?? "";
			if (!root.busy) {
				if (root.enrollment.status && !root.enrollment.done) root.enrollment = Object.assign({}, root.enrollment, { done: true, status: root.enrollment.status === "waiting" ? "stopped" : root.enrollment.status });
				if (root.test.status && !root.test.done) root.test = Object.assign({}, root.test, { done: true, status: root.test.status === "waiting" ? "stopped" : root.test.status });
			}
			break;
		case "enroll":
			root.enrollment = data;
			if (data.status === "enroll-completed") {
				Sounds.play("saved");
				root.enrolled(data.finger ?? "");
			}
			break;
		case "verify":
			root.test = data;
			if (data.status === "verify-match" || data.status === "verify-no-match") {
				Sounds.play(data.status === "verify-match" ? "confirm" : "denied");
				root.matched(data.finger ?? "", data.status === "verify-match");
			}
			break;
		case "unlocked":
			if (root.unlockAnimation) root.playUnlock();
			break;
		case "finger":
			root.fingerPresent = data.present === true;
			root.fingerNeeded = data.needed === true;
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	Timer {
		id: clearError

		interval: 6000
		onTriggered: root.error = ""
	}

	Process {
		id: daemon

		running: root.enabled && root.loaded
		stdinEnabled: true
		command: ["python3", "-u", root.script]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(line)
		}
		onExited: {
			root.device = { online: false };
			root.busy = "";
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
