pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Whether a microphone, a camera or the screen is in use by some program,
// for the marks the cursor carries (CursorTheme). Read from PipeWire's links:
// a microphone or camera device feeding a program's stream, or one of niri's
// screencasts feeding a program that is not the shell's own (the light
// mirroring, the game's eyes, a live screenshot). A camera opened without
// PipeWire is found by its open device, looked for every few seconds while
// anything is watching.
Singleton {
	id: root

	// set while someone wants to know (CursorTheme)
	property bool watched: false

	readonly property var groups: root.watched ? (Pipewire.linkGroups?.values ?? []) : []

	// No PwObjectTracker here: binding the short-lived nodes of links crashed
	// Quickshell (pw_proxy_destroy in safeDestroy when a node went away). Node
	// type, name and isStream come unbound; an "…/Internal" stream has no
	// known type, so it is no stream.

	// a program's stream, not one of the shell's own readers of the screen
	// and the microphone
	function foreign(node) {
		return !!node && node.isStream && !/^(python|quickshell|qs$|gst|cava|wf-recorder|pw-record|pw-cat)/i.test(String(node.name || ""));
	}

	readonly property bool mic: root.groups.some(group => !!group.source && !group.source.isStream
		&& group.source.type === PwNodeType.AudioSource && root.foreign(group.target))
	readonly property bool cameraLinked: root.groups.some(group => !!group.source && !group.source.isStream
		&& (group.source.type & PwNodeType.Video) && (group.source.type & PwNodeType.Source) && root.foreign(group.target))
	readonly property bool sharing: root.groups.some(group => !!group.source && group.source.isStream
		&& (group.source.type & PwNodeType.Video) && String(group.source.name) === "niri" && root.foreign(group.target))
	property bool cameraOpen: false
	readonly property bool camera: root.cameraLinked || root.cameraOpen

	// a camera can be used without PipeWire: its device is open
	Timer {
		interval: 4000
		repeat: true
		running: root.watched
		triggeredOnStart: true
		onTriggered: if (!probe.running) probe.running = true
	}

	Process {
		id: probe

		command: ["sh", "-c", "ls /dev/video* >/dev/null 2>&1 || exit 1; find /proc/[0-9]*/fd -lname '/dev/video*' -print -quit 2>/dev/null | grep -q ."]
		onExited: code => root.cameraOpen = code === 0
	}
}
