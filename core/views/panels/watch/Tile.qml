import QtQuick
import qs.style.theme
import qs.style.widgets

// A surface of >watch, like the printer's and the control center's tiles:
// filled, no outline. When the panel opens it rises into place after the
// ones before it (order), a little scaled down at first, as if it bloomed.
Rectangle {
	id: root

	property int order: 0
	property real rise: 22

	radius: Theme.radius.huge
	color: Theme.layer1
	opacity: 0
	transformOrigin: Item.Top

	transform: [
		Translate {
			id: shift

			y: root.rise
		},
		Scale {
			id: grow

			origin.x: root.width / 2
			origin.y: 0
			xScale: 0.96
			yScale: 0.96
		}
	]

	function appear() {
		comeIn.restart();
	}

	function hide() {
		comeIn.stop();
		root.opacity = 0;
		shift.y = root.rise;
		grow.xScale = grow.yScale = 0.96;
	}

	SequentialAnimation {
		id: comeIn

		ScriptAction {
			script: root.hide()
		}
		PauseAnimation {
			duration: 60 + root.order * 70
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "opacity"
				to: 1
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.standard
			}
			NumberAnimation {
				target: shift
				property: "y"
				to: 0
				duration: Motion.extraLong + 120
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
			NumberAnimation {
				targets: [grow]
				properties: "xScale,yScale"
				to: 1
				duration: Motion.extraLong + 120
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}
}
