pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The machine: each device on the left with its curve, the one picked large
// on the right with what there is to know of it. Switching devices slides
// the new one in.
Item {
	id: root

	readonly property var system: TaskManager.system
	readonly property var series: TaskManager.series
	readonly property var devices: {
		const out = [{ id: "cpu", name: "Processor", glyph: "cpu_64_bit", value: TaskManager.percent(TaskManager.cpu, 0), level: TaskManager.cpu, curve: "cpu", color: Theme.primary }];
		const memory = TaskManager.memory;
		out.push({ id: "memory", name: "Memory", glyph: "memory", value: `${Format.bytes(memory.used)}`, level: TaskManager.memoryLevel, curve: "memory", color: Theme.secondary });
		for (const gpu of TaskManager.gpus)
			out.push({ id: `gpu:${gpu.pci}`, name: TaskManager.gpus.length > 1 ? gpu.name : "Graphics", glyph: "expansion_card_variant", value: gpu.busy !== null ? TaskManager.percent(gpu.busy, 0) : "", level: gpu.busy ?? 0, curve: `gpu:${gpu.pci}`, color: Theme.tertiary });
		for (const disk of TaskManager.disks)
			out.push({ id: `disk:${disk.name}`, name: disk.kind === "usb" ? `USB ${disk.name}` : `Disk ${disk.name}`, glyph: disk.kind === "usb" ? "usb_flash_drive_outline" : (disk.kind === "hdd" ? "harddisk" : "chip"), value: TaskManager.percent(disk.busy, 0), level: disk.busy, curve: `disk:${disk.name}:r`, color: Theme.success });
		for (const net of TaskManager.network.filter(n => n.kind !== "virtual" && n.up))
			out.push({ id: `net:${net.name}`, name: net.kind === "wifi" ? "Wi‑Fi" : (net.kind === "vpn" ? `VPN ${net.name}` : `Ethernet ${net.name}`), glyph: net.kind === "wifi" ? "wifi" : (net.kind === "vpn" ? "vpn" : "ethernet"), value: Format.rate(net.down), level: -1, curve: `net:${net.name}:d`, color: Theme.warning });
		if ((TaskManager.temps.cpu ?? null) !== null)
			out.push({ id: "sensors", name: "Sensors", glyph: "thermometer", value: `${Math.round(TaskManager.temps.cpu)} °C`, level: TaskManager.temps.cpu / (TaskManager.temps.cpuCrit || 100), curve: "temp", color: Theme.danger });
		if (root.system?.power?.battery)
			out.push({ id: "power", name: "Battery", glyph: SysStats.batteryIcon, value: root.system.power.watts > 0 ? `${root.system.power.watts.toFixed(1)} W` : `${root.system.power.percent ?? ""}%`, level: (root.system.power.percent ?? 0) / 100, curve: "watts", color: Theme.success });
		return out;
	}
	readonly property var current: root.devices.find(d => d.id === TaskManager.device) ?? root.devices[0] ?? null
	readonly property int currentIndex: Math.max(0, root.devices.findIndex(d => d.id === root.current?.id))
	property int lastIndex: 0
	property int direction: 1

	onCurrentIndexChanged: {
		root.direction = root.currentIndex >= root.lastIndex ? 1 : -1;
		root.lastIndex = root.currentIndex;
		swap.restart();
	}

	function pick(id) {
		TaskManager.device = id;
		TaskManager.saveSettings();
	}

	function rateFormat(value) {
		return Format.rate(value);
	}

	function stepDevice(delta) {
		const next = root.devices[Math.max(0, Math.min(root.devices.length - 1, root.currentIndex + delta))];
		if (next) root.pick(next.id);
	}

	RowLayout {
		anchors.fill: parent
		spacing: 0

		// ── the devices ────────────────────────────────────────────────────
		Flickable {
			Layout.preferredWidth: 236
			Layout.fillHeight: true
			contentHeight: deviceColumn.implicitHeight + 24
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			Column {
				id: deviceColumn

				x: 10
				y: 12
				width: parent.width - 20
				spacing: 4

				Repeater {
					model: ScriptModel {
						values: root.devices
						objectProp: "id"
					}

					delegate: Clickable {
						id: tile

						required property var modelData
						required property int index
						readonly property bool picked: root.current?.id === tile.modelData.id

						width: deviceColumn.width
						height: 64
						radius: Theme.radius.large
						color: tile.picked ? Theme.primaryContainer : (tile.hovered ? Theme.layer2 : "transparent")
						onClicked: root.pick(tile.modelData.id)
						opacity: 0
						Component.onCompleted: appear.start()

						Behavior on color {
							ColorAnim {}
						}

						SequentialAnimation {
							id: appear

							PauseAnimation {
								duration: tile.index * 35
							}
							NumberAnimation {
								target: tile
								property: "opacity"
								to: 1
								duration: Motion.medium
							}
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 10

							Rectangle {
								Layout.preferredWidth: 58
								Layout.preferredHeight: 40
								radius: Theme.radius.medium
								color: Qt.alpha(tile.modelData.color, 0.1)
								border.width: 1
								border.color: Qt.alpha(tile.modelData.color, 0.35)
								clip: true

								LiveGraph {
									anchors.fill: parent
									anchors.margins: 1
									series: [(root.series[tile.modelData.curve] ?? []).slice(-40)]
									colors: [tile.modelData.color]
									span: 40
									maximum: tile.modelData.level >= 0 && tile.modelData.curve !== "temp" && tile.modelData.curve !== "watts" && !tile.modelData.curve.startsWith("disk") ? 1 : 0
									minimumScale: tile.modelData.curve === "temp" ? 100 : 1
									guides: false
									readout: false
									lineWidth: 1.5
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									Layout.fillWidth: true
									text: tile.modelData.name
									font.weight: Font.Medium
									elide: Text.ElideRight
									tone: tile.picked ? Theme.primary : Theme.text
								}

								StyledText {
									Layout.fillWidth: true
									text: tile.modelData.value
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
									tabular: true
								}
							}
						}
					}
				}
			}
		}

		Rectangle {
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			color: Theme.outline
		}

		// ── the one picked ─────────────────────────────────────────────────
		Item {
			id: stage

			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true

			SequentialAnimation {
				id: swap

				ParallelAnimation {
					NumberAnimation {
						target: view
						property: "opacity"
						to: 0
						duration: 90
					}
					NumberAnimation {
						target: shift
						property: "y"
						to: -18 * root.direction
						duration: 90
					}
				}
				PropertyAction {
					target: view
					property: "device"
					value: root.current?.id ?? "cpu"
				}
				PropertyAction {
					target: shift
					property: "y"
					value: 26 * root.direction
				}
				ParallelAnimation {
					NumberAnimation {
						target: view
						property: "opacity"
						to: 1
						duration: Motion.medium
					}
					NumberAnimation {
						target: shift
						property: "y"
						to: 0
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
			}

			Flickable {
				id: view

				property string device: root.current?.id ?? "cpu"
				readonly property var meta: root.devices.find(d => d.id === view.device) ?? root.devices[0] ?? null

				anchors.fill: parent
				contentHeight: deviceView.implicitHeight + 44
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}
				transform: Translate {
					id: shift
				}

				ColumnLayout {
					id: deviceView

					x: 24
					y: 20
					width: view.width - 48
					spacing: 16

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						Glyph {
							icon: view.meta?.glyph ?? "chip"
							size: 26
							color: view.meta?.color ?? Theme.primary
						}

						StyledText {
							text: view.meta?.name ?? ""
							font.pixelSize: Theme.size.heading + 4
							font.weight: Font.Bold
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							Layout.maximumWidth: view.width * 0.5
							text: {
								const id = view.device;
								if (id === "cpu") return TaskManager.info.cpu ?? "";
								if (id.startsWith("gpu:")) return TaskManager.gpus.find(g => `gpu:${g.pci}` === id)?.name ?? "";
								if (id.startsWith("disk:")) return TaskManager.disks.find(d => `disk:${d.name}` === id)?.model ?? "";
								if (id === "memory") return Format.bytes(TaskManager.memory.total);
								return "";
							}
							tone: Theme.textMuted
							elide: Text.ElideRight
						}
					}

					Loader {
						Layout.fillWidth: true
						sourceComponent: {
							const id = view.device;
							if (id === "cpu") return cpuView;
							if (id === "memory") return memoryView;
							if (id.startsWith("gpu:")) return gpuView;
							if (id.startsWith("disk:")) return diskView;
							if (id.startsWith("net:")) return netView;
							if (id === "sensors") return sensorsView;
							if (id === "power") return powerView;
							return cpuView;
						}
					}
				}
			}
		}
	}

	// ── pieces ─────────────────────────────────────────────────────────────
	component Graph: Rectangle {
		id: graph

		property alias series: live.series
		property alias colors: live.colors
		property alias maximum: live.maximum
		property alias minimumScale: live.minimumScale
		property alias format: live.format
		property alias names: live.names
		property alias fill: live.fill

		Layout.fillWidth: true
		Layout.preferredHeight: 210
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		clip: true

		LiveGraph {
			id: live

			anchors.fill: parent
			anchors.topMargin: 10
			span: TaskManager.span
		}
	}

	component Stat: ColumnLayout {
		id: stat

		property string label
		property string value
		property color tone: Theme.text

		spacing: 0
		Layout.minimumWidth: 110

		RollText {
			calm: true
			text: stat.value
			tone: stat.tone
			pixelSize: Theme.size.heading
			weight: Font.DemiBold
		}

		StyledText {
			text: stat.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	component Stats: Flow {
		Layout.fillWidth: true
		spacing: 22
	}

	component TopList: ColumnLayout {
		id: topList

		property string title
		property var items: []
		property string metric: "c"

		Layout.fillWidth: true
		spacing: 4
		visible: topList.items.length > 0

		SectionLabel {
			text: topList.title
		}

		Repeater {
			id: topEntries

			readonly property var list: topList.items.slice(0, 5)
			model: topEntries.list.length

			Clickable {
				id: entry

				required property int index
				readonly property var modelData: topEntries.list[index] ?? ({})
				readonly property var row: ({ t: "group", kind: entry.modelData.kind, i: entry.modelData.icon, n: entry.modelData.name })
				readonly property string icon: TaskManager.iconOf(entry.row)

				Layout.fillWidth: true
				implicitHeight: 38
				radius: Theme.radius.medium
				onClicked: TaskManager.showKey(entry.modelData.key)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 8
					anchors.rightMargin: 10
					spacing: 10

					Item {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22

						Image {
							anchors.fill: parent
							visible: !entry.icon.startsWith("glyph:")
							source: entry.icon.startsWith("glyph:") ? "" : entry.icon
							sourceSize: Qt.size(44, 44)
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: entry.icon.startsWith("glyph:")
							icon: entry.icon.slice(6)
							size: 16
						}
					}

					StyledText {
						Layout.preferredWidth: 160
						text: TaskManager.nameOf(entry.row)
						elide: Text.ElideRight
					}

					Meter {
						Layout.fillWidth: true
						value: topList.metric === "m" ? entry.modelData.m / Math.max(1, TaskManager.memory.total) : (topList.metric === "g" ? entry.modelData.g : entry.modelData.c)
						color: topList.metric === "m" ? Theme.secondary : (topList.metric === "g" ? Theme.tertiary : Theme.primary)
						thickness: 5
					}

					StyledText {
						Layout.preferredWidth: 72
						horizontalAlignment: Text.AlignRight
						text: topList.metric === "m" ? Format.bytes(entry.modelData.m) : TaskManager.percent(topList.metric === "g" ? entry.modelData.g : entry.modelData.c)
						tabular: true
						tone: Theme.textMuted
					}
				}
			}
		}
	}

	// ── processor ──────────────────────────────────────────────────────────
	Component {
		id: cpuView

		ColumnLayout {
			spacing: 18

			Graph {
				series: [root.series.cpu ?? []]
				colors: [Theme.primary]
				maximum: 1
			}

			// each core: a tile that fills
			GridLayout {
				Layout.fillWidth: true
				columns: Math.max(4, Math.min(16, Math.floor(width / 64)))
				columnSpacing: 6
				rowSpacing: 6

				Repeater {
					model: (root.system?.cores ?? []).length

					Rectangle {
						id: coreTile

						required property int index
						readonly property real load: root.system?.cores?.[coreTile.index] ?? 0
						readonly property int mhz: root.system?.freq?.[coreTile.index] ?? 0

						Layout.fillWidth: true
						Layout.preferredHeight: 54
						radius: Theme.radius.medium
						color: Theme.layer1
						clip: true

						Rectangle {
							anchors.bottom: parent.bottom
							width: parent.width
							height: parent.height * coreTile.load
							color: Qt.alpha(coreTile.load > 0.9 ? Theme.danger : (coreTile.load > 0.7 ? Theme.warning : Theme.primary), 0.32)

							Behavior on height {
								SpatialAnim {
									duration: 650
								}
							}
							Behavior on color {
								ColorAnim {}
							}
						}

						Column {
							anchors.centerIn: parent
							spacing: 0

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: `${Math.round(coreTile.load * 100)}%`
								font.weight: Font.DemiBold
								tabular: true
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: coreTile.mhz > 0 ? `${(coreTile.mhz / 1000).toFixed(1)} GHz` : `${coreTile.index}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								tabular: true
							}
						}
					}
				}
			}

			Stats {
				Stat {
					label: "Utilization"
					value: TaskManager.percent(TaskManager.cpu, 0)
				}
				Stat {
					label: "Speed"
					value: {
						const freq = root.system?.freq ?? [];
						return freq.length > 0 ? `${(freq.reduce((a, b) => a + b, 0) / freq.length / 1000).toFixed(2)} GHz` : "–";
					}
				}
				Stat {
					label: "Processes"
					value: `${root.system?.tasks?.procs ?? 0}`
				}
				Stat {
					label: "Threads"
					value: `${root.system?.tasks?.threads ?? 0}`
				}
				Stat {
					label: "Load 1 · 5 · 15 min"
					value: (root.system?.load ?? []).map(v => v.toFixed(1)).join(" · ")
				}
				Stat {
					label: "Waited for the processor"
					value: TaskManager.percent(TaskManager.pressure.cpu?.some ?? 0, 0)
					tone: (TaskManager.pressure.cpu?.some ?? 0) > 0.2 ? Theme.warning : Theme.text
				}
				Stat {
					visible: (TaskManager.temps.cpu ?? null) !== null
					label: "Temperature"
					value: `${Math.round(TaskManager.temps.cpu ?? 0)} °C`
				}
				Stat {
					label: "Up for"
					value: Format.duration(root.system?.uptime ?? 0)
				}
				Stat {
					label: "Cores · threads"
					value: `${TaskManager.info.cores ?? "?"} · ${TaskManager.info.threads ?? "?"}`
				}
			}

			TopList {
				title: "Using it most"
				items: TaskManager.top
			}
		}
	}

	// ── memory ─────────────────────────────────────────────────────────────
	Component {
		id: memoryView

		ColumnLayout {
			spacing: 18

			readonly property var memory: TaskManager.memory

			Graph {
				series: [root.series.memory ?? [], root.series.swap ?? []]
				colors: [Theme.secondary, Theme.warning]
				names: ["Memory", "Swap"]
				maximum: 1
			}

			// what the memory holds
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 8

				readonly property var parts: [
					{ label: "In use", value: Math.max(0, parent.memory.used - parent.memory.shared), color: Theme.secondary },
					{ label: "Shared", value: parent.memory.shared, color: Qt.alpha(Theme.secondary, 0.6) },
					{ label: "Cache", value: parent.memory.cached + parent.memory.buffers, color: Qt.alpha(Theme.secondary, 0.28) },
					{ label: "Free", value: parent.memory.free, color: Theme.layer3 }
				]

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 26

					Rectangle {
						anchors.fill: parent
						radius: Theme.radius.medium
						color: Theme.layer2
					}

					Row {
						anchors.fill: parent
						spacing: 2

						Repeater {
							id: memoryBar

							readonly property var list: parent.parent.parent.parts
							model: memoryBar.list.length

							Rectangle {
								required property int index
								readonly property var modelData: memoryBar.list[index] ?? ({})

								height: parent.height
								width: Math.max(0, (parent.width - 6) * modelData.value / Math.max(1, TaskManager.memory.total))
								radius: Theme.radius.small
								color: modelData.color

								Behavior on width {
									SpatialAnim {
										duration: 800
									}
								}
							}
						}
					}
				}

				Flow {
					Layout.fillWidth: true
					spacing: 18

					Repeater {
						id: memoryLegend

						readonly property var list: parent.parent.parts
						model: memoryLegend.list.length

						Row {
							required property int index
							readonly property var modelData: memoryLegend.list[index] ?? ({})

							spacing: 6

							Rectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: 10
								height: 10
								radius: 3
								color: modelData.color
							}

							StyledText {
								text: `${modelData.label} ${Format.bytes(modelData.value)}`
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Stats {
				Stat {
					label: "In use"
					value: Format.bytes(TaskManager.memory.used)
				}
				Stat {
					label: "Available"
					value: Format.bytes(TaskManager.memory.available)
				}
				Stat {
					label: "Swap"
					value: TaskManager.memory.swapTotal > 0 ? `${Format.bytes(TaskManager.memory.swapUsed)} / ${Format.bytes(TaskManager.memory.swapTotal)}` : "None"
				}
				Stat {
					label: "Promised to programs"
					value: Format.bytes(TaskManager.memory.committed)
				}
				Stat {
					label: "Waiting to be written"
					value: Format.bytes(TaskManager.memory.dirty)
				}
				Stat {
					label: "Waited for memory"
					value: TaskManager.percent(TaskManager.pressure.memory?.some ?? 0, 0)
					tone: (TaskManager.pressure.memory?.some ?? 0) > 0.1 ? Theme.warning : Theme.text
				}
			}

			TopList {
				title: "Holding the most"
				items: TaskManager.topMem
				metric: "m"
			}
		}
	}

	// ── graphics ───────────────────────────────────────────────────────────
	Component {
		id: gpuView

		ColumnLayout {
			spacing: 18

			readonly property var gpu: TaskManager.gpus.find(g => `gpu:${g.pci}` === view.device) ?? null

			Graph {
				series: [root.series[view.device] ?? []]
				colors: [Theme.tertiary]
				maximum: 1
			}

			Repeater {
				id: engineList

				readonly property var list: Object.keys(parent.gpu?.engines ?? {})
				model: engineList.list.length

				RowLayout {
					required property int index
					readonly property string modelData: engineList.list[index] ?? ""

					Layout.fillWidth: true
					spacing: 12

					StyledText {
						Layout.preferredWidth: 110
						text: modelData.replace(/-/g, " ").replace(/^./, c => c.toUpperCase())
						tone: Theme.textMuted
					}

					Meter {
						Layout.fillWidth: true
						value: parent.parent.gpu?.engines?.[modelData] ?? 0
						color: Theme.tertiary
					}

					StyledText {
						Layout.preferredWidth: 48
						horizontalAlignment: Text.AlignRight
						text: TaskManager.percent(parent.parent.gpu?.engines?.[modelData] ?? 0, 0)
						tabular: true
					}
				}
			}

			Stats {
				Stat {
					label: "Utilization"
					value: TaskManager.percent(parent.parent.gpu?.busy ?? 0, 0)
				}
				Stat {
					visible: !!parent.parent.gpu?.freq
					label: "Clock"
					value: `${Math.round(parent.parent.gpu?.freq ?? 0)} MHz`
				}
				Stat {
					visible: !!parent.parent.gpu?.memTotal
					label: "Video memory"
					value: `${Format.bytes(parent.parent.gpu?.memUsed ?? 0)} / ${Format.bytes(parent.parent.gpu?.memTotal ?? 0)}`
				}
				Stat {
					visible: !!parent.parent.gpu?.temp
					label: "Temperature"
					value: `${Math.round(parent.parent.gpu?.temp ?? 0)} °C`
				}
				Stat {
					visible: !!parent.parent.gpu?.watts
					label: "Power"
					value: `${(parent.parent.gpu?.watts ?? 0).toFixed(1)} W`
				}
				Stat {
					label: "Driver"
					value: parent.parent.gpu?.driver ?? ""
				}
			}

			TopList {
				title: "Using it most"
				items: TaskManager.topGpu
				metric: "g"
			}
		}
	}

	// ── a disk ─────────────────────────────────────────────────────────────
	Component {
		id: diskView

		ColumnLayout {
			spacing: 18

			readonly property string name: view.device.slice(5)
			readonly property var disk: TaskManager.disks.find(d => d.name === name) ?? null

			Graph {
				series: [root.series[`disk:${parent.name}:r`] ?? [], root.series[`disk:${parent.name}:w`] ?? []]
				colors: [Theme.success, Theme.primary]
				names: ["Read", "Write"]
				minimumScale: 1048576
				format: value => Format.rate(value)
			}

			Stats {
				Stat {
					label: "Read"
					value: Format.rate(parent.parent.disk?.read ?? 0)
				}
				Stat {
					label: "Write"
					value: Format.rate(parent.parent.disk?.write ?? 0)
				}
				Stat {
					label: "Active"
					value: TaskManager.percent(parent.parent.disk?.busy ?? 0, 0)
				}
				Stat {
					label: "Size"
					value: Format.bytes(parent.parent.disk?.size ?? 0)
				}
				Stat {
					label: "Type"
					value: ({ nvme: "NVMe SSD", ssd: "SSD", hdd: "Hard disk", usb: "USB" })[parent.parent.disk?.kind] ?? ""
				}
				Stat {
					label: "Waited for disks"
					value: TaskManager.percent(TaskManager.pressure.io?.some ?? 0, 0)
					tone: (TaskManager.pressure.io?.some ?? 0) > 0.2 ? Theme.warning : Theme.text
				}
			}

			SectionLabel {
				text: "Mounted"
				visible: filesystemList.count > 0
			}

			Repeater {
				id: filesystemList

				readonly property var list: (root.system?.filesystems ?? []).filter(fs => fs.disk === parent.name)
				model: filesystemList.list.length

				ColumnLayout {
					required property int index
					readonly property var modelData: filesystemList.list[index] ?? ({})

					Layout.fillWidth: true
					spacing: 4

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							text: modelData.mount
							font.weight: Font.Medium
						}

						StyledText {
							text: modelData.type
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							text: `${Format.bytes(modelData.free)} free of ${Format.bytes(modelData.total)}`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}

					Meter {
						Layout.fillWidth: true
						value: modelData.used / Math.max(1, modelData.total)
						color: Theme.success
						alarming: true
						thickness: 8
					}
				}
			}
		}
	}

	// ── a network ──────────────────────────────────────────────────────────
	Component {
		id: netView

		ColumnLayout {
			spacing: 18

			readonly property string name: view.device.slice(4)
			readonly property var net: TaskManager.network.find(n => n.name === name) ?? null

			Graph {
				series: [root.series[`net:${parent.name}:d`] ?? [], root.series[`net:${parent.name}:u`] ?? []]
				colors: [Theme.warning, Theme.primary]
				names: ["In", "Out"]
				minimumScale: 131072
				format: value => Format.rate(value)
			}

			Stats {
				Stat {
					label: "Receiving"
					value: Format.rate(parent.parent.net?.down ?? 0)
				}
				Stat {
					label: "Sending"
					value: Format.rate(parent.parent.net?.upRate ?? 0)
				}
				Stat {
					label: "Received"
					value: Format.bytes(parent.parent.net?.rx ?? 0)
				}
				Stat {
					label: "Sent"
					value: Format.bytes(parent.parent.net?.tx ?? 0)
				}
				Stat {
					label: "Interface"
					value: parent.parent.name
				}
			}
		}
	}

	// ── sensors ────────────────────────────────────────────────────────────
	Component {
		id: sensorsView

		ColumnLayout {
			spacing: 14

			Graph {
				series: [root.series.temp ?? []]
				colors: [Theme.danger]
				minimumScale: 100
				maximum: 100
				format: value => `${Math.round(value)} °C`
			}

			Repeater {
				id: sensorGroups

				readonly property var list: {
					const groups = [];
					for (const temp of TaskManager.temps.list ?? []) {
						let group = groups.find(g => g.name === temp.group);
						if (!group) groups.push(group = { name: temp.group, items: [] });
						group.items.push(temp);
					}
					return groups;
				}
				model: sensorGroups.list.length

				ColumnLayout {
					id: sensorGroup

					required property int index
					readonly property var modelData: sensorGroups.list[index] ?? ({})

					Layout.fillWidth: true
					spacing: 6

					SectionLabel {
						text: sensorGroup.modelData.name
					}

					Repeater {
						id: sensorItems

						readonly property var list: sensorGroup.modelData.items
						model: sensorItems.list.length

						RowLayout {
							required property int index
							readonly property var modelData: sensorItems.list[index] ?? ({})

							Layout.fillWidth: true
							spacing: 12

							StyledText {
								Layout.preferredWidth: 130
								text: modelData.label
								elide: Text.ElideRight
								tone: Theme.textMuted
							}

							Meter {
								Layout.fillWidth: true
								value: modelData.value / (modelData.crit || 100)
								color: Theme.primary
								alarming: true
							}

							StyledText {
								Layout.preferredWidth: 60
								horizontalAlignment: Text.AlignRight
								text: `${Math.round(modelData.value)} °C`
								tabular: true
							}
						}
					}
				}
			}

			SectionLabel {
				text: "Fans"
				visible: (TaskManager.temps.fans ?? []).length > 0
			}

			Repeater {
				id: fanList

				readonly property var list: TaskManager.temps.fans ?? []
				model: fanList.list.length

				RowLayout {
					required property int index
					readonly property var modelData: fanList.list[index] ?? ({})

					Layout.fillWidth: true
					spacing: 12

					Glyph {
						icon: "fan"
						size: 16
						color: Theme.textMuted
						rotation: 0

						RotationAnimation on rotation {
							running: modelData.rpm > 0
							from: 0
							to: 360
							loops: Animation.Infinite
							duration: Math.max(300, 60000 / Math.max(1, modelData.rpm) * 20)
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: modelData.label
						tone: Theme.textMuted
					}

					StyledText {
						text: `${modelData.rpm} rpm`
						tabular: true
					}
				}
			}
		}
	}

	// ── the battery ────────────────────────────────────────────────────────
	Component {
		id: powerView

		ColumnLayout {
			spacing: 18

			readonly property var power: root.system?.power ?? {}

			Graph {
				series: [root.series.watts ?? []]
				colors: [Theme.success]
				minimumScale: 10
				format: value => `${value.toFixed(1)} W`
			}

			Stats {
				Stat {
					label: parent.parent.power.status === "Charging" ? "Charging with" : "Drawing"
					value: `${(parent.parent.power.watts ?? 0).toFixed(1)} W`
				}
				Stat {
					label: "Charge"
					value: `${parent.parent.power.percent ?? "?"}%`
				}
				Stat {
					visible: !!parent.parent.power.left
					label: parent.parent.power.status === "Charging" ? "Full in" : "Left"
					value: Format.duration(parent.parent.power.left ?? 0)
				}
				Stat {
					visible: !!parent.parent.power.health
					label: "Health"
					value: `${Math.round((parent.parent.power.health ?? 0) * 100)}%`
				}
				Stat {
					visible: !!parent.parent.power.cycles
					label: "Cycles"
					value: `${parent.parent.power.cycles ?? 0}`
				}
				Stat {
					label: "State"
					value: parent.parent.power.status ?? ""
				}
			}

			TopList {
				title: "Using the most power"
				items: TaskManager.top
			}
		}
	}
}
