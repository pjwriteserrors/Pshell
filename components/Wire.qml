import QtQuick

// The pen. A filament is a line that can be cold, lit along a stretch, and
// can carry a pulse of light from one end to the other. Every line in the
// shell is one of these; nothing is a plain border.
//
//   lit        0..1 how much of it is lit, measured from litFrom
//   litFrom    0..1 where the lit stretch starts (0 = left/top)
//   pulse()    sends a bright pulse along the whole length
Item {
	id: wire

	property bool vertical: false
	property real thickness: 2
	property real lit: 0
	property real litFrom: 0
	property color cold: Filament.wire
	property color hot: Filament.charge
	property bool glow: true
	property bool animateLit: true
	property real pulseWidth: 90
	property int pulseDuration: 0

	readonly property real length: vertical ? height : width
	readonly property real litStart: Math.round(length * Math.max(0, Math.min(1, litFrom)))
	readonly property real litLength: Math.round(length * Math.max(0, Math.min(1, lit)))

	implicitWidth: vertical ? thickness : 40
	implicitHeight: vertical ? 40 : thickness

	property real litShown: lit
	Behavior on litShown {
		enabled: wire.animateLit
		NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle }
	}

	function pulse() {
		pulseAnim.stop();
		pulseAnim.duration = wire.pulseDuration > 0 ? wire.pulseDuration : Filament.travelTime(wire.length);
		pulseAnim.start();
	}

	Rectangle {
		id: coldLine
		x: wire.vertical ? Math.round((wire.width - wire.thickness) / 2) : 0
		y: wire.vertical ? 0 : Math.round((wire.height - wire.thickness) / 2)
		width: wire.vertical ? wire.thickness : wire.width
		height: wire.vertical ? wire.height : wire.thickness
		radius: wire.thickness / 2
		color: wire.cold
	}

	// The halo of the lit stretch — cheap: one rectangle, no blur.
	Rectangle {
		visible: wire.glow && wire.litShown > 0.002
		x: wire.vertical ? coldLine.x - wire.thickness * 2.5 : coldLine.x + wire.litStart
		y: wire.vertical ? coldLine.y + wire.litStart : coldLine.y - wire.thickness * 2.5
		width: wire.vertical ? wire.thickness * 6 : Math.round(wire.length * wire.litShown)
		height: wire.vertical ? Math.round(wire.length * wire.litShown) : wire.thickness * 6
		radius: height / 2
		color: Qt.alpha(wire.hot, 0.16)
	}

	Rectangle {
		visible: wire.litShown > 0.002
		x: wire.vertical ? coldLine.x : coldLine.x + wire.litStart
		y: wire.vertical ? coldLine.y + wire.litStart : coldLine.y
		width: wire.vertical ? wire.thickness : Math.round(wire.length * wire.litShown)
		height: wire.vertical ? Math.round(wire.length * wire.litShown) : wire.thickness
		radius: wire.thickness / 2
		color: wire.hot
	}

	Rectangle {
		id: pulseLight
		property real travel: 0
		visible: pulseAnim.running
		x: wire.vertical ? coldLine.x - wire.thickness : -wire.pulseWidth + travel * (wire.width + wire.pulseWidth)
		y: wire.vertical ? -wire.pulseWidth + travel * (wire.height + wire.pulseWidth) : coldLine.y - wire.thickness
		width: wire.vertical ? wire.thickness * 3 : wire.pulseWidth
		height: wire.vertical ? wire.pulseWidth : wire.thickness * 3
		radius: wire.thickness * 1.5
		gradient: Gradient {
			orientation: wire.vertical ? Gradient.Vertical : Gradient.Horizontal
			GradientStop { position: 0.0; color: "transparent" }
			GradientStop { position: 0.5; color: Qt.alpha(wire.hot, 0.95) }
			GradientStop { position: 1.0; color: "transparent" }
		}

		NumberAnimation on travel {
			id: pulseAnim
			running: false
			from: 0
			to: 1
			duration: 400
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Filament.easeTravel
		}
	}
}
