import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One of the Pi's numbers on the Server page: a ring with the value in it,
// what it is below and a line of detail; the ring turns warning or danger
// past its limits. A click picks it for the history chart.
Clickable {
	id: root

	property string label: ""
	property string value: ""
	property string detail: ""
	property string icon: ""
	// 0…1, below 0 when unknown
	property real fill: -1
	property real warnAt: 0.8
	property real dangerAt: 0.92
	property bool selected: false

	readonly property color tone: root.fill < 0 ? Theme.textFaint : (root.fill >= root.dangerAt ? Theme.danger : (root.fill >= root.warnAt ? Theme.warning : Theme.primary))

	Layout.fillWidth: true
	implicitHeight: column.implicitHeight + 20
	radius: Theme.radius.large
	color: root.selected ? Qt.alpha(root.tone, 0.1) : (root.hovered ? Theme.layer2 : "transparent")
	pressedScale: 0.97

	Behavior on color {
		ColorAnim {}
	}

	ColumnLayout {
		id: column

		anchors.horizontalCenter: parent.horizontalCenter
		y: 10
		width: parent.width - 16
		spacing: 6

		Ring {
			Layout.alignment: Qt.AlignHCenter
			Layout.preferredWidth: 72
			Layout.preferredHeight: 72
			value: Math.max(0, root.fill)
			thickness: 6
			sweep: 270
			color: root.tone

			Behavior on color {
				ColorAnim {
					duration: Motion.long
				}
			}

			ColumnLayout {
				anchors.centerIn: parent
				spacing: 0

				Glyph {
					Layout.alignment: Qt.AlignHCenter
					icon: root.icon
					size: 14
					color: Theme.textMuted
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: root.value
					font.pixelSize: Theme.size.body
					font.weight: Font.Bold
					tabular: true
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			horizontalAlignment: Text.AlignHCenter
			text: root.label
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}

		StyledText {
			Layout.fillWidth: true
			horizontalAlignment: Text.AlignHCenter
			text: root.detail
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			elide: Text.ElideRight
		}
	}
}
