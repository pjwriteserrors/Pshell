pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Workspaces of every monitor, one capsule per monitor, left to right like
// the monitors are arranged – identical on every bar. The focused workspace
// is a stretched accent pill, the visible workspace of other monitors a
// muted pill, occupied ones solid dots, empty ones faint rings. Scroll to
// switch, right click opens the window overview.
BarButton {
	id: root

	visible: Plugins.on("workspaces") && Niri.workspaceGroups.length > 0
	panelId: "overview"
	tooltip: "Workspaces · scroll to switch · right-click for overview"
	acceptedButtons: Qt.RightButton
	toggleButton: Qt.RightButton
	wheelEnabled: true
	padding: 4
	onRightClicked: toggle()
	onScrolled: wheel => Niri.focusWorkspaceRelative((wheel.angleDelta.y || -wheel.angleDelta.x) > 0 ? -1 : 1)

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 6

		Repeater {
			model: Niri.workspaceGroups

			delegate: ScreenGroup {
				id: group

				required property var modelData

				bar: root.bar
				output: group.modelData.output
				inset: 9
				spacing: 5

				Repeater {
					model: group.modelData.workspaces

					delegate: Item {
						id: dot

						required property var modelData

						width: dot.modelData.focused ? 22 : (dot.modelData.active ? 14 : 8)
						height: group.height

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Rectangle {
							anchors.centerIn: parent
							width: parent.width
							height: dotMouse.containsMouse && !dot.modelData.focused ? 10 : 8
							radius: height / 2
							color: dot.modelData.focused ? Theme.primary
								: (dot.modelData.active ? Theme.textMuted
								: (dot.modelData.occupied ? Theme.textSubtle : "transparent"))
							border.width: dot.modelData.focused || dot.modelData.active || dot.modelData.occupied ? 0 : 1.5
							border.color: Theme.textSubtle

							Behavior on color {
								ColorAnim {}
							}
							Behavior on height {
								SpatialAnim {
									duration: Motion.short
								}
							}
						}

						MouseArea {
							id: dotMouse

							anchors.fill: parent
							anchors.margins: -2
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
								onPressed: Popups.close()
								onClicked: Niri.focusWorkspace(dot.modelData)
						}
					}
				}
			}
		}
	}
}
