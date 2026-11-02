pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What happens between a click and the first picture: a line that fills step by
// step and says which step it is. A step that takes long keeps creeping, so it
// never looks stuck, and after a while it offers the browser.
Item {
	id: root

	// ask | sound | check | extras | connect | seek | buffer
	property string step: "ask"
	property string seekText: ""
	property string url: ""
	property real ui: 1
	readonly property var steps: [
		{ id: "ask", label: "Asking YouTube for the video", to: 0.32 },
		{ id: "sound", label: "Finding the original sound", to: 0.42 },
		{ id: "check", label: "Checking that the streams answer", to: 0.56 },
		{ id: "extras", label: "Looking for sponsor segments", to: 0.66 },
		{ id: "connect", label: "Connecting to the video", to: 0.82 },
		{ id: "seek", label: root.seekText !== "" ? `Going to ${root.seekText}` : "Going to where you stopped", to: 0.92 },
		{ id: "buffer", label: "Filling the buffer", to: 1 }
	]
	readonly property int index: Math.max(0, root.steps.findIndex(entry => entry.id === root.step))
	readonly property var current: root.steps[root.index]
	readonly property real from: root.index > 0 ? root.steps[root.index - 1].to : 0
	property real elapsed: 0
	property real inStep: 0
	// creeps toward the end of the step, ever more slowly
	readonly property real goal: root.from + (root.current.to - root.from) * (1 - Math.exp(-root.inStep / 2.2))

	onStepChanged: root.inStep = 0

	Timer {
		interval: 100
		repeat: true
		running: root.visible
		onTriggered: {
			root.inStep += 0.1;
			root.elapsed += 0.1;
		}
	}

	ColumnLayout {
		anchors.centerIn: parent
		width: Math.min(parent.width - 60, 560 * root.ui)
		spacing: 10 * root.ui

		Text {
			Layout.fillWidth: true
			text: root.current.label
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 19 * root.ui
			font.weight: Font.Bold
			style: Text.Raised
			styleColor: Qt.rgba(0, 0, 0, 0.55)
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 8 * root.ui
			radius: height / 2
			color: Qt.rgba(1, 1, 1, 0.24)

			Rectangle {
				height: parent.height
				radius: parent.radius
				color: "white"
				width: parent.width * root.goal

				Behavior on width {
					NumberAnimation {
						duration: 240
						easing.type: Easing.OutCubic
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			Text {
				text: `Step ${root.index + 1} of ${root.steps.length}`
				color: Qt.rgba(1, 1, 1, 0.74)
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
			}
			Item {
				Layout.fillWidth: true
			}
			Text {
				text: `${Math.floor(root.elapsed)} s`
				color: Qt.rgba(1, 1, 1, 0.74)
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
				font.features: { "tnum": 1 }
			}
		}

		// no need to sit through a slow day
		Text {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 6 * root.ui
			visible: root.elapsed > 12
			text: "Taking longer than usual. Open it in the browser instead?"
			color: browserArea.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.8)
			font.family: Theme.fontFamily
			font.pixelSize: 14 * root.ui
			font.underline: true

			MouseArea {
				id: browserArea

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: Browser.open(root.url)
			}
		}
	}
}
