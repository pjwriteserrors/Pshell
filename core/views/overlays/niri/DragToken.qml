import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A chip you can pick up and drop on something that takes it (a DropArea
// with the same key). Let go elsewhere, it glides back. A click works too.
Item {
	id: root

	property string text: ""
	property string icon: ""
	property string dragKey: "token"
	property var payload: null
	property color accent: Theme.primary

	signal clicked

	implicitWidth: chip.implicitWidth
	implicitHeight: chip.implicitHeight

	Rectangle {
		id: chip

		property bool held: mouse.drag.active

		implicitWidth: row.implicitWidth + 22
		implicitHeight: 32
		width: root.width
		height: root.height
		radius: height / 2
		color: chip.held ? root.accent : (mouse.containsMouse ? Theme.layer3 : Theme.layer2)
		border.width: 1
		border.color: chip.held ? root.accent : Theme.outline
		scale: chip.held ? 1.08 : (mouse.pressed ? 0.95 : 1)
		z: chip.held ? 100 : 0

		Drag.active: mouse.drag.active
		Drag.keys: [root.dragKey]
		Drag.source: root
		Drag.hotSpot.x: width / 2
		Drag.hotSpot.y: height / 2

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}
		Behavior on x {
			enabled: !chip.held
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on y {
			enabled: !chip.held
			SpatialAnim {
				duration: Motion.medium
			}
		}

		states: State {
			when: chip.held

			ParentChange {
				target: chip
				parent: root.Window.contentItem
			}
		}

		RowLayout {
			id: row

			anchors.centerIn: parent
			spacing: 6

			Glyph {
				visible: root.icon !== ""
				icon: root.icon
				size: 14
				color: chip.held ? Theme.onPrimary : Theme.primary
			}

			StyledText {
				text: root.text
				tone: chip.held ? Theme.onPrimary : Theme.text
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
			}
		}

		MouseArea {
			id: mouse

			anchors.fill: parent
			hoverEnabled: true
			preventStealing: true
			cursorShape: chip.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor
			drag.target: chip
			drag.threshold: 6
			onClicked: root.clicked()
			onReleased: {
				if (chip.held) chip.Drag.drop();
				chip.x = 0;
				chip.y = 0;
			}
		}
	}
}
