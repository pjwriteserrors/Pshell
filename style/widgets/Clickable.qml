import QtQuick
import qs.style.theme

// Base for every pressable surface. Presses sink the surface slightly and it
// springs back with a small overshoot when released.
//
// The content sits above the interaction layer: plain content lets clicks
// fall through to the surface, while nested controls (a chevron, a toggle,
// a delete button) receive their own clicks.
Rectangle {
	id: root

	signal clicked(var mouse)
	signal rightClicked(var mouse)
	signal middleClicked(var mouse)
	signal scrolled(var wheel)
	signal entered
	signal exited

	// stays true over nested controls, unlike the layer's containsMouse
	readonly property bool hovered: hoverHandler.hovered && root.interactive
	property alias pressed: layer.pressed
	property alias stateLayer: layer
	property alias showHover: layer.showHover
	property alias bloom: layer.bloom
	property color tint: Theme.text
	property bool interactive: true
	property real pressedScale: 0.94
	property int acceptedButtons: Qt.LeftButton
	property bool wheelEnabled: false
	default property alias content: holder.data

	color: "transparent"
	scale: layer.pressed ? root.pressedScale : 1

	Behavior on scale {
		NumberAnimation {
			duration: layer.pressed ? Motion.micro : Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: layer.pressed ? Motion.standard : Motion.spatialFast
		}
	}

	Behavior on color {
		ColorAnim {}
	}

	StateLayer {
		id: layer

		z: 10
		enabled: root.interactive
		tint: root.tint
		acceptedButtons: root.acceptedButtons
		onClicked: mouse => {
			if (mouse.button === Qt.RightButton)
				root.rightClicked(mouse);
			else if (mouse.button === Qt.MiddleButton)
				root.middleClicked(mouse);
			else
				root.clicked(mouse);
		}
		onWheel: wheel => {
			if (!root.wheelEnabled) {
				wheel.accepted = false;
				return;
			}
			root.scrolled(wheel);
		}
		onEntered: root.entered()
		onExited: root.exited()
	}

	HoverHandler {
		id: hoverHandler
	}

	Item {
		id: holder

		z: 11
		anchors.fill: parent
	}
}
