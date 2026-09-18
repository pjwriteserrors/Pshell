pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import "components"

// The spine again, on a screen that is not the primary one.
//
// Same organism, fewer organs: the specimen plate, the tendons and the clusters
// are here, but the readings that belong to the machine as a whole (weather,
// notifications) stay on the one spine that owns them. Every press is a signal
// — this window knows nothing about popups.
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
	required property string networkStatusType
	required property var niriState

	// Kept so the primary shell can keep handing its palette over; the colours
	// themselves come from Bio, which reads the same Wallust file.
	property color foreground: Bio.text
	property color background: Bio.carapace
	property color secondaryBoxColor: Bio.tissue1
	property color secondaryBoxStrongColor: Bio.tissue2
	property color secondaryInsetColor: Bio.cavity
	property color tertiary: Bio.organAlt
	property color primary: Bio.organ
	property color onPrimaryColor: Bio.onOrgan
	property color danger: Bio.necrosis

	property date now: new Date()

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

	exclusiveZone: Math.round(bar.y + Bio.spine)
	implicitHeight: Math.round(bar.y + bar.height)
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
		anchors.leftMargin: Bio.s5
		anchors.rightMargin: Bio.s5
		anchors.topMargin: Bio.s2
		height: Bio.spine + plate.overhang

		readonly property real line: Bio.spine / 2

		// The carapace edge, as on the primary spine: without it the bone lines
		// vanish wherever the wallpaper is pale.
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.topMargin: -bar.anchors.topMargin
			anchors.leftMargin: -Bio.s5
			anchors.rightMargin: -Bio.s5
			height: Bio.spine + Bio.s5
			gradient: Gradient {
				GradientStop { position: 0.0; color: Qt.alpha(Bio.cavity, 0.92) }
				GradientStop { position: 0.62; color: Qt.alpha(Bio.cavity, 0.66) }
				GradientStop { position: 1.0; color: "transparent" }
			}
		}

		Row {
			id: leftCluster
			anchors.left: parent.left
			y: bar.line - height / 2
			spacing: Bio.s3

			BioNode {
				id: launcherNode
				anchors.verticalCenter: parent.verticalCenter
				seed: 0
				onClicked: root.launcherClicked()

				BioSigil {
					anchors.centerIn: parent
					width: parent.width * 0.64
					height: parent.height * 0.64
					seed: 7
					detail: 0.6
					weight: Bio.ribThin
					lineColor: Bio.text
				}
			}

			Row {
				anchors.verticalCenter: parent.verticalCenter
				spacing: Bio.s2
				visible: trayRepeater.count > 0

				Repeater {
					id: trayRepeater
					model: ScriptModel {
						values: SystemTray.items.values
					}

					BioNode {
						id: trayNode

						required property SystemTrayItem modelData
						required property int index

						anchors.verticalCenter: parent?.verticalCenter ?? undefined
						size: 26
						seed: trayNode.index + 1
						acceptedButtons: Qt.LeftButton | Qt.RightButton

						Image {
							anchors.centerIn: parent
							width: 14
							height: 14
							source: root.trayIconSource(trayNode.modelData.icon)
							fillMode: Image.PreserveAspectFit
							smooth: true
							mipmap: true
						}

						onClicked: event => {
							if (event.button === Qt.RightButton) trayNode.modelData.secondaryActivate();
							else trayNode.modelData.activate();
						}
					}
				}
			}

			NiriTaskbar {
				anchors.verticalCenter: parent.verticalCenter
				visible: root.niriState.tasksForOutput(String(root.screen?.name || "")).length > 0
				height: Bio.spine
				niriState: root.niriState
				outputName: String(root.screen?.name || "")
				background: Bio.tissue1
				foreground: Bio.text
				secondaryBoxColor: Bio.tissue2
				secondaryBoxStrongColor: Bio.tissue3
			}

			NowPlaying {
				anchors.verticalCenter: parent.verticalCenter
				height: Bio.spine
				foreground: Bio.text
				secondaryBoxColor: Bio.tissue1
				progressColor: Bio.organ
				onClicked: root.mediaClicked()
			}
		}

		BioTendon {
			anchors.left: leftCluster.right
			anchors.right: plate.left
			anchors.leftMargin: Bio.s4
			anchors.rightMargin: Bio.s3
			y: bar.line - height / 2
			height: 16
			facing: Qt.LeftToRight
			sag: 2
			weight: Bio.rib * 1.15
			lineColor: Bio.boneDim
			visible: width > 40
		}

		BioTendon {
			anchors.left: plate.right
			anchors.right: rightCluster.left
			anchors.leftMargin: Bio.s3
			anchors.rightMargin: Bio.s4
			y: bar.line - height / 2
			height: 16
			facing: Qt.RightToLeft
			sag: 2
			weight: Bio.rib * 1.15
			lineColor: Bio.boneDim
			visible: width > 40
		}

		BioSurface {
			id: plate

			readonly property real overhang: 18

			anchors.horizontalCenter: parent.horizontalCenter
			y: 0
			width: Math.max(168, plateColumn.implicitWidth + 64)
			height: Bio.spine + overhang
			washTop: Bio.membrane
			washBottom: Bio.membraneDeep
			haloStrength: 0.18
			intensity: plateTouch.live
			padding: 0

			Column {
				id: plateColumn
				anchors.centerIn: parent
				spacing: -2

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "specimen"
					font.pixelSize: 24
					text: Qt.formatDateTime(root.now, "HH:mm")
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "muted"
					font.pixelSize: 9
					text: Qt.formatDateTime(root.now, "ddd dd MMM")
				}
			}

			BioTouch {
				id: plateTouch
				onClicked: root.clockClicked()
			}
		}

		Timer {
			running: true
			repeat: true
			interval: 1000
			onTriggered: root.now = new Date()
		}

		Row {
			id: rightCluster
			anchors.right: parent.right
			y: bar.line - height / 2
			spacing: Bio.s3

			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				seed: 2
				iconSource: Bio.icon("edit-paste-symbolic")
				onClicked: root.clipboardClicked()
			}

			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				seed: 3
				iconSource: Bio.icon("bluetooth-active-symbolic")
				onClicked: root.bluetoothClicked()
			}

			BioNode {
				anchors.verticalCenter: parent.verticalCenter
				seed: 0
				iconSource: root.networkStatusType === "ethernet"
					? Bio.icon("network-wired-symbolic")
					: Bio.icon("network-wireless-signal-excellent-symbolic")
				onClicked: root.networkClicked()
			}

			TopBarResourceBars {
				anchors.verticalCenter: parent.verticalCenter
				height: Bio.spine
				onClicked: root.resourcesClicked()
			}

			BioNode {
				id: powerNode
				anchors.verticalCenter: parent.verticalCenter
				seed: 2
				ringColor: Qt.alpha(Bio.necrosis, 0.45)
				liveColor: Bio.necrosis
				iconColor: Qt.alpha(Bio.necrosis, 0.85)
				iconSource: Bio.icon("system-shutdown-symbolic")
				onClicked: root.powerClicked()
			}
		}
	}
}
