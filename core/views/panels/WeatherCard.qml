pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Current conditions, the next hours and a five day outlook with range bars.
Rectangle {
	id: root

	implicitHeight: column.implicitHeight + 28
	radius: Theme.radius.huge
	color: Theme.layer1

	readonly property int weekMin: Weather.daily.reduce((m, d) => Math.min(m, d.min), 99)
	readonly property int weekMax: Weather.daily.reduce((m, d) => Math.max(m, d.max), -99)

	ColumnLayout {
		id: column

		x: 16
		y: 14
		width: parent.width - 32
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Glyph {
				icon: Weather.icon
				size: 42
				color: Theme.secondary
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					text: Weather.temperature
					font.pixelSize: Theme.size.display
					font.weight: Font.Bold
					tabular: true
				}

				StyledText {
					Layout.fillWidth: true
					text: `${Weather.description} · feels ${Weather.feelsLike}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			ColumnLayout {
				spacing: 3

				RowLayout {
					Layout.alignment: Qt.AlignRight
					spacing: 4
					Glyph { icon: "weather_sunset_up"; size: 14; color: Theme.primary }
					StyledText { text: Weather.sunrise; tabular: true; font.pixelSize: Theme.size.small }
				}
				RowLayout {
					Layout.alignment: Qt.AlignRight
					spacing: 4
					Glyph { icon: "weather_sunset_down"; size: 14; color: Theme.tertiary }
					StyledText { text: Weather.sunset; tabular: true; font.pixelSize: Theme.size.small }
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: [
					{ icon: "water_percent", text: Weather.humidity },
					{ icon: "weather_windy", text: Weather.wind },
					{ icon: "umbrella", text: Weather.precipitation },
					{ icon: "gauge", text: Weather.pressure }
				]

				delegate: Rectangle {
					required property var modelData

					height: 26
					width: metric.implicitWidth + 18
					radius: 13
					color: Theme.layer2

					RowLayout {
						id: metric

						anchors.centerIn: parent
						spacing: 4
						Glyph { icon: modelData.icon; size: 13; color: Theme.textMuted }
						StyledText { text: modelData.text; tabular: true; font.pixelSize: Theme.size.small; font.weight: Font.Medium }
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: Weather.hourly.length > 0
			spacing: 0

			Repeater {
				model: Weather.hourly

				delegate: Column {
					required property var modelData
					required property int index

					Layout.fillWidth: true
					Layout.preferredWidth: 1
					spacing: 3

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: modelData.label
						tone: index === 0 ? Theme.primary : Theme.textSubtle
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Bold
					}
					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: modelData.icon
						size: 18
						color: Theme.text
					}
					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: `${modelData.temp}°`
						tabular: true
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: Weather.daily.length > 0
			spacing: 4

			Repeater {
				model: Weather.daily

				delegate: RowLayout {
					id: dayRow

					required property var modelData

					Layout.fillWidth: true
					spacing: 8

					StyledText {
						Layout.preferredWidth: 42
						text: dayRow.modelData.label
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
					Glyph {
						icon: dayRow.modelData.icon
						size: 16
					}
					StyledText {
						Layout.preferredWidth: 26
						horizontalAlignment: Text.AlignRight
						text: `${dayRow.modelData.min}°`
						tone: Theme.textMuted
						tabular: true
						font.pixelSize: Theme.size.small
					}
					Item {
						Layout.fillWidth: true
						implicitHeight: 6

						Rectangle {
							anchors.fill: parent
							radius: 3
							color: Theme.layer3
						}

						Rectangle {
							readonly property real span: Math.max(1, root.weekMax - root.weekMin)
							x: parent.width * (dayRow.modelData.min - root.weekMin) / span
							width: Math.max(6, parent.width * (dayRow.modelData.max - dayRow.modelData.min) / span)
							height: parent.height
							radius: 3
							gradient: Gradient {
								orientation: Gradient.Horizontal
								GradientStop { position: 0; color: Theme.secondary }
								GradientStop { position: 1; color: Theme.primary }
							}
						}
					}
					StyledText {
						Layout.preferredWidth: 26
						text: `${dayRow.modelData.max}°`
						tabular: true
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: `${Weather.location}${Weather.observationTime !== "" ? " · updated " + Qt.formatDateTime(new Date(Weather.observationTime), "HH:mm") : ""}`
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny
		}
	}
}
