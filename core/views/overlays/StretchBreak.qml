pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Guided five minute stretch. The outer ring runs down the whole break, the
// inner one the current step; steps slide in one after another and the
// icon breathes along. → skips a step, Escape or a click ends it early.
ModalWindow {
	id: root

	readonly property var steps: [
		{ icon: "human_handsup", title: "Stand up", detail: "Reach up high, shake out arms and legs", seconds: 30 },
		{ icon: "head_outline", title: "Neck", detail: "Ear to shoulder, slowly, each side", seconds: 45 },
		{ icon: "rotate_right", title: "Shoulders", detail: "Roll them back, then pull the blades together", seconds: 45 },
		{ icon: "human_handsup", title: "Chest", detail: "Hands behind your back, open up, look up", seconds: 45 },
		{ icon: "hand_back_right_outline", title: "Wrists", detail: "Arm out, pull the fingers back, each side", seconds: 45 },
		{ icon: "walk", title: "Walk", detail: "A few steps, refill your bottle", seconds: 90 }
	]
	readonly property int total: root.steps.reduce((sum, step) => sum + step.seconds, 0)

	property int step: 0
	property real stepProgress: 0
	property bool done: false
	readonly property int elapsedBefore: root.steps.slice(0, root.step).reduce((sum, s) => sum + s.seconds, 0)
	readonly property real overall: (root.elapsedBefore + root.stepProgress * root.steps[root.step].seconds) / root.total
	readonly property int secondsLeft: Math.ceil((1 - root.stepProgress) * root.steps[root.step].seconds)

	modalId: "stretch"
	scrimColor: Qt.rgba(0, 0, 0, 0.82)

	function begin(index) {
		root.step = index;
		root.stepProgress = 0;
		stepRun.duration = root.steps[index].seconds * 1000;
		stepRun.restart();
		slideIn.restart();
	}

	function next() {
		if (root.done) return;
		if (root.step + 1 < root.steps.length) {
			root.begin(root.step + 1);
		} else {
			stepRun.stop();
			root.stepProgress = 1;
			root.done = true;
			finish.restart();
		}
	}

	onModalOpened: {
		root.done = false;
		root.begin(0);
	}

	onShownChanged: {
		if (root.shown) return;
		stepRun.stop();
		finish.stop();
	}

	NumberAnimation {
		id: stepRun

		target: root
		property: "stepProgress"
		from: 0
		to: 1
		onFinished: if (root.stepProgress >= 1) root.next()
	}

	Timer {
		id: finish

		interval: 1400
		onTriggered: Breaks.finishStretch(true)
	}

	Item {
		anchors.fill: parent
		focus: true

		Keys.onRightPressed: root.next()
		Keys.onSpacePressed: root.next()

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 30

			Item {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 300
				Layout.preferredHeight: 300

				Rectangle {
					anchors.centerIn: parent
					width: 300
					height: 300
					radius: 150
					color: Qt.alpha(root.done ? Theme.success : Theme.primary, 0.1)
					scale: 0.84

					SequentialAnimation on scale {
						running: root.shown && !root.done
						loops: Animation.Infinite

						NumberAnimation {
							to: 1
							duration: 4000
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 0.84
							duration: 4000
							easing.type: Easing.InOutSine
						}
					}
				}

				Ring {
					anchors.centerIn: parent
					width: 240
					height: 240
					thickness: 6
					animated: false
					value: root.done ? 1 : 1 - root.overall
					color: root.done ? Theme.success : Theme.primary
					trackColor: Qt.rgba(1, 1, 1, 0.08)
				}

				Ring {
					anchors.centerIn: parent
					width: 206
					height: 206
					thickness: 3
					animated: false
					visible: !root.done
					value: 1 - root.stepProgress
					color: Qt.alpha(Theme.primary, 0.55)
					trackColor: "transparent"
				}

				ColumnLayout {
					id: face

					anchors.centerIn: parent
					spacing: 4

					Glyph {
						Layout.alignment: Qt.AlignHCenter
						icon: root.done ? "check" : root.steps[root.step].icon
						size: 60
						color: root.done ? Theme.success : "white"
						surface: "transparent"
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						visible: !root.done
						text: root.secondsLeft
						tone: Qt.rgba(1, 1, 1, 0.75)
						surface: "transparent"
						font.pixelSize: Theme.size.display
						font.weight: Font.Light
						tabular: true
					}
				}
			}

			ColumnLayout {
				id: caption

				Layout.alignment: Qt.AlignHCenter
				spacing: 6

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: root.done ? "Done" : root.steps[root.step].title
					tone: "white"
					surface: "transparent"
					font.pixelSize: 30
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					visible: !root.done
					text: root.steps[root.step].detail
					tone: Qt.rgba(1, 1, 1, 0.7)
					surface: "transparent"
					font.pixelSize: Theme.size.title
				}

				transform: Translate {
					id: slide
				}
			}

			Row {
				Layout.alignment: Qt.AlignHCenter
				spacing: 8

				Repeater {
					model: root.steps.length

					delegate: Rectangle {
						required property int index

						width: index === root.step && !root.done ? 26 : 8
						height: 8
						radius: 4
						color: index < root.step || root.done ? Theme.primary : (index === root.step ? "white" : Qt.rgba(1, 1, 1, 0.25))

						Behavior on width {
							SpatialAnim {}
						}
					}
				}
			}
		}

		ParallelAnimation {
			id: slideIn

			NumberAnimation {
				target: slide
				property: "x"
				from: 40
				to: 0
				duration: Motion.extraLong
				easing.type: Easing.OutCubic
			}
			NumberAnimation {
				target: caption
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.long
			}
			SequentialAnimation {
				NumberAnimation {
					target: face
					property: "scale"
					to: 0.7
					duration: Motion.short
				}
				SpatialAnim {
					target: face
					property: "scale"
					to: 1
				}
			}
		}
	}
}
