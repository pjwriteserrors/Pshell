import QtQuick

// What every clickable surface in the shell does when a pointer is on it.
//
// The old contract was a grey tint and a ripple. Here a surface is tissue: it
// warms with the organ colour and a vein lights along its leading edge. Same
// API — drop it in, use onClicked — so every call site that already had one
// reacts correctly without knowing any of this.
MouseArea {
	id: layer

	property color tint: Bio.organ
	property real cornerRadius: parent?.radius ?? 0
	property bool showHover: true
	property bool rippleEnabled: false      // kept for source compatibility
	property bool veined: true

	readonly property real live: !showHover ? 0 : pressed ? 1 : containsMouse ? 0.6 : 0

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	Rectangle {
		anchors.fill: parent
		radius: layer.cornerRadius
		color: Qt.alpha(Bio.organ, 0.13 * layer.live)

		Behavior on color {
			ColorAnimation { duration: Bio.twitch }
		}
	}

	Rectangle {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		visible: layer.veined
		width: Bio.rib * 1.5
		height: parent.height * (0.3 + 0.62 * layer.live)
		radius: width / 2
		color: Bio.organ
		opacity: layer.live

		Behavior on opacity {
			NumberAnimation { duration: Bio.twitch }
		}
		Behavior on height {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}
	}
}
