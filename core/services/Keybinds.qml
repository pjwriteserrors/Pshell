pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// niri's key binds, edited in the shell (>keys, plugin `keybinds`). The file
// work is scripts/keybinds.py: it lists every bind niri has, writes them to
// ~/.config/niri/keybinds.kdl (the first save takes over config.kdl's binds)
// and lets nothing through that `niri validate` rejects. niri reloads the
// file on its own.
//
// A bind: { uid, key, props, action, args, aprops, disabled, source }
//   key     "Mod+Shift+D", props { repeat, cooldown-ms, allow-when-locked,
//           allow-inhibiting, hotkey-overlay-title }, action "spawn",
//   args    ["kitty"], aprops { focus: false }
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("niri-settings")
	readonly property string script: `${Paths.scripts}/keybinds.py`

	property var binds: []
	property bool adopted: false
	property string file: ""
	property bool loading: false
	property bool loaded: false
	property bool saving: false
	// what niri said about the last write that failed
	property string error: ""
	// the lists before each save, for undo
	property var history: []
	// bumps on every write that landed: the window shows its note
	property int savedCount: 0
	property string savedNote: ""

	// catalogs, fetched when the editor first opens
	property var niriActions: []
	property var shellActions: []
	// xkb keycode -> key name of niri's layout
	property var keymap: ({})

	property int nextUid: 1

	readonly property var categories: [
		{ id: "Shell", label: "Shell", icon: "shimmer" },
		{ id: "Launch", label: "Launch", icon: "apps" },
		{ id: "Windows", label: "Windows", icon: "window_maximize" },
		{ id: "Workspaces", label: "Workspaces", icon: "view_grid_outline" },
		{ id: "Monitors", label: "Monitors", icon: "monitor_multiple" },
		{ id: "Screenshots", label: "Screenshots", icon: "monitor_screenshot" },
		{ id: "System", label: "System", icon: "cog" }
	]

	function load() {
		if (!root.enabled || lister.running) return;
		root.loading = true;
		lister.running = true;
	}

	function loadCatalogs() {
		if (!root.enabled) return;
		if (root.niriActions.length === 0 && !actionsProc.running) actionsProc.running = true;
		if (root.shellActions.length === 0 && !shellProc.running) shellProc.running = true;
		if (Object.keys(root.keymap).length === 0 && !keymapProc.running) keymapProc.running = true;
	}

	function stamp(list) {
		return list.map(bind => {
			if (bind.uid) return bind;
			const copy = Object.assign({}, bind);
			copy.uid = root.nextUid++;
			return copy;
		});
	}

	// a list read again keeps the uids of the binds it already had
	function restamp(list) {
		const sign = bind => `${root.norm(bind.key)}|${bind.action}|${JSON.stringify(bind.args || [])}|${!!bind.disabled}`;
		const known = {};
		root.binds.forEach(bind => known[sign(bind)] = bind.uid);
		return list.map(bind => Object.assign({}, bind, { uid: known[sign(bind)] ?? root.nextUid++ }));
	}

	function strip(list) {
		return list.map(bind => ({
			key: bind.key,
			props: bind.props || {},
			action: bind.action,
			args: bind.args || [],
			aprops: bind.aprops || {},
			disabled: !!bind.disabled
		}));
	}

	// writes `list` and shows it at once; a list niri rejects is taken back
	function commit(list, note) {
		root.write(root.stamp(list), root.history.concat([root.binds]).slice(-30), note);
	}

	// shows `list` and writes it; when niri says no, binds and history go back
	function write(list, history, note) {
		// a change while a write runs goes out right after it
		if (writer.running) {
			root.binds = list;
			root.history = history;
			writer.again = note || "Saved";
			return;
		}
		writer.previous = root.binds;
		writer.previousHistory = root.history;
		root.binds = list;
		root.history = history;
		root.error = "";
		root.saving = true;
		writer.note = note || "Saved";
		writer.command = ["python3", root.script, "write", JSON.stringify({ binds: root.strip(list) })];
		writer.running = true;
	}

	function undo() {
		if (root.history.length === 0 || root.saving) return;
		root.write(root.history[root.history.length - 1], root.history.slice(0, -1), "Undone");
	}

	function upsert(bind) {
		const list = root.binds.slice();
		const index = list.findIndex(other => other.uid === bind.uid);
		const copy = Object.assign({}, bind);
		if (!copy.uid) copy.uid = root.nextUid++;
		if (index >= 0) list[index] = copy;
		else list.push(copy);
		root.commit(list, index >= 0 ? `${root.keyText(copy.key)} saved` : `${root.keyText(copy.key)} added`);
		return copy.uid;
	}

	function remove(uid) {
		const bind = root.byUid(uid);
		root.commit(root.binds.filter(other => other.uid !== uid), bind ? `${root.keyText(bind.key)} deleted` : "Deleted");
	}

	function setDisabled(uid, disabled) {
		const bind = root.byUid(uid);
		if (!bind) return;
		if (!disabled) {
			const other = root.conflict(bind.key, uid);
			if (other) {
				root.error = `${root.keyText(bind.key)} is taken by “${root.title(other)}”`;
				return;
			}
		}
		root.commit(root.binds.map(other => other.uid === uid ? Object.assign({}, other, { disabled: disabled }) : other),
			`${root.keyText(bind.key)} ${disabled ? "switched off" : "switched on"}`);
	}

	// a bind and the one in the way swap their keys; `others` are edited at once
	function commitMany(changed, note) {
		const byUid = {};
		changed.forEach(bind => byUid[bind.uid] = bind);
		const list = root.binds.map(bind => byUid[bind.uid] ?? bind);
		changed.filter(bind => !root.byUid(bind.uid)).forEach(bind => {
			const copy = Object.assign({}, bind);
			copy.uid = copy.uid || root.nextUid++;
			list.push(copy);
		});
		root.commit(list, note);
	}

	function byUid(uid) {
		return root.binds.find(bind => bind.uid === uid) ?? null;
	}

	// ── keys ───────────────────────────────────────────────────────────────
	readonly property var modifierNames: ({
		mod: "Mod", super: "Super", win: "Super", ctrl: "Ctrl", control: "Ctrl", shift: "Shift", alt: "Alt",
		iso_level3_shift: "ISO_Level3_Shift", mod5: "ISO_Level3_Shift", iso_level5_shift: "ISO_Level5_Shift"
	})
	readonly property var modifierOrder: ["Mod", "Super", "Ctrl", "Alt", "Shift", "ISO_Level3_Shift", "ISO_Level5_Shift"]

	function split(key) {
		const parts = String(key || "").split("+").filter(part => part !== "");
		if (parts.length === 0) return { mods: [], key: "" };
		const mods = parts.slice(0, -1).map(part => root.modifierNames[part.toLowerCase()] ?? part);
		return { mods: mods, key: parts[parts.length - 1] };
	}

	function join(mods, key) {
		const sorted = mods.slice().sort((a, b) => root.modifierOrder.indexOf(a) - root.modifierOrder.indexOf(b));
		return sorted.concat(key ? [key] : []).join("+");
	}

	function norm(key) {
		const parts = root.split(key);
		if (parts.key === "") return "";
		const mods = Array.from(new Set(parts.mods)).sort((a, b) => root.modifierOrder.indexOf(a) - root.modifierOrder.indexOf(b));
		return mods.concat([parts.key.toLowerCase()]).join("+");
	}

	// the live bind on this key, other than `uid`
	function conflict(key, uid) {
		const target = root.norm(key);
		if (target === "") return null;
		return root.binds.find(bind => bind.uid !== uid && !bind.disabled && root.norm(bind.key) === target) ?? null;
	}

	readonly property var keyLabels: ({
		Mod: "Super", Super: "Super", Ctrl: "Ctrl", Alt: "Alt", Shift: "Shift", ISO_Level3_Shift: "AltGr", ISO_Level5_Shift: "Level5",
		left: "←", right: "→", up: "↑", down: "↓",
		page_down: "PgDn", page_up: "PgUp", next: "PgDn", prior: "PgUp", home: "Home", end: "End",
		bracketleft: "[", bracketright: "]", braceleft: "{", braceright: "}", parenleft: "(", parenright: ")",
		comma: ",", period: ".", minus: "−", equal: "=", plus: "+", slash: "/", backslash: "\\", semicolon: ";",
		apostrophe: "'", grave: "`", numbersign: "#", less: "<", greater: ">", asciicircum: "^", dead_circumflex: "^",
		dead_acute: "´", dead_grave: "`", ssharp: "ß", adiaeresis: "Ä", odiaeresis: "Ö", udiaeresis: "Ü",
		return: "Enter", space: "Space", escape: "Esc", tab: "Tab", backspace: "⌫", delete: "Del", insert: "Ins", print: "Print",
		wheelscrolldown: "Wheel ↓", wheelscrollup: "Wheel ↑", wheelscrollleft: "Wheel ←", wheelscrollright: "Wheel →",
		touchpadscrolldown: "Touchpad ↓", touchpadscrollup: "Touchpad ↑", touchpadscrollleft: "Touchpad ←", touchpadscrollright: "Touchpad →",
		mouseleft: "Left click", mouseright: "Right click", mousemiddle: "Middle click", mouseback: "Mouse back", mouseforward: "Mouse forward",
		xf86audioraisevolume: "Vol +", xf86audiolowervolume: "Vol −", xf86audiomute: "Mute", xf86audiomicmute: "Mic mute",
		xf86monbrightnessup: "Bright +", xf86monbrightnessdown: "Bright −", xf86audioplay: "Play", xf86audiopause: "Pause",
		xf86audionext: "Next", xf86audioprev: "Prev", xf86audiostop: "Stop", xf86calculator: "Calc", xf86search: "Search"
	})

	function keyLabel(part) {
		const raw = String(part || "");
		const label = root.keyLabels[raw] ?? root.keyLabels[raw.toLowerCase()];
		if (label) return label;
		if (raw.length === 1) return raw.toUpperCase();
		return raw.replace(/^XF86/, "").replace(/_/g, " ");
	}

	// keycaps of a key: ["Super", "Shift", "D"]
	function caps(key) {
		const parts = root.split(key);
		if (parts.key === "") return [];
		return parts.mods.map(mod => root.keyLabel(mod)).concat([root.keyLabel(parts.key)]);
	}

	function keyText(key) {
		return root.caps(key).join(" ");
	}

	// what niri calls the key a key event came from: its name without
	// modifiers, from the layout (scripts/keybinds.py keymap)
	readonly property var qtKeys: ({
		[Qt.Key_Left]: "Left", [Qt.Key_Right]: "Right", [Qt.Key_Up]: "Up", [Qt.Key_Down]: "Down",
		[Qt.Key_PageUp]: "Page_Up", [Qt.Key_PageDown]: "Page_Down", [Qt.Key_Home]: "Home", [Qt.Key_End]: "End",
		[Qt.Key_Return]: "Return", [Qt.Key_Enter]: "KP_Enter", [Qt.Key_Space]: "space", [Qt.Key_Tab]: "Tab", [Qt.Key_Backtab]: "Tab",
		[Qt.Key_Escape]: "Escape", [Qt.Key_Backspace]: "BackSpace", [Qt.Key_Delete]: "Delete", [Qt.Key_Insert]: "Insert",
		[Qt.Key_Print]: "Print", [Qt.Key_Comma]: "Comma", [Qt.Key_Period]: "Period", [Qt.Key_Minus]: "Minus",
		[Qt.Key_Equal]: "Equal", [Qt.Key_Plus]: "plus", [Qt.Key_Slash]: "Slash", [Qt.Key_BracketLeft]: "BracketLeft",
		[Qt.Key_BracketRight]: "BracketRight", [Qt.Key_VolumeUp]: "XF86AudioRaiseVolume", [Qt.Key_VolumeDown]: "XF86AudioLowerVolume",
		[Qt.Key_VolumeMute]: "XF86AudioMute", [Qt.Key_MediaPlay]: "XF86AudioPlay", [Qt.Key_MediaNext]: "XF86AudioNext",
		[Qt.Key_MediaPrevious]: "XF86AudioPrev", [Qt.Key_MonBrightnessUp]: "XF86MonBrightnessUp", [Qt.Key_MonBrightnessDown]: "XF86MonBrightnessDown"
	})
	readonly property var keysymAliases: ({ Prior: "Page_Up", Next: "Page_Down" })
	readonly property var modifierKeys: [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_AltGr, Qt.Key_Hyper_L, Qt.Key_Hyper_R, Qt.Key_CapsLock, Qt.Key_NumLock]

	function isModifierKey(event) {
		return root.modifierKeys.includes(event.key);
	}

	function modsOf(modifiers) {
		const mods = [];
		if (modifiers & Qt.MetaModifier) mods.push("Mod");
		if (modifiers & Qt.ControlModifier) mods.push("Ctrl");
		if (modifiers & Qt.AltModifier) mods.push("Alt");
		if (modifiers & Qt.ShiftModifier) mods.push("Shift");
		return mods;
	}

	// keys whose name does not depend on the layout: Qt knows them, also from
	// virtual keyboards that bring keymaps of their own
	readonly property var plainKeys: [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp, Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End,
		Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Tab, Qt.Key_Backtab, Qt.Key_Escape, Qt.Key_Backspace, Qt.Key_Delete, Qt.Key_Insert, Qt.Key_Print]

	function keyName(event) {
		let name = "";
		if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(event.key);
		else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9 && !(event.modifiers & Qt.ShiftModifier)) name = String.fromCharCode(event.key);
		else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35) name = `F${event.key - Qt.Key_F1 + 1}`;
		else if (root.plainKeys.includes(event.key)) name = root.qtKeys[event.key];
		if (name !== "") return name;
		// symbols: the key without Shift, as niri matches it (Shift+7 is 7, not /)
		name = root.keymap[String(event.nativeScanCode)] ?? "";
		if (/^(Shift|Control|Alt|Super|Meta|Hyper|ISO_Level\d)_?/.test(name)) return "";
		name = root.keysymAliases[name] ?? name;
		if (name === "") name = root.qtKeys[event.key] ?? "";
		if (/^[a-z]$/.test(name)) name = name.toUpperCase();
		return name;
	}

	// ── what a bind does, in words ─────────────────────────────────────────
	function category(bind) {
		const action = String(bind?.action || "");
		const args = bind?.args || [];
		if (root.isShell(bind)) return "Shell";
		if (action === "spawn" || action === "spawn-sh") return "Launch";
		if (action.includes("screenshot")) return "Screenshots";
		if (action.includes("monitor")) return "Monitors";
		if (action.includes("workspace")) return "Workspaces";
		if (["window", "column", "consume", "expel", "tabbed", "floating", "maximize"].some(word => action.includes(word))) return "Windows";
		return "System";
	}

	function categoryIcon(id) {
		return root.categories.find(entry => entry.id === id)?.icon ?? "keyboard";
	}

	function isShell(bind) {
		const args = bind?.args || [];
		return bind?.action === "spawn" && args[0] === "qs" && args.includes("ipc") && args.indexOf("call") >= 0;
	}

	// { target, fn, params } of a shell bind
	function shellCall(bind) {
		const args = bind.args || [];
		const at = args.indexOf("call");
		return { target: String(args[at + 1] || ""), fn: String(args[at + 2] || ""), params: args.slice(at + 3).map(String) };
	}

	function appId(bind) {
		const args = bind?.args || [];
		if (bind?.action === "spawn" && args[0] === "app2unit" && args[1] === "--" && String(args[2] || "").endsWith(".desktop"))
			return String(args[2]).slice(0, -8);
		return "";
	}

	function app(bind) {
		if (bind?.action !== "spawn") return null;
		const id = root.appId(bind);
		const apps = DesktopEntries.applications.values;
		if (id !== "") return apps.find(entry => entry.id === id) ?? DesktopEntries.byId(id);
		const program = String((bind.args || [])[0] || "").split("/").pop();
		if (program === "" || program === "qs") return null;
		return apps.find(entry => entry.id === program || String(entry.command?.[0] || "").split("/").pop() === program) ?? null;
	}

	function words(name) {
		const text = String(name || "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[-_]/g, " ").toLowerCase().trim();
		return text.charAt(0).toUpperCase() + text.slice(1);
	}

	function argText(value) {
		if (typeof value === "string") return value.replace(/^-/, "−");
		return String(value);
	}

	function actionTitle(bind) {
		if (!bind || !bind.action) return "";
		if (root.isShell(bind)) {
			const call = root.shellCall(bind);
			const params = call.params.filter(p => p !== "").length ? ` · ${call.params.join(" ")}` : "";
			// lock lock → Lock, toggleMedia panels → Toggle media
			const fn = root.words(call.fn);
			const target = root.words(call.target).toLowerCase();
			if (fn.toLowerCase() === target) return `${fn}${params}`;
			if (fn.includes(" ")) return `${root.words(call.target)}: ${fn.toLowerCase()}${params}`;
			return `${fn} ${target}${params}`;
		}
		const app = root.app(bind);
		if (app) return app.name;
		if (bind.action === "spawn") return String((bind.args || [])[0] || "").split("/").pop();
		if (bind.action === "spawn-sh") return String((bind.args || [])[0] || "");
		const args = (bind.args || []).map(root.argText).join(" ");
		return `${root.words(bind.action)}${args ? " " + args : ""}`;
	}

	// the name it shows with: its overlay title, or what it does
	function title(bind) {
		const named = bind?.props?.["hotkey-overlay-title"];
		if (typeof named === "string" && named !== "") return named;
		return root.actionTitle(bind);
	}

	// the line under the title: the call as niri reads it
	function detail(bind) {
		if (!bind || !bind.action) return "";
		if (root.isShell(bind)) {
			const call = root.shellCall(bind);
			return `shell ipc · ${call.target} ${call.fn}${call.params.length ? " " + call.params.join(" ") : ""}`;
		}
		if (bind.action === "spawn") return (bind.args || []).join(" ");
		if (bind.action === "spawn-sh") return "shell command";
		const named = bind?.props?.["hotkey-overlay-title"];
		return named ? root.actionTitle(bind) : bind.action;
	}

	function kind(bind) {
		if (!bind || !bind.action) return "";
		if (root.isShell(bind)) return "shell";
		if (root.appId(bind) !== "" || (bind.action === "spawn" && root.app(bind))) return "app";
		if (bind.action === "spawn" || bind.action === "spawn-sh") return "command";
		return "niri";
	}

	// runs a bind's action now, the way niri would
	function run(bind) {
		if (!bind || !bind.action) return;
		const args = (bind.args || []).map(String);
		if (bind.action === "spawn") {
			if (args.length > 0) Quickshell.execDetached(args.map(arg => arg.replace(/^~(?=\/|$)/, Paths.home)));
			return;
		}
		if (bind.action === "spawn-sh") {
			Quickshell.execDetached(["sh", "-c", args.join(" ")]);
			return;
		}
		const props = [];
		for (const name in (bind.aprops || {})) props.push(`--${name}`, String(bind.aprops[name]));
		Quickshell.execDetached(["niri", "msg", "action", bind.action].concat(props, args));
	}

	onEnabledChanged: if (root.enabled) root.load()

	Process {
		id: lister

		command: ["python3", root.script, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				root.loading = false;
				try {
					const data = JSON.parse(text);
					root.adopted = !!data.adopted;
					root.file = String(data.file || "");
					root.binds = root.restamp(data.binds || []);
					root.loaded = true;
					// the binds niri has now are taken over the first time
					if (!root.adopted && root.binds.length > 0 && !adopter.running) adopter.running = true;
				} catch (error) {
					root.error = `Could not read the binds: ${error}`;
				}
			}
		}
		onExited: root.loading = false
	}

	Process {
		id: writer

		property string note: ""
		property var previous: []
		property var previousHistory: []
		property real doneAt: 0
		property string again: ""

		stdout: StdioCollector {
			onStreamFinished: {
				root.saving = false;
				writer.doneAt = Date.now();
				let result = null;
				try {
					result = JSON.parse(text);
				} catch (error) {
					result = { ok: false, error: String(text || "keybinds.py failed") };
				}
				if (writer.again !== "") {
					const note = writer.again;
					writer.again = "";
					if (result.ok) {
						Qt.callLater(() => root.write(root.binds, root.history, note));
						return;
					}
				}
				if (result.ok) {
					root.savedNote = result.adopted ? "Your binds are now kept in keybinds.kdl" : writer.note;
					root.savedCount += 1;
					if (result.adopted) {
						root.adopted = true;
						// sources change from config.kdl to keybinds.kdl
						root.load();
					}
				} else {
					root.error = String(result.error || "niri rejected the binds");
					root.binds = writer.previous;
					root.history = writer.previousHistory;
				}
			}
		}
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
					result = { ok: false, error: String(text || "keybinds.py adopt failed") };
				}
				if (result.ok) {
					root.adopted = true;
					if (!result.already) {
						root.savedNote = `${root.binds.length} binds taken over into keybinds.kdl`;
						root.savedCount += 1;
					}
					writer.doneAt = Date.now();
					root.load();
				} else {
					root.error = String(result.error || "Could not take over the binds");
				}
			}
		}
	}

	Process {
		id: actionsProc

		command: ["python3", root.script, "actions"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.niriActions = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	Process {
		id: shellProc

		command: ["python3", root.script, "shell-actions"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.shellActions = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	Process {
		id: keymapProc

		command: ["python3", root.script, "keymap"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.keymap = JSON.parse(text);
				} catch (error) {}
			}
		}
	}

	// a hand edit of keybinds.kdl shows up
	FileView {
		path: root.enabled && root.adopted ? root.file : ""
		watchChanges: true
		printErrors: false
		// our own writes are no news
		onFileChanged: if (!writer.running && Date.now() - writer.doneAt > 1500) reloadSoon.restart()
	}

	Timer {
		id: reloadSoon

		interval: 400
		onTriggered: if (!writer.running) root.load()
	}
}
