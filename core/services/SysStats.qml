pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// CPU, memory, disks, the mouse battery (the mouse daemon, UPower or a Razer
// mouse's sysfs) and the laptop battery (UPower, as it changes). CPU/RAM keep a short history for charts.
Singleton {
	id: root

	property real cpu: 0
	property real memory: 0
	property real memoryUsedKiB: 0
	property real memoryTotalKiB: 0
	property int cpuCores: 0
	property var cpuHistory: root.zeros()
	property var memoryHistory: root.zeros()
	property var disks: []
	// the mouse reported a level
	// the mouse: { name, percent, status } of the first source that knows it
	property var razer: null
	readonly property var upowerMouse: {
		if (!Plugins.on("mouse-battery")) return null;
		const device = UPower.devices.values.find(d => d.type === UPowerDeviceType.Mouse && d.isPresent);
		return device ? { name: device.model || "Mouse", percent: device.percentage * 100, status: root.stateName(device.state) } : null;
	}
	readonly property var mouseSource: {
		if (!Plugins.on("mouse-battery")) return null;
		const battery = Mouse.online ? Mouse.state.battery : null;
		// a Logitech mouse on its receiver: the daemon's word (the kernel says nothing)
		if (battery && Number.isFinite(Number(battery.percent)))
			return { name: Mouse.device.name, percent: Number(battery.percent), status: battery.status === "discharging" ? "Discharging" : (battery.status === "full" ? "Full" : "Charging") };
		return root.upowerMouse ?? root.razer;
	}
	readonly property bool mouseFound: root.mouseSource !== null
	readonly property bool mouseAvailable: root.mouseFound
	readonly property real mouseLevel: root.mouseFound ? root.clamp01(root.mouseSource.percent / 100) : 0
	readonly property string mouseText: root.mouseFound ? `${Math.round(root.mouseSource.percent)}%` : ""
	readonly property string mouseName: root.mouseSource?.name || "Mouse"
	readonly property string mouseStatus: root.mouseSource?.status ?? ""
	// the laptop's battery
	readonly property var laptop: Plugins.on("battery") && UPower.displayDevice.ready && UPower.displayDevice.isLaptopBattery ? UPower.displayDevice : null
	readonly property int batteryPercent: root.laptop ? Math.round(root.laptop.percentage * 100) : -1
	readonly property string batteryStatus: root.laptop ? root.stateName(root.laptop.state) : ""
	property real lastIdle: 0
	property real lastTotal: 0
	property bool cpuReady: false

	readonly property string memoryText: `${Format.bytes(root.memoryUsedKiB * 1024)} / ${Format.bytes(root.memoryTotalKiB * 1024)}`
	readonly property string cpuText: root.cpuCores > 0 ? `${root.cpuCores} cores` : ""
	readonly property bool batteryAvailable: Plugins.on("battery") && root.batteryPercent >= 0
	readonly property bool charging: String(root.batteryStatus).toLowerCase() === "charging"
	readonly property bool charged: String(root.batteryStatus).toLowerCase() === "full"
	readonly property string batteryIcon: {
		if (!root.batteryAvailable) return "battery_alert";
		if (root.charged) return "battery_charging_100";
		const level = Math.max(1, Math.min(9, Math.round(root.batteryPercent / 10)));
		if (root.charging) return level >= 10 ? "battery_charging_100" : `battery_charging_${level * 10}`;
		if (root.batteryPercent >= 95) return "battery";
		return `battery_${level * 10}`;
	}

	function zeros() {
		const out = [];
		for (let i = 0; i < 40; i += 1) out.push(0);
		return out;
	}

	function push(history, value) {
		const next = history.slice(1);
		next.push(value);
		return next;
	}

	// UPower's state as the power supply class says it
	function stateName(state) {
		switch (state) {
		case UPowerDeviceState.Charging: return "Charging";
		case UPowerDeviceState.FullyCharged: return "Full";
		case UPowerDeviceState.PendingCharge:
		case UPowerDeviceState.PendingDischarge: return "Not charging";
		case UPowerDeviceState.Discharging:
		case UPowerDeviceState.Empty: return "Discharging";
		}
		return "";
	}

	function clamp01(value) {
		return Math.max(0, Math.min(1, Number(value) || 0));
	}

	function updateMemory(raw) {
		const totalMatch = raw.match(/MemTotal:\s+(\d+)/);
		const availableMatch = raw.match(/MemAvailable:\s+(\d+)/);
		if (!totalMatch || !availableMatch) return;
		const total = Number(totalMatch[1]);
		const available = Number(availableMatch[1]);
		if (total <= 0) return;
		root.memoryTotalKiB = total;
		root.memoryUsedKiB = total - available;
		root.memory = root.clamp01((total - available) / total);
		root.memoryHistory = root.push(root.memoryHistory, root.memory);
	}

	function updateCpu(raw) {
		const match = raw.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/m);
		if (!match) return;
		const stats = match.slice(1).map(value => Number(value));
		const total = stats.reduce((sum, value) => sum + value, 0);
		const idle = stats[3] + (stats[4] || 0);
		if (!root.cpuReady) {
			root.lastIdle = idle;
			root.lastTotal = total;
			root.cpuReady = true;
			return;
		}
		const totalDiff = total - root.lastTotal;
		const idleDiff = idle - root.lastIdle;
		if (totalDiff > 0) root.cpu = root.clamp01(1 - idleDiff / totalDiff);
		root.lastIdle = idle;
		root.lastTotal = total;
		root.cpuHistory = root.push(root.cpuHistory, root.cpu);
	}

	function parseDisks(text) {
		try {
			const data = JSON.parse(text);
			const diskMap = {};
			const countedFs = {};
			function walk(devices, parentDiskName) {
				for (const dev of devices) {
					if (dev.type === "disk")
						parentDiskName = dev.name && !String(dev.name).startsWith("zram") ? dev.name : "";
					const isMounted = !!dev.mountpoint && dev.mountpoint !== "[SWAP]";
					const fsKey = `${dev.name}:${dev.mountpoint || ""}`;
					if (isMounted && parentDiskName) {
						if (!diskMap[parentDiskName])
							diskMap[parentDiskName] = { name: parentDiskName, used: 0, total: 0 };
						if (!countedFs[fsKey]) {
							countedFs[fsKey] = true;
							diskMap[parentDiskName].used += Number(dev.fsused) || 0;
							diskMap[parentDiskName].total += Number(dev.fssize) || 0;
						}
					}
					if (dev.children) walk(dev.children, parentDiskName);
				}
			}
			walk(data.blockdevices || [], "");
			root.disks = Object.values(diskMap).map(disk => ({
				name: disk.name,
				usedText: Format.bytes(disk.used),
				totalText: Format.bytes(disk.total),
				freeText: Format.bytes(Math.max(0, disk.total - disk.used)),
				usage: disk.total > 0 ? root.clamp01(disk.used / disk.total) : 0
			}));
		} catch (error) {}
	}

	Timer {
		running: Plugins.on("system-monitor")
		repeat: true
		interval: 2000
		triggeredOnStart: true
		onTriggered: {
			cpuStat.reload();
			memInfo.reload();
		}
	}

	Timer {
		running: Plugins.on("system-monitor")
		repeat: true
		interval: 30000
		triggeredOnStart: true
		onTriggered: storageProc.running = true
	}

	// a Razer mouse (OpenRazer's kernel driver) is in neither UPower nor the
	// daemon; asked only while nothing else knows a mouse
	Timer {
		running: Plugins.on("mouse-battery") && root.upowerMouse === null && !(Mouse.online && Mouse.state.battery)
		repeat: true
		interval: 60000
		triggeredOnStart: true
		onTriggered: razerProc.running = true
	}

	FileView {
		path: "/proc/cpuinfo"
		onLoaded: {
			const data = text();
			const coreMatch = data.match(/cpu cores\s*:\s*(\d+)/);
			if (coreMatch) {
				root.cpuCores = Number(coreMatch[1]) || 0;
				return;
			}
			const processors = data.match(/^processor\s*:/gm);
			root.cpuCores = processors ? processors.length : 0;
		}
	}

	FileView {
		id: cpuStat
		path: "/proc/stat"
		onLoaded: root.updateCpu(text())
	}

	FileView {
		id: memInfo
		path: "/proc/meminfo"
		onLoaded: root.updateMemory(text())
	}

	Process {
		id: storageProc
		command: ["lsblk", "-J", "-b", "-o", "NAME,PKNAME,TYPE,FSUSED,FSSIZE,MOUNTPOINT"]
		stdout: StdioCollector {
			onStreamFinished: root.parseDisks(text)
		}
	}

	Process {
		id: razerProc

		command: ["sh", "-c", "for dir in /sys/bus/hid/drivers/razermouse/*/; do [ -r \"$dir/charge_level\" ] && printf '%s|%s|%s\\n' \"$(cat \"$dir/charge_level\")\" \"$(cat \"$dir/charge_status\" 2>/dev/null)\" \"$(cat \"$dir/device_type\" 2>/dev/null)\" && break; done"]
		stdout: StdioCollector {
			onStreamFinished: {
				const [level, status, name] = String(text).trim().split("|");
				// 0 … 255
				const value = Number(level);
				root.razer = level && Number.isFinite(value) ? { name: name || "Razer mouse", percent: Math.min(100, value > 100 ? value * 100 / 255 : value), status: status === "1" ? "Charging" : "Discharging" } : null;
			}
		}
	}
}
