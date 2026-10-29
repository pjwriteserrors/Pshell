import QtQuick
import qs.style.theme
import qs.style.widgets

// A figure that runs to its new value instead of jumping: `value` is the
// number, `format` turns the one on the way into text.
StyledText {
	id: root

	property real value: 0
	property var format: value => String(Math.round(value))
	property int duration: 700
	property real shown: root.value

	text: root.format(root.shown)
	tabular: true

	Behavior on shown {
		NumberAnimation {
			duration: root.duration
			easing.type: Easing.OutCubic
		}
	}
}
