import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A figure of the statistics: icon and label, the value large – counting up
// to it when the page comes – and a line under it.
Rectangle {
	id: root

	property string icon: ""
	property string label: ""
	property real value: 0
	property var format: value => String(Math.round(value))
	property string note: ""
	property color accent: Theme.primary
	property bool highlight: false
	// counts up from nothing each time this turns true
	property bool play: true

	implicitHeight: 84
	radius: Theme.radius.large
	color: root.highlight ? Qt.alpha(root.accent, 0.13) : Theme.layer1
	border.width: root.highlight ? 1 : 0
	border.color: Qt.alpha(root.accent, 0.3)

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 12
		spacing: 2

		RowLayout {
			spacing: 6

			Glyph {
				icon: root.icon
				size: 14
				color: root.accent
			}

			StyledText {
				Layout.fillWidth: true
				text: root.label
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				elide: Text.ElideRight
			}
		}

		RollingText {
			id: figure

			Layout.fillWidth: true
			value: root.play ? root.value : 0
			duration: 1100
			format: root.format
			font.pixelSize: Theme.size.heading + 2
			font.weight: Font.Bold
			tone: root.highlight ? root.accent : Theme.text
			elide: Text.ElideRight
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.note !== ""
			text: root.note
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
			elide: Text.ElideRight
		}
	}
}
