import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A switch with its label (Icons & Pointer).
RowLayout {
	id: root

	property string label: ""
	property bool checked: false

	signal toggled(bool on)

	Layout.fillWidth: true
	spacing: 10

	StyledText {
		Layout.fillWidth: true
		text: root.label
		elide: Text.ElideRight
	}
	Toggle {
		checked: root.checked
		onToggled: on => root.toggled(on)
	}
}
