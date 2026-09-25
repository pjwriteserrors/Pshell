pragma Singleton

import QtQuick
import Quickshell

// MX Master 4 haptics through mxh (~/.local/bin/mxh → mx4-hapticd FIFO).
// Only moments that deserve a physical confirmation play something; plain
// clicks stay silent. Features name the moment, this table picks the effect.
//
// Waveforms the mouse knows: SHARP/DAMP STATE CHANGE, SHARP/DAMP/SUBTLE/
// WHISPER COLLISION, HAPPY/ANGRY ALERT, COMPLETED, SQUARE, WAVE, FIREWORK,
// MAD, KNOCK, JINGLE, RINGING.
Singleton {
	id: root

	readonly property string mxhPath: `${Quickshell.env("HOME")}/.local/bin/mxh`

	readonly property var effects: ({
		// notifications (silent while do-not-disturb is on)
		notification: "DAMP STATE CHANGE",
		// screenshots and recordings
		captured: "SUBTLE COLLISION",
		copied: "COMPLETED",
		saved: "COMPLETED",
		colorPicked: "SHARP COLLISION",
		pinned: "DAMP COLLISION",
		// something (a Bluetooth pairing request …) waits for an answer
		attention: "KNOCK",
		recordingStarted: "SHARP STATE CHANGE",
		recordingStopped: "COMPLETED",
		// modes
		dndOn: "DAMP STATE CHANGE",
		dndOff: "SHARP STATE CHANGE",
		// results of longer jobs
		taskDone: "COMPLETED",
		taskFailed: "ANGRY ALERT",
		sent: "COMPLETED",
		// lock screen
		wrongPassword: "ANGRY ALERT",
		// all items of a todo list are done
		listDone: "FIREWORK"
	})

	function play(event) {
		const effect = root.effects[event] ?? event;
		if (!effect) return;
		Quickshell.execDetached([root.mxhPath, String(effect)]);
	}
}
