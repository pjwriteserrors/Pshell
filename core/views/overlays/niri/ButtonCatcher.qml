import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// "Press the button": the mouse button pressed here becomes the scroll
// button (its evdev code, the way libinput names it).
Clickable {
	id: root

	property int code: 0

	signal caught(int code)

	readonly property var names: ({ 272: "Left", 273: "Right", 274: "Middle", 275: "Back (side)", 276: "Forward (extra)", 277: "Button 6", 278: "Button 7" })

	implicitHeight: 64
	implicitWidth: 260
	radius: Theme.radius.large
	acceptedButtons: Qt.AllButtons
	color: root.hovered ? Theme.primaryContainer : Theme.layer2
	border.width: root.hovered ? 1.5 : 0
	border.color: Theme.primary

	function codeOf(button) {
		switch (button) {
		case Qt.LeftButton: return 272;
		case Qt.RightButton: return 273;
		case Qt.MiddleButton: return 274;
		case Qt.BackButton: return 275;
		case Qt.ForwardButton: return 276;
		case Qt.ExtraButton3: return 277;
		case Qt.ExtraButton4: return 278;
		default: return 0;
		}
	}

	onClicked: mouse => root.caught(root.codeOf(mouse.button))
	onRightClicked: mouse => root.caught(root.codeOf(mouse.button))
	onMiddleClicked: mouse => root.caught(root.codeOf(mouse.button))

	RowLayout {
		anchors.fill: parent
		anchors.margins: 14
		spacing: 12

		Glyph {
			icon: "mouse"
			size: 24
			color: root.hovered ? Theme.primary : Theme.textMuted
			scale: root.pressed ? 0.85 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: root.code ? `${root.names[root.code] ?? "Button"} · ${root.code}` : "Not set"
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: root.hovered ? "Press the button you want – here, now" : "Point here and press a mouse button"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}
	}
}
