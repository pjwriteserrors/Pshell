pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The task manager: its pages on the left with the machine at a glance under
// them, the page on the right. Typing anywhere searches; the pages slide in
// from the side they are on. A page is made the first time it is opened and
// kept, so going back is instant.
FocusScope {
	id: root

	property bool windowed: true

	readonly property var tabs: [
		{ id: "apps", label: "Apps", icon: "view_list_outline" },
		{ id: "performance", label: "Performance", icon: "chart_areaspline" },
		{ id: "services", label: "Services", icon: "cog_transfer_outline" },
		{ id: "startup", label: "Startup", icon: "rocket_launch_outline" },
		{ id: "ports", label: "Ports", icon: "lan" },
		{ id: "history", label: "History", icon: "chart_timeline_variant" }
	]
	readonly property int tabIndex: Math.max(0, root.tabs.findIndex(t => t.id === TaskManager.tab))
	property int lastIndex: 0
	property int direction: 1
	property var visited: ({ [TaskManager.tab]: true })

	onTabIndexChanged: {
		root.direction = root.tabIndex >= root.lastIndex ? 1 : -1;
		root.lastIndex = root.tabIndex;
		root.visited = Object.assign({}, root.visited, { [TaskManager.tab]: true });
		if (TaskManager.tab === "apps" && Plugins.on("task-manager")) TaskManager.findLeftovers();
	}

	function go(id) {
		TaskManager.tab = id;
		TaskManager.saveSettings();
		keys.forceActiveFocus();
	}

	function takeFocus() {
		keys.forceActiveFocus();
		Qt.callLater(() => keys.forceActiveFocus());
		TaskManager.findLeftovers();
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			if (settings.shown) return;
			const ctrl = event.modifiers & Qt.ControlModifier;
			if (ctrl && event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
				root.go(root.tabs[event.key - Qt.Key_1].id);
				event.accepted = true;
				return;
			}
			if (ctrl && event.key === Qt.Key_F) {
				search.input.forceActiveFocus();
				event.accepted = true;
				return;
			}
			if (event.key === Qt.Key_Escape) {
				if (TaskManager.filter !== "") search.text = "";
				else if (TaskManager.selected !== "" && TaskManager.tab === "apps") TaskManager.select("");
				else TaskManager.close();
				event.accepted = true;
				return;
			}
			if (TaskManager.tab === "apps" && pageLoader(0)?.handleKey(event)) {
				event.accepted = true;
				return;
			}
			if (TaskManager.tab === "performance" && (event.key === Qt.Key_Down || event.key === Qt.Key_Up)) {
				pageLoader(1)?.stepDevice(event.key === Qt.Key_Down ? 1 : -1);
				event.accepted = true;
				return;
			}
			// typing searches
			if (!ctrl && event.text !== "" && /\S/.test(event.text)) {
				search.input.forceActiveFocus();
				search.text = search.text + event.text;
				event.accepted = true;
			}
		}
	}

	function pageLoader(index) {
		return pages.itemAt(index)?.page ?? null;
	}

	RowLayout {
		anchors.fill: parent
		spacing: 0

		// ── the pages ──────────────────────────────────────────────────────
		Rectangle {
			Layout.preferredWidth: 236
			Layout.fillHeight: true
			color: Theme.layer1

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 16
				spacing: 14

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					Rectangle {
						Layout.preferredWidth: 44
						Layout.preferredHeight: 44
						radius: Theme.radius.large
						color: Theme.primaryContainer

						// a heartbeat that beats with the load
						Glyph {
							id: badge

							anchors.centerIn: parent
							icon: "monitor_dashboard"
							size: 22
							color: Theme.primary
						}

						SequentialAnimation {
							running: root.visible && TaskManager.connected
							loops: Animation.Infinite
							NumberAnimation {
								target: badge
								property: "scale"
								to: 1 + 0.08 + TaskManager.cpu * 0.1
								duration: 180
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								target: badge
								property: "scale"
								to: 1
								duration: 420
								easing.type: Easing.OutCubic
							}
							PauseAnimation {
								duration: Math.max(300, 1400 - TaskManager.cpu * 1000)
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: "Task manager"
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: TaskManager.connected ? `${TaskManager.info.host ?? ""} · up ${Format.duration(TaskManager.system?.uptime ?? 0)}` : "Starting…"
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}
					}
				}

				Field {
					id: search

					Layout.fillWidth: true
					icon: "magnify"
					placeholder: "Search"
					text: TaskManager.filter
					onEdited: text => TaskManager.filter = text
					onTextChanged: if (TaskManager.filter !== search.text) TaskManager.filter = search.text
					onEscapePressed: {
						if (search.text !== "") search.text = "";
						else keys.forceActiveFocus();
					}
					onDownPressed: keys.forceActiveFocus()
					onAccepted: keys.forceActiveFocus()
				}

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: nav.height

					Rectangle {
						id: marker

						readonly property Item target: navRepeater.count >= 0 ? navRepeater.itemAt(root.tabIndex) : null

						width: nav.width
						height: 40
						y: marker.target ? marker.target.y : 0
						radius: Theme.radius.large
						color: Theme.primaryContainer

						Behavior on y {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Rectangle {
							x: 0
							anchors.verticalCenter: parent.verticalCenter
							width: 3
							height: 18
							radius: 1.5
							color: Theme.primary
						}
					}

					Column {
						id: nav

						width: parent.width
						spacing: 2

						Repeater {
							id: navRepeater

							model: root.tabs

							delegate: Clickable {
								id: tab

								required property var modelData
								required property int index
								readonly property bool picked: TaskManager.tab === tab.modelData.id

								width: nav.width
								height: 40
								radius: Theme.radius.large
								pressedScale: 0.97
								onClicked: root.go(tab.modelData.id)

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 14
									anchors.rightMargin: 12
									spacing: 12

									Glyph {
										icon: tab.modelData.icon
										size: 18
										color: tab.picked ? Theme.primary : Theme.textMuted
										scale: tab.picked ? 1.1 : 1

										Behavior on scale {
											SpatialAnim {
												duration: Motion.medium
											}
										}
									}

									StyledText {
										Layout.fillWidth: true
										text: tab.modelData.label
										tone: tab.picked ? Theme.primary : Theme.text
										font.weight: tab.picked ? Font.DemiBold : Font.Medium
									}

									StyledText {
										visible: tab.hovered && !tab.picked
										text: `^${tab.index + 1}`
										tone: Theme.textFaint
										font.pixelSize: Theme.size.tiny
									}
								}
							}
						}
					}
				}

				Item {
					Layout.fillHeight: true
				}

				// ── the machine at a glance ─────────────────────────────────
				// the model stays the same; only what a line shows changes, so
				// its graph keeps running instead of being made anew each second
				Repeater {
					model: ["cpu", "memory", "gpu", "temp"]

					delegate: Clickable {
						id: glance

						required property string modelData
						readonly property var info: glance.modelData === "cpu"
							? { label: "CPU", value: TaskManager.percent(TaskManager.cpu, 0), level: TaskManager.cpu, curve: "cpu", color: Theme.primary, device: "cpu", shows: true }
							: glance.modelData === "memory"
							? { label: "Memory", value: TaskManager.percent(TaskManager.memoryLevel, 0), level: TaskManager.memoryLevel, curve: "memory", color: Theme.secondary, device: "memory", shows: true }
							: glance.modelData === "gpu"
							? { label: "GPU", value: TaskManager.percent(TaskManager.gpu, 0), level: TaskManager.gpu, curve: "gpu", color: Theme.tertiary, device: TaskManager.gpus.length > 0 ? `gpu:${TaskManager.gpus[0].pci}` : "cpu", shows: TaskManager.hasGpu }
							: { label: "Temperature", value: TaskManager.temps.cpu ? `${Math.round(TaskManager.temps.cpu)} °C` : "", level: (TaskManager.temps.cpu ?? 0) / 100, curve: "temp", color: Theme.danger, device: "sensors", shows: (TaskManager.temps.cpu ?? null) !== null }

						Layout.fillWidth: true
						Layout.preferredHeight: 44
						visible: glance.info.shows
						radius: Theme.radius.medium
						onClicked: {
							TaskManager.device = glance.info.device;
							root.go("performance");
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 10

							ColumnLayout {
								Layout.preferredWidth: 80
								spacing: 0

								StyledText {
									text: glance.info.label
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.tiny
								}

								RollText {
									calm: true
									text: glance.info.value
									pixelSize: Theme.size.body
									weight: Font.DemiBold
									tone: glance.info.level > 0.9 ? Theme.danger : (glance.info.level > 0.75 ? Theme.warning : Theme.text)
								}
							}

							LiveGraph {
								Layout.fillWidth: true
								Layout.fillHeight: true
								Layout.topMargin: 6
								Layout.bottomMargin: 6
								series: [(TaskManager.series[glance.info.curve] ?? []).slice(-50)]
								colors: [glance.info.color]
								span: 50
								maximum: glance.info.curve === "temp" ? 100 : 1
								guides: false
								readout: false
								lineWidth: 1.5
							}
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 4

					IconButton {
						icon: "cog_outline"
						onClicked: settings.shown = true
					}

					Item {
						Layout.fillWidth: true
					}

					StyledText {
						text: TaskManager.system?.self ? `${TaskManager.percent(TaskManager.system.self.cpu)} · ${Format.bytes(TaskManager.system.self.mem)}` : ""
						tone: Theme.textFaint
						font.pixelSize: Theme.size.tiny
						tabular: true
					}

					IconButton {
						visible: Plugins.on("task-manager-bar")
						icon: root.windowed ? "dock_window" : "open_in_new"
						onClicked: root.windowed ? TaskManager.dock() : TaskManager.popOut()
					}
				}
			}
		}

		Rectangle {
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			color: Theme.outline
		}

		// ── the page ───────────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 0

			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 60
				Layout.leftMargin: 24
				Layout.rightMargin: 16
				Layout.fillHeight: false
				spacing: 10

				StyledText {
					text: root.tabs[root.tabIndex].label
					font.pixelSize: Theme.size.heading + 4
					font.weight: Font.Bold
				}

				StyledText {
					visible: TaskManager.tab === "apps"
					text: `${TaskManager.system?.tasks?.procs ?? 0} processes`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				Item {
					Layout.fillWidth: true
				}

				// only on the list: apps or processes, flat or a tree
				Row {
					spacing: 6
					visible: opacity > 0.01
					opacity: TaskManager.tab === "apps" ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					IconButton {
						anchors.verticalCenter: parent.verticalCenter
						visible: TaskManager.mode === "procs"
						icon: "file_tree_outline"
						checked: TaskManager.tree
						onClicked: {
							TaskManager.tree = !TaskManager.tree;
							TaskManager.saveSettings();
						}
					}

					Segmented {
						width: 230
						options: [{ value: "apps", label: "Apps" }, { value: "procs", label: "Processes" }]
						current: TaskManager.mode
						onSelected: value => {
							TaskManager.mode = value;
							TaskManager.saveSettings();
						}
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true

				Repeater {
					id: pages

					model: root.tabs

					delegate: Item {
						id: holder

						required property var modelData
						required property int index
						readonly property bool current: holder.index === root.tabIndex
						readonly property Item page: loader.item

						anchors.fill: parent
						visible: opacity > 0.01
						opacity: holder.current ? 1 : 0
						enabled: holder.current
						transform: Translate {
							id: slide

							x: holder.current ? 0 : (holder.index < root.tabIndex ? -28 : 28)

							Behavior on x {
								SpatialAnim {
									duration: Motion.long
								}
							}
						}

						Behavior on opacity {
							Anim {
								duration: holder.current ? Motion.medium : Motion.short
							}
						}

						Loader {
							id: loader

							anchors.fill: parent
							active: !!root.visited[holder.modelData.id]
							asynchronous: holder.index !== root.tabIndex
							source: ({
								apps: "AppsPage.qml", performance: "PerformancePage.qml", services: "ServicesPage.qml",
								startup: "StartupPage.qml", ports: "PortsPage.qml", history: "HistoryPage.qml"
							})[holder.modelData.id]
						}
					}
				}
			}
		}
	}

	SettingsSheet {
		id: settings

		anchors.fill: parent
		onShownChanged: if (settings.shown) settings.forceActiveFocus(); else keys.forceActiveFocus()
	}

	// held while open: the machine's values come every second, with the GPU's
	Component.onCompleted: TaskManager.watch(1, true)
	Component.onDestruction: TaskManager.watch(-1, true)
}
