import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "Nodes.js" as Nodes

// The focus ring or the border: how thick, and its colors for the active,
// the other and the urgent window. Works on the section node and hands the
// new one back (layout, a window rule, a monitor's layout – all the same).
ColumnLayout {
	id: root

	property var section: null
	property real defaultWidth: 4
	property string defaultActive: "#7fc8ff"
	property string defaultInactive: "#505050"
	property string defaultUrgent: "#9b0000"
	property bool showWidth: true

	signal changed(var section)

	spacing: 14

	RowLayout {
		Layout.fillWidth: true
		visible: root.showWidth
		spacing: 12

		StyledText {
			Layout.preferredWidth: 78
			text: "Width"
			tone: Theme.textMuted
			font.weight: Font.Medium
		}

		ValueSlider {
			from: 0
			to: 16
			step: 0.5
			decimals: 1
			unit: " px"
			icon: "border_outside"
			value: Number(Nodes.arg(root.section, "width", root.defaultWidth))
			format: v => Number(v) % 1 === 0 ? `${v} px` : `${Number(v).toFixed(1)} px`
			onMoved: v => root.changed(Nodes.withArg(root.section, "width", v))
		}

		ResetPill {
			shown: Nodes.has(root.section, "width")
			onClicked: root.changed(Nodes.without(root.section, "width"))
		}
	}

	PaintRow {
		Layout.fillWidth: true
		section: root.section
		kind: "active"
		label: "Active"
		fallback: root.defaultActive
		onChanged: s => root.changed(s)
	}

	PaintRow {
		Layout.fillWidth: true
		section: root.section
		kind: "inactive"
		label: "Inactive"
		fallback: root.defaultInactive
		onChanged: s => root.changed(s)
	}

	PaintRow {
		Layout.fillWidth: true
		section: root.section
		kind: "urgent"
		label: "Urgent"
		fallback: root.defaultUrgent
		onChanged: s => root.changed(s)
	}
}
