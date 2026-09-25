import QtQuick
import qs.style.theme

// Growth, movement and shape morphs: expressive curve with a soft overshoot.
NumberAnimation {
	duration: Motion.long
	easing.type: Easing.BezierSpline
	easing.bezierCurve: Motion.spatial
}
