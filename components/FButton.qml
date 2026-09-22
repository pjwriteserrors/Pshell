import QtQuick

// A bead that does one thing. Hover warms it, press compresses it, the
// click lets a ring out. `kind` says how much light it carries:
//   "bead"    outlined, the default
//   "charge"  filled with the charge, for the one verb a surface is for
//   "ghost"   words only, warmth appears on hover
//   "alert"   outlined in the alert colour
Item {
	id: button

	property string text: ""
	property string icon: ""
	property var iconFallbacks: []
	property string kind: "bead"
	property bool enabled: true
	property bool compact: false
	property bool square: false
	property real iconSize: 15
	property string tooltip: ""
	readonly property bool hovered: touch.containsMouse
	readonly property bool pressed: touch.pressed
	readonly property bool filled: kind === "charge"
	readonly property color tone: kind === "alert" ? Filament.alert : Filament.charge
	readonly property color labelColor: filled ? Filament.onCharge : (kind === "alert" ? Filament.alert : (hovered ? Filament.ink : Filament.inkSoft))

	signal clicked(var mouse)

	implicitWidth: square ? implicitHeight : row.implicitWidth + (compact ? 18 : 26)
	implicitHeight: compact ? 26 : 32
	opacity: enabled ? 1 : 0.42

	scale: pressed ? 0.95 : 1
	Behavior on scale { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.005 } }

	MouseArea {
		id: touch
		anchors.fill: parent
		hoverEnabled: true
		enabled: button.enabled
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => { ring.fire(); button.clicked(mouse); }
	}

	Rectangle {
		anchors.centerIn: parent
		width: parent.width + 10
		height: parent.height + 10
		radius: height / 2
		color: Qt.alpha(button.tone, 0.18)
		opacity: button.hovered ? 1 : 0
		scale: button.hovered ? 1 : 0.85
		Behavior on opacity { NumberAnimation { duration: Filament.quick } }
		Behavior on scale { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }
	}

	Rectangle {
		id: body
		anchors.fill: parent
		radius: height / 2
		color: button.filled
			? (button.hovered ? Qt.lighter(button.tone, 1.08) : button.tone)
			: (button.kind === "ghost" ? "transparent" : (button.hovered ? Qt.alpha(button.tone, 0.12) : Filament.planeRaised))
		border.width: button.kind === "ghost" || button.filled ? 0 : 1
		border.color: button.kind === "alert" ? Filament.alert : (button.hovered ? button.tone : Filament.wire)
		Behavior on color { ColorAnimation { duration: Filament.quick } }
		Behavior on border.color { ColorAnimation { duration: Filament.quick } }
	}

	Rectangle {
		id: ring
		anchors.fill: parent
		radius: height / 2
		color: "transparent"
		border.width: 1.5
		border.color: button.tone
		opacity: 0
		function fire() { ringAnim.restart(); }
		ParallelAnimation {
			id: ringAnim
			NumberAnimation { target: ring; property: "scale"; from: 1; to: 1.4; duration: 300; easing.type: Easing.OutCubic }
			SequentialAnimation {
				NumberAnimation { target: ring; property: "opacity"; from: 0; to: 0.9; duration: 40 }
				NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 260; easing.type: Easing.OutCubic }
			}
		}
	}

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 7

		FIcon {
			visible: button.icon !== ""
			anchors.verticalCenter: parent.verticalCenter
			name: button.icon
			fallbacks: button.iconFallbacks
			size: button.iconSize
			color: button.labelColor
		}

		FText {
			visible: button.text !== ""
			anchors.verticalCenter: parent.verticalCenter
			text: button.text
			color: button.labelColor
			font.pixelSize: button.compact ? Filament.textSm : Filament.textMd
			font.weight: button.filled ? Font.DemiBold : Font.Medium
			Behavior on color { ColorAnimation { duration: Filament.quick } }
		}
	}
}
