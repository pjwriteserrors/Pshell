pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The ACE: its spools on a shelf (AceShelf: the one feeding turns, its
// filament runs up to the printer), the air in the box, and drying – a
// preset for the material and a ring that counts down.
Item {
	id: root

	readonly property var box: Printer.ace
	readonly property var drying: root.box?.drying ?? null
	property int preset: 0

	RowLayout {
		anchors.fill: parent
		spacing: 18

		Rectangle {
			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.minimumWidth: 360
			radius: Theme.radius.huge
			color: Theme.layer1
			border.width: 1
			border.color: Theme.outline

			// a soft light from above
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.alpha(Printer.printing ? Printer.hot : Theme.primary, 0.06)
					}
					GradientStop {
						position: 0.6
						color: "transparent"
					}
				}
			}

			AceShelf {
				anchors.fill: parent
				anchors.margins: 14
				visible: Printer.slots.length > 0
			}
		}

		// ── the air in the box, drying ───────────────────────────────────
		ColumnLayout {
			Layout.preferredWidth: 280
			Layout.maximumWidth: 280
			Layout.fillHeight: true
			spacing: 12

			RowLayout {
				Layout.fillWidth: true

				SectionLabel {
					Layout.fillWidth: true
					text: "Inside the ACE"
				}

				AceSync {}
			}

			RowLayout {
				spacing: 16

				Repeater {
					model: [
						{ label: "Humidity", value: root.box?.humidity ?? 0, unit: "%", max: 100, icon: "water_percent", color: Theme.secondary },
						{ label: "Temperature", value: root.box?.temp ?? 0, unit: "°C", max: 70, icon: "thermometer", color: Printer.hot }
					]

					delegate: Item {
						id: gauge

						required property var modelData

						Layout.preferredWidth: 110
						Layout.preferredHeight: 110

						Ring {
							anchors.fill: parent
							value: gauge.modelData.value > 0 ? gauge.modelData.value / gauge.modelData.max : 0
							thickness: 7
							sweep: 270
							color: gauge.modelData.color
						}

						Column {
							anchors.centerIn: parent
							spacing: 0

							Glyph {
								anchors.horizontalCenter: parent.horizontalCenter
								icon: gauge.modelData.icon
								size: 15
								color: gauge.modelData.color
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: gauge.modelData.value > 0 ? `${gauge.modelData.value}${gauge.modelData.unit}` : "–"
								font.pixelSize: 22
								font.weight: Font.Bold
								tabular: true
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: gauge.modelData.label
								tone: Theme.textMuted
								font.pixelSize: Theme.size.tiny
							}
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: "The ACE reports the air only while it feeds or dries."
				visible: !(root.box?.humidity > 0)
				wrapMode: Text.Wrap
				tone: Theme.textFaint
				font.pixelSize: Theme.size.small
			}

			SectionLabel {
				Layout.topMargin: 8
				text: "Drying"
			}

			// drying now: the time left as a ring
			RowLayout {
				Layout.fillWidth: true
				visible: Printer.drying
				spacing: 14

				Item {
					Layout.preferredWidth: 64
					Layout.preferredHeight: 64

					Ring {
						anchors.fill: parent
						value: root.drying && root.drying.duration > 0 ? 1 - root.drying.remain_time / root.drying.duration : 0
						thickness: 5
						color: Printer.hot
					}

					Glyph {
						anchors.centerIn: parent
						icon: "fan"
						size: 20
						color: Printer.hot

						RotationAnimation on rotation {
							running: Printer.drying && root.visible
							from: 0
							to: 360
							duration: 1600
							loops: Animation.Infinite
						}
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						text: `Drying at ${root.drying?.target_temp ?? 0}°C`
						font.weight: Font.DemiBold
					}

					StyledText {
						text: `${Printer.duration(Number(root.drying?.remain_time ?? 0) * 60)} left`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						tabular: true
					}
				}
			}

			// not drying: a preset and the button
			Flow {
				Layout.fillWidth: true
				visible: !Printer.drying
				spacing: 6

				Repeater {
					model: Printer.dryPresets

					delegate: Chip {
						required property var modelData
						required property int index

						text: `${modelData.label} · ${modelData.temp}° · ${modelData.minutes / 60} h`
						selected: root.preset === index
						onClicked: root.preset = index
					}
				}
			}

			TextButton {
				Layout.fillWidth: true
				text: Printer.drying ? "Stop drying" : "Start drying"
				icon: Printer.drying ? "stop" : "fan"
				variant: Printer.drying ? "danger" : "tonal"
				confirm: true
				confirmText: Printer.drying ? "Stop it?" : `Dry at ${Printer.dryPresets[root.preset].temp}°?`
				enabled: Printer.online && root.box !== null
				onActivated: Printer.drying ? Printer.stopDrying() : Printer.dry(Printer.dryPresets[root.preset])
			}

			Item {
				Layout.fillHeight: true
			}
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: Printer.slots.length === 0
		icon: "palette"
		title: Printer.online ? "The ACE has not answered yet" : "The printer is offline"
	}
}
