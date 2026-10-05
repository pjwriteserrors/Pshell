import QtQuick
import Quickshell
import qs.core.services

// system: what the system monitor shows.
Topic {
	id: topic

	name: "system"
	throttle: 500

	function rounded(values) {
		return values.map(value => Math.round(value * 1000) / 1000);
	}

	data: topic.wanted ? ({
		cpu: Math.round(SysStats.cpu * 1000) / 1000,
		cores: SysStats.cpuCores,
		cpuHistory: topic.rounded(SysStats.cpuHistory),
		memory: Math.round(SysStats.memory * 1000) / 1000,
		memoryUsed: SysStats.memoryUsedKiB,
		memoryTotal: SysStats.memoryTotalKiB,
		memoryHistory: topic.rounded(SysStats.memoryHistory),
		disks: SysStats.disks,
		battery: SysStats.batteryAvailable ? { percent: SysStats.batteryPercent, charging: SysStats.charging } : null,
		mouse: SysStats.mouseAvailable ? { name: SysStats.mouseName, level: SysStats.mouseLevel, text: SysStats.mouseText } : null
	}) : null
}
