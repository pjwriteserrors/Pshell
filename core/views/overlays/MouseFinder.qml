pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The light of FindMouse on one screen: everything dims but a circle around
// the pointer, which closes in on it from far out and sends rings off while
// the shaking goes on. The screen takes the pointer for as long as that, to
// learn where it is; a click ends it at once.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	// the pointer is on this screen
	readonly property bool here: FindMouse.output === root.name
	readonly property bool shown: FindMouse.active && FindMouse.output !== ""
	property real reveal: root.shown ? 1 : 0
	// the circle: wide open when the light comes, then down to the pointer
	property real radius: root.shown ? 76 : 520
	// the dimmed ring around the circle reaches past every corner
	readonly property real reach: root.width + root.height

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.short : Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.standard
		}
	}

	Behavior on radius {
		NumberAnimation {
			duration: root.shown ? Motion.extraLong : Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.spatial : Motion.accel
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
	visible: FindMouse.active || root.reveal > 0.002
	WlrLayershell.namespace: "shell-find-mouse"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	// only while it is wanted: what fades out is clicked through
	mask: Region {
		regions: FindMouse.active ? [everywhere] : []
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
		cursorShape: grown.visible ? Qt.BlankCursor : Qt.ArrowCursor
		onPositionChanged: mouse => FindMouse.at(root.name, mouse.x, mouse.y)
		onEntered: FindMouse.at(root.name, catcher.mouseX, catcher.mouseY)
		onPressed: FindMouse.hide()
		onWheel: FindMouse.hide()
	}

	// the other screens only dim
	Rectangle {
		anchors.fill: parent
		visible: !root.here
		color: Theme.scrim
		opacity: Math.min(1, root.reveal)
	}

	Item {
		x: FindMouse.x
		y: FindMouse.y
		visible: root.here
		opacity: Math.min(1, root.reveal)

		// the dark around the circle, drawn as the border of a far bigger one
		Rectangle {
			anchors.centerIn: parent
			width: (root.radius + root.reach) * 2
			height: width
			radius: width / 2
			color: "transparent"
			border.width: root.reach
			border.color: Theme.scrim
		}

		Rectangle {
			anchors.centerIn: parent
			width: root.radius * 2
			height: width
			radius: width / 2
			color: Qt.alpha(Theme.primary, 0.1)
			border.width: 3
			border.color: Theme.primary
		}

		// rings that run off, one behind the other
		Repeater {
			model: 3

			Rectangle {
				id: ring

				required property int index
				property real run: 0

				anchors.centerIn: parent
				width: (root.radius + ring.run * 150) * 2
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 2 + 3 * (1 - ring.run)
				border.color: Theme.primary
				opacity: (1 - ring.run) * 0.8

				SequentialAnimation {
					running: root.shown && root.here
					loops: Animation.Infinite
					onStopped: ring.run = 0

					PauseAnimation {
						duration: ring.index * 300
					}

					NumberAnimation {
						target: ring
						property: "run"
						from: 0
						to: 1
						duration: 900
						easing.type: Easing.OutCubic
					}

					PauseAnimation {
						duration: (2 - ring.index) * 300
					}
				}
			}
		}
	}

	// the pointer itself grows while it is sought, the cursor theme's own
	// arrow, and shrinks back into the real one as the light goes
	PshellCursor {
		id: grown

		visible: root.here && root.reveal > 0.01 && CursorStyle.ready
		x: FindMouse.x
		y: FindMouse.y
		shape: "arrow"
		scale: FindMouse.active ? 2.6 : 1
		transformOrigin: Item.TopLeft

		Behavior on scale {
			NumberAnimation {
				duration: FindMouse.active ? Motion.long : Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: FindMouse.active ? Motion.spatial : Motion.standard
			}
		}
	}
}
