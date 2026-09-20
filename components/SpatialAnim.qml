import QtQuick

// Brass. Anything small that moves into a position holds that position against
// a detent: it goes a hair past the stop and settles back into it.
NumberAnimation {
	duration: Arc.turn
	easing.type: Easing.Bezier
	easing.bezierCurve: Arc.curveDetent
}
