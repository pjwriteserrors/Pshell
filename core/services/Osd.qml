pragma Singleton

import QtQuick
import Quickshell

// Transient level indicator (volume, microphone, brightness), and how far a
// theme change is.
Singleton {
	id: root

	property bool visible: false
	property string kind: ""
	property string label: ""
	property string icon: ""
	property string valueText: ""
	property real progress: 0
	property int serial: 0

	function show(kind, label, progress, valueText, icon) {
		if (!Plugins.on("osd")) return;
		root.kind = kind;
		root.label = label;
		root.progress = Math.max(0, Math.min(1.5, progress));
		root.valueText = valueText;
		root.icon = icon;
		root.visible = true;
		root.serial += 1;
		hideTimer.interval = 1400;
		hideTimer.restart();
	}

	// a job counting its steps: stays up until the last one. Steps that run
	// side by side may report out of order, so the bar never goes back
	function advance(kind, label, done, total, icon) {
		const running = root.visible && root.kind === kind;
		let progress = total > 0 ? Math.min(1, done / total) : 1;
		// the end of a job whose bar has left already (a step took its time)
		if (progress >= 1 && !running) return;
		if (done > 0 && running) progress = Math.max(root.progress, progress);
		show(kind, label, progress, `${Math.round(progress * 100)}%`, icon);
		if (progress < 1 && root.visible) {
			hideTimer.interval = 15000;
			hideTimer.restart();
		}
	}

	Timer {
		id: hideTimer
		onTriggered: root.visible = false
	}
}
