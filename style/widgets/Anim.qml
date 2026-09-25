import QtQuick
import qs.style.theme

// Plain eased value change: opacity, small offsets, progress values.
NumberAnimation {
	duration: Motion.medium
	easing.type: Easing.BezierSpline
	easing.bezierCurve: Motion.standard
}
