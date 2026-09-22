import QtQuick

// The vertical thread rows hang from. The light on it slides to the
// selected row instead of a highlight jumping between rows.
Item {
	id: thread

	property real litY: -1
	property real litLength: 24
	property bool lit: litY >= 0

	implicitWidth: 2
	width: 2

	property real shownY: litY
	Behavior on shownY {
		enabled: thread.lit
		NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle }
	}

	Wire {
		anchors.fill: parent
		vertical: true
		cold: Filament.wireDim
		lit: thread.lit ? Math.min(1, thread.litLength / Math.max(1, height)) : 0
		litFrom: Math.max(0, Math.min(1, (thread.shownY - thread.litLength / 2) / Math.max(1, height)))
		animateLit: false
	}
}
