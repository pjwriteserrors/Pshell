import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The weather right now; opens the same panel as the clock.
BarButton {
	id: root

	panelId: "today"
	primaryAnchor: false
	tooltip: `${Weather.description} · ${Weather.location}`
	padding: 8
	visible: Weather.available
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
