pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The virtual machines of libvirt and their launch (the `vm-launcher`
// plugin, scripts/vm.py). A launch walks three steps: the drives the disk
// images live on are mounted (and a drive the machine gets whole must not be
// mounted on the host), the machine starts, Looking Glass comes up and waits
// for Windows; the launch is done once its host application answers.
//
// The launch lives here, not in the popup: closing the popup leaves it
// running. Status is read only while the popup is up, the phone looks or a
// launch runs.
Singleton {
	id: root

	readonly property string script: `${Paths.scripts}/vm.py`
	readonly property string logPath: `${Paths.runtime}/looking-glass.log`

	property var vms: []
	property bool loaded: false
	property string error: ""
	// someone looks: the popup is up
	property bool watched: false
	// someone looks from elsewhere: the phone app
	property bool remote: false

	// ── the launch ─────────────────────────────────────────────────────────
	// the machine being launched, "" while none is
	property string target: ""
	// "storage" | "start" | "display" | "done" | "failed"
	property string step: ""
	// the step that failed, and why
	property string failedStep: ""
	property string failure: ""
	// what would help: "root" (a password once), "busy" (a drive to free)
	property string remedy: ""
	property var busy: []
	// a terminal with sudo is open for `allow`
	property bool authorizing: false
	// a shutdown, kill or unmount under way, by machine
	property var pending: ({})

	readonly property var steps: ["storage", "start", "display"]
	readonly property bool launching: root.target !== "" && root.step !== "done" && root.step !== "failed"

	// ── Looking Glass ──────────────────────────────────────────────────────
	readonly property var lgWindow: Niri.windows.find(window => window.app_id === "looking-glass-client") ?? null
	readonly property bool lgOpen: root.lgWindow !== null
	// what its log says: "", "waiting" (for the host application), "ready", "incompatible"
	readonly property string lgState: {
		const text = String(lgLog.text() || "");
		if (/not compatible/i.test(text)) return "incompatible";
		const ready = Math.max(text.lastIndexOf("Host version"), text.lastIndexOf("Starting session"));
		const waiting = Math.max(text.lastIndexOf("Waiting for the host"), text.lastIndexOf("host application seems to not be running"));
		if (ready >= 0 && ready > waiting) return "ready";
		if (waiting >= 0) return "waiting";
		return "";
	}

	signal launched(string name)

	function vm(name) {
		return root.vms.find(each => each.name === name) ?? null;
	}

	function stepIndex(step) {
		if (step === "done") return root.steps.length;
		return root.steps.indexOf(step);
	}

	function refresh() {
		if (!lister.running) lister.running = true;
	}

	function launch(name) {
		const machine = root.vm(name);
		if (!machine || root.launching) return;
		root.target = name;
		root.failure = "";
		root.failedStep = "";
		root.remedy = "";
		root.busy = [];
		root.goTo("storage");
	}

	function retry() {
		if (root.target === "" || root.step !== "failed") return;
		const from = root.failedStep || "storage";
		root.failure = "";
		root.remedy = "";
		root.failedStep = "";
		root.goTo(from);
	}

	function dismiss() {
		if (root.launching) return;
		root.target = "";
		root.step = "";
		root.failure = "";
		root.failedStep = "";
		root.remedy = "";
	}

	function fail(step, message, remedy) {
		root.failedStep = step;
		root.failure = message || "Something went wrong";
		root.remedy = remedy || "";
		root.step = "failed";
		Sounds.play("error");
	}

	function goTo(step) {
		root.step = step;
		const machine = root.vm(root.target);
		switch (step) {
		case "storage":
			root.run(mounter, ["mount", root.target]);
			break;
		case "start":
			if (machine?.running) {
				root.goTo("display");
				return;
			}
			root.run(starter, ["start", root.target]);
			break;
		case "display":
			if (!machine?.lookingGlass) {
				root.finish();
				return;
			}
			if (root.lgOpen) {
				Niri.focusWindow(root.lgWindow.id);
				root.checkDisplay();
				return;
			}
			root.lgFresh = false;
			lgStarter.running = true;
			break;
		}
	}

	// whether the log is that of the Looking Glass this launch started
	property bool lgFresh: false

	function checkDisplay() {
		if (root.step !== "display") return;
		if (root.lgState === "incompatible") root.fail("display", "Looking Glass and its host application in Windows are different versions");
		else if (root.lgState === "ready" && (root.lgFresh || root.lgOpen)) root.finish();
	}

	function finish() {
		root.step = "done";
		Sounds.play("taskDone");
		root.launched(root.target);
		root.refresh();
	}

	function run(process, args) {
		process.command = ["python3", root.script].concat(args);
		process.running = true;
	}

	// Looking Glass for a machine that already runs
	function openDisplay(name) {
		if (root.lgOpen) {
			Niri.focusWindow(root.lgWindow.id);
			return;
		}
		root.launch(name);
	}

	function setPending(name, what) {
		const next = Object.assign({}, root.pending);
		if (what) next[name] = what;
		else delete next[name];
		root.pending = next;
	}

	function shutdown(name) {
		root.lifecycle(name, "shutdown");
	}

	function kill(name) {
		root.lifecycle(name, "kill");
	}

	function unmount(name) {
		root.lifecycle(name, "unmount");
	}

	function lifecycle(name, action) {
		if (root.pending[name]) return;
		root.setPending(name, action);
		const process = lifecycleComponent.createObject(root, { name: name, action: action });
		process.command = ["python3", root.script, action, name];
		process.running = true;
	}

	// what needs root runs in a terminal with sudo: the fstab entry with
	// `user` once, freeing a passed-through drive every time it is mounted
	function authorize() {
		if (root.target === "" || root.authorizing) return;
		root.authorizing = true;
		const state = `${Paths.state}/vms.json`;
		const inner = `printf '\\n  Pshell needs your password to prepare ${root.target}.\\n\\n'; sudo python3 '${root.script}' allow '${root.target}' '${state}'; code=$?; if [ $code -ne 0 ]; then printf '\\n  Press Enter to close.'; read _; fi; exit $code`;
		authorizer.command = ["kitty", "--class", "pshell-vm-auth", "--title", "Pshell · virtual machine", "-o", "initial_window_width=72c", "-o", "initial_window_height=14c", "sh", "-c", inner];
		authorizer.running = true;
	}

	function answerOf(text) {
		try {
			return JSON.parse(String(text || "").trim().split("\n").pop() || "{}");
		} catch (error) {
			return {};
		}
	}

	// status every few seconds while someone looks, faster while a launch runs
	Timer {
		interval: root.launching ? 1000 : 2500
		repeat: true
		running: Plugins.on("vm-launcher") && (root.watched || root.remote || root.launching || Object.keys(root.pending).length > 0)
		triggeredOnStart: true
		onTriggered: root.refresh()
	}

	Process {
		id: lister

		command: ["python3", root.script, "status"]
		stdout: StdioCollector {
			onStreamFinished: {
				const data = root.answerOf(text);
				if (!data.vms) return;
				root.error = data.error || "";
				// the same machines as before keep their objects
				if (JSON.stringify(data.vms) !== JSON.stringify(root.vms)) root.vms = data.vms;
				root.loaded = true;
			}
		}
	}

	Process {
		id: mounter

		stdout: StdioCollector {
			id: mountOut
		}
		onExited: code => {
			if (root.step !== "storage") return;
			const data = root.answerOf(mountOut.text);
			if (code === 0) {
				root.refresh();
				root.goTo("start");
			} else if (code === 4) {
				root.fail("storage", "Mounting the VM drive needs your password once", "root");
			} else if (code === 5) {
				root.busy = data.busy || [];
				root.fail("storage", data.error || "A drive of the VM is in use on this computer", "busy");
			} else {
				root.fail("storage", data.error);
			}
		}
	}

	Process {
		id: starter

		stdout: StdioCollector {
			id: startOut
		}
		onExited: code => {
			if (root.step !== "start") return;
			if (code !== 0) {
				root.fail("start", root.answerOf(startOut.text).error);
				return;
			}
			root.refresh();
			root.goTo("display");
		}
	}

	Process {
		id: lgStarter

		command: ["python3", root.script, "lg"]
		stdout: StdioCollector {
			id: lgOut
		}
		onExited: code => {
			if (code !== 0) {
				root.fail("display", root.answerOf(lgOut.text).error);
				return;
			}
			lgLog.reload();
			root.lgFresh = true;
		}
	}

	Process {
		id: authorizer

		onExited: code => {
			root.authorizing = false;
			if (code === 0 && root.step === "failed") root.retry();
		}
	}

	Component {
		id: lifecycleComponent

		Process {
			id: job

			property string name
			property string action

			stdout: StdioCollector {
				id: jobOut
			}
			onExited: code => {
				// a shutdown only asks Windows; it stays pending until it is off
				if (code !== 0) {
					root.setPending(job.name, "");
					Sounds.play("error");
					console.warn(`Machines: ${job.action} ${job.name}: ${root.answerOf(jobOut.text).error}`);
				} else if (job.action !== "shutdown") {
					root.setPending(job.name, "");
				}
				root.refresh();
				job.destroy();
			}
		}
	}

	// a machine that went off is no longer shutting down
	onVmsChanged: {
		for (const name of Object.keys(root.pending))
			if (root.pending[name] === "shutdown" && root.vm(name) && !root.vm(name).running) root.setPending(name, "");
	}

	// the host application answered: Windows is there
	onLgStateChanged: root.checkDisplay()

	// the log is read again while Looking Glass is waited for, in case a
	// change slipped past the watch (the file is truncated on each start)
	Timer {
		interval: 700
		repeat: true
		running: root.step === "display" && root.lgFresh
		onTriggered: {
			lgLog.reload();
			root.checkDisplay();
		}
	}

	// Looking Glass closed before the host answered
	onLgOpenChanged: {
		if (root.step === "display" && !root.lgOpen && !lgStarter.running && root.lgState !== "") root.fail("display", "Looking Glass closed");
	}

	FileView {
		id: lgLog

		path: root.logPath
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
	}
}
