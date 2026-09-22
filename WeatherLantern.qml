pragma ComponentBehavior: Bound

import QtQuick
import "components"

// The weather as a reading on a wire: the condition large, then each
// measure as a short filament lit by how much of its range it fills, and
// the day drawn as an arc from sunrise to sunset with the sun where it is.
Item {
	id: weather

	property real reveal: 1
	property string location: ""
	property string temperature: "--"
	property string icon: "weather-overcast-symbolic"
	property string description: ""
	property string feelsLike: "--"
	property string humidity: "--"
	property string wind: "--"
	property string precipitation: "--"
	property string pressure: "--"
	property string sunrise: "--"
	property string sunset: "--"
	property string observationTime: ""
	readonly property bool ready: temperature !== "--"

	signal refreshRequested()

	implicitHeight: column.implicitHeight

	function numberOf(text) {
		const match = String(text).match(/-?[0-9.]+/);
		return match ? Number(match[0]) : NaN;
	}

	function minutesOf(hhmm) {
		const match = String(hhmm).match(/^(\d+):(\d+)$/);
		return match ? Number(match[1]) * 60 + Number(match[2]) : NaN;
	}

	readonly property real dayProgress: {
		const rise = minutesOf(sunrise), set = minutesOf(sunset);
		if (!isFinite(rise) || !isFinite(set) || set <= rise) return -1;
		const now = new Date();
		const minutes = now.getHours() * 60 + now.getMinutes();
		return Math.max(0, Math.min(1, (minutes - rise) / (set - rise)));
	}

	readonly property var measures: [
		{ label: "feels like", value: feelsLike, level: (numberOf(feelsLike) + 10) / 45 },
		{ label: "humidity", value: humidity, level: numberOf(humidity) / 100 },
		{ label: "wind", value: wind, level: numberOf(wind) / 60 },
		{ label: "rain", value: precipitation, level: numberOf(precipitation) / 10 },
		{ label: "pressure", value: pressure, level: (numberOf(pressure) - 960) / 90 }
	]

	Column {
		id: column
		width: parent.width
		spacing: 12

		Band {
			reveal: weather.reveal
			order: 0
			width: parent.width
			height: 64

			FIcon {
				id: bigIcon
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				name: weather.icon
				fallbacks: ["weather-overcast-symbolic"]
				size: 44
				color: weather.ready ? Filament.charge2 : Filament.inkMute
			}

			Column {
				anchors.left: bigIcon.right
				anchors.leftMargin: 14
				anchors.verticalCenter: parent.verticalCenter
				spacing: 2
				Row {
					spacing: 8
					FText {
						text: weather.temperature
						mono: true
						font.pixelSize: Filament.textDisplay
						font.weight: Font.DemiBold
					}
					FText {
						anchors.baseline: parent.children[0].baseline
						text: weather.description
						tone: "soft"
						font.pixelSize: Filament.textMd
					}
				}
				FText {
					text: weather.location
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}

			FButton {
				anchors.right: parent.right
				anchors.top: parent.top
				icon: "view-refresh-symbolic"
				kind: "ghost"
				square: true
				compact: true
				tooltip: "Refresh"
				onClicked: weather.refreshRequested()
			}
		}

		Repeater {
			model: weather.measures
			Band {
				id: measure
				required property var modelData
				required property int index
				reveal: weather.reveal
				order: 1 + index
				width: column.width
				height: 22

				FText {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 78
					text: measure.modelData.label
					tone: "mute"
					caps: true
					font.pixelSize: Filament.textXs
				}

				Wire {
					x: 86
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width - 86 - 70
					height: 2
					cold: Filament.wireDim
					hot: Filament.charge2
					lit: isFinite(measure.modelData.level) ? Math.max(0, Math.min(1, measure.modelData.level)) : 0
				}

				FText {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					text: measure.modelData.value
					mono: true
					font.pixelSize: Filament.textSm
				}
			}
		}

		// The day: sunrise at the left knot, sunset at the right, the sun on
		// the arc where the hour puts it.
		Band {
			reveal: weather.reveal
			order: 7
			width: parent.width
			height: 58

			Canvas {
				id: arc
				anchors.fill: parent
				property real progress: weather.dayProgress
				property color wireColor: Filament.wireDim
				property color hotColor: Filament.charge
				onProgressChanged: requestPaint()
				onWireColorChanged: requestPaint()
				onPaint: {
					const ctx = getContext("2d");
					ctx.clearRect(0, 0, width, height);
					const left = 30, right = width - 30, baseY = height - 14, top = 8;
					ctx.lineWidth = 2;
					ctx.lineCap = "round";
					const draw = (to, color) => {
						ctx.beginPath();
						ctx.strokeStyle = color;
						const steps = 40;
						for (let i = 0; i <= steps * to; i += 1) {
							const t = i / steps;
							const x = left + (right - left) * t;
							const y = baseY - Math.sin(t * Math.PI) * (baseY - top);
							if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
						}
						ctx.stroke();
					};
					draw(1, wireColor);
					if (progress >= 0) draw(progress, hotColor);
				}
			}

			Spark {
				visible: weather.dayProgress >= 0
				x: 30 + (parent.width - 60) * Math.max(0, weather.dayProgress) - 4
				y: (parent.height - 14) - Math.sin(Math.max(0, weather.dayProgress) * Math.PI) * (parent.height - 22) - 4
				size: 8
				breathing: true
			}

			FText {
				anchors.left: parent.left
				anchors.bottom: parent.bottom
				text: "↑ " + weather.sunrise
				mono: true
				tone: "soft"
				font.pixelSize: Filament.textXs
			}
			FText {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				text: weather.sunset + " ↓"
				mono: true
				tone: "soft"
				font.pixelSize: Filament.textXs
			}
			FText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				text: weather.observationTime !== "" ? "read " + Qt.formatDateTime(new Date(weather.observationTime), "HH:mm") : ""
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}
}
