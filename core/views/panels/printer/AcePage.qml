pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The ACE: its four spools as cards (the one feeding turns), the air in the
// box, and drying – a preset for the material and a ring that counts down.
Item {
	id: root

	readonly property var box: Printer.ace
	readonly property var drying: root.box?.drying ?? null
	property int preset: 0

	RowLayout {
		anchors.fill: parent
		spacing: 18

		GridLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.minimumWidth: 360
			columns: 2
			rowSpacing: 12
			columnSpacing: 12

			Repeater {
				model: Printer.slots

				delegate: Rectangle {
					id: card

					required property var modelData
					required property int index
					readonly property bool empty: card.modelData.type === ""
					readonly property bool feeding: (root.box?.loaded ?? -1) === card.modelData.index

					Layout.fillWidth: true
					Layout.fillHeight: true
					radius: Theme.radius.huge
					color: Theme.layer1
					border.width: 1
					border.color: card.feeding ? Qt.alpha(Printer.hot, 0.5) : Theme.outline
					opacity: 0
					scale: 0.94

					Component.onCompleted: appear.start()

					SequentialAnimation {
						id: appear

						PauseAnimation {
							duration: card.index * 70
						}
						ParallelAnimation {
							NumberAnimation {
								target: card
								property: "opacity"
								to: 1
								duration: 300
							}
							NumberAnimation {
								target: card
								property: "scale"
								to: 1
								duration: 450
								easing.type: Easing.OutBack
							}
						}
					}

					// the filament's colour, softly behind the spool
					Rectangle {
						anchors.left: parent.left
						anchors.top: parent.top
						anchors.bottom: parent.bottom
						width: parent.width * 0.5
						radius: parent.radius
						visible: !card.empty
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop {
								position: 0
								color: Qt.alpha(Printer.rgb(card.modelData.color), 0.16)
							}
							GradientStop {
								position: 1
								color: "transparent"
							}
						}
					}

					RowLayout {
						anchors.fill: parent
						anchors.margins: 16
						spacing: 16

						Spool {
							Layout.preferredWidth: 74
							Layout.preferredHeight: 74
							slot: card.modelData
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							StyledText {
								Layout.fillWidth: true
								text: card.empty ? "Empty" : card.modelData.type
								font.pixelSize: Theme.size.title
								font.weight: Font.DemiBold
								tone: card.empty ? Theme.textFaint : Theme.text
							}

							StyledText {
								Layout.fillWidth: true
								visible: !card.empty
								text: {
									const c = card.modelData.color;
									const hex = "#" + c.map(v => v.toString(16).padStart(2, "0")).join("").toUpperCase();
									return card.modelData.sku ? `${hex} · ${card.modelData.sku}` : hex;
								}
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
								font.family: Theme.monoFamily
							}

							Rectangle {
								Layout.topMargin: 6
								Layout.preferredHeight: 20
								Layout.preferredWidth: badge.implicitWidth + 16
								radius: 10
								visible: !card.empty
								color: card.feeding ? Qt.alpha(Printer.hot, 0.16) : Theme.layer2

								StyledText {
									id: badge

									anchors.centerIn: parent
									text: card.feeding ? "Feeding" : `Slot ${card.modelData.slot + 1} · ready`
									font.pixelSize: Theme.size.tiny
									font.weight: Font.DemiBold
									tone: card.feeding ? Printer.hot : Theme.textMuted
								}
							}
						}
					}
				}
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
