pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The machine this shell runs on: hosts/machines.json maps the hostname to a
// profile in hosts/<profile>.json: outputs, wallpapers, theme hooks and which
// plugins a fresh setup of that machine starts with (see Plugins).
Singleton {
	id: root

	readonly property string hostname: hostnameFile.text().trim()
	// PSHELL_HOST picks a profile by name, before the machine is in machines.json
	readonly property string name: Quickshell.env("PSHELL_HOST") || root.mappedName
	readonly property string mappedName: {
		try {
			return String(JSON.parse(machinesFile.text() || "{}")[root.hostname] || "");
		} catch (error) {
			return "";
		}
	}
	readonly property var profile: {
		try {
			return JSON.parse(profileFile.text() || "{}");
		} catch (error) {
			console.warn(`Host: hosts/${root.name}.json is not valid JSON`);
			return {};
		}
	}
	readonly property string primaryOutput: String(root.profile.primaryOutput || "")
	readonly property string wallpapers: String(root.profile.wallpapers || "~/Pictures/Wallpapers").replace(/^~(?=\/|$)/, Quickshell.env("HOME"))
	readonly property string user: Quickshell.env("USER") || ""
	readonly property string kernel: kernelFile.text().trim()

	// how long the machine has been up, "3 days, 4 hours" (read when asked)
	function uptime() {
		uptimeFile.reload();
		const seconds = Math.floor(Number(String(uptimeFile.text()).split(" ")[0]) || 0);
		const days = Math.floor(seconds / 86400);
		const hours = Math.floor(seconds % 86400 / 3600);
		const minutes = Math.floor(seconds % 3600 / 60);
		const parts = [];
		if (days > 0) parts.push(`${days} ${days === 1 ? "day" : "days"}`);
		if (hours > 0) parts.push(`${hours} ${hours === 1 ? "hour" : "hours"}`);
		if (days === 0 && (minutes > 0 || hours === 0)) parts.push(`${minutes} ${minutes === 1 ? "minute" : "minutes"}`);
		return parts.join(", ");
	}

	FileView {
		id: kernelFile

		path: "/proc/sys/kernel/osrelease"
		blockLoading: true
	}

	FileView {
		id: uptimeFile

		path: "/proc/uptime"
		blockLoading: true
	}

	FileView {
		id: hostnameFile

		path: "/etc/hostname"
		blockLoading: true
	}

	FileView {
		id: machinesFile

		path: `${Quickshell.shellDir}/hosts/machines.json`
		blockLoading: true
	}

	FileView {
		id: profileFile

		path: root.name !== "" ? `${Quickshell.shellDir}/hosts/${root.name}.json` : ""
		blockLoading: true
		watchChanges: true
		onFileChanged: reload()
	}
}
