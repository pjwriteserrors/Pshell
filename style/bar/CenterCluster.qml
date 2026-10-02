import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Centre of the bar: clock (the date slides out on hover), current weather
// and the qtrack timer as a live activity that is always visible. A screen
// recording joins as a second live activity while it runs.
Row {
	id: root

	required property var bar

	// width without the hover date and the timer's project name, and what
	// the name would add; the bar hands back the room it can spare
	readonly property real fixedWidth: {
		let sum = 0;
		let shown = 0;
		for (let i = 0; i < root.children.length; i += 1) {
			const child = root.children[i];
			if (!child.visible || child === timer) continue;
			sum += child === clockButton ? clockButton.padding * 2 + time.implicitWidth : child.width;
			shown += 1;
		}
		return timer.visible ? sum + timer.fixedWidth + root.spacing * shown : sum + root.spacing * Math.max(0, shown - 1);
	}
	readonly property real textWant: timer.visible ? timer.textWant : 0
	property alias room: timer.room
	readonly property real dateWidth: date.implicitWidth + 9
	property bool dateFits: true

	spacing: 4

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	BarButton {
		id: clockButton

		bar: root.bar
		panelId: "today"
		tooltip: "Calendar & notifications"
		padding: 12
		visible: Plugins.on("clock")
		onClicked: toggle()

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 0

			Item {
				id: dateSlot

				anchors.verticalCenter: parent.verticalCenter
				width: root.dateFits && (clockButton.hovered || clockButton.active) ? root.dateWidth : 0
				height: date.implicitHeight
				clip: true

				Behavior on width {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				StyledText {
					id: date

					text: Qt.formatDateTime(clock.date, "ddd d MMM")
					tone: Theme.textMuted
					font.pixelSize: Theme.size.body
					font.weight: Font.Medium
					elide: Text.ElideNone
				}
			}

			StyledText {
				id: time

				anchors.verticalCenter: parent.verticalCenter
				text: Qt.formatDateTime(clock.date, "HH:mm")
				tabular: true
				font.pixelSize: 15
				font.weight: Font.Bold
				tone: clockButton.active ? Theme.primary : Theme.text
			}
		}
	}

	BarButton {
		bar: root.bar
		panelId: "today"
		primaryAnchor: false
		tooltip: `${Weather.description} · ${Weather.location}`
		padding: 8
		visible: Plugins.on("weather") && Weather.available
		onClicked: toggle()

		Row {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 5

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: Weather.icon
				size: 17
				color: Theme.secondary
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: Weather.temperature
				tabular: true
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}
		}
	}

	TimerChip {
		id: timer

		bar: root.bar
		visible: Plugins.on("qtrack")
	}

	RecordingChip {
		bar: root.bar
	}
}
