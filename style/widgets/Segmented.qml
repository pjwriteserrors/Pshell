import QtQuick
import qs.style.theme

// Segmented switch. The highlight slides and stretches between options.
Rectangle {
	id: root

	property var options: [] // [{ value, label, icon }]
	property string current: ""
	signal selected(string value)

	readonly property int index: {
		for (let i = 0; i < root.options.length; i += 1)
			if (String(root.options[i].value) === root.current)
				return i;
		return 0;
	}
	readonly property real segment: (width - 6) / Math.max(1, root.options.length)

	implicitHeight: 36
	implicitWidth: 240
	radius: height / 2
	color: Theme.layer1

	Rectangle {
		id: highlight

		y: 3
		height: parent.height - 6
		x: 3 + root.index * root.segment
		width: root.segment
		radius: height / 2
		color: Theme.primary

		Behavior on x {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	Row {
		x: 3
		y: 3

		Repeater {
			model: root.options

			delegate: Item {
				id: option

				required property var modelData
				required property int index
				readonly property bool active: option.index === root.index

				width: root.segment
				height: root.height - 6

				Row {
					anchors.centerIn: parent
					spacing: 6

					Glyph {
						visible: String(option.modelData.icon || "") !== ""
						anchors.verticalCenter: parent.verticalCenter
						icon: String(option.modelData.icon || "")
						size: 15
						color: option.active ? Theme.onPrimary : Theme.textMuted
						surface: option.active ? highlight.color : Theme.surfaceBehind(option)
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: String(option.modelData.label || "")
						tone: option.active ? Theme.onPrimary : Theme.textMuted
						surface: option.active ? highlight.color : Theme.surfaceBehind(option)
						font.pixelSize: Theme.size.label
						font.weight: option.active ? Font.DemiBold : Font.Medium
					}
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: root.selected(String(option.modelData.value))
				}
			}
		}
	}
}
