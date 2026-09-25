import QtQuick
import QtQuick.Layouts
import qs.style.theme

// Labelled button. `variant`: filled | tonal | ghost | danger.
// A `confirm` button needs two clicks: the first arms it (it turns red and
// the label changes), the second one fires. It disarms itself after a moment.
Clickable {
	id: root

	property string text: ""
	property string icon: ""
	property string variant: "tonal"
	property bool confirm: false
	property string confirmText: "Sure?"
	property bool armed: false
	property bool busy: false
	signal activated

	readonly property color contentColor: {
		if (root.armed)
			return Theme.bg;
		if (root.variant === "filled")
			return Theme.onPrimary;
		if (root.variant === "danger")
			return Theme.danger;
		return Theme.text;
	}

	implicitHeight: 34
	implicitWidth: row.implicitWidth + 28
	radius: height / 2
	tint: root.contentColor
	opacity: root.enabled ? 1 : 0.4
	color: {
		if (root.armed)
			return Theme.danger;
		switch (root.variant) {
		case "filled":
			return Theme.primary;
		case "danger":
			return Qt.alpha(Theme.danger, root.hovered ? 0.18 : 0.12);
		case "ghost":
			return "transparent";
		default:
			return Theme.layer2;
		}
	}

	onClicked: {
		if (root.busy)
			return;
		if (root.confirm && !root.armed) {
			root.armed = true;
			disarm.restart();
			return;
		}
		root.armed = false;
		root.activated();
	}

	Timer {
		id: disarm
		interval: 2600
		onTriggered: root.armed = false
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 7

		Spinner {
			visible: root.busy
			Layout.preferredWidth: 14
			Layout.preferredHeight: 14
			color: root.contentColor
		}

		Glyph {
			visible: root.icon !== "" && !root.busy
			icon: root.armed ? "alert" : root.icon
			size: 15
			color: root.contentColor
		}

		StyledText {
			text: root.armed ? root.confirmText : root.text
			tone: root.contentColor
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}
	}
}
