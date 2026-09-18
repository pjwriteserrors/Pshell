import QtQuick

// What a living surface does when you touch it: it lights up from inside and
// settles back. No grey wash, no ripple, no lift — those belong to a material
// that was manufactured.
//
// Anything clickable puts one of these inside it and binds the parent's frame
// to `live`.
MouseArea {
	id: touch

	// 0 at rest, up through hover, full while pressed. Bind a frame's
	// `intensity` to this and the whole element reacts with one number.
	readonly property real live: pressed ? 1.0 : containsMouse ? 0.62 : base
	property real base: 0
	property bool lit: false          // held on: a selected row, an open popup

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	onLitChanged: base = lit ? 0.42 : 0
	Component.onCompleted: base = lit ? 0.42 : 0
}
