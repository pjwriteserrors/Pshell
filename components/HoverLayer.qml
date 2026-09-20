import QtQuick

// What a surface does with a pointer on it: light comes up behind it. No tint,
// no ripple, no outline. Same API as before, so every call site that already
// had one answers correctly without knowing any of this.
MouseArea {
	id: layer

	property color tint: Arc.aether
	property real cornerRadius: parent?.radius ?? 0
	property bool showHover: true
	property bool rippleEnabled: false
	property bool veined: true

	readonly property real live: !showHover ? 0 : pressed ? 1 : containsMouse ? 0.6 : 0

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	ArcHalo {
		anchors.fill: parent
		anchors.margins: -6
		color: Arc.aether
		strength: 0.26 * layer.live
		spread: 0.5
		flicker: true
		visible: layer.live > 0.02
	}

	Rectangle {
		anchors.fill: parent
		radius: layer.cornerRadius
		color: Qt.alpha(Arc.aether, 0.07 * layer.live)

		Behavior on color {
			ColorAnimation { duration: Arc.tick }
		}
	}
}
