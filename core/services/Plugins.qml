pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Everything the shell can do is a plugin from core/plugins.json: a widget, a
// panel, a command, an automation. Whether one is on is decided per setup:
// the switches live in ~/.local/state/pshell/plugins.json, outside the
// repository. Until a plugin is switched there, the host profile's `plugins`
// and then the registry's `default` apply. A plugin whose `requires` are off
// is off as well. QML asks Plugins.on("<id>"), scripts `host.py has <id>`.
Singleton {
	id: root

	readonly property var list: {
		try {
			return JSON.parse(registryFile.text() || "[]");
		} catch (error) {
			console.warn("Plugins: core/plugins.json is not valid JSON");
			return [];
		}
	}
	readonly property var byId: {
		const map = {};
		for (const plugin of root.list) map[plugin.id] = plugin;
		return map;
	}
	readonly property var categories: {
		const names = [];
		for (const plugin of root.list)
			if (!names.includes(plugin.category)) names.push(plugin.category);
		return names;
	}

	// what was switched on this setup: { id: bool }
	property var switches: ({})
	readonly property var profile: Host.profile.plugins || {}

	// every plugin's effective state
	readonly property var state: {
		const map = {};
		const resolve = id => {
			if (map[id] !== undefined) return map[id];
			const plugin = root.byId[id];
			if (!plugin) return false;
			// a cycle in `requires` reads as off
			map[id] = false;
			map[id] = root.wanted(id) && (plugin.requires || []).every(resolve);
			return map[id];
		};
		for (const plugin of root.list) resolve(plugin.id);
		return map;
	}

	function on(id) {
		return root.state[id] === true;
	}

	function fallback(id) {
		const fromProfile = root.profile[id];
		if (fromProfile !== undefined) return fromProfile === true;
		return root.byId[id]?.default !== false;
	}

	// the plugin's own switch, whatever its requirements say
	function wanted(id) {
		const switched = root.switches[id];
		return switched !== undefined ? switched === true : root.fallback(id);
	}

	// required plugins that keep this one off
	function missing(id) {
		return (root.byId[id]?.requires || []).filter(required => !root.on(required)).map(required => root.byId[required]?.name ?? required);
	}

	// ids that have a preview picture; the others show their icon
	property var pictured: []

	function preview(id) {
		return root.pictured.includes(id) ? `${Quickshell.shellDir}/assets/plugins/${id}.png` : "";
	}

	function set(id, on) {
		if (!root.byId[id]) return;
		const next = Object.assign({}, root.switches);
		if (!!on === root.fallback(id)) delete next[id];
		else next[id] = !!on;
		root.switches = next;
		file.setText(JSON.stringify(next, null, "\t") + "\n");
	}

	function toggle(id) {
		root.set(id, !root.wanted(id));
	}

	function load(text) {
		try {
			const parsed = JSON.parse(text || "{}");
			root.switches = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
		} catch (error) {
			console.warn("Plugins: plugins.json is not valid JSON");
		}
	}

	Component.onCompleted: root.load(file.text())

	Process {
		running: true
		command: ["ls", `${Quickshell.shellDir}/assets/plugins`]
		stdout: StdioCollector {
			onStreamFinished: root.pictured = String(text).split("\n").filter(name => name.endsWith(".png")).map(name => name.slice(0, -4))
		}
	}

	FileView {
		id: registryFile

		path: `${Quickshell.shellDir}/core/plugins.json`
		blockLoading: true
		watchChanges: true
		onFileChanged: reload()
	}

	FileView {
		id: file

		path: Paths.stateFile("plugins.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: root.load(text())
	}
}
