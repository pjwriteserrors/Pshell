pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The apps of the phone whose notifications reached this PC, and the ones
// that are not to show here; the other way, the programs of the PC whose
// notifications went to the phone, and the ones that are not to go; and,
// with no phone in it, the programs that notified on this PC and the ones
// that are not to (the Notifications page of the Pshell settings). Who
// sent how many and when is kept in phone-apps.json; what a notification
// said is not.
Singleton {
	id: root

	// package → { name, count, last (ms) }
	property var apps: ({})
	// packages whose notifications are not shown here
	property var muted: []
	// the same for what the PC sends to the phone, by the program's name
	property var pcApps: ({})
	property var pcMuted: []
	// the programs that notified here, and the ones whose notifications are dropped
	property var localApps: ({})
	property var localMuted: []
	property bool loaded: false

	// most recent first
	readonly property var list: Object.keys(root.apps).map(id => Object.assign({ id: id, muted: root.muted.includes(id) }, root.apps[id]))
		.sort((a, b) => b.last - a.last)

	readonly property var pcList: Object.keys(root.pcApps).map(id => Object.assign({ id: id, muted: root.pcMuted.includes(id) }, root.pcApps[id]))
		.sort((a, b) => b.last - a.last)

	// a notification of the PC is about to go to the phone; true if it is not to
	function sending(app) {
		const id = String(app || "");
		if (id === "") return false;
		const next = Object.assign({}, root.pcApps);
		next[id] = { name: id, count: (next[id]?.count ?? 0) + 1, last: Date.now() };
		root.pcApps = next;
		saving.restart();
		return root.pcMuted.includes(id);
	}

	function setPcMuted(id, on) {
		if (root.pcMuted.includes(id) === !!on) return;
		root.pcMuted = on ? root.pcMuted.concat([id]) : root.pcMuted.filter(entry => entry !== id);
		root.save();
	}

	function forgetPc(id) {
		const next = Object.assign({}, root.pcApps);
		delete next[id];
		root.pcApps = next;
		root.pcMuted = root.pcMuted.filter(entry => entry !== id);
		root.save();
	}

	readonly property var localList: Object.keys(root.localApps).map(id => Object.assign({ id: id, muted: root.localMuted.includes(id) }, root.localApps[id]))
		.sort((a, b) => b.last - a.last)

	// a program notifies on this PC; true if it is not to show
	function arriving(app) {
		const id = String(app || "");
		if (id === "") return false;
		const next = Object.assign({}, root.localApps);
		next[id] = { name: id, count: (next[id]?.count ?? 0) + 1, last: Date.now() };
		root.localApps = next;
		saving.restart();
		return root.localMuted.includes(id);
	}

	function setLocalMuted(id, on) {
		if (root.localMuted.includes(id) === !!on) return;
		root.localMuted = on ? root.localMuted.concat([id]) : root.localMuted.filter(entry => entry !== id);
		root.save();
	}

	function forgetLocal(id) {
		const next = Object.assign({}, root.localApps);
		delete next[id];
		root.localApps = next;
		root.localMuted = root.localMuted.filter(entry => entry !== id);
		root.save();
	}

	function idOf(data) {
		return String(data.package || data.app || "");
	}

	function isMuted(id) {
		return root.muted.includes(id);
	}

	// a notification of the phone came in; true if it is not to show
	function saw(data) {
		const id = root.idOf(data);
		if (id === "") return false;
		// the same notification again (a chat that goes on, what the phone
		// tells anew when the link starts) is not counted twice, but its app is known
		const known = root.apps[id];
		if (!data.update || !known) {
			const next = Object.assign({}, root.apps);
			next[id] = {
				name: String(data.app || known?.name || id),
				count: (known?.count ?? 0) + (data.update ? 0 : 1),
				last: data.update ? (Number(data.time) || Date.now()) : Date.now()
			};
			root.apps = next;
			saving.restart();
		}
		return root.isMuted(id);
	}

	function setMuted(id, on) {
		if (root.isMuted(id) === !!on) return;
		root.muted = on ? root.muted.concat([id]) : root.muted.filter(entry => entry !== id);
		root.save();
	}

	function forget(id) {
		const next = Object.assign({}, root.apps);
		delete next[id];
		root.apps = next;
		root.muted = root.muted.filter(entry => entry !== id);
		root.save();
	}

	function save() {
		if (root.loaded) file.setText(JSON.stringify({ apps: root.apps, muted: root.muted, pcApps: root.pcApps, pcMuted: root.pcMuted, localApps: root.localApps, localMuted: root.localMuted }, null, "\t") + "\n");
	}

	function load(text) {
		let data = {};
		try {
			data = JSON.parse(String(text || "{}"));
		} catch (error) {
			data = {};
		}
		root.apps = data.apps && typeof data.apps === "object" ? data.apps : {};
		root.muted = Array.isArray(data.muted) ? data.muted.map(String) : [];
		root.pcApps = data.pcApps && typeof data.pcApps === "object" ? data.pcApps : {};
		root.pcMuted = Array.isArray(data.pcMuted) ? data.pcMuted.map(String) : [];
		root.localApps = data.localApps && typeof data.localApps === "object" ? data.localApps : {};
		root.localMuted = Array.isArray(data.localMuted) ? data.localMuted.map(String) : [];
		root.loaded = true;
	}

	Timer {
		id: saving

		interval: 2000
		onTriggered: root.save()
	}

	FileView {
		id: file

		path: Paths.stateFile("phone-apps.json")
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.load(file.text())
		onLoadFailed: root.load("{}")
	}
}
