pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Floorp's workspaces through its local API (plugin browser-workspaces,
// docs/browser.md): Floorp listens on 127.0.0.1 once floorp.os.enabled is
// true in about:config and writes its token to ~/.floorp/os-server-token.
// A niri workspace can be given a Floorp workspace; with `follow` on, Floorp
// switches to it whenever niri does. The choices are kept in
// ~/.local/state/pshell/browser-workspaces.json.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-workspaces")

	// [{ id, name, icon, isDefault, isSelected }]
	property var workspaces: []
	property string currentId: ""
	property bool reachable: false
	property string error: ""

	// kept: { port, follow, map: { niriKey: floorpId } }
	property var saved: ({})
	readonly property int port: Number(root.saved.port) > 0 ? Number(root.saved.port) : 58261
	readonly property bool follow: root.saved.follow !== false
	readonly property var map: root.saved.map && typeof root.saved.map === "object" ? root.saved.map : ({})

	readonly property var current: root.workspaces.find(ws => ws.id === root.currentId) ?? null
	readonly property var focusedNiri: Niri.workspaces.find(ws => ws.is_focused) ?? null
	readonly property string focusedKey: root.focusedNiri ? root.niriKey(root.focusedNiri) : ""
	property string lastKey: ""

	// a niri workspace by its name, else by its output and place
	function niriKey(workspace) {
		if (!workspace) return "";
		return workspace.name ? `name:${workspace.name}` : `${workspace.output}/${workspace.idx}`;
	}

	function niriLabel(key) {
		if (key.startsWith("name:")) return key.slice(5);
		const [output, idx] = key.split("/");
		return `${idx} · ${output}`;
	}

	function request(method, path, callback) {
		if (!root.enabled) return;
		const xhr = new XMLHttpRequest();
		xhr.onreadystatechange = () => {
			if (xhr.readyState !== XMLHttpRequest.DONE) return;
			let body = null;
			try {
				body = JSON.parse(xhr.responseText || "null");
			} catch (error) {
				body = null;
			}
			const ok = xhr.status >= 200 && xhr.status < 300;
			// Floorp writes a new token when it starts
			if (xhr.status === 401 || xhr.status === 0) tokenFile.reload();
			root.reachable = xhr.status !== 0;
			root.error = ok ? "" : xhr.status === 0 ? "Floorp's API does not answer" : xhr.status === 401 ? "Token refused" : String(body?.error || `HTTP ${xhr.status}`);
			if (callback) callback(ok, body);
		};
		xhr.open(method, `http://127.0.0.1:${root.port}${path}`);
		if (String(tokenFile.text() || "") === "") tokenFile.reload();
		const token = String(tokenFile.text() || "").trim();
		if (token !== "") xhr.setRequestHeader("Authorization", `Bearer ${token}`);
		xhr.send(method === "POST" ? "{}" : null);
	}

	function refresh(then) {
		root.request("GET", "/workspaces", (ok, body) => {
			if (ok && body) {
				root.workspaces = Array.isArray(body.workspaces) ? body.workspaces : [];
				root.currentId = String(body.currentId || "");
			}
			if (then) then(ok);
		});
	}

	function answered(ok, body) {
		if (ok && body?.workspaceId) root.currentId = String(body.workspaceId);
		refreshDelay.restart();
	}

	function next() {
		root.request("POST", "/workspaces/next", root.answered);
	}

	function previous() {
		root.request("POST", "/workspaces/previous", root.answered);
	}

	// by id, or by name (case ignored)
	function switchTo(which) {
		const text = String(which || "");
		if (root.workspaces.length === 0) {
			root.refresh(ok => {
				if (ok && root.workspaces.length > 0) root.switchTo(text);
			});
			return;
		}
		const found = root.workspaces.find(ws => ws.id === text) ?? root.workspaces.find(ws => String(ws.name).toLowerCase() === text.toLowerCase());
		const id = found ? found.id : text;
		if (id === "" || id === root.currentId) return;
		root.request("POST", `/workspaces/${encodeURIComponent(id)}/switch`, root.answered);
	}

	function save(next) {
		root.saved = next;
		stateFile.setText(JSON.stringify(next, null, 2) + "\n");
	}

	function setFollow(on) {
		root.save(Object.assign({}, root.saved, { follow: !!on }));
	}

	function setPort(port) {
		root.save(Object.assign({}, root.saved, { port: Math.max(1, Math.min(65535, Number(port) || 58261)) }));
		root.refresh();
	}

	// floorpId "" takes the niri workspace's choice away
	function assign(niriKey, floorpId) {
		const map = Object.assign({}, root.map);
		if (floorpId) map[niriKey] = String(floorpId);
		else delete map[niriKey];
		root.save(Object.assign({}, root.saved, { map: map }));
		if (niriKey === root.focusedKey && floorpId && root.follow) root.switchTo(floorpId);
	}

	function followNiri() {
		const key = root.focusedKey;
		if (key === root.lastKey) return;
		const first = root.lastKey === "";
		root.lastKey = key;
		// the shell (re)starting is no switch
		if (first || !root.enabled || !root.follow || key === "") return;
		const target = root.map[key];
		if (target) root.switchTo(target);
	}

	onFocusedKeyChanged: root.followNiri()
	onEnabledChanged: if (root.enabled) root.refresh()
	function load() {
		try {
			const data = JSON.parse(String(stateFile.text() || "{}"));
			root.saved = data && typeof data === "object" ? data : {};
		} catch (error) {
			root.saved = {};
		}
	}

	Component.onCompleted: {
		// blockLoading: read now, so the first request knows the port
		root.load();
		root.lastKey = root.focusedKey;
		if (root.enabled) root.refresh();
	}

	Timer {
		id: refreshDelay

		interval: 400
		onTriggered: root.refresh()
	}

	// a workspace switched in Floorp shows as tabs hidden and shown
	Connections {
		target: WebLink
		enabled: root.enabled

		function onTabsUpdated() {
			refreshDelay.restart();
		}
	}

	FileView {
		id: tokenFile

		path: `${Paths.home}/.floorp/os-server-token`
		blockLoading: true
		watchChanges: true
		printErrors: false
		onFileChanged: {
			tokenFile.reload();
			if (root.enabled) refreshDelay.restart();
		}
	}

	FileView {
		id: stateFile

		path: Paths.stateFile("browser-workspaces.json")
		blockLoading: true
		printErrors: false
		onLoaded: root.load()
	}
}
