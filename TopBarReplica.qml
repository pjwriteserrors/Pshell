pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.SystemTray
import "components"

PanelWindow {
	id: root

	signal launcherClicked
	signal mediaClicked
	signal clockClicked
	signal clipboardClicked
	signal bluetoothClicked
	signal networkClicked
	signal resourcesClicked
	signal powerClicked

	required property var screenModel
	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color tertiary
	required property string networkStatusType
	required property var niriState
	property color primary: secondaryBoxColor
	property color onPrimaryColor: background
	property color danger: "#d95c5c"

	function trayIconSource(icon) {
		if (!icon) return "";

		if (icon.includes("?path=")) {
			const parts = icon.split("?path=");
			const name = parts[0];
			const path = parts[1];
			return Qt.resolvedUrl(`${path}/${name.slice(name.lastIndexOf("/") + 1)}`);
		}

		return icon;
	}

	screen: screenModel

	anchors {
		left: true
		right: true
		top: true
	}

	margins {
		left: 0
		right: 0
		top: 0
	}

	exclusiveZone: bar.y + bar.implicitHeight
	implicitHeight: bar.y + bar.implicitHeight + ThemeEngine.shadowRenderMargin
	color: "transparent"
	mask: Region {
		x: bar.x
		y: bar.y
		width: bar.width
		height: bar.height
	}

	Item {
		id: bar
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: 12
		anchors.rightMargin: 12
		anchors.topMargin: 6
		height: implicitHeight
		implicitHeight: 34
		clip: false

		Row {
			anchors.left: parent.left
			anchors.leftMargin: 0
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10

			ThemedRectangle {
				id: launcherButton
				width: 38
				height: bar.height
				radius: ThemeEngine.radiusMedium
				color: root.primary

				HoverLayer {
					id: launcherInteraction
					tint: root.onPrimaryColor
					onClicked: root.launcherClicked()
				}

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 16
					height: 16
					source: "/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.onPrimaryColor
				}
			}

			ThemedRectangle {
				id: trayIsland
				visible: trayRepeater.count > 0
				width: trayRow.implicitWidth + 20
				height: bar.height
				radius: ThemeEngine.radiusMedium
				color: root.secondaryBoxColor
				border.width: 0
				border.color: "transparent"

				Row {
					id: trayRow
					anchors.centerIn: parent
					spacing: 6

					Repeater {
						id: trayRepeater
						model: ScriptModel {
							values: SystemTray.items.values
						}

						Item {
							id: replicaTrayIcon

							required property SystemTrayItem modelData

							width: 18
							height: 18

							Image {
								anchors.fill: parent
								source: root.trayIconSource(replicaTrayIcon.modelData.icon)
								fillMode: Image.PreserveAspectFit
								smooth: true
								mipmap: true
							}

							HoverLayer {
								tint: root.foreground
								cornerRadius: 5
								acceptedButtons: Qt.LeftButton | Qt.RightButton

								onClicked: event => {
									if (event.button === Qt.RightButton) replicaTrayIcon.modelData.secondaryActivate();
									else replicaTrayIcon.modelData.activate();
								}
							}
						}
					}
				}
			}

			NiriTaskbar {
				visible: root.niriState.tasksForOutput(String(root.screenModel?.name || "")).length > 0
				height: bar.height
				niriState: root.niriState
				outputName: String(root.screenModel?.name || "")
				background: root.background
				foreground: root.foreground
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
			}

			NowPlaying {
				height: bar.height
				foreground: root.foreground
				secondaryBoxColor: root.secondaryBoxColor
				progressColor: root.tertiary
				onClicked: root.mediaClicked()
			}
		}

		ThemedRectangle {
			id: clockIsland
			width: Math.max(clock.width + 32, 132)
			height: parent.height
			anchors.centerIn: parent
			radius: ThemeEngine.radiusMedium
			color: root.secondaryBoxColor
			border.width: 0
			border.color: "transparent"

			HoverLayer {
				id: clockInteraction
				tint: root.foreground
				onClicked: root.clockClicked()
			}
		}

		Text {
			id: clock
			anchors.centerIn: parent
			color: root.foreground
			font.pixelSize: 18
			font.weight: Font.Medium
			text: Qt.formatDateTime(new Date(), "HH:mm")
		}

		Timer {
			running: true
			repeat: true
			interval: 1000

			onTriggered: clock.text = Qt.formatDateTime(new Date(), "HH:mm")
		}

		TopBarNetworkButton {
			anchors.right: bluetoothButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			foreground: root.foreground
			secondaryBoxColor: root.secondaryBoxColor
			iconSource: "/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg"
			onClicked: root.clipboardClicked()
		}

		TopBarNetworkButton {
			id: bluetoothButton
			anchors.right: networkButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			foreground: root.foreground
			secondaryBoxColor: root.secondaryBoxColor
			iconSource: "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg"
			onClicked: root.bluetoothClicked()
		}

		TopBarNetworkButton {
			id: networkButton
			anchors.right: resourceBars.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			foreground: root.foreground
			secondaryBoxColor: root.secondaryBoxColor
			iconSource: root.networkStatusType === "ethernet"
				? "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg"
				: "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg"
			onClicked: root.networkClicked()
		}

		TopBarResourceBars {
			id: resourceBars
			anchors.right: powerButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			height: parent.height
			foreground: root.foreground
			secondaryBoxColor: root.secondaryBoxColor
			secondaryInsetColor: root.secondaryInsetColor
			barColor: root.tertiary
			cpuIcon: "/usr/share/icons/hicolor/scalable/actions/xsi-cpu-symbolic.svg"
			memoryIcon: "/usr/share/icons/hicolor/scalable/actions/xsi-applications-electronics-symbolic.svg"
			storageIcon: Quickshell.iconPath("drive-harddisk-symbolic", true) || Quickshell.iconPath("drive-harddisk-system-symbolic", true) || Quickshell.iconPath("xsi-drive-harddisk-symbolic", true)
			mouseIcon: "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg"
			onClicked: root.resourcesClicked()
		}

		ThemedRectangle {
			id: powerButton
			width: 34
			height: parent.height
			anchors.right: parent.right
			anchors.rightMargin: 0
			anchors.verticalCenter: parent.verticalCenter
			radius: ThemeEngine.radiusMedium
			color: Qt.tint(root.secondaryBoxColor, Qt.alpha(root.danger, 0.25))

			HoverLayer {
				id: powerInteraction
				tint: root.danger
				onClicked: root.powerClicked()
			}

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 16
					height: 16
					source: "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.danger
				}
			}
	}
}
