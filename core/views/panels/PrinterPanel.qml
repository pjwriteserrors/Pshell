pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.printer

// The 3D printer. Left the part as far as it is printed (or, for a job not
// started yet, built up once and scrubbed by dragging); right what the
// printer does, or for a new job its filaments with the ACE slot each comes
// from and the button that prints it. Below, the jobs that came in.
Drawer {
	id: root

	panelId: "printer"
	panelWidth: 840
	centered: true
	contentHeight: layout.implicitHeight

	// the job shown: the one picked, else the one printing
	readonly property var job: Printer.job(Printer.selected) ?? Printer.printingJob
	readonly property bool showsLive: Printer.printing && (root.job === null || root.job === Printer.printingJob)
	property var mapping: []
	readonly property bool mapped: root.mapping.length > 0 && root.mapping.every(pick => pick.slot >= 0)
	readonly property bool sending: root.job !== null && (root.job.status === "uploading" || Printer.uploads[root.job.id] !== undefined)

	function remap() {
		root.mapping = Printer.suggestAll(root.job);
	}

	function pick(tool, slot) {
		root.mapping = root.mapping.map(entry => entry.tool === tool ? { tool, slot } : entry);
	}

	onJobChanged: root.remap()
	onPanelOpened: {
		Printer.refresh();
		root.remap();
	}

	Connections {
		target: Printer

		// the ACE answered after the job was picked: fill what is still open
		function onSlotsChanged() {
			if (root.mapping.some(pick => pick.slot < 0)) root.remap();
		}
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 16

		// ── header ───────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Glyph {
				icon: "printer_3d"
				size: 26
				color: Theme.primary
			}

			ColumnLayout {
				spacing: 0

				StyledText {
					text: Words.of("printer.title", Printer.name)
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				RowLayout {
					spacing: 6

					Rectangle {
						Layout.preferredWidth: 7
						Layout.preferredHeight: 7
						radius: 4
						color: !Printer.online ? Theme.danger : (Printer.printing ? Printer.hot : Theme.success)
					}

					StyledText {
						text: Printer.status + (Printer.firmware ? ` · ${Printer.firmware}` : "")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Repeater {
				model: Printer.online ? [
					{ icon: "printer_3d_nozzle", now: Printer.temps.curr_nozzle_temp, target: Printer.temps.target_nozzle_temp },
					{ icon: "radiator", now: Printer.temps.curr_hotbed_temp, target: Printer.temps.target_hotbed_temp }
				] : []

				delegate: RowLayout {
					id: temp

					required property var modelData

					spacing: 4

					Glyph {
						icon: temp.modelData.icon
						size: 15
						color: (temp.modelData.target ?? 0) > 0 ? Printer.hot : Theme.textMuted
					}

					StyledText {
						text: `${Math.round(temp.modelData.now ?? 0)}°` + ((temp.modelData.target ?? 0) > 0 ? ` / ${temp.modelData.target}°` : "")
						font.pixelSize: Theme.size.label
						tabular: true
					}
				}
			}

			IconButton {
				icon: "refresh"
				onClicked: Printer.refresh()
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

		// ── stage and side ───────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: Printer.configured
			spacing: 18

			Stage {
				Layout.preferredWidth: 470
				Layout.preferredHeight: 352
				job: root.job
				liveLayer: root.showsLive ? Number(Printer.project.curr_layer ?? 0) : -1
			}

			// what the printer does
			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.showsLive
				spacing: 12

				StyledText {
					Layout.fillWidth: true
					text: root.job ? Printer.title(root.job) : String(Printer.project?.filename ?? "")
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					wrapMode: Text.Wrap
					maximumLineCount: 2
				}

				RowLayout {
					spacing: 8

					StyledText {
						text: `${Math.round(Printer.progress * 100)}`
						font.pixelSize: Theme.size.hero
						font.weight: Font.Bold
						tabular: true
					}

					ColumnLayout {
						spacing: 0

						StyledText {
							text: "%"
							font.pixelSize: Theme.size.title
							tone: Theme.textMuted
						}

						StyledText {
							text: Printer.status
							font.pixelSize: Theme.size.label
							tone: Printer.paused ? Theme.warning : Theme.textMuted
						}
					}
				}

				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 10

					Rectangle {
						anchors.fill: parent
						radius: 5
						color: Qt.alpha(Theme.fg, 0.08)
					}

					Rectangle {
						width: parent.width * Printer.progress
						height: parent.height
						radius: 5
						gradient: Gradient {
							orientation: Gradient.Horizontal

							GradientStop {
								position: 0
								color: Theme.primary
							}

							GradientStop {
								position: 1
								color: Printer.hot
							}
						}

						Behavior on width {
							Anim {
								duration: Motion.long
							}
						}
					}
				}

				GridLayout {
					Layout.fillWidth: true
					columns: 2
					columnSpacing: 14
					rowSpacing: 6

					Repeater {
						model: {
							const project = Printer.project ?? {};
							const left = Number(project.remain_time ?? 0) * 60;
							return [
								{ label: "Layer", value: `${project.curr_layer ?? 0} / ${project.total_layers ?? 0}` },
								{ label: "Left", value: Printer.duration(left) },
								{ label: "Done at", value: Qt.formatTime(new Date(Date.now() + left * 1000), "HH:mm") },
								{ label: "Running", value: Printer.duration(Number(project.print_time ?? 0) * 60) }
							];
						}

						delegate: ColumnLayout {
							id: fact

							required property var modelData

							Layout.fillWidth: true
							spacing: 0

							SectionLabel {
								text: fact.modelData.label
							}

							StyledText {
								text: fact.modelData.value
								font.pixelSize: Theme.size.title
								tabular: true
							}
						}
					}
				}

				Item {
					Layout.fillHeight: true
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					TextButton {
						Layout.fillWidth: true
						text: Printer.paused ? "Resume" : "Pause"
						icon: Printer.paused ? "play" : "pause"
						onActivated: Printer.paused ? Printer.resume() : Printer.pause()
					}

					TextButton {
						Layout.fillWidth: true
						text: "Stop"
						icon: "stop"
						variant: "danger"
						confirm: true
						confirmText: "Stop the print?"
						onActivated: Printer.stop()
					}
				}
			}

			// a job that is not printing: its filaments, the slots, print
			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: !root.showsLive && root.job !== null
				spacing: 12

				StyledText {
					Layout.fillWidth: true
					text: Printer.title(root.job)
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					wrapMode: Text.Wrap
					maximumLineCount: 2
				}

				Flow {
					Layout.fillWidth: true
					spacing: 14

					Repeater {
						model: {
							const meta = root.job?.meta;
							if (!meta) return [];
							return [
								{ icon: "clock_outline", text: meta.seconds > 0 ? Printer.duration(meta.seconds) : "–" },
								{ icon: "weight_gram", text: `${meta.grams} g` },
								{ icon: "layers_outline", text: `${meta.layers} layers` },
								{ icon: "ruler", text: `${meta.height} mm` }
							];
						}

						delegate: RowLayout {
							id: info

							required property var modelData

							spacing: 4

							Glyph {
								icon: info.modelData.icon
								size: 14
								color: Theme.textMuted
							}

							StyledText {
								text: info.modelData.text
								font.pixelSize: Theme.size.label
								tone: Theme.textMuted
								tabular: true
							}
						}
					}
				}

				SectionLabel {
					text: (root.job?.meta?.filaments ?? []).length > 1 ? "Filaments" : "Filament"
				}

				Repeater {
					model: root.job?.meta?.filaments ?? []

					delegate: FilamentRow {
						required property var modelData

						Layout.fillWidth: true
						filament: modelData
						picked: root.mapping.find(entry => entry.tool === modelData.tool)?.slot ?? -1
						onPick: slot => root.pick(modelData.tool, slot)
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: Printer.online && Printer.slots.length === 0
					text: "The ACE has not answered yet"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Repeater {
					model: [
						{ key: "leveling", label: "Level the bed first" },
						{ key: "flow", label: "Calibrate the flow" }
					]

					delegate: RowLayout {
						id: option

						required property var modelData

						Layout.fillWidth: true

						StyledText {
							Layout.fillWidth: true
							text: option.modelData.label
							font.pixelSize: Theme.size.label
						}

						Toggle {
							checked: !!Printer.options[option.modelData.key]
							onToggled: checked => Printer.setOption(option.modelData.key, checked)
						}
					}
				}

				Item {
					Layout.fillHeight: true
				}

				StyledText {
					Layout.fillWidth: true
					visible: root.job?.status === "sent" || root.job?.status === "failed"
					text: root.job?.status === "failed" ? "The last try failed" : `Sent ${Qt.formatDateTime(new Date(root.job?.printed ?? 0), "d MMM, HH:mm")}`
					tone: root.job?.status === "failed" ? Theme.danger : Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					TextButton {
						text: "Remove"
						icon: "delete_outline"
						variant: "ghost"
						confirm: true
						confirmText: "Remove?"
						onActivated: Printer.forget(root.job.id)
					}

					TextButton {
						Layout.fillWidth: true
						text: root.sending ? "Sending…" : (Printer.printing ? "Printer is busy" : "Print")
						icon: "printer_3d"
						variant: "filled"
						busy: root.sending
						enabled: Printer.online && !Printer.printing && root.mapped && !root.sending
						onActivated: Printer.start(root.job.id, root.mapping)
					}
				}
			}

			// nothing picked: the ACE as it is
			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: !root.showsLive && root.job === null
				spacing: 10

				SectionLabel {
					text: "ACE"
				}

				Repeater {
					model: Printer.slots

					delegate: RowLayout {
						id: spool

						required property var modelData

						Layout.fillWidth: true
						spacing: 10

						Rectangle {
							Layout.preferredWidth: 26
							Layout.preferredHeight: 26
							radius: 13
							color: spool.modelData.type === "" ? "transparent" : Printer.rgb(spool.modelData.color)
							border.width: 1
							border.color: spool.modelData.type === "" ? Theme.textFaint : Theme.outline

							StyledText {
								anchors.centerIn: parent
								text: spool.modelData.slot + 1
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: spool.modelData.type || "Empty"
							tone: spool.modelData.type === "" ? Theme.textFaint : Theme.text
						}

						StyledText {
							visible: spool.modelData.percent > 0
							text: `${spool.modelData.percent} %`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							tabular: true
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: Printer.boxes.length > 0 && (Printer.boxes[0].temp ?? 0) > 0
					text: `${Printer.boxes[0]?.temp ?? 0} °C` + ((Printer.boxes[0]?.humidity ?? 0) > 0 ? ` · ${Printer.boxes[0].humidity} % humidity` : "")
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				StyledText {
					Layout.fillWidth: true
					visible: !Printer.online
					text: Printer.error ? `Not reachable (${Printer.error}). With LAN mode on, a restart of the printer helps.` : "Connecting…"
					wrapMode: Text.Wrap
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Item {
					Layout.fillHeight: true
				}
			}
		}

		// ── the jobs that came in ────────────────────────────────────────
		ListView {
			id: strip

			Layout.fillWidth: true
			Layout.preferredHeight: 92
			visible: Printer.configured && Printer.jobs.length > 0
			orientation: ListView.Horizontal
			spacing: 8
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			model: Printer.jobs

			delegate: Clickable {
				id: card

				required property var modelData
				readonly property bool current: root.job !== null && root.job.id === card.modelData.id
				readonly property bool onPrinter: Printer.printingJob !== null && Printer.printingJob.id === card.modelData.id

				width: 132
				height: 92
				radius: Theme.radius.large
				color: card.current ? Theme.primarySoft : Theme.layer1
				border.width: 1
				border.color: card.current ? Qt.alpha(Theme.primary, 0.5) : Theme.outline
				onClicked: Printer.selected = card.current && Printer.printing ? "" : card.modelData.id

				Image {
					anchors.top: parent.top
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.topMargin: 6
					width: parent.width - 16
					height: 54
					fillMode: Image.PreserveAspectFit
					source: card.modelData.frames > 0 ? `file://${card.modelData.preview}/model.png` : ""
					sourceSize.height: 108
					smooth: true
					asynchronous: true
				}

				StyledText {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 8
					text: Printer.title(card.modelData)
					font.pixelSize: Theme.size.tiny
					horizontalAlignment: Text.AlignHCenter
				}

				Rectangle {
					anchors.top: parent.top
					anchors.right: parent.right
					anchors.margins: 8
					width: 8
					height: 8
					radius: 4
					visible: card.onPrinter || card.modelData.status === "new"
					color: card.onPrinter ? Printer.hot : Theme.primary
				}
			}
		}
	}
}
