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
		mouse: SysStats.mouseAvailable ? { name: SysStats.mouseName, level: SysStats.mouseLevel, text: SysStats.mouseText } : null,
		// from the task manager: what takes the machine, and what can be ended from the phone
		tasks: topic.tasks ? {
			temp: TaskManager.temps.cpu ?? null,
			gpu: TaskManager.hasGpu ? Math.round(TaskManager.gpu * 1000) / 1000 : null,
			top: TaskManager.top.slice(0, 6).map(item => ({ key: item.key, name: item.name, kind: item.kind, cpu: item.c, mem: item.m, paused: TaskManager.isPaused(item.key) }))
		} : null
	}) : null

	readonly property bool tasks: Plugins.on("task-manager") && TaskManager.connected
	// the daemon keeps looking while the phone shows the page
	onWantedChanged: if (Plugins.on("task-manager")) TaskManager.watch(topic.wanted ? 1 : -1, false)

	function call(action, args, done) {
		if (!topic.tasks) throw new Error("plugin-off");
		const key = String(args.key ?? "");
		switch (action) {
		case "end":
		case "kill":
		case "pause":
		case "resume":
			if (key === "" || key === "pshell") throw new Error("Not this one");
			TaskManager.act(key, action);
			return {};
		}
		throw new Error("unknown-action");
	}
}
