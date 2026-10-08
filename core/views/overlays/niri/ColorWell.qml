import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "NiriColor.js" as NiriColor

// A color as a round swatch (see-through ones over a checkerboard) with its
// name; a click opens the picker right there.
Clickable {
	id: root

	property string value: "#000000"
	property string label: ""
	property bool alpha: true
	property bool allowTransparent: false
	property bool showHex: true
	property real size: 30

	signal picked(string css)

	implicitHeight: root.size + 8
	implicitWidth: row.implicitWidth + 12
	radius: height / 2
	pressedScale: 0.95
	color: root.hovered ? Theme.layer2 : "transparent"
	onClicked: picker.open()

	RowLayout {
		id: row

		anchors.verticalCenter: parent.verticalCenter
		x: 4
		spacing: 9

		Item {
			Layout.preferredWidth: root.size
			Layout.preferredHeight: root.size

			RoundClip {
				anchors.fill: parent
				radius: width / 2
				visible: NiriColor.qt(root.value).a < 0.999

				Checker {
					anchors.fill: parent
					cell: 4
				}
			}

			Rectangle {
				anchors.fill: parent
				radius: width / 2
				color: NiriColor.qt(root.value)
				border.width: 2
				border.color: Qt.alpha(Theme.text, 0.18)

				Behavior on color {
					ColorAnim {}
				}
			}

		}

		ColumnLayout {
			spacing: 0
			visible: root.label !== "" || root.showHex

			StyledText {
				visible: root.label !== ""
				text: root.label
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
			}

			StyledText {
				visible: root.showHex
				text: root.value
				tone: Theme.textSubtle
				font.family: Theme.monoFamily
				font.pixelSize: Theme.size.small
			}
		}
	}

	ColorPicker {
		id: picker

		y: root.height + 6
		x: Math.min(0, root.width - width)
		value: root.value
		alpha: root.alpha
		allowTransparent: root.allowTransparent
		onPicked: css => root.picked(css)
	}
}
