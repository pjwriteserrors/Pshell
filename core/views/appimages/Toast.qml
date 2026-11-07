import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A word on what just happened: rises from below, goes by itself.
Rectangle {
	id: root

	property string text: ""
	property string detail: ""
	property string icon: "check"
	property bool up: false

	function say(text, detail, icon) {
		root.text = String(text);
		root.detail = String(detail || "");
		root.icon = String(icon || "check");
		root.up = true;
		pop.restart();
		away.restart();
	}

	implicitWidth: row.implicitWidth + 32
	implicitHeight: 46
	radius: height / 2
	color: Theme.layer3
	border.width: 1
	border.color: Theme.outline
	visible: opacity > 0
	opacity: root.up ? 1 : 0
	transform: Translate {
		y: root.up ? 0 : 26

		Behavior on y {
			SpatialAnim {
				duration: root.up ? Motion.extraLong : Motion.medium
			}
		}
	}

	Behavior on opacity {
		Anim {
			duration: root.up ? Motion.medium : Motion.short
		}
	}

	Timer {
		id: away

		interval: 3600
		onTriggered: root.up = false
	}

	NumberAnimation {
		id: pop

		target: mark
		property: "scale"
		from: 0.3
		to: 1
		duration: Motion.extraLong
		easing.type: Easing.OutBack
		easing.overshoot: 2.2
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 10

		Glyph {
			id: mark

			icon: root.icon
			color: Theme.primary
		}

		StyledText {
			text: root.text
			font.weight: Font.DemiBold
		}

		StyledText {
			visible: root.detail !== ""
			text: root.detail
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	MouseArea {
		anchors.fill: parent
		onClicked: root.up = false
	}
}
