pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Quick settings: tiles for network / bluetooth / sound / mic, do not
// disturb, keep awake, power profile and the phone (KDE Connect); volume,
// laptop and external monitor brightness sliders and a live system strip.
// Chevrons slide into detail pages; the panel morphs to each page's height.
Drawer {
	id: root

	property string page: "main"
	property string userHost: ""
	property string uptime: ""

	panelId: "control"
	panelWidth: 430
	contentHeight: pages.implicitHeight

	// the plugin behind a page
	readonly property var pagePlugins: ({ network: "network", bluetooth: "bluetooth", audio: "sound", dnd: "dnd", power: "power-profiles", phone: Phone.plugin, system: "system-monitor" })

	function offers(page) {
		const plugin = root.pagePlugins[page];
		return plugin === undefined || Plugins.on(plugin);
	}

	onPanelOpened: {
		root.page = Popups.page !== "" && root.offers(Popups.page) ? Popups.page : "main";
		statsProc.running = true;
		Audio.refreshSinks();
		if (Plugins.on("backlight")) Brightness.refresh(false);
		Ddc.refresh();
		PowerProfile.refresh();
		Phone.refresh();
	}

	Connections {
		target: Popups
		function onPageChanged() {
			if (root.shown && Popups.page !== "" && root.offers(Popups.page)) root.page = Popups.page;
		}
	}

	Binding {
		target: Bluetooth
		property: "watchers"
		value: root.shown && root.page === "bluetooth" ? 1 : 0
		when: root.shown
		restoreMode: Binding.RestoreValue
	}

	Binding {
		target: KdeConnect
		property: "watchers"
		value: root.shown && root.page === "phone" ? 1 : 0
		when: root.shown
		restoreMode: Binding.RestoreValue
	}

	Process {
		id: statsProc
		command: ["sh", "-lc", `printf '%s|%s' "$USER@$(cat /etc/hostname 2>/dev/null || uname -n)" "$(uptime -p | sed 's/^up //')"`]
		stdout: StdioCollector {
			onStreamFinished: {
				const parts = String(text || "").split("|");
				root.userHost = parts[0] || "";
				root.uptime = parts[1] || "";
			}
		}
	}

	PageView {
		id: pages

		anchors.left: parent.left
		anchors.right: parent.right
		current: root.page

		// ── main ──────────────────────────────────────────────────────────
		Page {
			pageName: "main"

			ColumnLayout {
				width: parent.width
				spacing: 14

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					Rectangle {
						Layout.preferredWidth: 38
						Layout.preferredHeight: 38
						radius: 19
						color: Theme.primaryContainer

						StyledText {
							anchors.centerIn: parent
							text: (root.userHost || "?").charAt(0).toUpperCase()
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
							tone: Theme.primary
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						Layout.leftMargin: 4
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: root.userHost
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: root.uptime !== "" ? `up ${root.uptime}` : ""
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}

					IconButton {
						visible: Plugins.on("studio-wallpaper")
						icon: "palette"
						variant: "tonal"
						onClicked: Popups.openStudio("wallpaper", root.targetScreen)
					}

					IconButton {
						visible: Plugins.on("studio-motion")
						icon: "animation_play"
						variant: "tonal"
						onClicked: Popups.openStudio("motion", root.targetScreen)
					}

					IconButton {
						visible: Plugins.on("lock-screen")
						icon: "lock"
						variant: "tonal"
						onClicked: {
							Popups.close();
							Session.lock();
						}
					}

					IconButton {
						visible: Plugins.on("power-menu")
						icon: "power"
						variant: "danger"
						onClicked: Popups.openModal("power", root.targetScreen)
					}
				}

				GridLayout {
					Layout.fillWidth: true
					columns: 2
					columnSpacing: 10
					rowSpacing: 10

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("network")
						icon: Network.icon
						title: Network.label
						subtitle: Network.online ? (Network.ip || Network.iface) : "Not connected"
						active: Network.online
						onClicked: root.page = "network"
						onDetailsRequested: root.page = "network"
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("bluetooth")
						icon: Bluetooth.icon
						title: Words.of("control.bluetooth", "Bluetooth")
						subtitle: Bluetooth.summary
						active: Bluetooth.powered
						onClicked: Bluetooth.togglePower()
						onDetailsRequested: root.page = "bluetooth"
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("sound")
						icon: Audio.icon
						title: Audio.muted ? "Muted" : "Sound"
						subtitle: Audio.shortSinkName(Audio.sinkName)
						active: !Audio.muted
						onClicked: Audio.toggleMute()
						onDetailsRequested: root.page = "audio"
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("sound")
						icon: Audio.micIcon
						title: Words.of("control.microphone", "Microphone")
						subtitle: Audio.micMuted ? "Muted" : `${Math.round(Audio.micVolume * 100)}%`
						active: !Audio.micMuted
						hasDetails: false
						onClicked: Audio.toggleMicMute()
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("dnd")
						icon: Notifs.dnd ? "bell_sleep" : "bell_outline"
						title: Words.of("control.silence", "Silence")
						subtitle: Notifs.dndReason
						active: Notifs.dnd
						onClicked: Notifs.toggleDnd()
						onDetailsRequested: root.page = "dnd"
					}

					QuickTile {
						Layout.fillWidth: true
						visible: KeepAwake.available
						icon: KeepAwake.active ? "coffee" : "coffee_outline"
						title: Words.of("control.keepAwake", "Keep awake")
						subtitle: KeepAwake.active ? "On" : "Off"
						active: KeepAwake.active
						hasDetails: false
						onClicked: KeepAwake.toggle()
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Plugins.on("water")
						icon: "cup_water"
						title: Words.of("control.water", "Water")
						subtitle: `${Breaks.formatLitres(Breaks.waterMl)} / ${Breaks.formatLitres(Breaks.goalMl)}`
						active: Breaks.waterMl >= Breaks.goalMl
						onClicked: Popups.open("breaks", root.targetScreen)
						onDetailsRequested: Popups.open("breaks", root.targetScreen)
					}

					QuickTile {
						Layout.fillWidth: true
						visible: PowerProfile.available
						icon: PowerProfile.icon(PowerProfile.current)
						title: Words.of("control.power", "Power")
						subtitle: PowerProfile.label(PowerProfile.current)
						active: PowerProfile.current !== "balanced"
						onClicked: PowerProfile.cycle()
						onDetailsRequested: root.page = "power"
					}

					QuickTile {
						Layout.fillWidth: true
						visible: Phone.available
						icon: Phone.reachable ? "cellphone" : "cellphone_off"
						title: Phone.name
						subtitle: Phone.summary
						active: Phone.reachable
						onClicked: root.page = "phone"
						onDetailsRequested: root.page = "phone"
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 8

					PillSlider {
						Layout.fillWidth: true
						visible: Plugins.on("sound")
						icon: Audio.icon
						iconInteractive: true
						dimmed: Audio.muted
						value: Audio.volume
						onMoved: value => Audio.setVolume(value)
						onIconClicked: Audio.toggleMute()
					}

					PillSlider {
						Layout.fillWidth: true
						visible: Brightness.available
						icon: Brightness.icon(Brightness.value)
						label: Ddc.available ? "Laptop" : ""
						value: Brightness.value
						onMoved: value => Brightness.set(value)
					}

					Repeater {
						model: Ddc.available ? Ddc.monitors : []

						delegate: RowLayout {
							id: monitor

							required property var modelData

							Layout.fillWidth: true
							spacing: 8

							PillSlider {
								Layout.fillWidth: true
								icon: Brightness.icon(monitor.modelData.value)
								label: Ddc.label(monitor.modelData)
								value: monitor.modelData.value
								dimmed: !monitor.modelData.known
								onMoved: value => Ddc.set(monitor.modelData.bus, value)
							}

							Segmented {
								visible: monitor.modelData.inputs.length > 1
								implicitWidth: monitor.modelData.inputs.length * 58
								Layout.preferredHeight: 34
								current: monitor.modelData.input
								options: monitor.modelData.inputs.map(input => ({ value: input.code, label: input.label }))
								onSelected: value => Ddc.setInput(monitor.modelData.bus, value)
							}
						}
					}
				}

				Clickable {
					Layout.fillWidth: true
					visible: Plugins.on("system-monitor") || SysStats.batteryAvailable || SysStats.mouseAvailable
					interactive: Plugins.on("system-monitor")
					implicitHeight: 72
					radius: Theme.radius.large
					color: Theme.layer1
					pressedScale: 0.98
					onClicked: root.page = "system"

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 10
						spacing: 14

						Repeater {
							model: Plugins.on("system-monitor") ? [
								{ label: "CPU", value: SysStats.cpu, color: Theme.primary },
								{ label: "RAM", value: SysStats.memory, color: Theme.secondary }
							] : []

							delegate: RowLayout {
								id: stat

								required property var modelData

								spacing: 8

								Ring {
									Layout.preferredWidth: 44
									Layout.preferredHeight: 44
									value: stat.modelData.value
									thickness: 5
									sweep: 270
									color: stat.modelData.value > 0.85 ? Theme.danger : stat.modelData.color

									StyledText {
										anchors.centerIn: parent
										text: Math.round(stat.modelData.value * 100)
										tabular: true
										font.pixelSize: Theme.size.small
										font.weight: Font.Bold
									}
								}

								SectionLabel {
									text: stat.modelData.label
								}
							}
						}

						Item {
							Layout.fillWidth: true
						}

						ColumnLayout {
							spacing: 2
							visible: SysStats.batteryAvailable || SysStats.mouseAvailable

							RowLayout {
								visible: SysStats.batteryAvailable
								spacing: 5
								Glyph {
									icon: SysStats.batteryIcon
									size: 16
									color: SysStats.charging ? Theme.success : Theme.text
								}
								StyledText {
									text: `${SysStats.batteryPercent}%`
									tabular: true
									font.weight: Font.DemiBold
									font.pixelSize: Theme.size.label
								}
							}

							RowLayout {
								visible: SysStats.mouseAvailable
								spacing: 5
								Glyph {
									icon: "mouse"
									size: 16
								}
								StyledText {
									text: SysStats.mouseText
									tabular: true
									font.weight: Font.DemiBold
									font.pixelSize: Theme.size.label
								}
							}
						}

						Glyph {
							visible: Plugins.on("system-monitor")
							icon: "chevron_right"
							size: 18
							color: Theme.textSubtle
						}
					}
				}
			}
		}

		// ── network ───────────────────────────────────────────────────────
		Page {
			pageName: "network"

			ColumnLayout {
				width: parent.width
				spacing: 14

				PageHeader {
					Layout.fillWidth: true
					title: Network.label
					subtitle: Network.online ? `${Network.iface} · ${Network.ip || "no IP"}${Network.signal >= 0 ? ` · ${Network.signal}% signal` : ""}` : "No active connection"
					onBack: root.page = "main"

					TextButton {
						visible: Network.online
						text: "Disconnect"
						icon: "lan_disconnect"
						variant: "danger"
						confirm: true
						onActivated: Network.disconnect()
					}
				}

				Repeater {
					model: [
						{ label: "Download", icon: "arrow_down", speed: Network.download, history: Network.downloadHistory, color: Theme.primary },
						{ label: "Upload", icon: "arrow_up", speed: Network.upload, history: Network.uploadHistory, color: Theme.secondary }
					]

					delegate: Rectangle {
						id: graph

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 112
						radius: Theme.radius.large
						color: Theme.layer1
						clip: true

						Sparkline {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: 64
							values: graph.modelData.history
							color: graph.modelData.color
						}

						RowLayout {
							x: 14
							y: 12
							width: parent.width - 28
							spacing: 8

							Glyph {
								icon: graph.modelData.icon
								size: 16
								color: graph.modelData.color
							}

							SectionLabel {
								Layout.fillWidth: true
								text: graph.modelData.label
							}

							StyledText {
								text: Network.formatSpeed(graph.modelData.speed)
								tabular: true
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}
						}
					}
				}
			}
		}

		// ── bluetooth ─────────────────────────────────────────────────────
		Page {
			pageName: "bluetooth"

			ColumnLayout {
				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("control.bluetooth", "Bluetooth")
					subtitle: Bluetooth.summary
					onBack: root.page = "main"

					Toggle {
						checked: Bluetooth.powered
						onToggled: Bluetooth.togglePower()
					}
				}

				TextButton {
					Layout.fillWidth: true
					visible: Bluetooth.powered
					text: Bluetooth.scanning ? "Searching for devices…" : "Search for devices"
					icon: "magnify"
					busy: Bluetooth.scanning
					onActivated: Bluetooth.scanning ? Bluetooth.stopScan() : Bluetooth.startScan()
				}

				// pairing: a question from the agent or a code to type on the device
				Rectangle {
					id: pairCard

					readonly property var req: Bluetooth.request
					readonly property var shown: Bluetooth.display
					readonly property bool asksCode: pairCard.req !== null && (pairCard.req.type === "passkey" || pairCard.req.type === "pin")
					readonly property string code: pairCard.req?.passkey || pairCard.shown?.passkey || ""

					Layout.fillWidth: true
					visible: pairCard.req !== null || pairCard.shown !== null
					implicitHeight: pairColumn.implicitHeight + 28
					radius: Theme.radius.large
					color: Theme.primaryContainer

					onAsksCodeChanged: if (pairCard.asksCode) Qt.callLater(() => codeField.focusInput())

					ColumnLayout {
						id: pairColumn

						x: 14
						y: 14
						width: parent.width - 28
						spacing: 10

						RowLayout {
							Layout.fillWidth: true
							spacing: 10

							Glyph {
								icon: pairCard.shown && !pairCard.req ? "keyboard" : "bluetooth"
								size: 18
								color: Theme.primary
							}

							StyledText {
								Layout.fillWidth: true
								text: {
									const r = pairCard.req;
									if (!r) return pairCard.shown ? `Type on ${pairCard.shown.name}` : "";
									switch (r.type) {
									case "confirm": return `Pair with ${r.name}?`;
									case "authorize": return `${r.name} wants to pair`;
									case "service": return `Allow ${r.name}?`;
									default: return `Code for ${r.name}`;
									}
								}
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}
						}

						// the code to compare or to type, digit by digit
						Row {
							Layout.alignment: Qt.AlignHCenter
							visible: pairCard.code !== "" && !pairCard.asksCode
							spacing: 6

							Repeater {
								model: pairCard.code.split("")

								delegate: Rectangle {
									required property string modelData
									required property int index
									readonly property bool typed: pairCard.shown !== null && pairCard.req === null && index < pairCard.shown.entered

									width: 30
									height: 40
									radius: Theme.radius.small
									color: typed ? Theme.primary : Theme.layer2

									StyledText {
										anchors.centerIn: parent
										text: parent.modelData
										tabular: true
										tone: parent.typed ? Theme.onPrimary : Theme.text
										font.pixelSize: Theme.size.heading
										font.weight: Font.Bold
									}
								}
							}
						}

						Field {
							id: codeField

							Layout.fillWidth: true
							visible: pairCard.asksCode
							icon: "dialpad"
							placeholder: pairCard.req?.type === "pin" ? "PIN" : "Passkey"
							onAccepted: {
								Bluetooth.answer(true, codeField.text.trim());
								codeField.text = "";
							}
						}

						RowLayout {
							Layout.fillWidth: true
							visible: pairCard.req !== null
							spacing: 8

							TextButton {
								Layout.fillWidth: true
								text: "Reject"
								icon: "close"
								variant: "ghost"
								onActivated: Bluetooth.answer(false)
							}

							TextButton {
								Layout.fillWidth: true
								text: pairCard.asksCode ? "Pair" : "Accept"
								icon: "check"
								variant: "filled"
								enabled: !pairCard.asksCode || codeField.text.trim() !== ""
								onActivated: {
									Bluetooth.answer(true, pairCard.asksCode ? codeField.text.trim() : undefined);
									codeField.text = "";
								}
							}
						}
					}
				}

				EmptyState {
					Layout.fillWidth: true
					Layout.topMargin: 10
					Layout.bottomMargin: 10
					visible: !Bluetooth.powered || Bluetooth.devices.length === 0
					icon: Bluetooth.powered ? "bluetooth_settings" : "bluetooth_off"
					title: Bluetooth.powered ? "No devices yet" : "Bluetooth is off"
					subtitle: Bluetooth.powered ? "Put a device in pairing mode and search." : "Turn it on to connect headphones, mice and more."
				}

				ListView {
					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(contentHeight, 340)
					visible: Bluetooth.powered && Bluetooth.devices.length > 0
					clip: true
					spacing: 4
					model: Bluetooth.devices
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					add: Transition {
						Anim {
							property: "opacity"
							from: 0
							to: 1
						}
					}
					displaced: Transition {
						SpatialAnim {
							property: "y"
						}
					}

					delegate: ListItem {
						id: device

						required property var modelData
						readonly property string status: Bluetooth.statusFor(device.modelData)
						readonly property bool busy: device.status.endsWith("...")

						width: ListView.view.width
						icon: Bluetooth.deviceIcon(device.modelData.name, device.modelData.icon)
						title: device.modelData.name || device.modelData.address
						subtitle: device.status
						selected: device.modelData.connected
						onClicked: Bluetooth.toggleDevice(device.modelData.address)

						Spinner {
							visible: device.busy
							Layout.preferredWidth: 16
							Layout.preferredHeight: 16
						}

						Rectangle {
							visible: device.modelData.connected && String(device.modelData.battery || "") !== ""
							Layout.preferredHeight: 22
							Layout.preferredWidth: batteryRow.implicitWidth + 14
							radius: 11
							color: Theme.layer2

							RowLayout {
								id: batteryRow

								anchors.centerIn: parent
								spacing: 3

								Glyph {
									icon: "battery"
									size: 13
									color: Theme.success
								}

								StyledText {
									text: device.modelData.battery
									tabular: true
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}
							}
						}

						TextButton {
							visible: device.modelData.paired && !device.busy
							implicitHeight: 30
							text: ""
							icon: "link_off"
							variant: "danger"
							confirm: true
							confirmText: "Forget"
							opacity: device.hovered || armed ? 1 : 0
							onActivated: Bluetooth.forget(device.modelData.address)

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}
				}
			}
		}

		// ── audio outputs ─────────────────────────────────────────────────
		Page {
			pageName: "audio"

			ColumnLayout {
				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("control.sound", "Sound")
					subtitle: Audio.muted ? "Muted" : `${Math.round(Audio.volume * 100)}% · ${Audio.shortSinkName(Audio.sinkName)}`
					onBack: root.page = "main"
				}

				PillSlider {
					Layout.fillWidth: true
					icon: Audio.icon
					iconInteractive: true
					dimmed: Audio.muted
					value: Audio.volume
					onMoved: value => Audio.setVolume(value)
					onIconClicked: Audio.toggleMute()
				}

				PillSlider {
					Layout.fillWidth: true
					icon: Audio.micIcon
					iconInteractive: true
					dimmed: Audio.micMuted
					accent: Theme.secondary
					value: Audio.micVolume
					onMoved: value => Audio.setMicVolume(value)
					onIconClicked: Audio.toggleMicMute()
				}

				SectionLabel {
					Layout.topMargin: 4
					text: "Output device"
				}

				Repeater {
					model: Audio.sinks

					delegate: ListItem {
						id: sink

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 46
						icon: sink.modelData.headphones || /arctis/i.test(sink.modelData.description) ? "headphones" : "speaker"
						title: Audio.shortSinkName(sink.modelData.description)
						selected: sink.modelData.active
						onClicked: Audio.setDefaultSink(sink.modelData.name)

						Glyph {
							icon: "check_circle"
							size: 18
							color: Theme.primary
							scale: sink.modelData.active ? 1 : 0

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}
					}
				}

				SectionLabel {
					Layout.topMargin: 4
					visible: Audio.streams.length > 0
					text: "Apps"
				}

				Repeater {
					model: Audio.streams

					delegate: RowLayout {
						id: stream

						required property var modelData
						readonly property string iconSource: Audio.streamIcon(stream.modelData)

						Layout.fillWidth: true
						spacing: 10

						Image {
							Layout.preferredWidth: 26
							Layout.preferredHeight: 26
							source: stream.iconSource
							sourceSize: Qt.size(52, 52)
							fillMode: Image.PreserveAspectFit
							asynchronous: true
							smooth: true
							mipmap: true
							opacity: stream.modelData.audio?.muted ? 0.4 : 1
						}

						PillSlider {
							Layout.fillWidth: true
							implicitHeight: 34
							icon: Audio.volumeIcon(stream.modelData.audio?.volume ?? 0, stream.modelData.audio?.muted ?? false)
							iconInteractive: true
							label: [Audio.streamName(stream.modelData), Audio.streamTitle(stream.modelData)].filter(t => t !== "").join(" · ")
							dimmed: stream.modelData.audio?.muted ?? false
							accent: Theme.secondary
							value: stream.modelData.audio?.volume ?? 0
							onMoved: value => {
								if (!stream.modelData.audio) return;
								stream.modelData.audio.muted = false;
								stream.modelData.audio.volume = value;
							}
							onIconClicked: if (stream.modelData.audio) stream.modelData.audio.muted = !stream.modelData.audio.muted
						}
					}
				}

				SectionLabel {
					Layout.topMargin: 4
					text: "Pause media"
				}

				Repeater {
					model: [
						{ rule: "lock", icon: "lock_outline", title: "When locked", checked: Media.pauseOnLock },
						{ rule: "headphones", icon: "headphones", title: "When headphones disconnect", checked: Media.pauseOnHeadphones }
					]

					delegate: ListItem {
						id: pauseRule

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 46
						icon: pauseRule.modelData.icon
						title: pauseRule.modelData.title
						onClicked: Media.setRule(pauseRule.modelData.rule, !pauseRule.modelData.checked)

						Toggle {
							checked: pauseRule.modelData.checked
							onToggled: on => Media.setRule(pauseRule.modelData.rule, on)
						}
					}
				}
			}
		}

		// ── do not disturb ────────────────────────────────────────────────
		Page {
			pageName: "dnd"

			ColumnLayout {
				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("control.dnd", "Do not disturb")
					subtitle: Notifs.dndReason
					onBack: root.page = "main"

					Toggle {
						checked: Notifs.dnd
						onToggled: on => Notifs.setDnd(on)
					}
				}

				Repeater {
					model: [
						{ rule: "tracking", icon: "timer_outline", title: "While tracking time", checked: Notifs.dndWhileTracking },
						{ rule: "fullscreen", icon: "fullscreen", title: "In fullscreen", checked: Notifs.dndFullscreen },
						{ rule: "sharing", icon: "monitor_share", title: "While sharing the screen", checked: Notifs.dndSharing },
						{ rule: "meetings", icon: "calendar_clock", title: "In meetings", checked: Notifs.dndMeetings }
					].filter(rule => (rule.rule !== "tracking" || Plugins.on("qtrack")) && (rule.rule !== "meetings" || Plugins.on("microsoft-calendar")))

					delegate: ListItem {
						id: rule

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 50
						icon: rule.modelData.icon
						title: rule.modelData.title
						onClicked: Notifs.setDndRule(rule.modelData.rule, !rule.modelData.checked)

						Toggle {
							checked: rule.modelData.checked
							onToggled: on => Notifs.setDndRule(rule.modelData.rule, on)
						}
					}
				}
			}
		}

		// ── power profile ─────────────────────────────────────────────────
		Page {
			pageName: "power"

			ColumnLayout {
				width: parent.width
				spacing: 8

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("control.powerProfile", "Power profile")
					subtitle: PowerProfile.label(PowerProfile.current)
					onBack: root.page = "main"
				}

				Repeater {
					model: PowerProfile.profiles.slice().sort((a, b) => ["power-saver", "balanced", "performance"].indexOf(a) - ["power-saver", "balanced", "performance"].indexOf(b))

					delegate: ListItem {
						id: profile

						required property string modelData

						Layout.fillWidth: true
						implicitHeight: 50
						icon: PowerProfile.icon(profile.modelData)
						title: PowerProfile.label(profile.modelData)
						selected: PowerProfile.current === profile.modelData
						onClicked: PowerProfile.set(profile.modelData)
					}
				}
			}
		}

		// ── phone ─────────────────────────────────────────────────────────
		// files dragged onto the page are sent to the phone
		Page {
			pageName: "phone"

			ColumnLayout {
				id: phonePage

				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Phone.name
					subtitle: Phone.summary
					onBack: root.page = "main"

					IconButton {
						icon: "refresh"
						onClicked: Phone.refresh()
					}
				}

				Rectangle {
					Layout.fillWidth: true
					visible: Phone.reachable && Phone.battery >= 0
					implicitHeight: 64
					radius: Theme.radius.large
					color: Theme.layer1

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 16
						spacing: 12

						Ring {
							Layout.preferredWidth: 40
							Layout.preferredHeight: 40
							value: Phone.battery / 100
							thickness: 4.5
							color: Phone.charging ? Theme.success : (Phone.battery <= 20 ? Theme.danger : Theme.primary)

							Glyph {
								anchors.centerIn: parent
								icon: Phone.charging ? "flash" : "cellphone"
								size: 16
							}
						}

						StyledText {
							text: `${Phone.battery}%`
							tabular: true
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							visible: text !== ""
							text: Phone.network ?? ""
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}
					}
				}

				GridLayout {
					Layout.fillWidth: true
					columns: Phone.legacy || !Plugins.on("phone-handoff") ? 3 : 4
					columnSpacing: 8
					rowSpacing: 8
					enabled: Phone.reachable
					opacity: Phone.reachable ? 1 : 0.4

					Repeater {
						model: [
							{ icon: "content_paste", label: "Clipboard", run: () => Phone.sendClipboard() },
							{ icon: "file_send_outline", label: "File", run: () => {
								Phone.pickingFile = true;
								Popups.open("launcher", root.targetScreen, "", ">file ");
							} },
							{ icon: "phone_ring", label: "Ring", run: () => Phone.ring() }
						].concat(Phone.legacy || !Plugins.on("phone-handoff") ? [] : [{ icon: "cellphone_play", label: "Continue", run: () => Phone.handoffMedia() }])

						delegate: Clickable {
							id: action

							required property var modelData

							Layout.fillWidth: true
							implicitHeight: 64
							radius: Theme.radius.large
							color: Theme.layer1
							pressedScale: 0.95
							onClicked: action.modelData.run()

							ColumnLayout {
								anchors.centerIn: parent
								spacing: 4

								Glyph {
									Layout.alignment: Qt.AlignHCenter
									icon: action.modelData.icon
									size: 20
									color: Theme.primary
								}

								StyledText {
									Layout.alignment: Qt.AlignHCenter
									text: action.modelData.label
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}
							}
						}
					}
				}

				Field {
					id: phoneText

					Layout.fillWidth: true
					enabled: Phone.reachable
					icon: "send"
					placeholder: "Send text"
					onAccepted: {
						Phone.sendText(phoneText.text);
						phoneText.text = "";
					}
				}

				Loader {
					Layout.fillWidth: true
					active: !Phone.legacy
					visible: active
					sourceComponent: PhonePairing {}
				}
			}

			DropArea {
				id: drop

				width: phonePage.width
				height: phonePage.implicitHeight
				enabled: Phone.reachable
				keys: ["text/uri-list"]
				onDropped: event => {
					for (const url of event.urls) Phone.shareFile(String(url));
					event.accept();
				}

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.large
					color: Qt.alpha(Theme.base, 0.86)
					border.width: 2
					border.color: Theme.primary
					opacity: drop.containsDrag ? 1 : 0
					visible: opacity > 0.01

					Behavior on opacity {
						Anim {}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "tray_arrow_down"
						size: 34
						color: Theme.primary
					}
				}
			}
		}

		// ── system ────────────────────────────────────────────────────────
		Page {
			pageName: "system"

			ColumnLayout {
				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("control.system", "System")
					subtitle: SysStats.cpuText
					onBack: root.page = "main"
				}

				Repeater {
					model: [
						{ label: "Processor", icon: "chip", value: SysStats.cpu, detail: SysStats.cpuText, history: SysStats.cpuHistory, color: Theme.primary },
						{ label: "Memory", icon: "memory", value: SysStats.memory, detail: SysStats.memoryText, history: SysStats.memoryHistory, color: Theme.secondary }
					]

					delegate: Rectangle {
						id: usage

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 96
						radius: Theme.radius.large
						color: Theme.layer1
						clip: true

						Sparkline {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							height: 56
							values: usage.modelData.history
							maximum: 1
							color: usage.modelData.color
						}

						RowLayout {
							x: 14
							y: 12
							width: parent.width - 28

							Glyph {
								icon: usage.modelData.icon
								size: 17
								color: usage.modelData.color
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0
								StyledText {
									text: usage.modelData.label
									font.weight: Font.DemiBold
								}
								StyledText {
									text: usage.modelData.detail
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
								}
							}

							StyledText {
								text: `${Math.round(usage.modelData.value * 100)}%`
								tabular: true
								font.pixelSize: Theme.size.heading
								font.weight: Font.Bold
							}
						}
					}
				}

				SectionLabel {
					Layout.topMargin: 2
					text: "Disks"
				}

				Repeater {
					model: SysStats.disks

					delegate: ColumnLayout {
						id: disk

						required property var modelData

						Layout.fillWidth: true
						spacing: 6

						RowLayout {
							Layout.fillWidth: true
							Glyph {
								icon: "harddisk"
								size: 16
								color: Theme.textMuted
							}
							StyledText {
								Layout.fillWidth: true
								text: disk.modelData.name
								font.weight: Font.DemiBold
							}
							StyledText {
								text: `${disk.modelData.freeText} free of ${disk.modelData.totalText}`
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}

						Rectangle {
							Layout.fillWidth: true
							implicitHeight: 8
							radius: 4
							color: Theme.layer2

							Rectangle {
								height: parent.height
								radius: 4
								width: parent.width * disk.modelData.usage
								color: disk.modelData.usage > 0.9 ? Theme.danger : Theme.tertiary

								Behavior on width {
									SpatialAnim {}
								}
							}
						}
					}
				}

				Rectangle {
					Layout.fillWidth: true
					visible: SysStats.mouseAvailable
					implicitHeight: 54
					radius: Theme.radius.large
					color: Theme.layer1

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 14
						spacing: 10

						Glyph {
							icon: "mouse"
							size: 18
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0
							StyledText {
								text: SysStats.mouseName
								font.weight: Font.DemiBold
							}
							StyledText {
								visible: text !== ""
								text: SysStats.mouseStatus
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}

						Ring {
							Layout.preferredWidth: 34
							Layout.preferredHeight: 34
							value: SysStats.mouseLevel
							thickness: 4
							color: SysStats.mouseLevel < 0.2 ? Theme.danger : Theme.success
						}

						StyledText {
							text: SysStats.mouseText
							tabular: true
							font.weight: Font.Bold
						}
					}
				}
			}
		}
	}
}
