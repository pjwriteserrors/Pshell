pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Tray drop-down. Shows the first tray icons as an overlapping stack and a
// chevron; the full tray opens as a panel.
BarButton {
	id: root

	readonly property var items: SystemTray.items.values

	panelId: "tray"
	visible: Plugins.on("tray") && root.items.length > 0
	tooltip: `${root.items.length} tray apps`
	padding: 8
	onClicked: {
		register();
		Popups.toggle("tray", root.bar.screen, undefined, undefined, root);
	}

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 5

		Item {
			anchors.verticalCenter: parent.verticalCenter
			width: Math.min(3, root.items.length) * 11 + 6
			height: 18

			Repeater {
				model: Math.min(3, root.items.length)

				delegate: Rectangle {
					id: chip

					required property int index
					readonly property var item: root.items[chip.index]

					x: chip.index * (root.hovered ? 14 : 11)
					z: 3 - chip.index
					width: 18
					height: 18
					radius: 9
					color: Theme.layer2
					border.width: 1.5
					border.color: Theme.bg

					Behavior on x {
						SpatialAnim {
							duration: Motion.short
						}
					}

					Image {
						anchors.centerIn: parent
						width: 12
						height: 12
						source: chip.item ? AppIcons.app(AppIcons.trayIconSource(chip.item.icon)) : ""
						sourceSize: Qt.size(24, 24)
						fillMode: Image.PreserveAspectFit
						asynchronous: true
						smooth: true
					}
				}
			}
		}

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			icon: "chevron_down"
			size: 15
			color: root.active ? Theme.primary : Theme.textMuted
			rotation: root.active ? 180 : 0

			Behavior on rotation {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}
	}
}
