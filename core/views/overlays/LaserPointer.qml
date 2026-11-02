pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// The laser pointer on one screen: on the screen the pointer is on, a dot of
// light in the cursor theme's accent takes its place and draws a short
// streak behind it that fades as soon as it rests. Like MouseFinder the
// screen takes the pointer while the laser is on, to learn where it is; a
// click or the wheel ends it. Nothing shows before the pointer's first move.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	// the pointer is on this screen
	readonly property bool here: Laser.output === root.name
	readonly property bool shown: Laser.active && root.here
	property real reveal: root.shown ? 1 : 0

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.short : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.decel : Motion.accel
		}
	}

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	visible: Laser.active || root.reveal > 0.002
	WlrLayershell.namespace: "shell-laser-pointer"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	// the keys stay with the presentation; Escape comes through Input
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	// only while it is on: what fades out is clicked through
	mask: Region {
		regions: Laser.active ? [everywhere] : []
	}

	Region {
		id: everywhere

		item: catcher
	}

	MouseArea {
		id: catcher

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.AllButtons
		cursorShape: Laser.active ? Qt.BlankCursor : Qt.ArrowCursor
		onPositionChanged: mouse => root.follow(mouse.x, mouse.y)
		onEntered: root.follow(catcher.mouseX, catcher.mouseY)
		onPressed: Laser.hide()
		onWheel: Laser.hide()
	}

	function follow(x, y) {
		if (!Laser.active) return;
		Laser.at(root.name, x, y);
		light.add(x, y);
	}

	// the streak goes with the pointer when it leaves for another screen
	onHereChanged: if (!root.here) light.clear()

	Beam {
		id: light

		anchors.fill: parent
		px: Laser.x
		py: Laser.y
		lit: root.shown
		opacity: Math.min(1, root.reveal)
		visible: root.here
	}

	// The dot and its streak, drawn where px/py says (the hotspot); add()
	// tells it every place the pointer passes. Also used on its own, in
	// tests, fed with made-up places.
	component Beam: Item {
		id: beam

		property real px: 0
		property real py: 0
		property bool lit: true
		// how long a passed place stays in the streak, in ms
		property int life: 220
		// how many places the streak keeps at most
		property int length: 12
		// the places passed, oldest first: { x, y, t }
		property var samples: []
		// the pieces of the streak between them: { x, y, length, width, angle }
		property var pieces: []

		readonly property real radius: 3.2 * CursorStyle.unit

		function add(x, y) {
			const now = Date.now();
			const list = beam.samples.slice();
			const last = list[list.length - 1];
			if (last && Math.hypot(x - last.x, y - last.y) < 1) return;
			// a fast mouse tells of every few ms: places closer in time than a
			// frame are one, so the streak is as long on any mouse
			if (last && now - last.t < 16) {
				last.x = x;
				last.y = y;
			} else {
				list.push({ x: x, y: y, t: now });
			}
			beam.samples = list.slice(-beam.length);
			beam.update(now);
		}

		function clear() {
			beam.samples = [];
			beam.pieces = [];
		}

		// drops what has faded and lays the streak's pieces anew; the newest
		// piece runs up to the dot itself
		function update(now) {
			const list = beam.samples.filter(sample => now - sample.t < beam.life);
			const pieces = [];
			for (let i = 0; i < list.length; i++) {
				const a = list[i];
				const b = i + 1 < list.length ? list[i + 1] : { x: beam.px, y: beam.py };
				const fresh = Math.max(0, 1 - (now - a.t) / beam.life);
				const width = beam.radius * 1.6 * Math.pow(fresh, 0.7);
				const length = Math.hypot(b.x - a.x, b.y - a.y);
				if (width < 0.5) continue;
				pieces.push({
					x: (a.x + b.x) / 2,
					y: (a.y + b.y) / 2,
					length: length,
					width: width,
					angle: Math.atan2(b.y - a.y, b.x - a.x) * 180 / Math.PI
				});
			}
			if (list.length !== beam.samples.length) beam.samples = list;
			beam.pieces = pieces;
		}

		FrameAnimation {
			running: beam.samples.length > 0
			onTriggered: beam.update(Date.now())
		}

		// the streak, twice: a wide faint glow under a narrow core. Each is
		// drawn whole into a layer and faded as one, so where its pieces
		// overlap is not brighter
		Repeater {
			model: [
				{ grow: 2.6, opacity: 0.16 },
				{ grow: 1, opacity: 0.55 }
			]

			Item {
				id: streak

				required property var modelData
				// only as big as the streak: the layer is no bigger
				readonly property real pad: beam.radius * 3
				readonly property real fromX: Math.min(beam.px, ...beam.samples.map(sample => sample.x)) - streak.pad
				readonly property real fromY: Math.min(beam.py, ...beam.samples.map(sample => sample.y)) - streak.pad

				x: streak.fromX
				y: streak.fromY
				width: Math.max(beam.px, ...beam.samples.map(sample => sample.x)) + streak.pad - streak.fromX
				height: Math.max(beam.py, ...beam.samples.map(sample => sample.y)) + streak.pad - streak.fromY
				visible: beam.pieces.length > 0
				opacity: streak.modelData.opacity
				layer.enabled: streak.visible

				Repeater {
					model: beam.pieces

					Rectangle {
						required property var modelData
						readonly property real thick: modelData.width * streak.modelData.grow

						x: modelData.x - streak.fromX - width / 2
						y: modelData.y - streak.fromY - height / 2
						width: modelData.length + thick
						height: thick
						radius: thick / 2
						rotation: modelData.angle
						color: CursorStyle.accent
						antialiasing: true
					}
				}
			}
		}

		// the dot: a soft glow, the theme's outline and the accent inside
		Item {
			x: beam.px
			y: beam.py
			scale: beam.lit ? 1 : 0.4

			Behavior on scale {
				NumberAnimation {
					duration: Motion.short
					easing.type: Easing.BezierSpline
					easing.bezierCurve: beam.lit ? Motion.spatial : Motion.accel
				}
			}

			Rectangle {
				id: glow

				anchors.centerIn: parent
				width: beam.radius * 6
				height: width
				radius: width / 2
				color: CursorStyle.accent
				opacity: 0.12

				// breathes, just so
				SequentialAnimation on opacity {
					running: beam.lit
					loops: Animation.Infinite

					NumberAnimation {
						to: 0.2
						duration: 1100
						easing.type: Easing.InOutSine
					}

					NumberAnimation {
						to: 0.12
						duration: 1100
						easing.type: Easing.InOutSine
					}
				}
			}

			Rectangle {
				anchors.centerIn: parent
				width: beam.radius * 3.4
				height: width
				radius: width / 2
				color: CursorStyle.accent
				opacity: 0.22
			}

			Rectangle {
				anchors.centerIn: parent
				width: (beam.radius + CursorStyle.outlineWidth) * 2
				height: width
				radius: width / 2
				color: CursorStyle.outline
				antialiasing: true
			}

			Rectangle {
				anchors.centerIn: parent
				width: beam.radius * 2
				height: width
				radius: width / 2
				color: CursorStyle.accent
				antialiasing: true
			}
		}
	}
}
