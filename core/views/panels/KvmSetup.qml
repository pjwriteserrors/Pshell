pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Which edges of this PC's screens lead to which paired PC: the screens in
// miniature as they stand, each edge a button that steps through the PCs.
// Pushing the mouse against such an edge for a moment sends mouse and
// keyboard over; the other PC's own edge (or the one facing this PC) brings
// them back.
ColumnLayout {
	id: root

	spacing: 8
	visible: Kvm.enabled && Pcs.devices.length > 0

	readonly property var screens: Quickshell.screens
	readonly property real minX: Math.min(...root.screens.map(s => s.x))
	readonly property real minY: Math.min(...root.screens.map(s => s.y))
	readonly property real maxX: Math.max(...root.screens.map(s => s.x + s.width))
	readonly property real maxY: Math.max(...root.screens.map(s => s.y + s.height))
	readonly property real factor: Math.min((root.width - 24) / Math.max(1, root.maxX - root.minX), 150 / Math.max(1, root.maxY - root.minY))

	SectionLabel {
		text: "Mouse across PCs"
	}

	StyledText {
		Layout.fillWidth: true
		text: Kvm.mode === "away" ? `Mouse and keyboard are on ${Kvm.partner}. Push against its edge there, or Ctrl+Alt+Esc here.`
			: Kvm.mode === "guest" ? `The mouse of ${Kvm.partner} is here. Push against the lit edge to send it back.`
			: "Click an edge to lead it to a PC, again for the next one or none. Push the mouse against it to go over."
		tone: Kvm.mode === "local" ? Theme.textMuted : Theme.primary
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	Item {
		id: layout

		Layout.fillWidth: true
		implicitHeight: (root.maxY - root.minY) * root.factor + 24

		readonly property real offset: (layout.width - (root.maxX - root.minX) * root.factor) / 2

		Repeater {
			model: root.screens

			delegate: Rectangle {
				id: screenBox

				required property var modelData

				x: layout.offset + (screenBox.modelData.x - root.minX) * root.factor
				y: 12 + (screenBox.modelData.y - root.minY) * root.factor
				width: screenBox.modelData.width * root.factor
				height: screenBox.modelData.height * root.factor
				radius: 4
				color: Theme.layer2
				border.width: 1
				border.color: Theme.outline

				StyledText {
					anchors.centerIn: parent
					text: screenBox.modelData.name
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
				}

				Repeater {
					model: ["left", "right", "top", "bottom"]

					delegate: Rectangle {
						id: edgeButton

						required property string modelData
						readonly property var edge: Kvm.edgeAt(String(screenBox.modelData.name), edgeButton.modelData)
						readonly property bool vertical: edgeButton.modelData === "left" || edgeButton.modelData === "right"
						readonly property real thickness: 10

						x: edgeButton.modelData === "right" ? parent.width - edgeButton.thickness / 2 : (edgeButton.vertical ? -edgeButton.thickness / 2 : edgeButton.thickness)
						y: edgeButton.modelData === "bottom" ? parent.height - edgeButton.thickness / 2 : (edgeButton.vertical ? edgeButton.thickness : -edgeButton.thickness / 2)
						width: edgeButton.vertical ? edgeButton.thickness : parent.width - 2 * edgeButton.thickness
						height: edgeButton.vertical ? parent.height - 2 * edgeButton.thickness : edgeButton.thickness
						radius: edgeButton.thickness / 2
						color: edgeButton.edge ? Theme.primary : (hover.containsMouse ? Qt.alpha(Theme.primary, 0.35) : "transparent")

						Behavior on color {
							ColorAnimation {
								duration: 140
							}
						}

						// the PC it leads to, beside the edge, inside the screen
						StyledText {
							visible: !!edgeButton.edge
							text: Pcs.byId(edgeButton.edge?.pc ?? "")?.name ?? "?"
							font.pixelSize: Theme.size.tiny
							font.weight: Font.DemiBold
							tone: Theme.text
							x: edgeButton.modelData === "left" ? edgeButton.thickness + 2 : (edgeButton.modelData === "right" ? -implicitWidth - 2 : (edgeButton.width - implicitWidth) / 2)
							y: edgeButton.modelData === "top" ? edgeButton.thickness + 1 : (edgeButton.modelData === "bottom" ? -implicitHeight - 1 : (edgeButton.height - implicitHeight) / 2)
						}

						MouseArea {
							id: hover

							anchors.fill: parent
							anchors.margins: -3
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: Kvm.cycle(String(screenBox.modelData.name), edgeButton.modelData)
						}
					}
				}
			}
		}
	}

	PillSlider {
		id: holdSlider

		Layout.fillWidth: true
		icon: "timer_outline"
		label: "Hold"
		value: (Kvm.hold - 100) / 1400
		stepSize: 50 / 1400
		valueText: `${Math.round(100 + holdSlider.display * 1400)} ms`
		onMoved: value => {
			root.pendingHold = 100 + value * 1400;
			holdSave.restart();
		}
	}

	property real pendingHold: 0

	Timer {
		id: holdSave

		interval: 400
		onTriggered: Kvm.setHold(root.pendingHold)
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 10

		StyledText {
			Layout.fillWidth: true
			text: "The keyboard goes along"
			font.pixelSize: Theme.size.body
		}

		Toggle {
			checked: Kvm.keyboard
			onToggled: checked => Kvm.setKeyboard(checked)
		}
	}

	TextButton {
		Layout.fillWidth: true
		visible: Kvm.mode !== "local"
		icon: "mouse"
		text: Kvm.mode === "away" ? "Bring the mouse back" : `Send the mouse back to ${Kvm.partner}`
		onActivated: Kvm.home()
	}
}
