pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// niri's settings, edited in the shell (>niri, plugin `niri-settings`). The
// file work is scripts/niri_settings.py: the first time the window opens it
// takes over what config.kdl sets (everything but Studio's cursor theme and
// animations) into ~/.config/niri/settings.kdl, the monitors into
// display-profile.kdl. Every change is shown at once and written a moment
// later; niri reloads the files by itself, and what it would reject is never
// written (the settings go back to the last ones it took).
//
// The settings are KDL nodes as plain data: { name, args, props, children,
// disabled, comment }. A path names nested sections: ["layout", "border",
// "width"] is `layout { border { width 4 } }`.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("niri-settings")
	readonly property string script: `${Paths.scripts}/niri_settings.py`

	// the page the window shows (set before opening it: `>keys` → "keys")
	property string page: "displays"

	property var nodes: []
	property var outputs: []
	property var profileRules: []
	property string profile: ""
	property var shellStartup: []
	property var cursor: ({})
	property bool adopted: false
	property string file: ""
	property string profileFile: ""
	property bool loading: false
	property bool loaded: false
	property bool saving: false
	property string error: ""
	// [{ nodes, outputs, note }] before each change, for undo
	property var history: []
	property int savedCount: 0
	property string savedNote: ""

	// what the pickers offer
	property var live: ({ windows: [], layers: [], workspaces: [], outputs: [] })
	property var xkb: ({ layouts: [], options: [], groups: {} })
	property var drm: []

	// the order sections are written in when one is new
	readonly property var sectionOrder: ["prefer-no-csd", "input", "cursor", "layout", "spawn-at-startup", "spawn-sh-at-startup",
		"hotkey-overlay", "screenshot-path", "workspace", "window-rule", "layer-rule", "switch-events", "environment", "overview",
		"gestures", "recent-windows", "clipboard", "config-notification", "xwayland-satellite", "blur", "debug"]

	function prepare() {
		if (!root.enabled) return;
		root.load();
		root.refreshLive();
		if (root.xkb.layouts.length === 0 && !xkbProc.running) xkbProc.running = true;
		if (root.drm.length === 0 && !drmProc.running) drmProc.running = true;
	}

	function load() {
		if (!root.enabled || reader.running) return;
		root.loading = true;
		reader.running = true;
	}

	function refreshLive() {
		if (!liveProc.running) liveProc.running = true;
	}

	// ── reading ────────────────────────────────────────────────────────────
	function clone(value) {
		return JSON.parse(JSON.stringify(value));
	}

	function leaf(name, args, props) {
		return { name: name, args: args || [], props: props || {} };
	}

	function find(list, name) {
		return (list || []).find(node => node.name === name && !node.disabled) ?? null;
	}

	function nodeIn(list, path) {
		let node = null;
		for (const name of path) {
			node = root.find(list, name);
			if (!node) return null;
			list = node.children || [];
		}
		return node;
	}

	function node(path) {
		return root.nodeIn(root.nodes, path);
	}

	function has(path) {
		return !!root.node(path);
	}

	function arg(path, fallback) {
		const found = root.node(path);
		return found && found.args.length > 0 ? found.args[0] : fallback;
	}

	function argsOf(path) {
		return root.node(path)?.args ?? [];
	}

	function prop(path, name, fallback) {
		const value = root.node(path)?.props?.[name];
		return value === undefined ? fallback : value;
	}

	// a flag: there, and not `false`
	function flag(path) {
		const found = root.node(path);
		return !!found && found.args[0] !== false;
	}

	// a section with on/off inside (border, shadow, tab-indicator …)
	function sectionOn(path, fallback) {
		const found = root.node(path);
		if (!found) return fallback;
		const kids = found.children || [];
		if (root.find(kids, "off") && root.find(kids, "off").args[0] !== false) return false;
		if (root.find(kids, "on") && root.find(kids, "on").args[0] !== false) return true;
		return fallback;
	}

	function kids(path) {
		return root.node(path)?.children ?? [];
	}

	// the nodes of a repeated kind (window-rule, workspace …), switched-off ones too
	function items(names) {
		const wanted = [].concat(names);
		return root.nodes.filter(node => wanted.includes(node.name));
	}

	// ── changing ───────────────────────────────────────────────────────────
	function ensure(list, path, top) {
		let node = null;
		for (let i = 0; i < path.length; i++) {
			const name = path[i];
			node = root.find(list, name);
			if (!node) {
				node = { name: name, args: [], props: {}, children: [] };
				if (top && i === 0) root.insertOrdered(list, node);
				else list.push(node);
			}
			if (!node.children) node.children = [];
			list = node.children;
		}
		return node;
	}

	function insertOrdered(list, node) {
		const rank = name => {
			const index = root.sectionOrder.indexOf(name);
			return index < 0 ? 999 : index;
		};
		let at = list.length;
		for (let i = 0; i < list.length; i++) {
			if (rank(list[i].name) > rank(node.name)) {
				at = i;
				break;
			}
		}
		list.splice(at, 0, node);
	}

	// `fn(draft)` changes a copy; `key` folds a run of changes (a drag) into one undo step
	function edit(note, key, fn) {
		const draft = root.clone(root.nodes);
		fn(draft);
		root.commit(draft, null, note, key);
	}

	function setIn(list, path, args, props, top) {
		const parent = path.length > 1 ? root.ensure(list, path.slice(0, -1), top).children : list;
		const name = path[path.length - 1];
		let found = root.find(parent, name);
		if (!found) {
			found = root.leaf(name, args, props);
			if (top && path.length === 1) root.insertOrdered(parent, found);
			else parent.push(found);
		} else {
			found.args = args;
			if (props !== undefined) found.props = props;
		}
		return found;
	}

	function removeIn(list, path) {
		const parent = path.length > 1 ? root.nodeIn(list, path.slice(0, -1))?.children : list;
		if (!parent) return;
		const name = path[path.length - 1];
		for (let i = parent.length - 1; i >= 0; i--)
			if (parent[i].name === name && !parent[i].disabled) parent.splice(i, 1);
	}

	function set(path, value, note, key) {
		root.edit(note || root.noteFor(path), key ?? path.join("/"), draft => root.setIn(draft, path, [].concat(value), undefined, true));
	}

	function setArgs(path, args, note, key) {
		root.edit(note || root.noteFor(path), key ?? path.join("/"), draft => root.setIn(draft, path, args, undefined, true));
	}

	function setProps(path, props, note, key) {
		root.edit(note || root.noteFor(path), key ?? path.join("/"), draft => root.setIn(draft, path, [], props, true));
	}

	function setNode(path, args, props, note, key) {
		root.edit(note || root.noteFor(path), key ?? path.join("/"), draft => root.setIn(draft, path, args, props, true));
	}

	function setFlag(path, on, note) {
		root.edit(note || `${root.words(path[path.length - 1])} ${on ? "on" : "off"}`, "", draft => {
			if (on) root.setIn(draft, path, [], undefined, true);
			else root.removeIn(draft, path);
		});
	}

	// a flag whose default is on, written as `name false` to switch it off
	function setBool(path, on, fallback, note) {
		root.edit(note || `${root.words(path[path.length - 1])} ${on ? "on" : "off"}`, "", draft => {
			if (on === fallback) root.removeIn(draft, path);
			else root.setIn(draft, path, [on], undefined, true);
		});
	}

	function setSection(path, on, note) {
		root.edit(note || `${root.words(path[path.length - 1])} ${on ? "on" : "off"}`, "", draft => {
			const section = root.ensure(draft, path, true);
			section.children = section.children.filter(child => child.name !== "on" && child.name !== "off");
			section.children.unshift(root.leaf(on ? "on" : "off"));
		});
	}

	function setChildren(path, kids, note, key) {
		root.edit(note || root.noteFor(path), key ?? path.join("/"), draft => {
			root.ensure(draft, path, true).children = kids;
		});
	}

	// back to niri's default: the node goes
	function reset(path, note) {
		root.edit(note || `${root.words(path[path.length - 1])} back to niri's default`, "", draft => root.removeIn(draft, path));
	}

	// rewrites the nodes of a repeated kind, where the first of them stood
	function setItems(names, list, note, key) {
		const wanted = [].concat(names);
		root.edit(note || "Saved", key ?? "", draft => {
			let at = draft.findIndex(node => wanted.includes(node.name));
			const kept = draft.filter(node => !wanted.includes(node.name));
			if (at < 0) {
				const probe = { name: wanted[0] };
				const rank = name => {
					const index = root.sectionOrder.indexOf(name);
					return index < 0 ? 999 : index;
				};
				at = kept.findIndex(node => rank(node.name) > rank(probe.name));
				if (at < 0) at = kept.length;
			} else {
				at = draft.slice(0, at).filter(node => !wanted.includes(node.name)).length;
			}
			kept.splice(at, 0, ...root.clone(list));
			draft.length = 0;
			kept.forEach(node => draft.push(node));
		});
	}

	// ── monitors ───────────────────────────────────────────────────────────
	function output(name) {
		return root.outputs.find(block => String(block.args?.[0]) === name) ?? null;
	}

	function outputNode(name, path) {
		const block = root.output(name);
		return block ? root.nodeIn(block.children || [], path) : null;
	}

	function outputArg(name, path, fallback) {
		const found = root.outputNode(name, path);
		return found && found.args.length > 0 ? found.args[0] : fallback;
	}

	function outputFlag(name, path) {
		const found = root.outputNode(name, path);
		return !!found && found.args[0] !== false;
	}

	// `fn(block)` changes a copy of that monitor's block (made when missing)
	function editOutput(name, note, key, fn) {
		const draft = root.clone(root.outputs);
		let block = draft.find(item => String(item.args?.[0]) === name);
		if (!block) {
			block = { name: "output", args: [name], props: {}, children: [] };
			draft.push(block);
		}
		if (!block.children) block.children = [];
		fn(block);
		root.commit(null, draft, note, key);
	}

	function setOutputs(list, note) {
		root.commit(null, root.clone(list), note, "");
	}

	// ── writing ────────────────────────────────────────────────────────────
	property string lastKey: ""
	property real lastAt: 0

	function commit(nodes, outputs, note, key) {
		const now = Date.now();
		const fold = key !== "" && key === root.lastKey && now - root.lastAt < 2500 && root.history.length > 0;
		if (!fold) root.history = root.history.concat([{ nodes: root.nodes, outputs: root.outputs, note: note }]).slice(-60);
		root.lastKey = key;
		root.lastAt = now;
		if (nodes) {
			root.nodes = nodes;
			writer.nodesDirty = true;
		}
		if (outputs) {
			root.outputs = outputs;
			writer.outputsDirty = true;
		}
		writer.note = note || "Saved";
		root.error = "";
		flush.restart();
	}

	function undo() {
		if (root.history.length === 0) return;
		const last = root.history[root.history.length - 1];
		root.history = root.history.slice(0, -1);
		root.lastKey = "";
		if (JSON.stringify(last.nodes) !== JSON.stringify(root.nodes)) {
			root.nodes = last.nodes;
			writer.nodesDirty = true;
		}
		if (JSON.stringify(last.outputs) !== JSON.stringify(root.outputs)) {
			root.outputs = last.outputs;
			writer.outputsDirty = true;
		}
		writer.note = `Undone: ${last.note}`;
		flush.restart();
	}

	// gathers a burst of changes (a slider being dragged) into one write
	Timer {
		id: flush

		interval: 280
		onTriggered: root.write()
	}

	function write() {
		if (!writer.nodesDirty && !writer.outputsDirty) return;
		if (writer.running) {
			flush.restart();
			return;
		}
		const payload = {};
		if (writer.nodesDirty) payload.nodes = root.nodes;
		if (writer.outputsDirty) payload.outputs = root.outputs;
		writer.sentNodes = writer.nodesDirty;
		writer.sentOutputs = writer.outputsDirty;
		writer.nodesDirty = false;
		writer.outputsDirty = false;
		root.saving = true;
		writer.command = ["python3", root.script, "write", JSON.stringify(payload)];
		writer.running = true;
	}

	// what a change is called in the note at the bottom
	function words(name) {
		const text = String(name || "").replace(/[-_]/g, " ").trim();
		return text.charAt(0).toUpperCase() + text.slice(1);
	}

	function noteFor(path) {
		return `${root.words(path[path.length - 1])} changed`;
	}

	onEnabledChanged: if (!root.enabled) root.loaded = false

	Process {
		id: reader

		command: ["python3", root.script, "read"]
		stdout: StdioCollector {
			onStreamFinished: {
				root.loading = false;
				let data = null;
				try {
					data = JSON.parse(text);
				} catch (error) {
					root.error = `Could not read the settings: ${error}`;
					return;
				}
				root.adopted = !!data.adopted;
				root.file = String(data.file || "");
				root.profileFile = String(data.profileFile || "");
				root.profile = String(data.profile || "");
				root.profileRules = data.profileRules || [];
				root.shellStartup = data.shell || [];
				root.cursor = data.cursor || {};
				// a change still on its way is not overwritten
				if (!writer.nodesDirty && !writer.running) {
					root.nodes = data.nodes || [];
					writer.good = root.nodes;
				}
				if (!writer.outputsDirty && !writer.running) {
					root.outputs = data.outputs || [];
					writer.goodOutputs = root.outputs;
				}
				root.loaded = true;
				// what niri has now is taken over the first time
				if (!root.adopted && !adopter.running) adopter.running = true;
			}
		}
		onExited: root.loading = false
	}

	Process {
		id: adopter

		command: ["python3", root.script, "adopt"]
		stdout: StdioCollector {
			onStreamFinished: {
				let result = null;
				try {
					result = JSON.parse(text);
				} catch (error) {
					result = { ok: false, error: String(text || "niri_settings.py adopt failed") };
				}
				if (result.ok) {
					if (!result.already) {
						root.savedNote = `Your settings are now kept in settings.kdl – ${result.count} sections taken over`;
						root.savedCount += 1;
					}
					writer.doneAt = Date.now();
					root.load();
				} else {
					root.error = String(result.error || "Could not take over the settings");
				}
			}
		}
	}

	Process {
		id: writer

		property string note: ""
		property bool nodesDirty: false
		property bool outputsDirty: false
		property bool sentNodes: false
		property bool sentOutputs: false
		// the last state niri took
		property var good: []
		property var goodOutputs: []
		property real doneAt: 0

		stdout: StdioCollector {
			onStreamFinished: {
				root.saving = false;
				writer.doneAt = Date.now();
				let result = null;
				try {
					result = JSON.parse(text);
				} catch (error) {
					result = { ok: false, error: String(text || "niri_settings.py failed") };
				}
				if (result.ok) {
					if (writer.sentNodes) writer.good = root.nodes;
					if (writer.sentOutputs) writer.goodOutputs = root.outputs;
					root.savedNote = writer.note;
					root.savedCount += 1;
					if (!root.adopted) root.load();
				} else {
					root.error = String(result.error || "niri rejected the settings");
					// back to what niri has
					if (writer.sentNodes) root.nodes = writer.good;
					if (writer.sentOutputs) root.outputs = writer.goodOutputs;
					if (root.history.length > 0) root.history = root.history.slice(0, -1);
					root.lastKey = "";
				}
				if (writer.nodesDirty || writer.outputsDirty) flush.restart();
			}
		}
	}

	Process {
		id: liveProc

		command: ["python3", root.script, "live"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.live = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	Process {
		id: xkbProc

		command: ["python3", root.script, "xkb"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.xkb = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	Process {
		id: drmProc

		command: ["python3", root.script, "drm"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.drm = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	// a hand edit of settings.kdl or display-profile.kdl shows up
	FileView {
		path: root.enabled && root.adopted ? root.file : ""
		watchChanges: true
		printErrors: false
		// our own writes are no news
		onFileChanged: if (!writer.running && Date.now() - writer.doneAt > 1500) reloadSoon.restart()
	}

	FileView {
		path: root.enabled && root.adopted ? root.profileFile : ""
		watchChanges: true
		printErrors: false
		onFileChanged: if (!writer.running && Date.now() - writer.doneAt > 1500) reloadSoon.restart()
	}

	Timer {
		id: reloadSoon

		interval: 400
		onTriggered: if (!writer.running && !flush.running) root.load()
	}
}
