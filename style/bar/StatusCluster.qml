import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Network, Bluetooth, sound, battery and a tiny CPU/RAM meter in one target.
// States that are easy to forget show up only while they apply: keep awake,
// a non-default power profile and a phone that is running low.
// Click for quick settings, scroll for volume, middle click to mute.
BarButton {
	id: root

	panelId: "control"
	tooltip: "Quick settings · scroll for volume · middle-click mute"
	wheelEnabled: true
	padding: 10
	onClicked: toggle()
	onMiddleClicked: Audio.toggleMute()
	onScrolled: wheel => Audio.adjust((wheel.angleDelta.y || -wheel.angleDelta.x) > 0 ? 1 : -1)

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 10

		Row {
			anchors.verticalCenter: parent.verticalCenter
			visible: Plugins.on("system-monitor")
			spacing: 2.5

			Repeater {
				model: [SysStats.cpu, SysStats.memory]

				delegate: Rectangle {
					required property real modelData

					anchors.verticalCenter: parent.verticalCenter
					width: 4
					height: 15
					radius: 2
					color: Theme.layer3

					Rectangle {
						anchors.bottom: parent.bottom
						width: parent.width
						radius: 2
						height: Math.max(2, parent.height * parent.modelData)
						color: parent.modelData > 0.85 ? Theme.danger : Theme.secondary

						Behavior on height {
							Anim {}
						}
					}
				}
			}
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: Plugins.on("network")
			icon: Network.icon
			size: 17
			color: Network.online ? Theme.text : Theme.textSubtle
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: Plugins.on("bluetooth") && Bluetooth.powered
			icon: Bluetooth.icon
			size: 16
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: Plugins.on("sound")
			icon: Audio.icon
			size: 17
			color: Audio.muted ? Theme.textSubtle : Theme.text
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: Plugins.on("sound") && Audio.micMuted
			icon: "microphone_off"
			size: 16
			color: Theme.danger
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: KeepAwake.active
			icon: "coffee"
			size: 16
			color: Theme.warning
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: PowerProfile.available && PowerProfile.current !== "balanced"
			icon: PowerProfile.icon(PowerProfile.current)
			size: 16
			color: PowerProfile.current === "power-saver" ? Theme.success : Theme.warning
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			visible: Phone.reachable && Phone.battery >= 0 && Phone.battery <= 20 && !Phone.charging
			icon: "cellphone"
			size: 16
			color: Theme.danger
		}

		Row {
			anchors.verticalCenter: parent.verticalCenter
			visible: SysStats.batteryAvailable
			spacing: 3

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: SysStats.batteryIcon
				size: 17
				color: SysStats.charging || SysStats.charged ? Theme.success : (SysStats.batteryPercent <= 15 ? Theme.danger : Theme.text)
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: `${SysStats.batteryPercent}%`
				tabular: true
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}
		}
	}
}
