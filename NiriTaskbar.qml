pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

ThemedRectangle {
	id: root

	required property var niriState
	required property string outputName
	required property color background
	required property color foreground
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor

	readonly property int horizontalPadding: 10
	readonly property int taskSpacing: 6
	readonly property color hoverColor: Qt.alpha(root.foreground, 0.1)
	readonly property color focusedColor: Qt.tint(root.secondaryBoxColor, Qt.rgba(1, 1, 1, 0.08))
	readonly property int taskButtonSize: 24

	function iconSource(appId) {
		if (!appId) return Quickshell.iconPath("application-x-executable", true);

		const direct = Quickshell.iconPath(appId, true);
		if (direct !== "") return direct;

		const desktopName = appId.endsWith(".desktop") ? appId : `${appId}.desktop`;
		const desktopIcon = Quickshell.iconPath(desktopName, true);
		if (desktopIcon !== "") return desktopIcon;

		return Quickshell.iconPath("application-x-executable", true);
	}

	radius: ThemeEngine.radiusMedium
	color: "transparent"
	clip: !ThemeEngine.shadowEnabled
	implicitHeight: 30
	implicitWidth: Math.min(taskContent.implicitWidth + horizontalPadding * 2, 520)

	Item {
		id: taskRow
		anchors.fill: parent
		anchors.leftMargin: root.horizontalPadding
		anchors.rightMargin: root.horizontalPadding

		Row {
			id: taskContent
			anchors.fill: parent
			spacing: root.taskSpacing

			Repeater {
				id: taskRepeater

				// Keyed by window id so an unrelated window event reuses the
				// existing delegates instead of recreating them - recreating
				// reloads every icon, which reads as a flicker.
				model: ScriptModel {
					objectProp: "id"
					values: root.niriState.tasksForOutput(root.outputName)
				}

				// A plain Rectangle on purpose. As a ThemedRectangle the button
				// would cross the "has a surface colour" threshold the moment
				// the hover tint faded in and pop into a raised, bevelled,
				// lifted control in a single frame.
				delegate: Rectangle {
					id: taskButton

					required property var modelData
					readonly property var task: modelData
					readonly property bool hovered: mouseArea.containsMouse

					width: root.taskButtonSize + 4
					height: root.height - 6
					y: Math.round((root.height - height) / 2)
					radius: ThemeEngine.radiusMedium
					color: taskButton.task.isFocused
						? root.focusedColor
						: taskButton.hovered ? root.hoverColor : "transparent"
					border.width: taskButton.task.isUrgent ? 1 : 0
					border.color: root.secondaryBoxStrongColor

					Behavior on color {
						CAnim {}
					}

					// Atelier marks the focused window with a rule, not a tile.
					Rectangle {
						anchors.bottom: parent.bottom
						anchors.horizontalCenter: parent.horizontalCenter
						width: taskButton.task.isFocused ? 16 : 3
						height: 2
						color: taskButton.task.isFocused ? Atelier.accent : Atelier.muted

						Behavior on width {
							CAnim {}
						}
					}

					Image {
						anchors.centerIn: parent
						source: root.iconSource(taskButton.task.appId)
						sourceSize.width: 16
						sourceSize.height: 16
						width: 16
						height: 16
						fillMode: Image.PreserveAspectFit
						smooth: true
						mipmap: true
						asynchronous: true
						cache: true
						opacity: taskButton.task.isFocused || taskButton.hovered ? 1 : 0.78

						Behavior on opacity {
							CAnim {}
						}
					}

					MouseArea {
						id: mouseArea
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						acceptedButtons: Qt.LeftButton | Qt.MiddleButton
						onClicked: event => {
							if (event.button === Qt.MiddleButton)
								root.niriState.closeWindow(taskButton.task.id);
							else
								root.niriState.focusWindow(taskButton.task.id);
						}
					}
				}
			}
		}
	}
}
