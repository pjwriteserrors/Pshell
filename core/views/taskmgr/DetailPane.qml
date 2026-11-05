pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The row picked: what it is, its load and memory of the last two minutes,
// what it holds (memory as the kernel counts it, files, ports, windows), and
// what can be done with it. Its parts come in one after the other.
Item {
	id: root

	property string key: ""
	readonly property var row: TaskManager.rows[root.key] ?? null
	readonly property var facts: TaskManager.facts
	readonly property var main: root.facts?.kind === "proc" ? root.facts : (root.facts?.main ?? null)
	readonly property bool isGroup: root.row?.t === "group" && (root.row?.cnt ?? 1) > 1
	readonly property bool paused: TaskManager.isPaused(root.key)
	readonly property var history: TaskManager.detail?.key === root.key ? (TaskManager.detail.history ?? []) : []
	property var environ: []
	property bool environShown: false

	onKeyChanged: {
		root.environ = [];
		root.environShown = false;
		flick.contentY = 0;
		stagger.restart();
	}

	property int shownParts: 0

	Timer {
		id: stagger

		interval: 45
		repeat: true
		onTriggered: {
			root.shownParts += 1;
			if (root.shownParts > 12) stagger.stop();
		}
		onRunningChanged: if (running) root.shownParts = 0
	}

	Component.onCompleted: stagger.restart()

	component Part: ColumnLayout {
		id: part

		property int order: 0
		readonly property bool arrived: root.shownParts > part.order

		Layout.fillWidth: true
		spacing: 8
		opacity: part.arrived ? 1 : 0
		transform: Translate {
			y: part.arrived ? 0 : 10

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
	}

	component Fact: RowLayout {
		id: fact

		property string label
		property string value
		property bool mono: false
		property bool copy: false

		Layout.fillWidth: true
		visible: fact.value !== ""
		spacing: 10

		StyledText {
			Layout.preferredWidth: 96
			Layout.alignment: Qt.AlignTop
			text: fact.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}

		StyledText {
			Layout.fillWidth: true
			text: fact.value
			wrapMode: Text.WrapAnywhere
			maximumLineCount: 6
			elide: Text.ElideRight
			font.pixelSize: Theme.size.small
			font.family: fact.mono ? Theme.monoFamily : Theme.fontFamily
		}

		IconButton {
			visible: fact.copy
			Layout.preferredWidth: 24
			Layout.preferredHeight: 24
			Layout.alignment: Qt.AlignTop
			icon: "content_copy"
			onClicked: {
				Quickshell.execDetached(["wl-copy", "--", fact.value]);
				Sounds.play("copied");
			}
		}
	}

	component Stat: ColumnLayout {
		id: stat

		property string label
		property string value
		property color tone: Theme.text

		Layout.fillWidth: true
		Layout.preferredWidth: 1
		spacing: 0

		RollText {
			calm: true
			text: stat.value
			tone: stat.tone
			pixelSize: Theme.size.title
			weight: Font.DemiBold
		}

		StyledText {
			text: stat.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny
		}
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: body.implicitHeight + 40
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: body

			x: 18
			y: 18
			width: flick.width - 36
			spacing: 18

			// ── what it is ──────────────────────────────────────────────────
			Part {
				order: 0

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					Rectangle {
						Layout.preferredWidth: 52
						Layout.preferredHeight: 52
						radius: Theme.radius.large
						color: Theme.layer2

						readonly property string icon: TaskManager.iconOf(root.row)

						Image {
							anchors.centerIn: parent
							width: 34
							height: 34
							visible: !parent.icon.startsWith("glyph:")
							source: parent.icon.startsWith("glyph:") ? "" : parent.icon
							sourceSize: Qt.size(68, 68)
							fillMode: Image.PreserveAspectFit
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: parent.icon.startsWith("glyph:")
							icon: parent.icon.slice(6)
							size: 26
							color: Theme.primary
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							Layout.fillWidth: true
							text: TaskManager.nameOf(root.row)
							font.pixelSize: Theme.size.heading
							font.weight: Font.DemiBold
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								const row = root.row;
								if (!row) return "";
								const parts = [];
								parts.push(({ app: "App", pshell: "The shell", vm: "Virtual machine", svc: row.key?.startsWith("sys:") ? "System service" : "Service", kernel: "Kernel" })[row.kind] ?? "Process");
								if (root.isGroup) parts.push(`${row.cnt} processes`);
								else if (row.p) parts.push(`PID ${row.p}`);
								if (root.main?.state) parts.push(TaskManager.stateLabel(root.main.state));
								if (row.u) parts.push(row.u);
								return parts.join(" · ");
							}
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}
					}

					IconButton {
						Layout.alignment: Qt.AlignTop
						icon: "close"
						onClicked: TaskManager.select("")
					}
				}

				// what can be done with it
				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 6

					TextButton {
						Layout.fillWidth: true
						text: TaskManager.lingering[root.key] !== undefined ? "Force" : (root.isGroup || root.row?.kind === "app" ? "End task" : "End")
						icon: TaskManager.lingering[root.key] !== undefined ? "close_octagon_outline" : "close"
						variant: "danger"
						busy: TaskManager.ending[root.key] !== undefined && TaskManager.lingering[root.key] === undefined
						onActivated: TaskManager.lingering[root.key] !== undefined ? TaskManager.kill(root.key) : TaskManager.end(root.key)
					}

					TextButton {
						text: root.paused ? "Resume" : "Pause"
						icon: root.paused ? "play" : "pause"
						onActivated: root.paused ? TaskManager.resume(root.key) : TaskManager.pause(root.key)
					}

					IconButton {
						icon: TaskManager.watched[root.key] ? "bell_ring" : "bell_outline"
						checked: !!TaskManager.watched[root.key]
						variant: "tonal"
						onClicked: TaskManager.setWatched(root.key, !TaskManager.watched[root.key])
					}

					IconButton {
						visible: (root.row?.w ?? []).length > 0
						icon: "open_in_app"
						variant: "tonal"
						onClicked: {
							Niri.focusWindow(root.row.w[0]);
							TaskManager.close();
						}
					}
				}
			}

			// ── now and the last two minutes ───────────────────────────────
			Part {
				order: 1

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Stat {
						label: "CPU"
						value: TaskManager.percent(root.row?.c ?? 0)
						tone: (root.row?.c ?? 0) > 0.5 ? Theme.warning : Theme.text
					}

					Stat {
						label: "Memory"
						value: Format.bytes(root.row?.m ?? 0)
					}

					Stat {
						label: "Disk"
						value: Format.rate(root.row?.io ?? 0)
					}

					Stat {
						visible: TaskManager.hasGpu
						label: "GPU"
						value: TaskManager.percent(root.row?.g ?? 0, 0)
					}
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 92
					radius: Theme.radius.large
					color: Theme.layer1
					clip: true

					LiveGraph {
						anchors.fill: parent
						anchors.topMargin: 6
						series: [root.history.map(s => s[0])]
						colors: [Theme.primary]
						minimumScale: 0.05
						span: 120
						names: ["CPU"]
						format: value => TaskManager.percent(value, value < 0.1 ? 1 : 0)
					}
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 64
					radius: Theme.radius.large
					color: Theme.layer1
					clip: true

					LiveGraph {
						anchors.fill: parent
						anchors.topMargin: 6
						series: [root.history.map(s => s[1])]
						colors: [Theme.secondary]
						minimumScale: 16777216
						span: 120
						names: ["Memory"]
						format: value => Format.bytes(value)
					}
				}
			}

			// ── memory as the kernel counts it ─────────────────────────────
			Part {
				order: 2
				visible: !!root.facts?.memory

				SectionLabel {
					text: "Memory"
				}

				// what it takes for itself, what it shares, what is swapped out
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 10

					readonly property var memory: root.facts?.memory ?? { uss: 0, pss: 0, rss: 0, swap: 0 }
					readonly property real whole: Math.max(1, memory.rss + memory.swap)

					Rectangle {
						anchors.fill: parent
						radius: 5
						color: Theme.layer3
					}

					Row {
						anchors.fill: parent

						Repeater {
							id: memParts

							readonly property var memory: parent.parent.memory
							model: 3

							Rectangle {
								required property int index
								readonly property var modelData: [
									{ value: memParts.memory.uss, color: Theme.secondary },
									{ value: Math.max(0, memParts.memory.rss - memParts.memory.uss), color: Qt.alpha(Theme.secondary, 0.45) },
									{ value: memParts.memory.swap, color: Theme.warning }
								][index]

								height: parent.height
								width: parent.width * modelData.value / parent.parent.whole
								radius: 5
								color: modelData.color

								Behavior on width {
									SpatialAnim {
										duration: 700
									}
								}
							}
						}
					}
				}

				GridLayout {
					Layout.fillWidth: true
					columns: 2
					columnSpacing: 12
					rowSpacing: 6

					Repeater {
						model: 4

						RowLayout {
							required property int index
							readonly property var modelData: [
								["Its own", root.facts?.memory?.uss ?? 0, Theme.secondary],
								["Shared", Math.max(0, (root.facts?.memory?.rss ?? 0) - (root.facts?.memory?.uss ?? 0)), Qt.alpha(Theme.secondary, 0.45)],
								["Swapped out", root.facts?.memory?.swap ?? 0, Theme.warning],
								["Graphics", root.facts?.gpuMem ?? 0, Theme.tertiary]
							][index]

							Layout.fillWidth: true
							spacing: 6
							visible: modelData[1] > 0

							Rectangle {
								Layout.preferredWidth: 8
								Layout.preferredHeight: 8
								radius: 4
								color: modelData[2]
							}

							StyledText {
								Layout.fillWidth: true
								text: modelData[0]
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}

							StyledText {
								text: Format.bytes(modelData[1])
								font.pixelSize: Theme.size.small
								tabular: true
							}
						}
					}
				}
			}

			// ── its windows ────────────────────────────────────────────────
			Part {
				order: 3
				visible: (root.facts?.windows ?? []).length > 0

				SectionLabel {
					text: "Windows"
				}

				Repeater {
					id: windowList

					readonly property var list: root.facts?.windows ?? []
					model: windowList.list.length

					ListItem {
						required property int index
						readonly property var modelData: windowList.list[index] ?? ({})

						Layout.fillWidth: true
						icon: Parking.isParked(Number(modelData.id)) ? "dock_right" : "dock_window"
						title: modelData.title || modelData.appId
						subtitle: Niri.workspaceMap[Niri.windowMap[modelData.id]?.workspace_id]?.output ?? ""
						onClicked: {
							Niri.focusWindow(Number(modelData.id));
							TaskManager.close();
						}
					}
				}
			}

			// ── its processes ──────────────────────────────────────────────
			Part {
				order: 4
				visible: root.isGroup && (root.facts?.members ?? []).length > 0

				SectionLabel {
					text: "Processes"
				}

				Repeater {
					id: memberList

					readonly property var list: (root.facts?.members ?? []).slice(0, 12)
					model: memberList.list.length

					Clickable {
						id: member

						required property int index
						readonly property var modelData: memberList.list[index] ?? ({})

						Layout.fillWidth: true
						implicitHeight: 32
						radius: Theme.radius.small
						onClicked: {
							TaskManager.setExpanded(root.key, true);
							TaskManager.select(`p:${member.modelData[0]}`);
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 8
							anchors.rightMargin: 8
							spacing: 8

							StyledText {
								Layout.fillWidth: true
								text: member.modelData[1]
								elide: Text.ElideRight
								font.pixelSize: Theme.size.small
							}

							StyledText {
								text: TaskManager.percent(member.modelData[2])
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
								tabular: true
							}

							StyledText {
								Layout.preferredWidth: 70
								horizontalAlignment: Text.AlignRight
								text: Format.bytes(member.modelData[3])
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
								tabular: true
							}
						}
					}
				}
			}

			// ── what it listens on ─────────────────────────────────────────
			Part {
				order: 5
				visible: (root.facts?.ports ?? []).length > 0

				SectionLabel {
					text: "Listening"
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						id: portList

						readonly property var list: root.facts?.ports ?? []
						model: portList.list.length

						Chip {
							required property int index
							readonly property var modelData: portList.list[index] ?? ({})

							text: `${modelData.proto === "udp" ? "udp " : ""}:${modelData.port}`
							icon: modelData.scope === "local" ? "lan_disconnect" : "lan_connect"
							onClicked: if (modelData.proto === "tcp") Qt.openUrlExternally(`http://localhost:${modelData.port}`)
						}
					}
				}
			}

			// ── priority and cores ─────────────────────────────────────────
			Part {
				order: 6
				visible: !!root.main

				SectionLabel {
					text: "Priority"
				}

				Segmented {
					Layout.fillWidth: true
					options: [
						{ value: "background", label: "Background" },
						{ value: "low", label: "Low" },
						{ value: "normal", label: "Normal" },
						{ value: "high", label: "High" }
					]
					current: {
						const nice = root.main?.nice ?? 0;
						if (nice >= 15) return "background";
						if (nice >= 5) return "low";
						if (nice < 0) return "high";
						return "normal";
					}
					onSelected: value => TaskManager.setPriority(root.key, value)
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 8

					StyledText {
						text: "Cores"
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					Flow {
						Layout.fillWidth: true
						spacing: 4

						Repeater {
							model: TaskManager.coreCount

							Clickable {
								id: core

								required property int index
								readonly property bool on: (root.main?.affinity ?? []).includes(core.index)

								width: 26
								height: 22
								radius: Theme.radius.small
								color: core.on ? Theme.primaryContainer : Theme.layer2
								onClicked: {
									const set = new Set(root.main?.affinity ?? []);
									if (set.has(core.index)) set.delete(core.index);
									else set.add(core.index);
									if (set.size > 0) TaskManager.setAffinity(root.key, [...set]);
								}

								Behavior on color {
									ColorAnim {}
								}

								StyledText {
									anchors.centerIn: parent
									text: `${core.index}`
									tone: core.on ? Theme.primary : Theme.textSubtle
									font.pixelSize: Theme.size.tiny
									tabular: true
								}
							}
						}
					}
				}
			}

			// ── what it is, in detail ──────────────────────────────────────
			Part {
				order: 7
				visible: !!root.main

				SectionLabel {
					text: "Details"
				}

				Fact {
					label: "Command"
					value: (root.main?.cmd ?? []).join(" ")
					mono: true
					copy: true
				}

				Fact {
					label: "Program"
					value: root.main?.exe ?? ""
					mono: true
				}

				Fact {
					label: "Folder"
					value: root.main?.cwd ?? ""
					mono: true
				}

				Fact {
					label: "Started"
					value: root.main?.started ? `${Qt.formatDateTime(new Date(root.main.started * 1000), "ddd d MMM, HH:mm")} · ${Format.ago(root.main.started * 1000) === "now" ? "just now" : `${Format.ago(root.main.started * 1000)} ago`}` : ""
				}

				Fact {
					label: "CPU time"
					value: root.main?.cpuTime ? Format.duration(root.main.cpuTime, true) : ""
				}

				Fact {
					label: "Threads"
					value: root.isGroup ? `${root.facts?.threads ?? ""}` : `${root.main?.threads ?? ""}`
				}

				Fact {
					label: "Open files"
					value: root.main?.fds !== null && root.main?.fds !== undefined ? `${root.main.fds}` : ""
				}

				Fact {
					label: "Read · written"
					value: root.main?.io ? `${Format.bytes(root.main.io.read)} · ${Format.bytes(root.main.io.written)}` : ""
				}

				Fact {
					label: "Parent"
					value: root.main?.parent ? `${root.main.parent} (${root.main.ppid})` : ""
				}

				Fact {
					label: "Unit"
					value: root.facts?.unit || root.main?.unit || ""
					mono: true
				}

				Fact {
					label: "Disk priority"
					value: root.main?.ionice ?? ""
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 6

					TextButton {
						visible: (root.main?.cwd ?? "") !== ""
						text: "Open folder"
						icon: "folder_open_outline"
						onActivated: Qt.openUrlExternally(Format.fileUri(root.main.cwd))
					}

					TextButton {
						visible: root.main?.own === true || root.facts?.own === true
						text: root.environShown ? "Hide environment" : "Environment"
						icon: "variable"
						onActivated: {
							root.environShown = !root.environShown;
							if (root.environShown && root.environ.length === 0 && root.main)
								TaskManager.environ(root.main.pid, list => root.environ = list);
						}
					}
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: root.environShown ? Math.min(260, envList.implicitHeight + 16) : 0
					visible: Layout.preferredHeight > 0.5
					radius: Theme.radius.medium
					color: Theme.layer1
					clip: true

					Behavior on Layout.preferredHeight {
						SpatialAnim {}
					}

					Flickable {
						anchors.fill: parent
						anchors.margins: 8
						contentHeight: envList.implicitHeight
						clip: true
						ScrollBar.vertical: ThinScrollBar {}

						Column {
							id: envList

							width: parent.width
							spacing: 2

							Repeater {
								model: root.environ

								StyledText {
									required property var modelData

									width: envList.width
									text: `<b>${modelData[0]}</b>=${modelData[1]}`
									textFormat: Text.StyledText
									wrapMode: Text.WrapAnywhere
									font.family: Theme.monoFamily
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}
				}
			}

			// ── what the update replaced ───────────────────────────────────
			Part {
				order: 8
				visible: (root.facts?.oldlibs ?? []).length > 0

				SectionLabel {
					text: "From before the update"
				}

				Repeater {
					id: libraryList

					readonly property var list: root.facts?.oldlibs ?? []
					model: libraryList.list.length

					StyledText {
						required property int index
						readonly property string modelData: libraryList.list[index] ?? ""

						Layout.fillWidth: true
						text: modelData
						elide: Text.ElideMiddle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
						tone: Theme.textMuted
					}
				}

				TextButton {
					text: "Restart"
					icon: "restart"
					onActivated: {
						const item = TaskManager.oldLibs.find(entry => entry.key === root.key);
						TaskManager.restartApp(item ?? { key: root.key, kind: root.row?.kind ?? "proc", icon: root.row?.i ?? "", unit: root.row?.unit ?? "" });
					}
				}
			}
		}
	}
}
