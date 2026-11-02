pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// How far a series is: a step per episode, one half watched is half full.
// A new episode pushes the others together and lights up. Too many to tell
// apart (or none told) become one line, which still shows a new one coming.
Item {
	id: root

	// how much of each episode was watched, 0 to 1
	property var cells: []
	property int total: root.cells.length
	property real done: root.cells.reduce((sum, value) => sum + value, 0)
	property color accent: Theme.primary
	property real barHeight: 7
	readonly property bool dense: root.total >= 60 || root.cells.length === 0
	readonly property real gap: root.total > 30 ? 1 : 2

	implicitHeight: root.barHeight
	implicitWidth: 120

	onCellsChanged: sync()
	Component.onCompleted: {
		root.sync();
		root.loaded = true;
	}

	property bool loaded: false
	property int lastTotal: -1

	onTotalChanged: {
		if (root.loaded && root.lastTotal >= 0 && root.total > root.lastTotal) flash.restart();
		root.lastTotal = root.total;
	}

	function sync() {
		if (root.dense) {
			if (steps.count > 0) steps.clear();
			return;
		}
		while (steps.count > root.cells.length) steps.remove(steps.count - 1);
		for (let i = 0; i < root.cells.length; i += 1) {
			const value = Number(root.cells[i]);
			if (i < steps.count) {
				if (steps.get(i).value !== value) steps.setProperty(i, "value", value);
			} else {
				steps.append({ value: value, fresh: root.loaded });
			}
		}
	}

	ListModel {
		id: steps
	}

	// one line
	Rectangle {
		anchors.fill: parent
		visible: root.dense
		radius: height / 2
		color: Qt.alpha(Theme.text, 0.13)
		clip: true

		Rectangle {
			height: parent.height
			radius: parent.radius
			color: root.accent
			width: parent.width * (root.total > 0 ? Math.min(1, root.done / root.total) : 0)

			Behavior on width {
				NumberAnimation {
					duration: Motion.extraLong
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.decel
				}
			}
		}

		// the new episode, at the far end
		Rectangle {
			id: flashEnd

			anchors.right: parent.right
			height: parent.height
			width: Math.max(10, parent.width * 0.04)
			radius: parent.radius
			color: Theme.text
			opacity: 0
		}
	}

	SequentialAnimation {
		id: flash

		loops: 2
		NumberAnimation {
			target: flashEnd
			property: "opacity"
			to: 0.9
			duration: 260
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: flashEnd
			property: "opacity"
			to: 0
			duration: 420
			easing.type: Easing.InCubic
		}
	}

	// a step per episode
	Row {
		anchors.fill: parent
		visible: !root.dense
		spacing: root.gap

		Repeater {
			model: steps

			Rectangle {
				id: step

				required property int index
				required property real value
				required property bool fresh

				readonly property real fullWidth: Math.max(1, (root.width - root.gap * Math.max(0, root.cells.length - 1)) / Math.max(1, root.cells.length))
				property real grown: step.fresh ? 0 : 1

				width: step.fullWidth * step.grown
				height: root.height
				radius: Math.min(2.5, height / 2)
				color: Qt.alpha(Theme.text, 0.13)
				clip: true

				Component.onCompleted: {
					step.grown = 1;
					if (step.fresh) glow.start();
				}

				Behavior on width {
					NumberAnimation {
						duration: Motion.extraLong
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}

				Rectangle {
					height: parent.height
					radius: parent.radius
					color: root.accent
					width: parent.width * Math.max(0, Math.min(1, step.value))

					Behavior on width {
						NumberAnimation {
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.decel
						}
					}
				}

				Rectangle {
					id: spark

					anchors.fill: parent
					radius: parent.radius
					color: Theme.text
					opacity: 0
				}

				SequentialAnimation {
					id: glow

					PauseAnimation {
						duration: 240
					}
					SequentialAnimation {
						loops: 3
						NumberAnimation {
							target: spark
							property: "opacity"
							to: 0.95
							duration: 240
							easing.type: Easing.OutCubic
						}
						NumberAnimation {
							target: spark
							property: "opacity"
							to: 0.05
							duration: 420
							easing.type: Easing.InCubic
						}
					}
					NumberAnimation {
						target: spark
						property: "opacity"
						to: 0
						duration: 160
					}
				}
			}
		}
	}
}
