pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Every open window, grouped per monitor – identical on every bar. Each
// monitor gets its own capsule (the one of this screen is accent-tinted),
// ordered left to right like the monitors. Windows on hidden workspaces are
// dimmed, the focused one gets an accent bar under its icon. Clicking
// focuses the window wherever it lives, middle click closes it.
Row {
	id: root

	required property var bar

	anchors.verticalCenter: parent ? parent.verticalCenter : undefined
	spacing: 6

	Repeater {
		model: Niri.taskGroups

		delegate: ScreenGroup {
			id: group

			required property var modelData

			bar: root.bar
			output: group.modelData.output
			inset: 1

			Repeater {
				model: group.modelData.tasks

				delegate: BarButton {
					id: task

					required property var modelData

					bar: root.bar
					padding: 6
					implicitHeight: group.height
					tooltip: task.hovered ? `${Niri.titleOf(task.modelData.id)}  ·  ${task.modelData.output}` : ""
					onClicked: Niri.focusWindow(task.modelData.id)
					onMiddleClicked: Niri.closeWindow(task.modelData.id)

					Item {
						anchors.verticalCenter: parent.verticalCenter
						width: 20
						height: task.height

						Image {
							anchors.centerIn: parent
							width: 18
							height: 18
							source: AppIcons.forAppId(task.modelData.appId)
							sourceSize: Qt.size(36, 36)
							fillMode: Image.PreserveAspectFit
							smooth: true
							mipmap: true
							asynchronous: true
							opacity: task.modelData.onActiveWorkspace ? 1 : 0.4
							scale: task.hovered ? 1.14 : 1

							Behavior on scale {
								SpatialAnim {
									duration: Motion.short
								}
							}
						}

						Rectangle {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: parent.bottom
							anchors.bottomMargin: 1
							height: 3
							radius: 1.5
							width: task.modelData.isFocused ? 12 : (task.modelData.isUrgent ? 6 : 0)
							color: task.modelData.isUrgent ? Theme.danger : Theme.primary

							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}
					}
				}
			}
		}
	}
}
