import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A line of the player's settings that switches one of them.
RowLayout {
	id: root

	property string label: ""
	property string detail: ""
	property string setting: ""

	Layout.fillWidth: true

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 0

		Text {
			Layout.fillWidth: true
			text: root.label
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 14
		}
		Text {
			Layout.fillWidth: true
			visible: text !== ""
			text: root.detail
			color: Qt.rgba(1, 1, 1, 0.6)
			font.family: Theme.fontFamily
			font.pixelSize: 11
			wrapMode: Text.Wrap
		}
	}
	Toggle {
		checked: Streams.settings[root.setting] ?? false
		onToggled: checked => Streams.setSetting(root.setting, checked)
	}
}
