pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A finger unlocked something (core/services/Fingerprint.qml, any program's
// check: the lock screen, sudo, polkit, the Files vault): low on the focused
// screen a disc pops up, a light runs down the fingerprint, it turns into an
// open lock with a little ripple and drifts away – about 1.3 s, nothing to
// click, no focus taken.
PanelWindow {
	id: root

	required property var modelData

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-fingerprint-unlock"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	property real shown: 0
	property real pop: 0
	property real scan: 0
	property real done: 0
	property real ripple: 0

	Component.onCompleted: play.restart()

	Connections {
		target: Fingerprint

		function onUnlocksChanged() {
			play.restart();
		}
	}

	SequentialAnimation {
		id: play

		ScriptAction {
			script: {
				root.shown = 1;
				root.pop = 0;
				root.scan = 0;
				root.done = 0;
				root.ripple = 0;
			}
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "pop"
				to: 1
				duration: 380
				easing.type: Easing.OutBack
				easing.overshoot: 1.8
			}
			SequentialAnimation {
				PauseAnimation {
					duration: 110
				}
				NumberAnimation {
					target: root
					property: "scan"
					to: 1
					duration: 340
					easing.type: Easing.InOutCubic
				}
			}
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "done"
				to: 1
				duration: 300
				easing.type: Easing.OutBack
				easing.overshoot: 2
			}
			NumberAnimation {
				target: root
				property: "ripple"
				to: 1
				duration: 900
				easing.type: Easing.OutCubic
			}
		}
		PauseAnimation {
			duration: 260
		}
		NumberAnimation {
			target: root
			property: "shown"
			to: 0
			duration: 320
			easing.type: Easing.InCubic
		}
	}

	Item {
		id: stage

		readonly property real disc: 46

		width: 130
		height: 130
		x: (root.width - width) / 2
		y: root.height - height - Math.max(60, root.height * 0.09) - (1 - root.shown) * 14
		opacity: root.shown * Math.min(1, root.pop * 1.6)

		// a little ripple when it opens: three thin rings, one after another
		Repeater {
			model: 3

			Rectangle {
				id: ring

				required property int index
				readonly property real t: Math.max(0, Math.min(1, root.ripple * 1.6 - ring.index * 0.3))

				anchors.centerIn: parent
				width: stage.disc
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 2 / ring.scale
				border.color: Theme.primary
				scale: 1 + ring.t * 1.15
				opacity: ring.t > 0 && ring.t < 1 ? 0.75 * (1 - ring.t) * (1 - ring.index * 0.2) : 0
			}
		}

		// the disc
		Rectangle {
			id: disc

			anchors.centerIn: parent
			width: stage.disc
			height: width
			radius: width / 2
			scale: 0.55 + 0.45 * root.pop + 0.06 * Math.sin(Math.PI * root.done)
			color: Qt.tint(Qt.alpha(Theme.layer1, 0.94), Qt.alpha(Theme.primary, root.done))
			border.width: 1
			border.color: Qt.alpha(Theme.primary, 0.5 * (1 - root.done))

			// a soft shadow
			Rectangle {
				z: -1
				anchors.centerIn: parent
				anchors.verticalCenterOffset: 4
				width: parent.width + 10
				height: width
				radius: width / 2
				color: Theme.shadow
				opacity: 0.35
			}

			// the print: dim, then lit from the top down as the light runs over it
			Item {
				anchors.fill: parent
				opacity: 1 - root.done
				scale: 1 + root.done * 0.25

				Glyph {
					anchors.centerIn: parent
					icon: "fingerprint"
					size: stage.disc * 0.58
					color: Theme.textMuted
					animated: false
				}

				Item {
					id: lit

					x: 0
					y: 0
					width: parent.width
					height: parent.height * root.scan
					clip: true

					Glyph {
						x: (disc.width - width) / 2
						y: (disc.height - height) / 2
						icon: "fingerprint"
						size: stage.disc * 0.58
						color: Theme.primary
						animated: false
					}
				}

				// the light
				Rectangle {
					visible: root.scan > 0 && root.scan < 1
					x: parent.width * 0.2
					width: parent.width * 0.6
					height: 2
					radius: 1
					y: parent.height * (0.2 + 0.6 * root.scan)
					color: Theme.primary
					opacity: Math.sin(Math.PI * root.scan)

					Rectangle {
						anchors.centerIn: parent
						width: parent.width
						height: 8
						radius: 4
						color: Theme.primary
						opacity: 0.25
					}
				}
			}

			// open
			Glyph {
				anchors.centerIn: parent
				icon: "lock_open_variant"
				size: stage.disc * 0.5
				color: Theme.onPrimary
				animated: false
				opacity: root.done
				scale: 0.5 + 0.5 * root.done
				rotation: -14 * (1 - root.done)
			}
		}
	}
}
