pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl
import Quickshell
import Quickshell.Io
import "components"

ThemedRectangle {
	id: root

	signal clicked

	required property color foreground
	required property color secondaryBoxColor
	required property color secondaryInsetColor
	required property color barColor
	required property string cpuIcon
	required property string memoryIcon
	required property string storageIcon
	required property string mouseIcon

	property real cpuUsage: 0
	property real memoryUsage: 0
	property real storageUsage: 0
	property real mouseBatteryUsage: 0
	property real memoryUsedKiB: 0
	property real memoryTotalKiB: 0
	property int cpuCores: 0
	property var disks: []
	property bool mouseBatteryAvailable: false
	property string mouseBatteryText: ""
	property string mouseBatteryName: "Mouse"
	property string mouseBatteryStatus: ""

	property real lastCpuIdle: 0
	property real lastCpuTotal: 0
	property bool cpuSampleReady: false

	function clamp01(value) {
		return Math.max(0, Math.min(1, Number(value) || 0));
	}

	function formatStorage(kib) {
		const gib = (Number(kib) || 0) / (1024 * 1024);
		if (gib >= 1000) return `${(gib / 1024).toFixed(1)}TB`;
		return `${Math.round(gib)}GB`;
	}

	function updateMemoryUsage(raw) {
		const totalMatch = raw.match(/MemTotal:\s+(\d+)/);
		const availableMatch = raw.match(/MemAvailable:\s+(\d+)/);
		if (!totalMatch || !availableMatch) return;

		const total = Number(totalMatch[1]);
		const available = Number(availableMatch[1]);
		if (total <= 0) return;

		root.memoryTotalKiB = total;
		root.memoryUsedKiB = total - available;
		root.memoryUsage = root.clamp01((total - available) / total);
	}

	function updateCpuUsage(raw) {
		const match = raw.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/m);
		if (!match) return;

		const stats = match.slice(1).map(value => Number(value));
		const total = stats.reduce((sum, value) => sum + value, 0);
		const idle = stats[3] + (stats[4] || 0);

		if (!root.cpuSampleReady) {
			root.lastCpuIdle = idle;
			root.lastCpuTotal = total;
			root.cpuSampleReady = true;
			return;
		}

		const totalDiff = total - root.lastCpuTotal;
		const idleDiff = idle - root.lastCpuIdle;

		if (totalDiff > 0) root.cpuUsage = root.clamp01(1 - idleDiff / totalDiff);

		root.lastCpuIdle = idle;
		root.lastCpuTotal = total;
	}

	function updateMouseBattery(raw) {
		const values = {};

		for (const line of String(raw || "").split("\n")) {
			const index = line.indexOf("=");
			if (index <= 0) continue;
			values[line.slice(0, index).trim()] = line.slice(index + 1).trim();
		}

		const percent = Math.max(0, Math.min(100, Number(values.percent)));
		root.mouseBatteryAvailable = values.available === "1" && Number.isFinite(percent);

		if (!root.mouseBatteryAvailable) {
			root.mouseBatteryText = "";
			root.mouseBatteryUsage = 0;
			root.mouseBatteryStatus = "";
			return;
		}

		root.mouseBatteryName = values.name || "Mouse";
		root.mouseBatteryStatus = values.status || "";
		root.mouseBatteryUsage = root.clamp01(percent / 100);
		root.mouseBatteryText = `${Math.round(percent)}%`;
	}

	readonly property string memoryText: `${root.formatStorage(root.memoryUsedKiB)}/${root.formatStorage(root.memoryTotalKiB)}`
	readonly property string cpuText: root.cpuCores > 0 ? `${root.cpuCores} Cores` : ""

	radius: ThemeEngine.radiusMedium
	color: root.secondaryBoxColor
	implicitWidth: resourceRow.implicitWidth + 18
	implicitHeight: 27
	clip: !ThemeEngine.shadowEnabled

	HoverLayer {
		id: interaction
		tint: root.foreground
		onClicked: root.clicked()
	}

	Row {
		id: resourceRow
		anchors.centerIn: parent
		spacing: 8

		IconBadge {
			source: root.cpuIcon
		}

		IconBadge {
			source: root.memoryIcon
		}

		IconBadge {
			source: root.storageIcon
		}

		Row {
			visible: root.mouseBatteryAvailable
			height: 16
			spacing: 4

			IconBadge {
				source: root.mouseIcon
			}

			Text {
				anchors.verticalCenter: parent.verticalCenter
				color: root.foreground
				font.pixelSize: 10
				font.weight: Font.Medium
				text: root.mouseBatteryText
			}
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 2000
		triggeredOnStart: true
		onTriggered: {
			cpuStat.reload();
			memInfo.reload();
			storageProcess.running = true;
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 60000
		triggeredOnStart: true
		onTriggered: mouseBatteryProcess.running = true
	}

	FileView {
		id: cpuInfo
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
		onLoaded: root.updateCpuUsage(text())
	}

	FileView {
		id: memInfo
		path: "/proc/meminfo"
		onLoaded: root.updateMemoryUsage(text())
	}

	Process {
		id: storageProcess
		command: ["lsblk", "-J", "-b", "-o", "NAME,PKNAME,TYPE,FSUSED,FSSIZE,MOUNTPOINT"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(text);
					const diskMap = {};
					const countedFs = {};
					let totalUsed = 0;
					let totalSize = 0;

					function walk(devices, parentDiskName) {
						for (const dev of devices) {
							if (dev.type === "disk") {
								if (dev.name && !String(dev.name).startsWith("zram")) {
									parentDiskName = dev.name;
								} else {
									parentDiskName = "";
								}
							}

							const isMounted = !!dev.mountpoint
								&& dev.mountpoint !== "[SWAP]";
							const fsKey = `${dev.name}:${dev.mountpoint || ""}`;

							if (isMounted && parentDiskName) {
								if (!diskMap[parentDiskName]) {
									diskMap[parentDiskName] = {
										name: parentDiskName,
										used: 0,
										total: 0,
										usage: 0
									};
								}

								if (!countedFs[fsKey]) {
									const fsUsed = Number(dev.fsused) || 0;
									const fsSize = Number(dev.fssize) || 0;
									countedFs[fsKey] = true;
									totalUsed += fsUsed;
									totalSize += fsSize;
									diskMap[parentDiskName].used += fsUsed;
									diskMap[parentDiskName].total += fsSize;
								}
							}

							if (dev.children) {
								walk(dev.children, parentDiskName);
							}
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
					root.storageUsage = totalSize > 0 ? root.clamp01(totalUsed / totalSize) : 0;
				} catch (error) {
				}
			}
		}
	}

	Process {
		id: mouseBatteryProcess
		command: ["bash", `${Quickshell.shellDir}/scripts/mouse_battery_status.sh`]
		stdout: StdioCollector {
			onStreamFinished: root.updateMouseBattery(text)
		}
	}

	component IconBadge: Item {
		id: badge

		required property string source

		width: 16
		height: 16

		IconImage {
			anchors.fill: parent
			source: badge.source
			sourceSize: Qt.size(width, height)
			color: root.foreground
		}
	}
}
