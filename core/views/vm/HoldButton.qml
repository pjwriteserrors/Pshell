import QtQuick
import QtQuick.Layouts
import qs.core.services
import qs.style.theme
import qs.style.widgets

// A button that has to be held until it fills up – for what cannot be taken
// back (shutting a machine down, pulling its plug). Let go early and the fill
// runs back.
Item {
	id: root

	property string text: ""
	property string icon: ""
	property color accent: Theme.danger
	property bool busy: false
	property int holdTime: 800
	property real hold: 0

	signal confirmed

	implicitHeight: 44
	implicitWidth: row.implicitWidth + 36
	opacity: root.enabled ? 1 : 0.4

	Behavior on opacity {
		Anim {}
	}
	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	NumberAnimation {
		id: filling

		target: root
		property: "hold"
		to: 1
		duration: root.holdTime * (1 - root.hold)
		onFinished: {
			if (root.hold < 1) return;
			Sounds.play("select");
			root.confirmed();
			draining.restart();
		}
	}

	NumberAnimation {
		id: draining

		target: root
		property: "hold"
		to: 0
		duration: Motion.long
		easing.type: Easing.OutCubic
	}

	Rectangle {
		id: face

		anchors.fill: parent
		radius: height / 2
		color: mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.07)
		border.width: 1
		border.color: Qt.alpha(root.accent, mouse.containsMouse ? 0.5 : 0.18)
		clip: true
		scale: mouse.pressed ? 0.96 : 1

		Behavior on color {
			ColorAnim {}
		}
		Behavior on border.color {
			ColorAnim {}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Rectangle {
			width: parent.width * root.hold
			height: parent.height
			radius: parent.radius
			color: root.accent
			opacity: 0.9
		}

		RowLayout {
			id: row

			anchors.centerIn: parent
			spacing: 8

			Spinner {
				visible: root.busy
				Layout.preferredWidth: 16
				Layout.preferredHeight: 16
				color: root.accent
			}

			Glyph {
				visible: !root.busy && root.icon !== ""
				icon: root.icon
				size: 18
				color: root.hold > 0.5 ? Theme.bg : root.accent
				surface: "transparent"
			}

			StyledText {
				text: mouse.containsMouse && !root.busy && root.hold === 0 ? `Hold to ${root.text.toLowerCase()}` : root.text
				tone: root.hold > 0.5 ? Theme.bg : "white"
				surface: "transparent"
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		enabled: !root.busy
		cursorShape: Qt.PointingHandCursor
		onPressed: {
			draining.stop();
			filling.restart();
		}
		onReleased: {
			if (root.hold < 1) {
				filling.stop();
				draining.restart();
			}
		}
		onCanceled: {
			filling.stop();
			draining.restart();
		}

		// the fill runs round the pointer too, where the eyes are
		CursorRing {
			visible: mouse.pressed || root.hold > 0
			x: mouse.mouseX
			y: mouse.mouseY
			value: root.hold
			color: root.accent
			opacity: Math.min(1, root.hold * 6)
		}
	}
}
