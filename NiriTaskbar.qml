pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The realms: the windows on this output, hung along the left limb of the
// chain.
//
// Each window is a stone on a short cord. The focused one is a plate with the
// application's mark cut into it; the rest are blanks, because there is nothing
// to read on them — which one is in front is the only question a taskbar
// answers. An urgent window burns.
//
// A new realm is *hung*: the cord pays out and the stone drops onto the curve
// and swings once. When one closes the rest slide along the chain to close the
// gap rather than jumping.
Item {
	id: root

	required property var niriState
	required property string outputName

	// The chain this run is hung from, handed down by the gantry: the x this
	// item starts at on screen, and the curve to read a height off.
	property real originX: 0
	property var chainAt: null

	// Handed over by the chain so a screen can be re-coloured in one place; the
	// values themselves come from Arc.
	property color background: Arc.leaf1
	property color foreground: Arc.ink
	property color secondaryBoxColor: Arc.leaf2
	property color secondaryBoxStrongColor: Arc.leaf3

	readonly property int blankSize: 18
	readonly property int focusedSize: 27

	function iconSource(appId) {
		if (!appId) return Quickshell.iconPath("application-x-executable", true);

		const direct = Quickshell.iconPath(appId, true);
		if (direct !== "") return direct;

		const desktopName = appId.endsWith(".desktop") ? appId : `${appId}.desktop`;
		const desktopIcon = Quickshell.iconPath(desktopName, true);
		if (desktopIcon !== "") return desktopIcon;

		return Quickshell.iconPath("application-x-executable", true);
	}

	function heightAt(centreX) {
		return root.chainAt ? root.chainAt(centreX) : Arc.chainY(0.1);
	}

	implicitWidth: run.implicitWidth
	implicitHeight: Arc.gantryDepth

	Row {
		id: run
		height: parent.height
		spacing: Arc.s2

		// The gap closing when a realm is let go: the rest travel along the
		// chain rather than being re-laid out between frames.
		move: Transition {
			NumberAnimation {
				property: "x"
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		add: Transition {
			NumberAnimation {
				property: "x"
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveDetent
			}
		}

		Repeater {
			id: taskRepeater

			// Keyed by window id so an unrelated window event reuses the
			// existing delegates instead of recreating them — recreating
			// reloads every icon, which reads as a flicker.
			model: ScriptModel {
				objectProp: "id"
				values: root.niriState.tasksForOutput(root.outputName)
			}

			delegate: Item {
				id: realm

				required property var modelData
				readonly property var task: realm.modelData
				readonly property bool focused: realm.task.isFocused
				readonly property real size: realm.focused ? root.focusedSize : root.blankSize

				width: root.focusedSize
				height: root.height

				// Where the stone hangs, and where it is on its way down from.
				property real drop: 0

				Component.onCompleted: hang.start()

				NumberAnimation {
					id: hang
					target: realm
					property: "drop"
					from: 0
					to: 1
					duration: Arc.unroll
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveUnroll
				}

				readonly property real restY: root.heightAt(root.originX + realm.x + width / 2)

				// The cord.
				Rectangle {
					x: realm.width / 2
					y: realm.restY - 12
					width: Arc.ruleThin
					height: 12 * realm.drop
					color: Arc.giltGhost
				}

				Item {
					id: stone
					width: realm.size
					height: realm.size
					x: (realm.width - width) / 2
					y: Math.round(realm.restY - height / 2 + (1 - realm.drop) * -14)
					opacity: realm.drop

					Behavior on width {
						NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveDetent }
					}
					Behavior on height {
						NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveDetent }
					}

					ArcHalo {
						anchors.centerIn: parent
						width: root.focusedSize * 2.2
						height: root.focusedSize * 2.2
						color: realm.task.isUrgent ? Arc.bane : Arc.aether
						strength: 0.3
						spread: 0.32
						flicker: realm.task.isUrgent
						opacity: realm.focused || touch.containsMouse ? 1 : 0
						visible: opacity > 0.01

						Behavior on opacity {
							NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
						}
					}

					ArcPlate {
						anchors.fill: parent
						variant: "plate"
						weight: Arc.ruleThin
						inset: 0
						beading: false
						lineColor: realm.task.isUrgent ? Qt.alpha(Arc.bane, 0.8) : Arc.giltFaint
						liveColor: realm.task.isUrgent ? Arc.bane : Arc.aether
						fillTop: realm.focused ? Arc.leaf2 : Arc.leaf1
						fillBottom: Arc.leaf0
						intensity: realm.focused ? 1 : touch.live
					}

					Image {
						anchors.centerIn: parent
						source: root.iconSource(realm.task.appId)
						sourceSize.width: 15
						sourceSize.height: 15
						width: 15
						height: 15
						fillMode: Image.PreserveAspectFit
						smooth: true
						mipmap: true
						asynchronous: true
						cache: true
						opacity: realm.focused ? 1 : touch.containsMouse ? 0.9 : 0
						visible: opacity > 0.01

						Behavior on opacity {
							NumberAnimation { duration: Arc.tick }
						}
					}

					// The blank: what a realm you are not in looks like.
					Rectangle {
						anchors.centerIn: parent
						width: Arc.stud * 2
						height: Arc.stud * 2
						rotation: 45
						color: realm.task.isUrgent ? Arc.bane : Arc.giltDim
						opacity: realm.focused || touch.containsMouse ? 0 : 1
						visible: opacity > 0.01

						Behavior on opacity {
							NumberAnimation { duration: Arc.tick }
						}
					}

					ArcTouch {
						id: touch
						acceptedButtons: Qt.LeftButton | Qt.MiddleButton
						onClicked: event => {
							if (event.button === Qt.MiddleButton)
								root.niriState.closeWindow(realm.task.id);
							else
								root.niriState.focusWindow(realm.task.id);
						}
					}
				}
			}
		}
	}
}
