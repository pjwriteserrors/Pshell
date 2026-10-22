pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// A horizontal bar of colors with a knob: hue, alpha.
Item {
	id: root

	property real position: 0
	property var stops: []
	property color knob: "white"
	property bool checkered: false

	signal moved(real position)

	implicitHeight: 16

	RoundClip {
		id: track

		anchors.fill: parent
		radius: height / 2

		Checker {
			anchors.fill: parent
			visible: root.checkered
			cell: 4
		}

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				id: grad

				orientation: Gradient.Horizontal
			}
			Component.onCompleted: root.rebuild()
		}
	}

	// the stops are made anew when the colors change
	function rebuild() {
		const made = [];
		for (const stop of root.stops)
			made.push(stopComponent.createObject(grad, { position: stop.position, color: stop.color }));
		for (const old of grad.stops)
			if (!made.includes(old)) old.destroy();
		grad.stops = made;
	}

	onStopsChanged: Qt.callLater(root.rebuild)

	Component {
		id: stopComponent

		GradientStop {}
	}

	Rectangle {
		x: root.position * (root.width - width)
		anchors.verticalCenter: parent.verticalCenter
		width: mouse.pressed ? 24 : 20
		height: width
		radius: width / 2
		color: root.knob
		border.width: 3
		border.color: "white"

		Behavior on width {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		anchors.margins: -6
		preventStealing: true
		cursorShape: Qt.PointingHandCursor
		function pick(mouse) {
			root.moved(Math.max(0, Math.min(1, (mouse.x - 6) / root.width)));
		}
		onPressed: mouse => pick(mouse)
		onPositionChanged: mouse => pick(mouse)
	}
}
