import QtQuick
import qs.style.theme

// Capsule that frames everything belonging to one monitor in the bar. The
// group of the monitor this bar sits on is tinted with the accent, so each
// bar shows at a glance which part is "here" and which is elsewhere.
Rectangle {
	id: root

	required property var bar
	required property string output
	readonly property bool here: root.bar.screen && String(root.bar.screen.name) === root.output
	property real inset: 4
	property alias spacing: row.spacing
	default property alias content: row.data

	anchors.verticalCenter: parent ? parent.verticalCenter : undefined
	implicitWidth: row.implicitWidth + root.inset * 2
	implicitHeight: Theme.barHeight - 10
	radius: height / 2
	color: root.here ? Qt.alpha(Theme.primary, 0.14) : Qt.alpha(Theme.fg, 0.08)
	border.width: 1
	border.color: root.here ? Qt.alpha(Theme.primary, 0.28) : Qt.alpha(Theme.fg, 0.14)

	Row {
		id: row

		x: root.inset
		anchors.verticalCenter: parent.verticalCenter
		spacing: 0
	}
}
