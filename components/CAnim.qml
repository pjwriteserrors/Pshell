import QtQuick

// A colour change is a lamp being turned up or down, so it comes up fast and
// then creeps, the way a wick does.
ColorAnimation {
	duration: Arc.tick
	easing.type: Easing.Bezier
	easing.bezierCurve: Arc.curveKindle
}
