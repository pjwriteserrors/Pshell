import QtQuick
import qs.style.theme

// Growth, movement and shape morphs: under way at once, settling softly.
NumberAnimation {
	duration: Motion.long
	easing.type: Easing.BezierSpline
	easing.bezierCurve: Motion.spatial
}
