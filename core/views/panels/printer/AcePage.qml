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

	// the page shows: its cards rise in again
	property bool current: true
	readonly property var box: Printer.ace
	readonly property var drying: root.box?.drying ?? null
	property int preset: 0

	RowLayout {
		anchors.fill: parent
		spacing: 16
		visible: Printer.slots.length > 0

		Card {
			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.minimumWidth: 360
			order: 0
			cue: root.current
			clip: true

			// a soft light from above
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.alpha(Printer.printing ? Printer.hot : Theme.primary, 0.1)
					}
					GradientStop {
						position: 0.7
						color: "transparent"
					}
				}
			}

			AceShelf {
				anchors.fill: parent
				anchors.margins: 14
			}

			// how many are in, at the bottom
			Row {
				anchors.left: parent.left
				anchors.bottom: parent.bottom
				anchors.margins: 16
				spacing: 6

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "palette"
					size: 14
					color: Theme.textMuted
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: {
						const loaded = Printer.slots.filter(slot => slot.type !== "").length;
						return `${loaded} of ${Printer.slots.length} slots loaded`;
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			AceSync {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 12
			}
		}

		ColumnLayout {
			Layout.preferredWidth: 300
			Layout.maximumWidth: 300
			Layout.fillHeight: true
			spacing: 12

			// ── the air in the box ───────────────────────────────────────
			Card {
				Layout.fillWidth: true
				Layout.preferredHeight: climate.implicitHeight + 28
				order: 1
				cue: root.current

				ColumnLayout {
					id: climate

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 14
					spacing: 10

					SectionLabel {
						text: "Inside the ACE"
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Repeater {
							model: [
								{ label: "Humidity", value: Number(root.box?.humidity ?? 0), unit: "%", max: 100, icon: "water_percent", color: Theme.secondary },
								{ label: "Temperature", value: Number(root.box?.temp ?? 0), unit: "°C", max: 70, icon: "thermometer", color: Printer.hot }
							]

							delegate: Item {
								id: gauge

								required property var modelData
								property real shown: gauge.modelData.value

								Behavior on shown {
									NumberAnimation {
										duration: 1000
										easing.type: Easing.OutCubic
									}
								}

								Layout.fillWidth: true
								Layout.preferredHeight: 116

								Ring {
									anchors.centerIn: parent
									width: 112
									height: 112
									value: gauge.modelData.value > 0 ? gauge.modelData.value / gauge.modelData.max : 0
									thickness: 8
									sweep: 270
									color: gauge.modelData.color
								}

								Column {
									anchors.centerIn: parent
									spacing: 0

									Glyph {
										anchors.horizontalCenter: parent.horizontalCenter
										icon: gauge.modelData.icon
										size: 16
										color: gauge.modelData.color
									}

									StyledText {
										anchors.horizontalCenter: parent.horizontalCenter
										text: gauge.modelData.value > 0 ? `${Math.round(gauge.shown)}${gauge.modelData.unit}` : "–"
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
						horizontalAlignment: Text.AlignHCenter
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}

			// ── drying ───────────────────────────────────────────────────
			Card {
				Layout.fillWidth: true
				Layout.fillHeight: true
				order: 2
				cue: root.current
				color: Printer.drying ? Qt.tint(Theme.layer1, Qt.alpha(Printer.hot, 0.08)) : Theme.layer1

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 14
					spacing: 10

					SectionLabel {
						text: "Drying"
					}

					// drying now: the time left as a ring, the fan turning
					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true
						visible: Printer.drying

						Item {
							id: dial

							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: parent.top
							width: 104
							height: 104

							// the warmth going up from it
							Repeater {
								model: 3

								delegate: Rectangle {
									id: heat

									required property int index

									anchors.centerIn: parent
									width: 104
									height: 104
									radius: 52
									color: "transparent"
									border.width: 2
									border.color: Printer.hot
									opacity: 0

									SequentialAnimation {
										running: Printer.drying && root.visible
										loops: Animation.Infinite
										PauseAnimation { duration: heat.index * 700 }
										ParallelAnimation {
											NumberAnimation { target: heat; property: "scale"; from: 0.9; to: 1.35; duration: 2100; easing.type: Easing.OutCubic }
											NumberAnimation { target: heat; property: "opacity"; from: 0.4; to: 0; duration: 2100; easing.type: Easing.OutCubic }
										}
										PauseAnimation { duration: (2 - heat.index) * 700 }
									}
								}
							}

							Ring {
								anchors.fill: parent
								value: root.drying && root.drying.duration > 0 ? 1 - root.drying.remain_time / root.drying.duration : 0
								thickness: 7
								color: Printer.hot
							}

							Glyph {
								anchors.centerIn: parent
								icon: "fan"
								size: 34
								color: Printer.hot

								RotationAnimation on rotation {
									running: Printer.drying && root.visible
									from: 0
									to: 360
									duration: 1400
									loops: Animation.Infinite
								}
							}
						}

						Column {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.top: dial.bottom
							anchors.topMargin: 12
							spacing: 2

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: `Drying at ${root.drying?.target_temp ?? 0}°C`
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: `${Printer.duration(Number(root.drying?.remain_time ?? 0) * 60)} left`
								tone: Theme.textMuted
								font.pixelSize: Theme.size.label
								tabular: true
							}
						}
					}

					// not drying: a preset for the material
					GridLayout {
						Layout.fillWidth: true
						visible: !Printer.drying
						columns: 2
						columnSpacing: 8
						rowSpacing: 8

						Repeater {
							model: Printer.dryPresets

							delegate: Clickable {
								id: choice

								required property var modelData
								required property int index
								readonly property bool on: root.preset === choice.index

								Layout.fillWidth: true
								Layout.preferredHeight: 58
								radius: choice.on ? Theme.radius.large : 29
								color: choice.on ? Theme.primaryContainer : (choice.hovered ? Theme.layer3 : Theme.layer2)
								onClicked: root.preset = choice.index

								Behavior on radius {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 10
									anchors.rightMargin: 10
									spacing: 8

									Rectangle {
										Layout.preferredWidth: 32
										Layout.preferredHeight: 32
										radius: 16
										color: choice.on ? Theme.primary : Theme.layer3

										Behavior on color {
											ColorAnim {}
										}

										Glyph {
											anchors.centerIn: parent
											icon: choice.on ? "check" : "fan"
											size: 16
											color: choice.on ? Theme.onPrimary : Theme.textMuted
										}
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: -1

										StyledText {
											text: choice.modelData.label
											font.pixelSize: Theme.size.body
											font.weight: Font.Bold
										}

										StyledText {
											text: `${choice.modelData.temp}° · ${choice.modelData.minutes / 60} h`
											tone: Theme.textMuted
											font.pixelSize: Theme.size.small
											tabular: true
										}
									}
								}
							}
						}
					}

					Item {
						Layout.fillHeight: true
						visible: !Printer.drying
					}

					TextButton {
						Layout.fillWidth: true
						Layout.preferredHeight: 44
						text: Printer.drying ? "Stop drying" : "Start drying"
						icon: Printer.drying ? "stop" : "fan"
						variant: Printer.drying ? "danger" : "filled"
						confirm: true
						confirmText: Printer.drying ? "Stop it?" : `Dry at ${Printer.dryPresets[root.preset].temp}°?`
						enabled: Printer.online && root.box !== null
						onActivated: Printer.drying ? Printer.stopDrying() : Printer.dry(Printer.dryPresets[root.preset])
					}
				}
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
