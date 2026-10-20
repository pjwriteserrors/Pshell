import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The clock; the date slides out on hover when the bar has room for it.
BarButton {
	id: root

	// width without the date
	readonly property real fixedWidth: root.padding * 2 + time.implicitWidth
	readonly property real dateWidth: date.implicitWidth + 9
	readonly property bool dateFits: (root.bar?.sideSlack ?? 1e6) >= root.dateWidth / 2

	panelId: "today"
	tooltip: "Calendar & notifications"
	padding: 12
	onClicked: toggle()

	SystemClock {
		id: clock
		precision: SystemClock.Minutes
	}

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 0

		Item {
			anchors.verticalCenter: parent.verticalCenter
			width: root.dateFits && (root.hovered || root.active) ? root.dateWidth : 0
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
			tone: root.active ? Theme.primary : Theme.text
		}
	}
}
