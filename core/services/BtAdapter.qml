pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Bluetooth adapter itself (plugin `bt-adapter`; made on the Intel AX201,
// USB 8087:0026). scripts/btadapter/btadapter.py reads BlueZ, sysfs and the
// kernel's mgmt socket; what needs root goes through its helper (root.py,
// a root-owned copy polkit lets through). What the page keeps comes back
// whenever the adapter does. btadapter.json:
//
//   kept: { settings: { "link-security": 0|1, … }, phy: [..], exp: { uuid: bool },
//           debugfs: { key: value }, link: { policy, central }, afh: { classic, le,
//           assessment, avoid: [MHz ranges] }, appearance, publicAddress,
//           staticAddress, advertising: { on, kind, … } }
//   factoryAddress, restartPending: [keys]
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("bt-adapter")
	readonly property string script: `${Paths.scripts}/btadapter/btadapter.py`

	// ── what the daemon says ───────────────────────────────────────────────
	property var state: ({ present: false })
	property bool scanned: false
	property string helper: ""
	property string error: ""
	property var busy: ({})
	property var quality: []

	readonly property bool present: root.state.present === true
	readonly property var adapter: root.state.adapter ?? null
	readonly property var usb: root.state.usb ?? null
	readonly property var dev: root.state.dev ?? null
	readonly property var rootState: root.state.root ?? ({})
	readonly property bool hasRoot: root.helper === "ready" && !!root.rootState.info && !root.rootState.info.error
	readonly property var mgmt: root.hasRoot ? root.rootState : (root.state.mgmt ?? {})
	readonly property var info: root.mgmt.info ?? root.state.mgmt?.info ?? null
	readonly property var current: root.info?.current ?? []
	readonly property var supported: root.info?.supported ?? []
	readonly property var sysconfig: root.mgmt.sysconfig ?? root.state.mgmt?.sysconfig ?? ({})
	readonly property var exp: root.mgmt.exp ?? root.state.mgmt?.exp ?? []
	readonly property var expGlobal: root.mgmt.expGlobal ?? root.state.mgmt?.expGlobal ?? []
	readonly property var phy: root.rootState.phy && !root.rootState.phy.error ? root.rootState.phy : null
	readonly property var debugfs: root.rootState.debugfs && !root.rootState.debugfs.error ? root.rootState.debugfs : ({})
	readonly property var conf: root.state.conf ?? ({})
	readonly property var mainConf: root.conf["main.conf"] ?? ({})
	readonly property var links: root.rootState.links ?? []
	readonly property var devices: root.state.devices ?? []
	readonly property var staticInfo: root.state.static ?? null
	readonly property var firmware: root.state.firmware ?? ({})
	readonly property var params: root.state.params ?? ({})
	readonly property var modprobe: root.state.modprobe ?? ({})
	readonly property var wifi: root.state.wifi ?? null
	readonly property bool powered: !!root.adapter?.Powered
	readonly property bool blocked: !!root.state.rfkill?.soft || !!root.state.rfkill?.hard
	readonly property bool advertising: root.state.advertising === true
	readonly property string factoryAddress: root.config.factoryAddress || root.state.factoryAddress || ""

	function has(setting) {
		return root.current.includes(setting);
	}

	function can(setting) {
		return root.supported.includes(setting);
	}

	function expOn(id) {
		return root.exp.find(e => e.id === id)?.on === true;
	}

	function isBusy(tag) {
		return root.busy[tag] === true;
	}

	// ── what the page keeps ───────────────────────────────────────────────
	property var config: ({ kept: {} })
	property bool loaded: false
	readonly property var kept: root.config.kept ?? ({})
	readonly property var restartPending: root.config.restartPending ?? []

	function keep(key, value) {
		const kept = Object.assign({}, root.kept);
		if (value === undefined || value === null) delete kept[key];
		else kept[key] = value;
		root.config = Object.assign({}, root.config, { kept });
		saving.restart();
		root.send({ op: "config", config: root.kept, changed: [key] });
	}

	// one entry of a kept map (settings, debugfs, exp)
	function keepIn(map, key, value) {
		const next = Object.assign({}, root.kept[map] ?? {});
		if (value === undefined || value === null) delete next[key];
		else next[key] = value;
		root.keep(map, Object.keys(next).length ? next : null);
	}

	function setConfig(key, value) {
		root.config = Object.assign({}, root.config, { [key]: value });
		saving.restart();
	}

	// ── what the page asks for ────────────────────────────────────────────
	function setAdapter(key, value) {
		root.send({ op: "adapter", key, value });
	}

	function setDevice(path, key, value) {
		root.send({ op: "device", path, key, value });
	}

	function disconnect(path) {
		root.send({ op: "disconnect", path });
	}

	function setBlocked(block) {
		root.send({ op: "rfkill", block });
	}

	function installHelper(what) {
		root.send({ op: "install", what: what ?? "install" });
	}

	function ask(what, args, tag) {
		root.send({ op: "root", what, args: args ?? {}, tag: tag ?? what });
	}

	// a mgmt setting, live and kept
	function setSetting(name, value) {
		root.ask("setting", { name, value }, `setting-${name}`);
		root.keepIn("settings", name, value);
	}

	// BlueZ's own files; `live` is done through mgmt at once, the rest waits
	// for bluetoothd to start again
	function setConf(file, section, key, value, live) {
		root.ask("conf", { items: [{ file, section, key, value }] }, `conf-${key}`);
		if (!live && !root.restartPending.includes(`${section}.${key}`))
			root.setConfig("restartPending", root.restartPending.concat([`${section}.${key}`]));
	}

	function restartBluetooth() {
		root.ask("restart-bluetooth", {}, "restart");
		root.setConfig("restartPending", []);
	}

	function setTiming(key, value) {
		root.ask("sysconfig", { values: { [key]: value } }, `timing-${key}`);
	}

	function setPhy(selected) {
		root.ask("phy", { selected }, "phy");
		root.keep("phy", selected);
	}

	function setExp(uuid, on, global) {
		root.ask("exp", { uuid, on, global: !!global }, `exp-${uuid}`);
		if (!global) root.keepIn("exp", uuid, on);
	}

	function setDebug(key, value) {
		root.ask("debugfs", { key, value }, `debug-${key}`);
		root.keepIn("debugfs", key, value);
	}

	function setLink(patch) {
		root.ask("link", patch, "link");
		root.keep("link", Object.assign({}, root.kept.link ?? {}, patch));
	}

	function setAfh(patch) {
		root.ask("afh", patch, "afh");
		const next = Object.assign({}, root.kept.afh ?? {}, patch);
		for (const k of Object.keys(next)) if (next[k] === null) delete next[k];
		root.keep("afh", Object.keys(next).length ? next : null);
	}

	function setAddress(kind, value) {
		root.ask("address", { kind, value }, `address-${kind}`);
		const reset = kind === "public" ? value.toUpperCase() === root.factoryAddress.toUpperCase() : value === "00:00:00:00:00:00";
		root.keep(kind === "public" ? "publicAddress" : "staticAddress", reset ? null : value.toUpperCase());
	}

	function setAppearance(value) {
		root.ask("appearance", { value }, "appearance");
		root.keep("appearance", value);
	}

	function setAdvertising(patch) {
		root.keep("advertising", Object.assign({}, root.kept.advertising ?? {}, patch));
	}

	function setUsbPower(patch) {
		root.ask("usb-power", patch, "usb");
	}

	function setModule(param, value) {
		root.ask("modprobe", { param, value }, `module-${param}`);
	}

	function refresh() {
		root.send({ op: "refresh" });
	}

	property bool watching: false
	onWatchingChanged: root.send({ op: "watch", on: root.watching })

	Timer {
		id: saving

		interval: 400
		onTriggered: file.setText(JSON.stringify(root.config, null, "\t") + "\n")
	}

	FileView {
		id: file

		path: Paths.stateFile("btadapter.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(text() || "{}");
				root.config = Object.assign({ kept: {} }, data && typeof data === "object" ? data : {});
			} catch (error) {
				console.warn("BtAdapter: btadapter.json is not valid JSON");
			}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}

	// ── the daemon ────────────────────────────────────────────────────────
	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	function setBusy(tag, on) {
		const next = Object.assign({}, root.busy);
		if (on) next[tag] = true;
		else delete next[tag];
		root.busy = next;
	}

	function handle(line) {
		let data;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.event) {
		case "state":
			root.state = data;
			root.scanned = true;
			if (data.helper) root.helper = data.helper;
			break;
		case "helper":
			root.helper = data.status ?? "";
			break;
		case "busy":
			root.setBusy(data.what, true);
			break;
		case "done":
			root.setBusy(data.what, false);
			break;
		case "factory":
			if (!root.config.factoryAddress && data.address) root.setConfig("factoryAddress", data.address);
			break;
		case "quality":
			root.quality = data.reports ?? [];
			break;
		case "error":
			root.error = data.message ?? "";
			clearError.restart();
			break;
		}
	}

	Timer {
		id: clearError

		interval: 8000
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
		onRunningChanged: {
			if (!running) return;
			root.send({ op: "config", config: root.kept });
			if (root.watching) root.send({ op: "watch", on: true });
		}
		onExited: {
			root.state = { present: false };
			root.busy = {};
			if (root.enabled) revive.restart();
		}
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: if (root.enabled && !daemon.running) daemon.running = true
	}
}
