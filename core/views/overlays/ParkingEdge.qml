import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The right edge of a screen while a window is dragged (Parking): a faint
// light where it parks, and the outermost pixels that are entered once it is
// let go there. During the drag niri gives the pointer to nobody, so the
// strip neither catches it nor stands in the way to the next screen.
PanelWindow {
	id: root

	required property var modelData
	// how much of the edge takes the drop
	readonly property int strip: 2

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		right: true
	}
	implicitWidth: 24
	exclusiveZone: 0
	color: "transparent"
	mask: Region {
		item: area
	}
	WlrLayershell.namespace: "shell-parking-edge"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	Rectangle {
		anchors.fill: parent
		opacity: Parking.moving !== -1 ? 0.45 : 0
		gradient: Gradient {
			orientation: Gradient.Horizontal

			GradientStop {
				position: 0
				color: "transparent"
			}
			GradientStop {
				position: 1
				color: Theme.primary
			}
		}

		Behavior on opacity {
			NumberAnimation {
				duration: Motion.short
			}
		}
	}

	MouseArea {
		id: area

		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: parent.right
		width: root.strip
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onEntered: Parking.edgeEntered(String(root.modelData.name))
	}
}
