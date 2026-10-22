pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Every HID device of the PC (scripts/devices/devices.py) and who looks after
// it (core/devices.json): a known one opens its page, an unknown one – or a
// model a page fits only partly – starts a Claude session in the repo that
// reverse engineers it and builds its page.
SettingsPage {
	id: root

	title: "Devices"
	description: ""

	signal open(string page)

	property var devices: []
	property bool scanned: false
	property var hidden: []

	onActiveChanged: if (root.active && !scanner.running) scanner.running = true

	readonly property var shown: root.devices.filter(d => d.role !== "receiver" && d.handler?.role !== "receiver" && !root.hidden.includes(d.id))
	readonly property var known: root.shown.filter(d => d.handler?.page && !d.handler.partial)
	readonly property var partial: root.shown.filter(d => d.handler?.page && d.handler.partial)
	readonly property var unknown: root.shown.filter(d => !d.handler?.page)

	function icon(kind) {
		return ({ keyboard: "keyboard", mouse: "mouse_variant", trackball: "mouse_variant", touchpad: "gesture_tap", gamepad: "gamepad_variant", tablet: "draw", touchscreen: "gesture_tap", "media keys": "play_pause", numpad: "dialpad", presenter: "devices" })[kind] ?? "devices";
	}

	function where(device) {
		if (device.bus === "receiver") return device.via;
		return ({ usb: "USB", bluetooth: "Bluetooth", i2c: "Built in" })[device.bus] ?? device.bus;
	}

	function teach(device) {
		teacher.device = device;
		teacher.running = true;
	}

	function hide(id) {
		root.hidden = root.hidden.concat([id]);
		hiddenFile.setText(JSON.stringify({ hidden: root.hidden }) + "\n");
	}

	Process {
		id: scanner

		command: ["python3", `${Paths.scripts}/devices/devices.py`]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.devices = JSON.parse(this.text).devices ?? [];
				} catch (error) {
					console.warn("Devices: scan failed");
				}
				root.scanned = true;
			}
		}
	}

	// plugged in or out: again, while the page is open
	Timer {
		interval: 8000
		repeat: true
		running: root.active
		onTriggered: if (!scanner.running) scanner.running = true
	}

	Process {
		id: teacher

		property var device: null

		command: ["python3", `${Paths.scripts}/devices/devices.py`, "prompt", teacher.device?.id ?? ""]
		stdout: StdioCollector {
			onStreamFinished: {
				const file = this.text.trim();
				if (!file) return;
				Quickshell.execDetached(Terminal.shellCommand({ title: `Claude: ${teacher.device?.name ?? "device"}`, dir: Paths.shell }, `claude "$(cat '${file}')"`));
			}
		}
	}

	FileView {
		id: hiddenFile

		path: Paths.stateFile("devices.json")
		printErrors: false
		onLoaded: {
			try {
				root.hidden = JSON.parse(text() || "{}").hidden ?? [];
			} catch (error) {
				root.hidden = [];
			}
		}
	}

	SettingCard {
		anchor: "devices-list"
		title: root.scanned ? `${root.shown.length} ${root.shown.length === 1 ? "device" : "devices"}` : "Looking …"
		icon: "devices"

		trailing: IconButton {
			implicitWidth: 32
			implicitHeight: 32
			icon: "refresh"
			variant: "ghost"
			enabled: !scanner.running
			onClicked: scanner.running = true
		}

		Repeater {
			model: root.known.concat(root.partial).concat(root.unknown)

			delegate: Rectangle {
				id: tile

				required property var modelData
				readonly property var handler: tile.modelData.handler
				readonly property bool isKnown: !!tile.handler?.page
				readonly property bool pluginOn: !tile.handler?.plugin || Plugins.on(tile.handler.plugin)

				Layout.fillWidth: true
				implicitHeight: 64
				radius: Theme.radius.large
				color: Theme.layer2
				opacity: tile.modelData.online === false ? 0.6 : 1

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 16
					anchors.rightMargin: 12
					spacing: 14

					Rectangle {
						Layout.preferredWidth: 38
						Layout.preferredHeight: 38
						radius: 19
						color: tile.isKnown && !tile.handler.partial ? Theme.primaryContainer : Theme.layer3

						Glyph {
							anchors.centerIn: parent
							icon: root.icon(tile.modelData.kind)
							size: 19
							color: tile.isKnown && !tile.handler.partial ? Theme.primary : Theme.textMuted
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							text: tile.modelData.name || `${tile.modelData.vendor}:${tile.modelData.product}`
							font.weight: Font.DemiBold
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: [root.where(tile.modelData), `${tile.modelData.vendor}:${tile.modelData.product}`, tile.modelData.online === false ? "asleep" : ""].filter(s => s).join(" · ")
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}
					}

					TextButton {
						visible: tile.isKnown && !tile.pluginOn
						variant: "tonal"
						icon: "power"
						text: "Switch on"
						onActivated: Plugins.set(tile.handler.plugin, true)
					}

					TextButton {
						visible: tile.isKnown && tile.pluginOn
						variant: tile.handler?.partial ? "tonal" : "filled"
						icon: "tune_variant"
						text: "Settings"
						onActivated: root.open(tile.handler.page)
					}

					TextButton {
						visible: !tile.isKnown || tile.handler?.partial === true
						variant: tile.isKnown ? "ghost" : "filled"
						icon: "robot"
						text: tile.isKnown ? "Complete with Claude" : "Teach with Claude"
						enabled: !teacher.running
						onActivated: root.teach(tile.modelData)
					}

					IconButton {
						visible: !tile.isKnown
						implicitWidth: 30
						implicitHeight: 30
						icon: "eye_off_outline"
						variant: "ghost"
						onClicked: root.hide(tile.modelData.id)
					}
				}
			}
		}

		TextButton {
			visible: root.hidden.length > 0
			variant: "ghost"
			icon: "eye_outline"
			text: `${root.hidden.length} hidden`
			onActivated: {
				root.hidden = [];
				hiddenFile.setText(JSON.stringify({ hidden: [] }) + "\n");
			}
		}
	}
}
