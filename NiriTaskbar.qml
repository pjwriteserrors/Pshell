pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
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
	readonly property color hoverColor: Qt.alpha(root.foreground, 0.04)
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
	color: root.background
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
				model: root.niriState.tasksForOutput(root.outputName)

				delegate: ThemedRectangle {
					required property var modelData
					readonly property var task: modelData

					readonly property bool hovered: mouseArea.containsMouse

					width: root.taskButtonSize + 4
					height: root.height - 6
					y: Math.round((root.height - height) / 2)
					radius: ThemeEngine.radiusMedium
					color: task.isFocused ? root.focusedColor : (hovered ? root.hoverColor : root.background)
					border.width: task.isUrgent ? 1 : 0
					border.color: root.secondaryBoxStrongColor

					Behavior on color {
						CAnim {}
					}

					HoverLayer {
						id: mouseArea
						tint: root.foreground
						showHover: false
						rippleEnabled: false
						onClicked: root.niriState.focusWindow(parent.task.id)
					}

					RowLayout {
						id: taskLayout
						readonly property var task: parent.task
						anchors.centerIn: parent

						Image {
							source: root.iconSource(parent.task.appId)
							sourceSize.width: 16
							sourceSize.height: 16
							fillMode: Image.PreserveAspectFit
							smooth: true
							mipmap: true
							Layout.preferredWidth: 16
							Layout.preferredHeight: 16
						}
					}
				}
			}
		}
	}
}
