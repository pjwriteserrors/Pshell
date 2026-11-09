pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The pointer kept inside the focused window (plugin `mouse-capture`): a key
// (Page Down here, `mousecapture toggle`) catches it there and lets it go
// again, so that in a game the mouse swung far never lands on another
// window or monitor. scripts/mouse_capture.py takes the mice for as long as
// it lasts; MouseCaptureHud shows it coming and going.
//
// niri tells where a floating window is, not a tiled one: a tiled window as
// big as its screen is the screen, a bigger half of one is held to the part
// it covers wherever the view has scrolled it, a smaller one gets its
// whole screen (`scope` "screen").
Singleton {
	id: root

	readonly property bool available: Plugins.on("mouse-capture")
	property bool active: false
	property int windowId: -1
	property string title: ""
	property string appId: ""
	property string output: ""
	// "window" or "screen": what the pointer is held to
	property string scope: "window"
	// where, in logical pixels of the whole layout
	property var rect: null
	// the probe (overlays/PointerProbe) asks where the pointer is
	property bool probing: false
	// the daemon cannot work here; said once a capture
	property string failure: ""
	property bool again: false

	// settings (mouse-capture.json)
	property bool releaseOnFocus: true
	property bool hud: true
	// how far the pointer goes per count, on top of niri's own settings
	property real speed: 1.0

	// the overlay: a bump per thing to show, what it was and where
	property int flashes: 0
	property string flashKind: ""
	property var flashRect: null
	property string flashOutput: ""

	readonly property var failures: ({
		permission: "The mouse is not readable",
		devices: "No mouse found",
		uinput: "/dev/uinput is not writable"
	})

	function toggle() {
		if (root.active) root.release("key");
		else root.capture();
	}

	function capture() {
		if (!root.available || root.active || Session.locked) return;
		const window = Niri.windows.find(w => w.is_focused) ?? null;
		const place = window ? root.placeOf(window) : null;
		// another PC has the mouse (Kvm.qml): nothing to hold here
		if (!place || Kvm.mode === "away") {
			const screen = Quickshell.screens.find(s => s.name === (Niri.workspaces.find(w => w.is_focused)?.output ?? "")) ?? Quickshell.screens[0];
			root.flash("none", screen ? { x: screen.x, y: screen.y, w: screen.width, h: screen.height } : null, screen ? screen.name : "");
			return;
		}
		root.windowId = Number(window.id);
		root.title = String(window.title || "");
		root.appId = String(window.app_id || "");
		root.output = place.output;
		root.scope = place.scope;
		root.rect = place.rect;
		root.failure = "";
		root.active = true;
		root.probing = true;
		// the last one is still on its way out: this one starts after it
		if (daemon.running) root.again = true;
		else daemon.running = true;
		probeEnd.restart();
		root.flash("captured", place.rect, place.output);
	}

	// why: "key", "focus", "closed", "locked", "failed"
	function release(why) {
		if (!root.active) return;
		root.active = false;
		root.probing = false;
		if (daemon.running) daemon.write(JSON.stringify({ op: "quit" }) + "\n");
		quitGuard.restart();
		if (why !== "failed") root.flash("released", root.rect, root.output);
	}

	function flash(kind, rect, output) {
		if (!root.hud) return;
		root.flashKind = kind;
		root.flashRect = rect;
		root.flashOutput = output;
		root.flashes++;
	}

	// { output, scope, rect: {x, y, w, h} } of a window, or null
	function placeOf(window) {
		const workspace = Niri.workspaceById[window.workspace_id] ?? Niri.workspaces.find(w => w.id === window.workspace_id);
		const screen = Quickshell.screens.find(s => s.name === workspace?.output);
		const layout = window.layout;
		if (!screen || !layout) return null;
		const sx = screen.x, sy = screen.y, sw = screen.width, sh = screen.height;
		const size = layout.window_size ?? layout.tile_size ?? [sw, sh];
		const offset = layout.window_offset_in_tile ?? [0, 0];
		const ww = size[0], wh = size[1];
		const whole = { x: sx, y: sy, w: sw, h: sh };
		const tile = layout.tile_pos_in_workspace_view;
		if (tile) return { output: screen.name, scope: "window", rect: { x: sx + tile[0] + offset[0], y: sy + tile[1] + offset[1], w: ww, h: wh } };
		if (ww >= sw - 1 && wh >= sh - 1) return { output: screen.name, scope: "window", rect: whole };
		// tiled: wherever it lies on its screen it covers at least this
		if (ww > sw / 2 && wh > sh / 2) return { output: screen.name, scope: "window", rect: { x: sx + sw - ww, y: sy + sh - wh, w: 2 * ww - sw, h: 2 * wh - sh } };
		return { output: screen.name, scope: "screen", rect: whole };
	}

	function bounds() {
		const screens = Quickshell.screens;
		if (screens.length === 0) return [0, 0, 1, 1];
		return [Math.min(...screens.map(s => s.x)), Math.min(...screens.map(s => s.y)), Math.max(...screens.map(s => s.x + s.width)), Math.max(...screens.map(s => s.y + s.height))];
	}

	function send(data) {
		if (daemon.running) daemon.write(JSON.stringify(data) + "\n");
	}

	function sendRect() {
		if (root.rect) root.send(Object.assign({ op: "rect", bounds: root.bounds() }, root.rect));
	}

	function sendAccel() {
		const flat = String(NiriSettings.arg(["input", "mouse", "accel-profile"], "adaptive")) === "flat";
		root.send({ op: "accel", profile: flat ? "flat" : "adaptive", speed: Number(NiriSettings.arg(["input", "mouse", "accel-speed"], 0)) || 0, factor: root.speed });
	}

	function probed(x, y) {
		if (!root.probing) return;
		root.probing = false;
		root.send({ op: "at", x, y });
	}

	// the window moved or changed size: the cage goes along
	function follow() {
		if (!root.active) return;
		const window = Niri.windows.find(w => Number(w.id) === root.windowId);
		if (!window) {
			root.release("closed");
			return;
		}
		if (root.releaseOnFocus && Niri.focusedId !== -1 && Niri.focusedId !== root.windowId) {
			root.release("focus");
			return;
		}
		const place = root.placeOf(window);
		if (!place || JSON.stringify(place.rect) === JSON.stringify(root.rect)) return;
		root.rect = place.rect;
		root.scope = place.scope;
		root.output = place.output;
		root.sendRect();
	}

	function save() {
		settings.setText(JSON.stringify({ releaseOnFocus: root.releaseOnFocus, hud: root.hud, speed: root.speed }, null, "\t") + "\n");
	}

	function set(key, value) {
		root[key] = value;
		root.save();
		if (key === "speed") root.sendAccel();
	}

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (data.type === "error") {
			root.failure = data.reason ?? "";
			root.release("failed");
			Notifs.pushInternal("error", "Mouse capture", root.failures[data.reason] ?? "", { icon: "mouse" });
		}
	}

	Connections {
		target: Niri

		function onWindowsChanged() {
			root.follow();
		}
		function onFocusedIdChanged() {
			root.follow();
		}
	}

	Connections {
		target: Session

		function onLockedChanged() {
			if (Session.locked) root.release("locked");
		}
	}

	onAvailableChanged: if (!root.available) root.release("key")

	// the probe did not hear back: the daemon starts from the window's middle
	Timer {
		id: probeEnd

		interval: 900
		onTriggered: root.probing = false
	}

	// a daemon that does not end by itself is ended
	Timer {
		id: quitGuard

		interval: 1500
		onTriggered: if (!root.active && daemon.running) daemon.running = false
	}

	FileView {
		id: settings

		path: Paths.stateFile("mouse-capture.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.releaseOnFocus = data.releaseOnFocus !== false;
				root.hud = data.hud !== false;
				if (typeof data.speed === "number") root.speed = Math.min(3, Math.max(0.25, data.speed));
			} catch (error) {}
		}
	}

	Process {
		id: daemon

		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/mouse_capture.py`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onStarted: {
			root.sendRect();
			root.sendAccel();
		}
		onExited: {
			if (root.again && root.active) {
				root.again = false;
				daemon.running = true;
				return;
			}
			root.again = false;
			root.probing = false;
			if (root.active) root.release("failed");
		}
	}
}
