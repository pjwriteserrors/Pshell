import QtQuick
import Quickshell.Widgets
import qs.style.theme

// Interaction layer for any rounded surface: hover wash, press wash and a
// soft radial bloom from the pointer. Fills its parent and behaves like a
// MouseArea (clicked, pressed, containsMouse …).
MouseArea {
	id: layer

	property color tint: Theme.text
	// qmllint disable missing-property
	property real radius: parent?.radius ?? 0
	// qmllint enable missing-property
	property bool showHover: true
	property bool bloom: true
	property real hoverOpacity: 0.07
	property real pressOpacity: 0.12

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

	onPressed: event => {
		if (!layer.bloom)
			return;
		bloomAnim.stop();
		circle.x = event.x;
		circle.y = event.y;
		const dx = Math.max(event.x, width - event.x);
		const dy = Math.max(event.y, height - event.y);
		bloomAnim.reach = Math.sqrt(dx * dx + dy * dy) * 2;
		bloomAnim.start();
	}

	ClippingRectangle {
		anchors.fill: parent
		radius: layer.radius
		color: "transparent"

		Rectangle {
			anchors.fill: parent
			color: layer.tint
			opacity: !layer.enabled ? 0 : layer.pressed ? layer.pressOpacity : (layer.showHover && layer.containsMouse ? layer.hoverOpacity : 0)

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
		}

		Rectangle {
			id: circle

			width: 0
			height: width
			radius: width / 2
			color: layer.tint
			opacity: 0

			transform: Translate {
				x: -circle.width / 2
				y: -circle.height / 2
			}
		}
	}

	SequentialAnimation {
		id: bloomAnim

		property real reach: 0

		PropertyAction {
			target: circle
			property: "opacity"
			value: 0.12
		}
		ParallelAnimation {
			NumberAnimation {
				target: circle
				property: "width"
				from: 0
				to: bloomAnim.reach
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
			SequentialAnimation {
				PauseAnimation {
					duration: Motion.short
				}
				NumberAnimation {
					target: circle
					property: "opacity"
					to: 0
					duration: Motion.medium
				}
			}
		}
	}
}
