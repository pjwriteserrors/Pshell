import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One of the window switcher's settings as a row of choices (SwitcherSettings).
RowLayout {
	id: root

	property string label: ""
	// the Switcher setting it shows and sets
	property string name: ""
	property var options: []

	Layout.fillWidth: true
	spacing: 12

	StyledText {
		Layout.preferredWidth: 150
		text: root.label
		tone: Theme.textMuted
	}

	Segmented {
		Layout.fillWidth: true
		implicitHeight: 30
		options: root.options
		current: String(Switcher[root.name])
		onSelected: value => Switcher.set(root.name, value)
	}
}
