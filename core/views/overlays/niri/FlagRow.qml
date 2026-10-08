import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A switch with what it does, the whole row clickable. An optional picture
// on the left (`illustration`) plays what the switch changes.
Clickable {
	id: root

	property string title: ""
	property string subtitle: ""
	property string icon: ""
	property bool checked: false
	property bool modified: false
	default property alias illustration: art.data
	readonly property bool illustrated: art.children.length > 0

	signal toggled(bool on)
	signal reset

	Layout.fillWidth: true
	implicitHeight: Math.max(row.implicitHeight + 20, 52)
	radius: Theme.radius.large
	pressedScale: 0.985
	color: root.hovered ? Theme.layer2 : "transparent"
	onClicked: root.toggled(!root.checked)

	RowLayout {
		id: row

		anchors.fill: parent
		anchors.leftMargin: 12
		anchors.rightMargin: 12
		spacing: 14

		Item {
			id: art

			visible: root.illustrated
			Layout.preferredWidth: root.illustrated ? 64 : 0
			Layout.preferredHeight: 44
		}

		Glyph {
			visible: root.icon !== "" && !root.illustrated
			icon: root.icon
			size: 18
			color: root.checked ? Theme.primary : Theme.textMuted
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.title
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.subtitle !== ""
				text: root.subtitle
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		ResetPill {
			shown: root.modified
			onClicked: root.reset()
		}

		Toggle {
			checked: root.checked
			onToggled: on => root.toggled(on)
		}
	}
}
