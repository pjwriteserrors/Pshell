pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// CPU, memory, disks, mouse battery (scripts/mouse_battery_status.sh) and
// the laptop battery from sysfs. CPU/RAM keep a short history for charts.
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
	property bool mouseAvailable: false
	property real mouseLevel: 0
	property string mouseText: ""
	property string mouseName: "Mouse"
	property string mouseStatus: ""
	property int batteryPercent: -1
	property string batteryStatus: ""
	property real lastIdle: 0
	property real lastTotal: 0
	property bool cpuReady: false

	readonly property string memoryText: `${root.formatStorage(root.memoryUsedKiB)} / ${root.formatStorage(root.memoryTotalKiB)}`
	readonly property string cpuText: root.cpuCores > 0 ? `${root.cpuCores} cores` : ""
	readonly property bool batteryAvailable: root.batteryPercent >= 0
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

	function clamp01(value) {
		return Math.max(0, Math.min(1, Number(value) || 0));
	}

	function formatStorage(kib) {
		const gib = (Number(kib) || 0) / (1024 * 1024);
		if (gib >= 1000) return `${(gib / 1024).toFixed(1)} TB`;
		if (gib >= 100) return `${Math.round(gib)} GB`;
		return `${gib.toFixed(1)} GB`;
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

	function updateMouse(raw) {
		const values = {};
		for (const line of String(raw || "").split("\n")) {
			const index = line.indexOf("=");
			if (index > 0) values[line.slice(0, index).trim()] = line.slice(index + 1).trim();
		}
		const percent = Math.max(0, Math.min(100, Number(values.percent)));
		root.mouseAvailable = values.available === "1" && Number.isFinite(percent);
		if (!root.mouseAvailable) {
			root.mouseText = "";
			root.mouseLevel = 0;
			root.mouseStatus = "";
			return;
		}
		root.mouseName = values.name || "Mouse";
		root.mouseStatus = values.status || "";
		root.mouseLevel = root.clamp01(percent / 100);
		root.mouseText = `${Math.round(percent)}%`;
	}

	function updateBattery(text) {
		let percent = -1;
		let status = "";
		for (const rawLine of String(text).split(/\r?\n/)) {
			const line = rawLine.trim();
			if (line.startsWith("percent=")) {
				const value = Number(line.slice(8).trim());
				if (line.slice(8).trim() !== "" && Number.isFinite(value)) percent = Math.max(0, Math.min(100, Math.round(value)));
			} else if (line.startsWith("status=")) {
				status = line.slice(7).trim();
			}
		}
		root.batteryPercent = percent;
		root.batteryStatus = percent >= 0 ? status : "";
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
				usedText: root.formatStorage(disk.used / 1024),
				totalText: root.formatStorage(disk.total / 1024),
				freeText: root.formatStorage(Math.max(0, (disk.total - disk.used) / 1024)),
				usage: disk.total > 0 ? root.clamp01(disk.used / disk.total) : 0
			}));
		} catch (error) {}
	}

	Timer {
		running: true
		repeat: true
		interval: 2000
		triggeredOnStart: true
		onTriggered: {
			cpuStat.reload();
			memInfo.reload();
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 30000
		triggeredOnStart: true
		onTriggered: {
			storageProc.running = true;
			batteryProc.running = true;
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 60000
		triggeredOnStart: true
		onTriggered: mouseProc.running = true
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
		id: mouseProc
		command: ["bash", `${Quickshell.shellDir}/scripts/mouse_battery_status.sh`]
		stdout: StdioCollector {
			onStreamFinished: root.updateMouse(text)
		}
	}

	Process {
		id: batteryProc
		command: ["sh", "-lc", "for dir in /sys/class/power_supply/*; do\n"
			+ "  [ -r \"$dir/type\" ] || continue\n"
			+ "  [ \"$(cat \"$dir/type\" 2>/dev/null)\" = \"Battery\" ] || continue\n"
			+ "  capacity=$(cat \"$dir/capacity\" 2>/dev/null || true)\n"
			+ "  status=$(cat \"$dir/status\" 2>/dev/null || true)\n"
			+ "  [ -n \"$capacity\" ] || continue\n"
			+ "  printf 'percent=%s\\nstatus=%s\\n' \"$capacity\" \"$status\"\n"
			+ "  exit 0\n"
			+ "done\n"
			+ "printf 'percent=\\nstatus=\\n'\n"]
		stdout: StdioCollector {
			onStreamFinished: root.updateBattery(text)
		}
	}
}
