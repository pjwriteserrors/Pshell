import QtQuick
import qs.style.theme
import qs.style.widgets

// A surface of the printer panel, like the control center's tiles: filled,
// no outline. It rises into place when it comes – after the ones before it
// (order) – and again whenever its page comes back (cue).
Rectangle {
	id: root

	// its place in the page's choreography
	property int order: 0
	// a page coming back in replays the rise
	property bool cue: true
	property real rise: 16

	radius: Theme.radius.huge
	color: Theme.layer1
	opacity: 0

	transform: Translate {
		id: shift

		y: root.rise
	}

	function appear() {
		comeIn.restart();
	}

	Component.onCompleted: if (root.cue) root.appear()
	onCueChanged: if (root.cue) root.appear()

	SequentialAnimation {
		id: comeIn

		ScriptAction {
			script: {
				root.opacity = 0;
				shift.y = root.rise;
			}
		}
		PauseAnimation {
			duration: 40 + root.order * 55
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "opacity"
				to: 1
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.standard
			}
			NumberAnimation {
				target: shift
				property: "y"
				to: 0
				duration: Motion.extraLong
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}
}
