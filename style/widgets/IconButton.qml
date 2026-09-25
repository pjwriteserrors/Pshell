import QtQuick
import qs.style.theme

// Round icon button. When `checked` it morphs from a circle into a squircle
// and fills with the accent – a shape change you can read at a glance.
Clickable {
	id: root

	property string icon: ""
	property real iconSize: Math.round(root.height * 0.5)
	property string variant: "ghost" // ghost | tonal | filled | danger
	property bool checked: false
	property color iconColor: {
		if (root.variant === "filled" || root.checked)
			return root.variant === "danger" ? Theme.bg : Theme.onPrimary;
		if (root.variant === "danger")
			return Theme.danger;
		return Theme.text;
	}

	implicitWidth: 34
	implicitHeight: 34
	radius: root.checked ? Math.min(Theme.radius.medium, root.height / 2) : root.height / 2
	tint: root.iconColor
	color: {
		if (!root.enabled)
			return "transparent";
		if (root.checked || root.variant === "filled")
			return root.variant === "danger" ? Theme.danger : Theme.primary;
		if (root.variant === "tonal")
			return Theme.layer2;
		if (root.variant === "danger")
			return Qt.alpha(Theme.danger, root.hovered ? 0.16 : 0.1);
		return "transparent";
	}
	opacity: root.enabled ? 1 : 0.38

	Behavior on radius {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Glyph {
		anchors.centerIn: parent
		icon: root.icon
		size: root.iconSize
		color: root.iconColor
	}
}
