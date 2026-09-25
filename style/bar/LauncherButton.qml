import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// App launcher. The grid glyph turns a quarter on hover; a small dot marks
// a pending reboot (the updates panel behind the right click says why).
BarButton {
	id: root

	panelId: "updates"
	tooltip: "Apps & commands · right-click for updates"
	toggleButton: Qt.LeftButton
	altToggleButton: Qt.RightButton
	padding: 9
	closesPopups: false
	onClicked: Popups.toggle("launcher", root.bar.screen, undefined, undefined, root)
	onRightClicked: toggle()

	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		width: 28
		height: 28
		radius: Popups.current === "launcher" && Popups.screen === root.bar.screen ? Theme.radius.small : 14
		color: Theme.primary

		Behavior on radius {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Glyph {
			anchors.centerIn: parent
			icon: "dots_grid"
			size: 17
			color: Theme.onPrimary
			spin: root.hovered ? 90 : 0

			Behavior on spin {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		// reboot pending (kernel updated)
		Rectangle {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.rightMargin: -2
			anchors.topMargin: -2
			width: 9
			height: 9
			radius: 4.5
			color: Theme.warning
			border.width: 2
			border.color: Theme.base
			scale: Updates.rebootNeeded ? 1 : 0
			visible: scale > 0.01

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}
	}
}
