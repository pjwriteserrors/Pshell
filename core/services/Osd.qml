pragma Singleton

import QtQuick
import Quickshell

// Transient level indicator (volume, microphone, brightness).
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
		hideTimer.restart();
	}

	Timer {
		id: hideTimer
		interval: 1400
		onTriggered: root.visible = false
	}
}
