import QtQuick

// The default move for anything that is not made of one of the three
// materials — a position settling, a size following its content. Cut curve,
// never a stock ease: things in this instrument arrive against a stop.
NumberAnimation {
	duration: Arc.turn
	easing.type: Easing.Bezier
	easing.bezierCurve: Arc.curveRise
}
