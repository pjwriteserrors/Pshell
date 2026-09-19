pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import "components"

// The spine again, down the left of a screen that is not the primary one.
//
// Same organism, fewer organs: the hour, the windows on this output and the way
// out are here, but the readings that belong to the machine as a whole (weather,
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
		top: true
		bottom: true
	}

	margins {
		left: 0
		top: 0
		bottom: 0
	}

	exclusiveZone: Math.round(Bio.spine)
	implicitWidth: Math.round(Bio.spine)
	color: "transparent"
	mask: Region {
		x: 0
		y: 0
		width: Math.round(Bio.spine)
		height: root.height
	}

	Item {
		id: bar
		anchors.fill: parent

		readonly property real line: width / 2

		// The carapace edge, as on the primary spine: without it the bone lines
		// vanish wherever the wallpaper is pale.
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop { position: 0.0; color: Qt.alpha(Bio.cavity, 0.94) }
				GradientStop { position: 0.68; color: Qt.alpha(Bio.cavity, 0.7) }
				GradientStop { position: 1.0; color: "transparent" }
			}
		}

		Rectangle {
			x: Math.round(bar.line - width / 2)
			anchors.top: parent.top
			anchors.bottom: parent.bottom
			anchors.topMargin: Bio.s5
			anchors.bottomMargin: Bio.s5
			width: Bio.ribThin
			color: Bio.boneGhost
		}

		Column {
			id: leftCluster
			anchors.top: parent.top
			anchors.topMargin: Bio.s4
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: Bio.s3

			BioNode {
				id: launcherNode
				anchors.horizontalCenter: parent.horizontalCenter
				size: 38
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

			Column {
				anchors.horizontalCenter: parent.horizontalCenter
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

						anchors.horizontalCenter: parent?.horizontalCenter ?? undefined
						size: 26
						seed: trayNode.index + 1
						acceptedButtons: Qt.LeftButton | Qt.RightButton

						Image {
							anchors.centerIn: parent
							width: 14
							height: 14
							source: root.trayIconSource(trayNode.modelData?.icon ?? "")
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
				anchors.horizontalCenter: parent.horizontalCenter
				visible: root.niriState.tasksForOutput(String(root.screen?.name || "")).length > 0
				width: bar.width
				niriState: root.niriState
				outputName: String(root.screen?.name || "")
				background: Bio.tissue1
				foreground: Bio.text
				secondaryBoxColor: Bio.tissue2
				secondaryBoxStrongColor: Bio.tissue3
			}

		}

		BioSurface {
			id: plate

			anchors.horizontalCenter: parent.horizontalCenter
			anchors.verticalCenter: parent.verticalCenter
			width: bar.width
			height: plateColumn.implicitHeight + Bio.s6
			washTop: Bio.membrane
			washBottom: Bio.membraneDeep
			haloStrength: 0.18
			intensity: plateTouch.live
			padding: 0

			Column {
				id: plateColumn
				anchors.centerIn: parent
				spacing: 1

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "specimen"
					font.pixelSize: 21
					font.letterSpacing: 0
					text: Qt.formatDateTime(root.now, "HH")
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 16
					height: Bio.ribThin
					color: Bio.boneFaint
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "specimen"
					font.pixelSize: 21
					font.letterSpacing: 0
					tone: "organ"
					text: Qt.formatDateTime(root.now, "mm")
				}

				Item {
					width: 1
					height: Bio.s2
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "muted"
					font.pixelSize: 9
					text: Qt.formatDateTime(root.now, "ddd")
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "faint"
					font.pixelSize: 9
					font.letterSpacing: 0.4
					text: Qt.formatDateTime(root.now, "dd MMM")
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

		Column {
			id: rightCluster
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Bio.s4
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: Bio.s3

			NowPlaying {
				anchors.horizontalCenter: parent.horizontalCenter
				width: bar.width
				foreground: Bio.text
				secondaryBoxColor: Bio.tissue1
				progressColor: Bio.organ
				onClicked: root.mediaClicked()
			}

			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: Bio.s2

				BioNode {
					anchors.horizontalCenter: parent.horizontalCenter
					seed: 2
					iconSource: Bio.icon("edit-paste-symbolic")
					onClicked: root.clipboardClicked()
				}

				BioNode {
					anchors.horizontalCenter: parent.horizontalCenter
					seed: 3
					iconSource: Bio.icon("bluetooth-active-symbolic")
					onClicked: root.bluetoothClicked()
				}

				BioNode {
					anchors.horizontalCenter: parent.horizontalCenter
					seed: 0
					iconSource: root.networkStatusType === "ethernet"
						? Bio.icon("network-wired-symbolic")
						: Bio.icon("network-wireless-signal-excellent-symbolic")
					onClicked: root.networkClicked()
				}
			}

			TopBarResourceBars {
				anchors.horizontalCenter: parent.horizontalCenter
				width: bar.width
				onClicked: root.resourcesClicked()
			}

			Item {
				anchors.horizontalCenter: parent.horizontalCenter
				width: bar.width
				height: 22

				BioTendon {
					anchors.centerIn: parent
					width: parent.height
					height: 14
					rotation: 90
					facing: Qt.RightToLeft
					sag: 1.5
					weight: Bio.rib * 1.1
					lineColor: Bio.boneDim
				}
			}

			BioNode {
				id: powerNode
				anchors.horizontalCenter: parent.horizontalCenter
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
