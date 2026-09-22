import QtQuick

// A short filament with a spark on it. Drag the spark; while it is held it
// grows into a pill that says the value. Letting go sends a ripple down the
// wire. The wheel nudges it by `step`.
Item {
	id: slider

	property real value: 0
	property real step: 0.05
	property bool muted: false
	property bool enabled: true
	property var labelFor: v => `${Math.round(v * 100)}%`
	property color hot: muted ? Filament.inkMute : Filament.charge
	readonly property bool dragging: touch.pressed
	readonly property real knobX: Math.round(Math.max(0, Math.min(1, shown)) * (width - 1))

	signal moved(real value)
	signal released(real value)

	implicitHeight: 24
	implicitWidth: 160

	property real shown: value
	Behavior on shown {
		enabled: !slider.dragging
		NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle }
	}

	function place(mouseX) {
		const v = Math.max(0, Math.min(1, mouseX / Math.max(1, width)));
		shown = v;
		value = v;
		moved(v);
	}

	Wire {
		id: wire
		anchors.verticalCenter: parent.verticalCenter
		width: parent.width
		height: 2
		lit: slider.shown
		animateLit: false
		hot: slider.hot
		cold: Filament.wireDim
	}

	MouseArea {
		id: touch
		anchors.fill: parent
		anchors.topMargin: -6
		anchors.bottomMargin: -6
		enabled: slider.enabled
		cursorShape: Qt.PointingHandCursor
		hoverEnabled: true
		onPressed: mouse => slider.place(mouse.x)
		onPositionChanged: mouse => { if (pressed) slider.place(mouse.x); }
		onReleased: { wire.pulse(); slider.released(slider.value); }
		onWheel: wheel => {
			const delta = wheel.angleDelta.y > 0 ? slider.step : -slider.step;
			const v = Math.max(0, Math.min(1, slider.value + delta));
			slider.shown = v;
			slider.value = v;
			slider.moved(v);
			slider.released(v);
		}
	}

	// The spark, which becomes a pill while it is held.
	Rectangle {
		id: knob
		x: slider.knobX - width / 2
		anchors.verticalCenter: parent.verticalCenter
		width: slider.dragging ? pill.implicitWidth + 14 : (touch.containsMouse ? 12 : 10)
		height: slider.dragging ? 20 : width
		radius: height / 2
		color: slider.dragging ? Filament.planeSolid : slider.hot
		border.width: slider.dragging ? 1 : 0
		border.color: slider.hot
		Behavior on width { NumberAnimation { duration: Filament.quick; easing.type: Easing.OutCubic } }
		Behavior on height { NumberAnimation { duration: Filament.quick; easing.type: Easing.OutCubic } }

		Rectangle {
			anchors.centerIn: parent
			width: parent.width + 10
			height: parent.height + 10
			radius: height / 2
			color: Qt.alpha(slider.hot, 0.22)
			z: -1
			opacity: touch.containsMouse || slider.dragging ? 1 : 0
			Behavior on opacity { NumberAnimation { duration: Filament.quick } }
		}

		FText {
			id: pill
			anchors.centerIn: parent
			text: slider.labelFor(slider.value)
			mono: true
			font.pixelSize: Filament.textXs
			color: slider.hot
			opacity: slider.dragging ? 1 : 0
			Behavior on opacity { NumberAnimation { duration: 80 } }
		}
	}
}
