import QtQuick

// What a fitting does under the hand. One number: 0 at rest, up through hover,
// full while pressed — bind a plate's `intensity` to it and the whole element
// answers together.
//
// The reaction itself belongs to whatever is being touched: brass turns into
// its detent, vellum lifts at the corner, a flame kindles. Nothing here decides
// that, which is why a seat and a row can react to the same number in two
// completely different ways.
MouseArea {
	id: touch

	readonly property real live: pressed ? 1.0 : containsMouse ? 0.6 : base
	property real base: 0
	property bool lit: false          // held on: a selected row, an open panel

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	onLitChanged: base = lit ? 0.42 : 0
	Component.onCompleted: base = lit ? 0.42 : 0
}
