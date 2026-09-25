pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The machine this shell runs on: hosts/machines.json maps the hostname to a
// profile in hosts/<profile>.json. Everything that only makes sense on some
// machines asks Host.has("<feature>"); features a profile does not name are
// off, so an unknown machine gets the lean shell.
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
	readonly property var features: root.profile.features || {}

	readonly property string primaryOutput: String(root.profile.primaryOutput || "")
	readonly property string wallpapers: String(root.profile.wallpapers || "~/Pictures/Wallpapers").replace(/^~(?=\/|$)/, Quickshell.env("HOME"))

	function has(feature) {
		return root.features[feature] === true;
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
