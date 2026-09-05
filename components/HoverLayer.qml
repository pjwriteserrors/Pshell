import QtQuick
import Quickshell.Widgets

// Reusable hover-tint + press-ripple layer. Drop into any clickable
// rounded rect: it fills the parent, shows a soft tint on hover, a
// stronger tint while pressed and an expanding ripple from the click
// point. Use like a MouseArea (onClicked etc. work as usual).
MouseArea {
	id: layer

	property color tint: "#ffffff"
	// qmllint disable missing-property
	property real cornerRadius: parent?.radius ?? 0
	// qmllint enable missing-property
	property bool showHover: true
	property bool rippleEnabled: ThemeEngine.rippleEnabled

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	onPressed: event => {
		if (!layer.rippleEnabled)
			return;

		rippleAnim.cx = event.x;
		rippleAnim.cy = event.y;

		const dist = (ox, oy) => ox * ox + oy * oy;
		rippleAnim.targetRadius = Math.sqrt(Math.max(
			dist(event.x, event.y),
			dist(event.x, height - event.y),
			dist(width - event.x, event.y),
			dist(width - event.x, height - event.y)
		));

		rippleAnim.restart();
	}

	ClippingRectangle {
		anchors.fill: parent
		radius: layer.cornerRadius
		color: "transparent"

		Rectangle {
			anchors.fill: parent
			radius: layer.cornerRadius
			color: layer.tint
			opacity: layer.pressed ? ThemeEngine.pressedTintOpacity
				: (layer.showHover && layer.containsMouse) ? ThemeEngine.hoverTintOpacity : 0

			Behavior on opacity {
				NumberAnimation {
					duration: Motion.fast
					easing.type: ThemeEngine.standardEasing
				}
			}
		}

		Rectangle {
			id: ripple

			width: 0
			height: 0
			radius: width / 2
			color: layer.tint
			opacity: 0

			transform: Translate {
				x: -ripple.width / 2
				y: -ripple.height / 2
			}
		}
	}

	SequentialAnimation {
		id: rippleAnim

		property real cx
		property real cy
		property real targetRadius

		PropertyAction {
			target: ripple
			property: "x"
			value: rippleAnim.cx
		}
		PropertyAction {
			target: ripple
			property: "y"
			value: rippleAnim.cy
		}
		PropertyAction {
			target: ripple
			property: "opacity"
			value: 0.1
		}
		NumberAnimation {
			target: ripple
			properties: "width,height"
			from: 0
			to: rippleAnim.targetRadius * 2
			duration: Motion.normal
			easing.type: ThemeEngine.standardEasing
		}
		NumberAnimation {
			target: ripple
			property: "opacity"
			to: 0
			duration: Motion.normal
			easing.type: ThemeEngine.standardEasing
		}
	}
}
