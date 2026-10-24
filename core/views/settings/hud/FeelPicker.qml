pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../mouse/Waves.js" as Waves

// Every pattern of the mouse as a little drawing in a grid; resting on one
// a moment plays it in the hand, a click takes it.
Popup {
	id: root

	property string current: ""

	signal picked(string value)

	width: 4 * 92 + 3 * 6 + 20
	height: grid.implicitHeight + 20
	padding: 10
	modal: true
	dim: false
	closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

	enter: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				from: 0.9
				to: 1
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatialFast
			}
		}
	}
	exit: Transition {
		NumberAnimation {
			property: "opacity"
			to: 0
			duration: Motion.short
		}
	}

	background: Rectangle {
		radius: Theme.radius.huge
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	contentItem: GridLayout {
		id: grid

		columns: 4
		rowSpacing: 6
		columnSpacing: 6

		Repeater {
			model: Mouse.waveforms

			delegate: Clickable {
				id: tile

				required property string modelData
				required property int index
				readonly property bool chosen: tile.modelData === root.current

				Layout.preferredWidth: 92
				Layout.preferredHeight: 62
				radius: Theme.radius.medium
				color: tile.chosen ? Theme.primary : (tile.hovered ? Theme.layer3 : Theme.layer1)
				sound: ""
				opacity: 0
				scale: 0.8
				onClicked: {
					Mouse.play(tile.modelData);
					root.picked(tile.modelData);
					root.close();
				}
				onHoveredChanged: {
					if (tile.hovered) dwell.restart();
					else dwell.stop();
				}

				Behavior on color {
					ColorAnim {}
				}

				Connections {
					target: root

					function onAboutToShow() {
						tile.opacity = 0;
						tile.scale = 0.8;
						popIn.start();
					}
				}

				SequentialAnimation {
					id: popIn

					PauseAnimation {
						duration: (tile.index % 4 + Math.floor(tile.index / 4)) * 18
					}
					ParallelAnimation {
						NumberAnimation {
							target: tile
							property: "opacity"
							to: 1
							duration: Motion.short
						}
						NumberAnimation {
							target: tile
							property: "scale"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}
				}

				// resting on it a moment plays it
				Timer {
					id: dwell

					interval: 280
					onTriggered: {
						Mouse.play(tile.modelData);
						wave.play();
					}
				}

				MiniWave {
					id: wave

					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.top
					anchors.topMargin: 10
					width: parent.width - 22
					height: 22
					waveform: tile.modelData
					color: tile.chosen ? Theme.onPrimary : Qt.alpha(Theme.text, 0.55)
					glow: tile.chosen ? Theme.onPrimary : Theme.primary
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 8
					text: Waves.names[tile.modelData] ?? tile.modelData.toLowerCase()
					tone: tile.chosen ? Theme.onPrimary : Theme.text
					font.pixelSize: Theme.size.small
					font.weight: Font.Medium
				}
			}
		}
	}
}
