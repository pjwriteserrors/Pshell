pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// power-profiles-daemon via powerprofilesctl: read on demand, cycle or set.
Singleton {
	id: root

	property string current: ""
	property var profiles: []
	readonly property bool available: root.profiles.length > 0

	readonly property var labels: ({ "power-saver": "Power saver", "balanced": "Balanced", "performance": "Performance" })
	readonly property var icons: ({ "power-saver": "leaf", "balanced": "scale_balance", "performance": "speedometer" })

	function label(profile) {
		return root.labels[profile] ?? profile;
	}

	function icon(profile) {
		return root.icons[profile] ?? "speedometer";
	}

	function refresh() {
		if (Host.has("power-profiles") && !readProc.running) readProc.running = true;
	}

	function set(profile) {
		if (!profile || profile === root.current) return;
		root.current = profile;
		const proc = setter.createObject(root);
		proc.command = ["powerprofilesctl", "set", profile];
		proc.running = true;
	}

	function cycle() {
		const order = ["power-saver", "balanced", "performance"].filter(p => root.profiles.includes(p));
		if (order.length === 0) return;
		root.set(order[(order.indexOf(root.current) + 1) % order.length]);
	}

	Component {
		id: setter

		Process {
			onExited: {
				root.refresh();
				destroy();
			}
		}
	}

	Process {
		id: readProc

		command: ["sh", "-c", "powerprofilesctl get; powerprofilesctl list | sed -n 's/^[* ] *\\([a-z-]*\\):$/\\1/p'"]
		stdout: StdioCollector {
			onStreamFinished: {
				const lines = String(text).split("\n").map(l => l.trim()).filter(l => l !== "");
				if (lines.length === 0) return;
				root.current = lines[0];
				root.profiles = lines.slice(1);
			}
		}
	}

	Component.onCompleted: root.refresh()
}
