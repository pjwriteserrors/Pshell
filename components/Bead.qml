import QtQuick

// A bead strung on the wire. The bar is made of these.
//
// Hover warms it (a halo grows, it lifts a little on the spring), press
// compresses it, a click lets a ring of light out. `lit` is for beads that
// hold a live state (a connected radio, an open lantern); `alarm` tints the
// outline with the alert colour.
Item {
	id: bead

	default property alias content: slot.data
	property bool lit: false
	property bool active: false
	property bool alarm: false
	property real padding: 9
	property real beadHeight: Filament.beadHeight
	property color fill: Filament.planeSolid
	property color litColor: Filament.charge
	property int acceptedButtons: Qt.LeftButton
	property bool hoverEnabled: true
	property bool interactive: true
	property bool outlined: true
	readonly property bool hovered: touch.containsMouse
	readonly property bool pressed: touch.pressed
	readonly property real centerX: x + width / 2

	signal clicked(var mouse)
	signal wheel(var wheel)
	signal entered()
	signal exited()

	implicitWidth: slot.childrenRect.width + padding * 2
	implicitHeight: beadHeight
	height: beadHeight

	function flash() {
		ring.fire();
		glowAnim.restart();
	}

	scale: pressed ? 0.94 : (hovered ? 1.05 : 1)
	Behavior on scale { SpringAnimation { spring: 4; damping: 0.28; epsilon: 0.005 } }

	MouseArea {
		id: touch
		anchors.fill: parent
		hoverEnabled: bead.hoverEnabled && bead.interactive
		enabled: bead.interactive
		acceptedButtons: bead.acceptedButtons
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => { ring.fire(); bead.clicked(mouse); }
		onWheel: wheel => bead.wheel(wheel)
		onEntered: bead.entered()
		onExited: bead.exited()
	}

	// Warmth: a soft halo that grows in under the bead when the cursor is near.
	Rectangle {
		id: halo
		anchors.centerIn: parent
		width: parent.width + 14
		height: parent.height + 14
		radius: height / 2
		color: Qt.alpha(bead.litColor, 0.22)
		opacity: bead.hovered || bead.active ? 1 : 0
		scale: bead.hovered || bead.active ? 1 : 0.8
		Behavior on opacity { NumberAnimation { duration: Filament.quick } }
		Behavior on scale { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }
	}

	Rectangle {
		id: body
		anchors.fill: parent
		radius: height / 2
		color: bead.lit
			? Qt.tint(bead.fill, Qt.alpha(bead.litColor, 0.18))
			: (bead.hovered ? Qt.tint(bead.fill, Qt.alpha(bead.litColor, 0.10)) : bead.fill)
		border.width: bead.outlined ? 1 : 0
		border.color: bead.alarm
			? Filament.alert
			: (bead.lit || bead.active ? bead.litColor : (bead.hovered ? Filament.wireBright : Filament.wire))
		Behavior on color { ColorAnimation { duration: Filament.quick } }
		Behavior on border.color { ColorAnimation { duration: Filament.quick } }
	}

	// The light that arrives: a brief bloom when a spark lands on the bead.
	Rectangle {
		id: glowFill
		anchors.fill: parent
		radius: height / 2
		color: bead.litColor
		opacity: 0
		SequentialAnimation {
			id: glowAnim
			NumberAnimation { target: glowFill; property: "opacity"; to: 0.55; duration: 70 }
			NumberAnimation { target: glowFill; property: "opacity"; to: 0; duration: 520; easing.type: Easing.OutCubic }
		}
	}

	Rectangle {
		id: ring
		anchors.centerIn: parent
		width: parent.width
		height: parent.height
		radius: height / 2
		color: "transparent"
		border.width: 1.5
		border.color: bead.alarm ? Filament.alert : bead.litColor
		opacity: 0
		function fire() { ringAnim.restart(); }
		ParallelAnimation {
			id: ringAnim
			NumberAnimation { target: ring; property: "scale"; from: 1; to: 1.55; duration: 320; easing.type: Easing.OutCubic }
			SequentialAnimation {
				NumberAnimation { target: ring; property: "opacity"; from: 0; to: 0.9; duration: 40 }
				NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 280; easing.type: Easing.OutCubic }
			}
		}
	}

	Item {
		id: slot
		anchors.centerIn: parent
		width: childrenRect.width
		height: childrenRect.height
	}
}
