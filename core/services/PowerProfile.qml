pragma Singleton

import QtQuick
import Quickshell
// qualified: this singleton shares its name with UPower's enum
import Quickshell.Services.UPower as UPower

// power-profiles-daemon through Quickshell's PowerProfiles: follows it as it
// changes, cycles or sets.
Singleton {
	id: root

	readonly property bool wanted: Plugins.on("power-profiles")
	readonly property var names: ({ [UPower.PowerProfile.PowerSaver]: "power-saver", [UPower.PowerProfile.Balanced]: "balanced", [UPower.PowerProfile.Performance]: "performance" })
	readonly property string current: root.wanted ? (root.names[UPower.PowerProfiles.profile] ?? "") : ""
	readonly property var profiles: root.wanted ? ["power-saver", "balanced"].concat(UPower.PowerProfiles.hasPerformanceProfile ? ["performance"] : []) : []
	readonly property bool available: root.wanted && root.current !== ""

	readonly property var labels: ({ "power-saver": "Power saver", "balanced": "Balanced", "performance": "Performance" })
	readonly property var icons: ({ "power-saver": "leaf", "balanced": "scale_balance", "performance": "speedometer" })

	function label(profile) {
		return root.labels[profile] ?? profile;
	}

	function icon(profile) {
		return root.icons[profile] ?? "speedometer";
	}

	function set(profile) {
		if (!root.wanted || !profile || profile === root.current) return;
		const value = Object.keys(root.names).find(key => root.names[key] === profile);
		if (value !== undefined) UPower.PowerProfiles.profile = Number(value);
	}

	function cycle() {
		const order = root.profiles;
		if (order.length === 0) return;
		root.set(order[(order.indexOf(root.current) + 1) % order.length]);
	}
}
