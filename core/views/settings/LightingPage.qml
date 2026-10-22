pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Lighting (core/services/Lighting.qml): what every OpenRGB device shows –
// the wallpaper, the screen live, or nothing – and how live runs.
SettingsPage {
	id: root

	title: "Lighting"
	description: "The keyboard, the GPU, the fans and every other light OpenRGB finds: the wallpaper, or the screen as it changes."

	onActiveChanged: if (root.active) Lighting.scan()
	Component.onCompleted: Lighting.scan()

	readonly property var choices: [
		{ value: "wallpaper", label: "Wallpaper", icon: "wallpaper" },
		{ value: "live", label: "Live", icon: "television_ambient_light" },
		{ value: "off", label: "Off", icon: "lightbulb_off" }
	]
	readonly property int liveCount: Lighting.devices.filter(device => Lighting.modeOf(device.id) === "live").length

	function glyphOf(kind) {
		return ({ keyboard: "keyboard", gpu: "expansion_card", fans: "fan", strip: "led_strip_variant", memory: "memory", mouse: "mouse", headset: "headphones", light: "lightbulb" })[kind] ?? "led_strip_variant";
	}

	function shows(device, mode) {
		if (!device.present) return "Not plugged in";
		const keys = device.kind === "keyboard";
		if (mode === "live") return keys ? "The screen, projected onto the keys" : "The colour of the screen";
		if (mode === "off") return "Dark";
		return keys ? "The wallpaper, projected onto the keys" : "The wallpaper's accent colour";
	}

	// ── devices ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "lighting"
		title: "Devices"
		subtitle: "Wallpaper follows every theme change; live mirrors the screen while it changes"
		icon: "led_strip_variant"
		modified: Object.keys(Lighting.modes).length > 0
		onReset: {
			for (const id of Object.keys(Lighting.modes)) Lighting.setMode(id, "wallpaper");
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: Lighting.devices.length === 0
			text: !Lighting.scanned || Lighting.scanning ? "Looking for devices …" : (Lighting.server ? "OpenRGB finds no device it can light." : "No OpenRGB server answers – is OpenRGB installed?")
			tone: Theme.textMuted
		}

		Repeater {
			model: Lighting.devices

			delegate: DeviceRow {
				required property var modelData

				Layout.fillWidth: true
				device: modelData
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: Lighting.devices.length > 0
			text: "The keyboard is listed while the plugin “Keyboard (OpenRGB)” is on, the rest with “GPU & fan LEDs (OpenRGB)” (>plugins, Studio)."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// ── live ───────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "lighting-live"
		title: "Live"
		subtitle: Lighting.liveRunning ? `Mirrors ${Lighting.output || "the largest monitor"} on ${root.liveCount} ${root.liveCount === 1 ? "device" : "devices"}` : "Runs only while a device is set to live"
		icon: "television_ambient_light"
		modified: Lighting.output !== "" || Lighting.fps !== 15 || Math.abs(Lighting.smoothing - 0.5) > 0.001
		onReset: {
			Lighting.setOutput("");
			Lighting.setFps(15);
			Lighting.setSmoothing(0.5);
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					text: "Monitor"
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: Lighting.output === "" ? "None picked: the largest one, where games run as a rule" : `${Lighting.output} – click it again for the largest one`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			MonitorPicker {
				Layout.preferredWidth: 300
				Layout.preferredHeight: 110
				picked: Lighting.output
				onChosen: name => Lighting.setOutput(name)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					text: "Frames per second"
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: "At most – a still screen sends none. Fewer cost less; smoothing hides the steps."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Segmented {
				Layout.preferredWidth: 260
				options: [5, 10, 15, 30].map(fps => ({ value: String(fps), label: String(fps) }))
				current: String(Lighting.fps)
				onSelected: value => Lighting.setFps(Number(value))
			}
		}

		ValueSlider {
			from: 0
			to: 90
			step: 5
			unit: " %"
			icon: "blur"
			label: "Smoothing"
			value: Math.round(Lighting.smoothing * 100)
			onMoved: v => Lighting.setSmoothing(v / 100)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "niri hands over the screen on the GPU, which shrinks it to 160 pixels before the CPU sees it: about 2–3 % of one core at 15 frames with every device live. The OpenRGB Effects plugin's screen copy cannot read niri's screencasts, so the shell does it itself."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// one device: what it is, what it shows, and the choice
	component DeviceRow: Rectangle {
		id: row

		property var device: ({})
		readonly property string mode: Lighting.modeOf(row.device.id)

		implicitHeight: Math.max(texts.implicitHeight + 20, 56)
		radius: Theme.radius.large
		color: Theme.layer2

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 10
			spacing: 14

			Rectangle {
				Layout.preferredWidth: 34
				Layout.preferredHeight: 34
				radius: Theme.radius.medium
				color: row.mode === "off" || !row.device.present ? Theme.layer3 : Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: root.glyphOf(row.device.kind)
					size: 18
					color: row.mode === "off" || !row.device.present ? Theme.textMuted : Theme.primary
				}

				Rectangle {
					visible: row.mode === "live" && Lighting.liveRunning
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: -2
					width: 9
					height: 9
					radius: 4.5
					color: Theme.primary
					border.width: 2
					border.color: Theme.layer2

					SequentialAnimation on opacity {
						running: parent.visible && root.active
						loops: Animation.Infinite

						Anim {
							to: 0.35
							duration: Motion.extraLong
						}
						Anim {
							to: 1
							duration: Motion.extraLong
						}
					}
				}
			}

			ColumnLayout {
				id: texts

				Layout.fillWidth: true
				spacing: 1
				opacity: row.device.present ? 1 : 0.55

				StyledText {
					Layout.fillWidth: true
					text: row.device.name
					font.weight: Font.Medium
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: root.shows(row.device, row.mode)
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Segmented {
				Layout.preferredWidth: 300
				options: root.choices
				current: row.mode
				onSelected: value => Lighting.setMode(row.device.id, value)
			}
		}
	}
}
