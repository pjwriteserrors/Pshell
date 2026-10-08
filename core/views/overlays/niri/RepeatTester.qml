pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.views.overlays.keybinds

// Key repeat as time: the key goes down at the left, the first repeat comes
// after the delay, the next ones at the rate. Drag the first dot for the
// delay, the second for the rate. Hold the key to feel it.
ColumnLayout {
	id: root

	property int delay: 600
	property int rate: 25
	readonly property real span: 2000

	signal delayMoved(int ms)
	signal rateMoved(int perSecond)

	spacing: 14

	Item {
		id: line

		Layout.fillWidth: true
		Layout.preferredHeight: 70

		readonly property real px: line.width / root.span

		Rectangle {
			y: 34
			width: parent.width
			height: 2
			radius: 1
			color: Theme.layer3
		}

		// the key going down
		Rectangle {
			x: -6
			y: 23
			width: 12
			height: 24
			radius: 4
			color: Theme.text
		}

		// the wait
		Rectangle {
			x: 0
			y: 33
			width: root.delay * line.px
			height: 4
			radius: 2
			color: Qt.alpha(Theme.primary, 0.35)

			Behavior on width {
				enabled: !delayMouse.pressed
				SpatialAnim {}
			}
		}

		StyledText {
			x: Math.max(0, root.delay * line.px / 2 - width / 2)
			y: 4
			text: `${root.delay} ms`
			tabular: true
			tone: Theme.primary
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		Repeater {
			model: Math.min(80, Math.max(0, Math.floor((root.span - root.delay) * root.rate / 1000) + 1))

			delegate: Rectangle {
				required property int index
				readonly property real at: root.delay + index * 1000 / root.rate

				x: at * line.px - width / 2
				y: 35 - height / 2
				width: index < 2 ? 14 : 8
				height: width
				radius: width / 2
				color: index === 0 ? Theme.primary : (index === 1 ? Theme.secondary : Qt.alpha(Theme.primary, 0.55))
				border.width: index < 2 ? 2 : 0
				border.color: Theme.base
			}
		}

		StyledText {
			x: Math.min(line.width - width, (root.delay + 1000 / root.rate) * line.px + 10)
			y: 48
			text: `${root.rate} per second`
			tabular: true
			tone: Theme.secondary
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		// grab the first dot: the delay
		MouseArea {
			id: delayMouse

			x: root.delay * line.px - 14
			y: 21
			width: 28
			height: 28
			hoverEnabled: true
			preventStealing: true
			cursorShape: Qt.SizeHorCursor
			onPositionChanged: event => {
				if (!pressed) return;
				const p = mapToItem(line, event.x, 0).x;
				root.delayMoved(Math.max(100, Math.min(1500, Math.round(p / line.px / 25) * 25)));
			}
		}

		// grab the second one: the rate
		MouseArea {
			x: (root.delay + 1000 / root.rate) * line.px - 14
			y: 21
			width: 28
			height: 28
			preventStealing: true
			cursorShape: Qt.SizeHorCursor
			onPositionChanged: event => {
				if (!pressed) return;
				const gap = Math.max(8, mapToItem(line, event.x, 0).x / line.px - root.delay);
				root.rateMoved(Math.max(5, Math.min(100, Math.round(1000 / gap))));
			}
		}
	}

	// hold to try
	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		Item {
			Layout.preferredWidth: 64
			Layout.preferredHeight: 52

			Keycap {
				anchors.centerIn: parent
				text: "A"
				size: 40
				lit: hold.pressed
			}

			MouseArea {
				id: hold

				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onPressed: {
					typed.text = "a";
					first.restart();
				}
				onReleased: {
					first.stop();
					again.stop();
				}
			}

			Timer {
				id: first

				interval: root.delay
				onTriggered: again.start()
			}

			Timer {
				id: again

				interval: Math.max(10, 1000 / root.rate)
				repeat: true
				triggeredOnStart: true
				onTriggered: if (typed.text.length < 400) typed.text += "a"
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 40
			radius: Theme.radius.medium
			color: Theme.layer2
			clip: true

			StyledText {
				id: typed

				anchors.right: parent.right
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				width: Math.min(implicitWidth, parent.width - 24)
				elide: Text.ElideLeft
				text: ""
				font.family: Theme.monoFamily
			}

			StyledText {
				anchors.left: parent.left
				anchors.leftMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				visible: typed.text === ""
				text: "Hold the key to try it"
				tone: Theme.textSubtle
			}
		}
	}
}
