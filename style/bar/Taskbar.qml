pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
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

	// keyed: a focus change or a window that comes keeps the other buttons
	// (and their animations); what changes is read from Niri.taskById
	Repeater {
		model: ScriptModel {
			values: Niri.taskGroups
			objectProp: "output"
		}

		delegate: ScreenGroup {
			id: group

			required property var modelData

			bar: root.bar
			output: group.modelData.output
			inset: 1

			Repeater {
				model: ScriptModel {
					values: Niri.tasksOn[group.modelData.output] ?? []
					objectProp: "id"
				}

				delegate: BarButton {
					id: task

					required property var modelData
					readonly property var live: Niri.taskById[task.modelData.id] ?? task.modelData

					bar: root.bar
					padding: 6
					implicitHeight: group.height
					// its app keeps more than half a core busy (task-manager-hints)
					readonly property bool hot: Plugins.on("task-manager-hints") && TaskManager.hot.includes(Number(task.modelData.id))
					readonly property var load: task.hovered && Plugins.on("task-manager") ? TaskManager.windowLoad[String(task.modelData.id)] ?? null : null

					tooltip: task.hovered ? `${Niri.titleOf(task.modelData.id)}  ·  ${task.live.output}${task.load ? `  ·  ${TaskManager.percent(task.load[0], 0)} CPU · ${Format.bytes(task.load[1])}` : ""}` : ""
					onClicked: Niri.focusWindow(task.modelData.id)
					onMiddleClicked: Niri.closeWindow(task.modelData.id)
					onRightClicked: if (Plugins.on("task-manager")) TaskManager.showWindow(task.modelData.id)

					// dragged onto an app tray, the app goes in
					DragHandler {
						id: carry

						target: null
						enabled: AppTray.enabled
						dragThreshold: 10
					}

					Item {
						x: carry.centroid.pressPosition.x
						y: carry.centroid.pressPosition.y
						width: 1
						height: 1
						Drag.dragType: Drag.Automatic
						Drag.active: carry.active
						Drag.supportedActions: Qt.CopyAction
						Drag.proposedAction: Qt.CopyAction
						Drag.mimeData: AppTray.mimeFor({ kind: "app", app: String(DesktopEntries.heuristicLookup(String(task.modelData.appId))?.id ?? task.modelData.appId) })
					}

					Binding {
						target: AppTray
						property: "carrying"
						value: true
						when: carry.active
					}

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
							opacity: task.live.onActiveWorkspace ? 1 : 0.4
							scale: task.hovered ? 1.14 : 1

							Behavior on scale {
								SpatialAnim {
									duration: Motion.short
								}
							}
						}

						Rectangle {
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.topMargin: (task.height - 18) / 2 - 2
							anchors.rightMargin: -3
							width: 7
							height: 7
							radius: 3.5
							color: Theme.warning
							border.width: 1.5
							border.color: Theme.bg
							scale: task.hot ? 1 : 0
							visible: scale > 0.01

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							SequentialAnimation on opacity {
								running: task.hot
								loops: Animation.Infinite
								alwaysRunToEnd: true
								NumberAnimation {
									to: 0.55
									duration: 900
									easing.type: Easing.InOutSine
								}
								NumberAnimation {
									to: 1
									duration: 900
									easing.type: Easing.InOutSine
								}
							}
						}

						Rectangle {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: parent.bottom
							anchors.bottomMargin: 1
							height: 3
							radius: 1.5
							width: task.live.isFocused ? 12 : (task.live.isUrgent ? 6 : 0)
							color: task.live.isUrgent ? Theme.danger : Theme.primary

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
