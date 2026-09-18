pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The windows on this output, as a segment of spine.
//
// Every window is a vertebra on one bone. The focused one is a full ring with
// the application's icon in it; the rest are beads, sized by nothing and
// meaning only "there is another one". An urgent window flushes.
//
// This replaces a row of rounded buttons on purpose: a taskbar that looks like
// buttons invites reading each one, and there is nothing to read — the icon is
// the whole content.
Item {
	id: root

	required property var niriState
	required property string outputName

	// Handed over by the spine so a screen can be re-coloured in one place; the
	// values themselves come from Bio.
	property color background: Bio.tissue1
	property color foreground: Bio.text
	property color secondaryBoxColor: Bio.tissue2
	property color secondaryBoxStrongColor: Bio.tissue3

	readonly property int beadSize: 22
	readonly property int focusedSize: 28

	function iconSource(appId) {
		if (!appId) return Quickshell.iconPath("application-x-executable", true);

		const direct = Quickshell.iconPath(appId, true);
		if (direct !== "") return direct;

		const desktopName = appId.endsWith(".desktop") ? appId : `${appId}.desktop`;
		const desktopIcon = Quickshell.iconPath(desktopName, true);
		if (desktopIcon !== "") return desktopIcon;

		return Quickshell.iconPath("application-x-executable", true);
	}

	implicitHeight: Bio.spine
	implicitWidth: Math.min(chain.implicitWidth + Bio.s4, 520)

	// The bone the vertebrae sit on.
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.leftMargin: Bio.s3
		anchors.rightMargin: Bio.s3
		anchors.verticalCenter: parent.verticalCenter
		height: Bio.ribThin
		color: Bio.boneGhost
	}

	Row {
		id: chain
		anchors.centerIn: parent
		spacing: Bio.s2

		Repeater {
			id: taskRepeater

			// Keyed by window id so an unrelated window event reuses the
			// existing delegates instead of recreating them — recreating
			// reloads every icon, which reads as a flicker.
			model: ScriptModel {
				objectProp: "id"
				values: root.niriState.tasksForOutput(root.outputName)
			}

			delegate: Item {
				id: vertebra

				required property var modelData
				readonly property var task: modelData
				readonly property bool focused: vertebra.task.isFocused

				width: vertebra.focused ? root.focusedSize : root.beadSize
				height: root.focusedSize
				anchors.verticalCenter: parent?.verticalCenter ?? undefined

				Behavior on width {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
				}

				BioGlow {
					anchors.centerIn: parent
					width: root.focusedSize * 2
					height: root.focusedSize * 2
					color: vertebra.task.isUrgent ? Bio.necrosis : Bio.organ
					strength: 0.28
					spread: 0.32
					opacity: vertebra.focused || touch.containsMouse ? 1 : 0
					visible: opacity > 0.01

					Behavior on opacity {
						NumberAnimation { duration: Bio.grow }
					}
				}

				BioRing {
					anchors.centerIn: parent
					width: root.focusedSize
					height: root.focusedSize
					seed: vertebra.task.id % 4
					lineColor: Bio.boneFaint
					liveColor: vertebra.task.isUrgent ? Bio.necrosis : Bio.organ
					intensity: vertebra.focused ? 1 : touch.live
					opacity: vertebra.focused || touch.containsMouse ? 1 : 0.0
					visible: opacity > 0.01

					Behavior on opacity {
						NumberAnimation { duration: Bio.twitch }
					}
				}

				// The resting state: a bead on the bone, nothing else.
				Rectangle {
					anchors.centerIn: parent
					width: Bio.nodule * 2
					height: Bio.nodule * 2
					radius: width / 2
					color: vertebra.task.isUrgent ? Bio.necrosis : Bio.boneDim
					opacity: vertebra.focused || touch.containsMouse ? 0 : 1
					visible: opacity > 0.01

					Behavior on opacity {
						NumberAnimation { duration: Bio.twitch }
					}
				}

				Image {
					anchors.centerIn: parent
					source: root.iconSource(vertebra.task.appId)
					sourceSize.width: 15
					sourceSize.height: 15
					width: 15
					height: 15
					fillMode: Image.PreserveAspectFit
					smooth: true
					mipmap: true
					asynchronous: true
					cache: true
					opacity: vertebra.focused ? 1 : touch.containsMouse ? 0.85 : 0
					visible: opacity > 0.01

					Behavior on opacity {
						NumberAnimation { duration: Bio.twitch }
					}
				}

				BioTouch {
					id: touch
					acceptedButtons: Qt.LeftButton | Qt.MiddleButton
					onClicked: event => {
						if (event.button === Qt.MiddleButton)
							root.niriState.closeWindow(vertebra.task.id);
						else
							root.niriState.focusWindow(vertebra.task.id);
					}
				}
			}
		}
	}
}
