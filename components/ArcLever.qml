pragma ComponentBehavior: Bound

import QtQuick

// On or off, as a lever in a slot. The arm swings from one end of the slot to
// the other and arrests against the stop; the lamp under the slot comes up as
// it arrives, not before it.
Item {
	id: lever

	property bool checked: false
	property bool enabled: true

	signal toggled(bool value)

	implicitWidth: 40
	implicitHeight: 18
	opacity: enabled ? 1 : 0.45

	ArcPlate {
		anchors.fill: parent
		variant: "capsule"
		beading: false
		weight: Arc.ruleThin
		lineColor: Arc.giltFaint
		liveColor: Arc.aether
		fillTop: Arc.well
		fillBottom: Arc.well
		intensity: lever.checked ? 1 : touch.live * 0.5
	}

	// The lamp in the slot behind the arm: it belongs to the state, so it comes
	// up as the arm lands rather than travelling with it.
	Rectangle {
		anchors.fill: parent
		anchors.margins: 2
		color: Qt.alpha(Arc.aether, lever.checked ? 0.30 : 0)

		Behavior on color {
			ColorAnimation { duration: Arc.turn }
		}
	}

	Item {
		id: arm
		width: parent.height - Arc.s1
		height: width
		anchors.verticalCenter: parent.verticalCenter
		x: lever.checked ? parent.width - width - 2 : 2

		Behavior on x {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		// The arm turns as it travels, so the throw reads as a lever and not as
		// a bead sliding along a wire.
		rotation: lever.checked ? 30 : -30

		Behavior on rotation {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		Canvas {
			anchors.fill: parent
			renderStrategy: Canvas.Cooperative
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const c = width / 2;
				ctx.fillStyle = lever.checked ? Arc.aether : Arc.giltDim;
				ctx.beginPath();
				ctx.moveTo(c, 0);
				ctx.lineTo(width, c);
				ctx.lineTo(c, height);
				ctx.lineTo(0, c);
				ctx.closePath();
				ctx.fill();
			}

			Connections {
				target: lever
				function onCheckedChanged() { parent.requestPaint(); }
			}
		}
	}

	ArcTouch {
		id: touch
		enabled: lever.enabled
		onClicked: {
			lever.checked = !lever.checked;
			lever.toggled(lever.checked);
		}
	}
}
