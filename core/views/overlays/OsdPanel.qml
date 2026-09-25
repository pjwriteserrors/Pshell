import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Volume / brightness feedback: a small tab drops out of the bar centre,
// the level bar glides to the new value, then the tab tucks back in.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	property real reveal: Osd.visible ? 1 : 0

	Behavior on reveal {
		NumberAnimation {
			duration: Osd.visible ? Motion.long : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Osd.visible ? Motion.spatial : Motion.accel
		}
	}

	anchors.top: true
	margins.top: Theme.barHeight
	implicitWidth: 340 + Theme.panelFillet * 2
	implicitHeight: 72
	exclusiveZone: 0
	color: "transparent"
	visible: root.reveal > 0.002
	WlrLayershell.namespace: "shell-osd"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	Item {
		id: body

		x: (root.width - width) / 2
		width: 300 * (0.6 + 0.4 * Math.min(1, root.reveal))
		height: 58 * root.reveal

		PanelShape {
			anchors.fill: parent
		}

		Item {
			anchors.fill: parent
			clip: true

			Row {
				x: 18
				y: 17 - 8 * (1 - Math.min(1, root.reveal))
				spacing: 14
				opacity: Math.max(0, (root.reveal - 0.4) / 0.6)

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: Osd.icon
					size: 22
					color: Theme.primary
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: body.width - 36 - 22 - 14 - 14 - 44
					height: 8
					radius: 4
					color: Theme.layer3

					Rectangle {
						height: parent.height
						radius: 4
						width: parent.width * Math.min(1, Osd.progress)
						color: Osd.progress > 1 ? Theme.warning : Theme.primary

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					width: 44
					horizontalAlignment: Text.AlignRight
					text: Osd.valueText
					tabular: true
					font.pixelSize: Theme.size.label
					font.weight: Font.Bold
				}
			}
		}
	}
}
