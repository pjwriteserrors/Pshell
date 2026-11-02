import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A label and what sets it, on one line (Icons & Pointer).
RowLayout {
	id: root

	property string label: ""

	Layout.fillWidth: true
	spacing: 12

	StyledText {
		Layout.preferredWidth: 104
		text: root.label
		color: Theme.textMuted
	}
}
