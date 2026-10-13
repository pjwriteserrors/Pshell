pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The 3D printer, the same under the bar (PrinterPanel) and in a window of
// its own (PrinterWindow): a header with what the printer does and its
// light, camera and pop-out; then the pages – the print with the part in
// 3D, the ACE, the statistics – sliding into each other; below, the jobs.
Item {
	id: root

	// in a window the part gets the room there is
	property bool windowed: false
	readonly property int page: ["print", "ace", "stats"].indexOf(Printer.tab)

	implicitHeight: layout.implicitHeight

	ColumnLayout {
		id: layout

		anchors.fill: parent
		spacing: 14

		// ── header ───────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			// the printer's mark, ringed by the progress while it prints
			Item {
				Layout.preferredWidth: 44
				Layout.preferredHeight: 44

				Ring {
					anchors.fill: parent
					value: Printer.progress
					thickness: 3
					color: Printer.hot
					trackColor: Printer.printing ? Theme.layer3 : "transparent"
				}

				Rectangle {
					anchors.centerIn: parent
					width: 34
					height: 34
					radius: 17
					color: Printer.printing ? Qt.alpha(Printer.hot, 0.16) : Theme.primarySoft

					Behavior on color {
						ColorAnim {}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "printer_3d"
						size: 19
						color: Printer.printing ? Printer.hot : Theme.primary
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: Words.of("printer.title", Printer.name)
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				RowLayout {
					spacing: 6

					Rectangle {
						id: pulse

						Layout.preferredWidth: 7
						Layout.preferredHeight: 7
						radius: 4
						color: !Printer.online ? Theme.danger : (Printer.printing ? Printer.hot : Theme.success)

						SequentialAnimation on opacity {
							running: Printer.printing && !Printer.paused
							loops: Animation.Infinite
							onRunningChanged: if (!running) pulse.opacity = 1
							NumberAnimation {
								to: 0.3
								duration: 800
								easing.type: Easing.InOutSine
							}
							NumberAnimation {
								to: 1
								duration: 800
								easing.type: Easing.InOutSine
							}
						}
					}

					StyledText {
						text: Printer.status + (Printer.firmware ? ` · ${Printer.firmware}` : "")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}
				}
			}

			Repeater {
				model: Printer.online ? [
					{ icon: "printer_3d_nozzle", now: Number(Printer.temps.curr_nozzle_temp ?? 0), target: Number(Printer.temps.target_nozzle_temp ?? 0), label: "Nozzle" },
					{ icon: "radiator", now: Number(Printer.temps.curr_hotbed_temp ?? 0), target: Number(Printer.temps.target_hotbed_temp ?? 0), label: "Bed" }
				] : []

				delegate: TempChip {}
			}

			Item {
				Layout.preferredWidth: 4
			}

			IconButton {
				icon: Printer.light ? "lightbulb_on" : "lightbulb_outline"
				checked: Printer.light
				enabled: Printer.online
				onClicked: Printer.setLight(!Printer.light)
			}

			IconButton {
				icon: Printer.camera ? "video" : "video_off"
				checked: Printer.camera
				enabled: Printer.online && Printer.cameraUrl !== ""
				onClicked: Printer.setCamera(!Printer.camera)
			}

			IconButton {
				icon: root.windowed ? "dock_window" : "open_in_new"
				onClicked: root.windowed ? Printer.dock() : Printer.popOut()
			}
		}

		// ── not set up yet ───────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			visible: !Printer.configured
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				text: "Where is the printer? Its address is on the printer under Settings → Network, with LAN mode on."
				wrapMode: Text.Wrap
				tone: Theme.textMuted
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					id: address

					Layout.fillWidth: true
					placeholder: "192.168.…"
					icon: "lan"
					onAccepted: Printer.setAddress(address.text)
				}

				TextButton {
					text: "Connect"
					variant: "filled"
					onActivated: Printer.setAddress(address.text)
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			Layout.preferredHeight: 36
			visible: Printer.configured
			options: [
				{ value: "print", label: "Print", icon: "printer_3d" },
				{ value: "ace", label: "ACE", icon: "palette" },
				{ value: "stats", label: "Statistics", icon: "chart_bar" }
			]
			current: Printer.tab
			onSelected: value => Printer.tab = value
		}

		// ── the pages, sliding into each other ───────────────────────────
		Item {
			id: pages

			Layout.fillWidth: true
			Layout.fillHeight: root.windowed
			Layout.preferredHeight: root.windowed ? -1 : 430
			Layout.minimumHeight: 400
			visible: Printer.configured
			clip: true

			Repeater {
				model: 3

				delegate: Loader {
					id: holder

					required property int index
					readonly property bool current: holder.index === root.page
					// once seen, a page stays: the part keeps its turn
					property bool seen: holder.current

					onCurrentChanged: if (holder.current) holder.seen = true

					width: pages.width
					height: pages.height
					active: holder.seen
					visible: opacity > 0.01
					opacity: holder.current ? 1 : 0
					x: holder.current ? 0 : (holder.index < root.page ? -48 : 48)
					sourceComponent: [printPage, acePage, statsPage][holder.index]

					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}
					Behavior on x {
						SpatialAnim {}
					}
				}
			}
		}

		// ── the jobs that came in ────────────────────────────────────────
		JobStrip {
			Layout.fillWidth: true
			visible: Printer.configured && Printer.jobs.length > 0 && Printer.tab === "print"
		}
	}

	Component {
		id: printPage

		PrintPage {
			windowed: root.windowed
		}
	}

	Component {
		id: acePage

		AcePage {}
	}

	Component {
		id: statsPage

		StatsPage {}
	}

	component TempChip: Rectangle {
		id: chip

		required property var modelData
		readonly property bool heating: chip.modelData.target > 0 && Math.abs(chip.modelData.target - chip.modelData.now) > 3

		Layout.preferredHeight: 30
		Layout.preferredWidth: chipRow.implicitWidth + 20
		radius: 15
		color: chip.modelData.target > 0 ? Qt.alpha(Printer.hot, 0.12) : Theme.layer1
		border.width: 1
		border.color: chip.modelData.target > 0 ? Qt.alpha(Printer.hot, 0.3) : Theme.outline

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			id: chipRow

			anchors.centerIn: parent
			spacing: 5

			Glyph {
				id: flame

				icon: chip.modelData.icon
				size: 14
				color: chip.modelData.target > 0 ? Printer.hot : Theme.textMuted

				SequentialAnimation on opacity {
					running: chip.heating
					loops: Animation.Infinite
					onRunningChanged: if (!running) flame.opacity = 1
					NumberAnimation {
						to: 0.35
						duration: 600
					}
					NumberAnimation {
						to: 1
						duration: 600
					}
				}
			}

			StyledText {
				text: `${Math.round(chip.modelData.now)}°` + (chip.modelData.target > 0 ? ` / ${Math.round(chip.modelData.target)}°` : "")
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
				tabular: true
			}
		}
	}
}
