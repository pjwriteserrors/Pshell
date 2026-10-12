import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A setting that is on or off: its sign, its name and the switch.
RowLayout {
	id: root

	property string icon: ""
	property string text: ""
	property bool checked: false

	signal toggled(bool checked)

	Layout.fillWidth: true
	Layout.leftMargin: 4
	spacing: 8

	Glyph {
		icon: root.icon
		size: 16
		color: Theme.textMuted
	}

	StyledText {
		Layout.fillWidth: true
		text: root.text
		font.pixelSize: Theme.size.label
		font.weight: Font.DemiBold
	}

	Toggle {
		checked: root.checked
		onToggled: checked => root.toggled(checked)
	}
}
