import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// How many cursors Multicursor has in the text: the other ones cannot be
// drawn, a text field shows only its own. A small pill at the bottom of the
// screen that has the keyboard.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	readonly property bool here: Multicursor.cursors > 0 && (Niri.workspaces.find(workspace => workspace.focused)?.output ?? root.modelData.name) === root.modelData.name
	property real reveal: root.here ? 1 : 0

	Behavior on reveal {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	anchors.bottom: true
	margins.bottom: 28
	implicitWidth: 120
	implicitHeight: 44
	exclusiveZone: 0
	color: "transparent"
	visible: root.reveal > 0.002
	WlrLayershell.namespace: "shell-cursors"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	Rectangle {
		anchors.centerIn: parent
		width: row.implicitWidth + 28
		height: 36
		radius: height / 2
		color: Theme.layer3
		border.width: 1
		border.color: Theme.outline
		opacity: Math.min(1, root.reveal)
		scale: 0.8 + 0.2 * root.reveal

		Row {
			id: row

			anchors.centerIn: parent
			spacing: 8

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "cursor_text"
				size: 17
				color: Theme.primary
			}

			StyledText {
				id: count

				anchors.verticalCenter: parent.verticalCenter
				font.weight: Font.DemiBold
				// the last number stays while the pill goes
				Connections {
					target: Multicursor

					function onCursorsChanged() {
						if (Multicursor.cursors > 0) count.text = String(Multicursor.cursors);
					}
				}
			}
		}
	}
}
