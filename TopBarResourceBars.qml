pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// The vial rack: three readings standing side by side on the spine.
//
// Not icons with numbers next to them — each load is a vessel filling from the
// bottom, so a glance at their heights is the whole status. The engraved
// initial under each one says which organ it is.
Item {
	id: root

	signal clicked

	property bool lit: false


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

	implicitWidth: rack.implicitWidth + Bio.s4
	implicitHeight: Bio.spine

	readonly property real live: Math.max(interaction.live, root.lit ? 0.5 : 0)

	Row {
		id: rack
		anchors.centerIn: parent
		spacing: Bio.s3

		Vial {
			label: "C"
			value: root.cpuUsage
		}

		Vial {
			label: "M"
			value: root.memoryUsage
		}

		Vial {
			label: "D"
			value: root.storageUsage
		}

		Vial {
			visible: root.mouseBatteryAvailable
			label: "P"
			value: root.mouseBatteryUsage
			// A pointer running out of charge is the one reading here that is
			// bad when it is low rather than when it is high.
			inverted: true
		}
	}

	BioTouch {
		id: interaction
		onClicked: root.clicked()
	}

	component Vial: Item {
		id: vial

		property string label: ""
		property real value: 0
		property bool inverted: false

		readonly property bool strained: vial.inverted ? vial.value < 0.2 : vial.value > 0.85

		width: 13
		height: Bio.spine

		// The vessel the reading stands in. Without it three loose veins read as
		// scratches on the wallpaper rather than as instruments.
		BioFrame {
			id: tube
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: parent.top
			width: parent.width
			height: parent.height - 11
			variant: "capsule"
			beading: false
			weight: Bio.ribThin
			inset: 1
			lineColor: Bio.boneFaint
			liveColor: vial.strained ? Bio.necrosis : Bio.organ
			fillTop: Bio.cavity
			fillBottom: Bio.cavity
			intensity: Math.max(root.live * 0.8, vial.strained ? 0.75 : 0)
		}

		BioMeter {
			anchors.horizontalCenter: tube.horizontalCenter
			anchors.top: tube.top
			anchors.topMargin: 3
			width: 6
			height: tube.height - 6
			vertical: true
			value: vial.value
			weight: Bio.rib
			trackColor: "transparent"
			fillColor: vial.strained ? Bio.necrosis : (root.live > 0.3 ? Bio.organ : Bio.organAlt)
		}

		BioText {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			role: "label"
			font.pixelSize: 8
			tone: root.live > 0.3 ? "organ" : "faint"
			text: vial.label
		}
	}

	// CPU and memory come from /proc: two cheap file reads.
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

	// Disk usage is an lsblk process. It does not move fast enough to be worth
	// spawning one every two seconds for the rest of the session.
	Timer {
		running: true
		repeat: true
		interval: 60000
		triggeredOnStart: true
		onTriggered: storageProcess.running = true
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

}
