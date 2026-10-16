pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The 3D printer, the same under the bar (PrinterPanel) and in a window of
// its own (PrinterWindow): a header with what the printer does, the pages
// to switch, the heaters, its light, camera and pop-out; then the pages –
// the print with the part in 3D, the ACE, the statistics – sliding into
// each other; below, the jobs. Files dropped anywhere on it go into the
// inbox; a print that finished throws confetti.
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
				Layout.preferredWidth: 48
				Layout.preferredHeight: 48

				Ring {
					anchors.fill: parent
					value: Printer.progress
					thickness: 3
					color: Printer.paused ? Theme.warning : Printer.hot
					trackColor: Printer.printing ? Theme.layer3 : "transparent"
				}

				Rectangle {
					anchors.centerIn: parent
					width: 38
					height: 38
					radius: 19
					color: Printer.printing ? Printer.hot : (Printer.online ? Theme.primary : Theme.layer2)

					Behavior on color {
						ColorAnim {
							duration: Motion.long
						}
					}

					Glyph {
						id: head

						anchors.centerIn: parent
						icon: "printer_3d"
						size: 20
						color: Printer.online ? Theme.bg : Theme.textMuted

						// the head runs to and fro while it prints
						SequentialAnimation on anchors.horizontalCenterOffset {
							running: Printer.printing && !Printer.paused && root.visible
							loops: Animation.Infinite
							onRunningChanged: if (!running) head.anchors.horizontalCenterOffset = 0
							NumberAnimation { to: 2; duration: 520; easing.type: Easing.InOutSine }
							NumberAnimation { to: -2; duration: 1040; easing.type: Easing.InOutSine }
							NumberAnimation { to: 0; duration: 520; easing.type: Easing.InOutSine }
						}
					}
				}
			}

			ColumnLayout {
				Layout.preferredWidth: 230
				Layout.maximumWidth: 230
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					elide: Text.ElideRight
					text: Words.of("printer.title", Printer.name)
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					Item {
						Layout.preferredWidth: 8
						Layout.preferredHeight: 8

						// a ring goes out of the dot while it works
						Rectangle {
							id: ripple

							anchors.centerIn: parent
							width: 8
							height: 8
							radius: 4
							color: "transparent"
							border.width: 1.5
							border.color: dot.color
							opacity: 0
							visible: Printer.printing && !Printer.paused

							ParallelAnimation {
								running: ripple.visible && root.visible
								loops: Animation.Infinite
								NumberAnimation { target: ripple; property: "scale"; from: 1; to: 2.6; duration: 1400; easing.type: Easing.OutCubic }
								NumberAnimation { target: ripple; property: "opacity"; from: 0.9; to: 0; duration: 1400; easing.type: Easing.OutCubic }
							}
						}

						Rectangle {
							id: dot

							anchors.fill: parent
							radius: 4
							color: !Printer.online ? Theme.danger : (Printer.paused ? Theme.warning : (Printer.printing ? Printer.hot : Theme.success))

							Behavior on color {
								ColorAnim {}
							}
						}
					}

					StyledText {
						Layout.fillWidth: true
						elide: Text.ElideRight
						text: {
							if (Printer.printing && Printer.secondsLeft > 0)
								return `${Printer.status} · ${Math.round(Printer.progress * 100)} % · ready ${Qt.formatTime(new Date(Date.now() + Printer.secondsLeft * 1000), "HH:mm")}`;
							return Printer.status + (Printer.firmware ? ` · ${Printer.firmware}` : "");
						}
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
						tabular: true
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			// the pages
			Segmented {
				Layout.preferredWidth: 300
				Layout.preferredHeight: 36
				visible: Printer.configured
				options: [
					{ value: "print", label: "Print", icon: "printer_3d" },
					{ value: "ace", label: "ACE", icon: "palette" },
					{ value: "stats", label: "Stats", icon: "chart_bar" }
				]
				current: Printer.tab
				onSelected: value => Printer.tab = value
			}

			Item {
				Layout.fillWidth: true
			}

			// the heaters, at a glance
			Rectangle {
				Layout.preferredHeight: 36
				Layout.preferredWidth: heaters.implicitWidth + 8
				radius: 18
				color: Theme.layer1
				visible: Printer.online

				Row {
					id: heaters

					anchors.centerIn: parent

					Repeater {
						model: [
							{ icon: "printer_3d_nozzle", now: Number(Printer.temps.curr_nozzle_temp ?? 0), target: Number(Printer.temps.target_nozzle_temp ?? 0) },
							{ icon: "radiator", now: Number(Printer.temps.curr_hotbed_temp ?? 0), target: Number(Printer.temps.target_hotbed_temp ?? 0) }
						]

						delegate: TempReadout {}
					}
				}
			}

			// light, camera, a window of its own
			Rectangle {
				Layout.preferredHeight: 36
				Layout.preferredWidth: actions.implicitWidth + 6
				radius: 18
				color: Theme.layer1

				Row {
					id: actions

					anchors.centerIn: parent
					spacing: 2

					IconButton {
						width: 30
						height: 30
						icon: Printer.light ? "lightbulb_on" : "lightbulb_outline"
						checked: Printer.light
						enabled: Printer.online
						onClicked: Printer.setLight(!Printer.light)
					}

					IconButton {
						width: 30
						height: 30
						icon: Printer.camera ? "video" : "video_off"
						checked: Printer.camera
						enabled: Printer.online && Printer.cameraUrl !== ""
						onClicked: Printer.setCamera(!Printer.camera)
					}

					IconButton {
						width: 30
						height: 30
						icon: root.windowed ? "dock_window" : "open_in_new"
						onClicked: root.windowed ? Printer.dock() : Printer.popOut()
					}
				}
			}
		}

		// ── not set up yet ───────────────────────────────────────────────
		Card {
			Layout.fillWidth: true
			Layout.preferredHeight: setup.implicitHeight + 56
			visible: !Printer.configured
			cue: !Printer.configured

			ColumnLayout {
				id: setup

				anchors.centerIn: parent
				width: Math.min(parent.width - 48, 460)
				spacing: 14

				Rectangle {
					Layout.alignment: Qt.AlignHCenter
					Layout.preferredWidth: 72
					Layout.preferredHeight: 72
					radius: 36
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: "lan"
						size: 32
						color: Theme.primary
					}
				}

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: "Where is the printer?"
					font.pixelSize: Theme.size.title + 2
					font.weight: Font.Bold
				}

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: "Its address is on the printer under Settings → Network, with LAN mode on."
					wrapMode: Text.Wrap
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 8

					Field {
						id: address

						Layout.fillWidth: true
						Layout.preferredHeight: 40
						color: Theme.layer2
						placeholder: "192.168.…"
						icon: "lan"
						onAccepted: Printer.setAddress(address.text)
					}

					TextButton {
						Layout.preferredHeight: 40
						text: "Connect"
						variant: "filled"
						onActivated: Printer.setAddress(address.text)
					}
				}
			}
		}

		// ── the pages, sliding into each other ───────────────────────────
		Item {
			id: pages

			Layout.fillWidth: true
			Layout.fillHeight: root.windowed
			Layout.preferredHeight: root.windowed ? -1 : 470
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
					scale: holder.current ? 1 : 0.985
					x: holder.current ? 0 : (holder.index < root.page ? -64 : 64)
					sourceComponent: [printPage, acePage, statsPage][holder.index]

					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}
					Behavior on x {
						SpatialAnim {}
					}
					Behavior on scale {
						SpatialAnim {}
					}
				}
			}
		}

		// ── the jobs that came in ────────────────────────────────────────
		Item {
			id: strip

			readonly property bool wanted: Printer.configured && Printer.tab === "print"

			Layout.fillWidth: true
			Layout.preferredHeight: strip.wanted ? jobs.implicitHeight : 0
			Layout.topMargin: strip.wanted ? 0 : -14
			clip: true
			opacity: strip.wanted ? 1 : 0

			Behavior on Layout.preferredHeight {
				SpatialAnim {}
			}
			Behavior on Layout.topMargin {
				SpatialAnim {}
			}
			Behavior on opacity {
				Anim {}
			}

			JobStrip {
				id: jobs

				width: parent.width
				height: jobs.implicitHeight
			}
		}
	}

	// ── files dropped on it ──────────────────────────────────────────────
	DropArea {
		id: drop

		property int count: 0

		function paths(event) {
			return (event.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
		}

		anchors.fill: parent
		enabled: Printer.configured
		onEntered: drag => {
			drop.count = drop.paths(drag).filter(path => Printer.takes(path)).length;
			if (drop.count > 0) drag.accept(Qt.CopyAction);
		}
		onExited: drop.count = 0
		onDropped: event => {
			const added = Printer.addFiles(drop.paths(event));
			drop.count = 0;
			if (added > 0) {
				event.accept(Qt.CopyAction);
				Printer.tab = "print";
			}
		}
	}

	Rectangle {
		id: dropCover

		readonly property bool on: drop.containsDrag && drop.count > 0

		anchors.fill: parent
		anchors.margins: -6
		radius: Theme.radius.huge
		color: Qt.alpha(Theme.bg, 0.86)
		opacity: dropCover.on ? 1 : 0
		visible: opacity > 0.01
		z: 20

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		// a border that marches round
		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			ShapePath {
				strokeColor: Theme.primary
				strokeWidth: 2.5
				strokeStyle: ShapePath.DashLine
				dashPattern: [5, 4]
				fillColor: "transparent"

				NumberAnimation on dashOffset {
					running: dropCover.visible
					from: 0
					to: -18
					duration: 700
					loops: Animation.Infinite
				}

				PathRectangle {
					x: 2
					y: 2
					width: dropCover.width - 4
					height: dropCover.height - 4
					radius: dropCover.radius - 2
				}
			}
		}

		Column {
			anchors.centerIn: parent
			spacing: 14
			scale: dropCover.on ? 1 : 0.9

			Behavior on scale {
				SpatialAnim {}
			}

			Item {
				anchors.horizontalCenter: parent.horizontalCenter
				width: 120
				height: 120

				// rings going out from the target
				Repeater {
					model: 3

					delegate: Rectangle {
						id: wave

						required property int index

						anchors.centerIn: parent
						width: 88
						height: 88
						radius: 44
						color: "transparent"
						border.width: 2
						border.color: Theme.primary
						opacity: 0

						SequentialAnimation {
							running: dropCover.visible
							loops: Animation.Infinite
							PauseAnimation { duration: wave.index * 500 }
							ParallelAnimation {
								NumberAnimation { target: wave; property: "scale"; from: 0.9; to: 1.5; duration: 1500; easing.type: Easing.OutCubic }
								NumberAnimation { target: wave; property: "opacity"; from: 0.6; to: 0; duration: 1500; easing.type: Easing.OutCubic }
							}
							PauseAnimation { duration: (2 - wave.index) * 500 }
						}
					}
				}

				Rectangle {
					anchors.centerIn: parent
					width: 88
					height: 88
					radius: 44
					color: Theme.primary

					Glyph {
						anchors.centerIn: parent
						icon: "tray_arrow_down"
						size: 38
						color: Theme.onPrimary

						SequentialAnimation on anchors.verticalCenterOffset {
							running: drop.containsDrag
							loops: Animation.Infinite
							NumberAnimation { to: 6; duration: 420; easing.type: Easing.InOutSine }
							NumberAnimation { to: -2; duration: 420; easing.type: Easing.InOutSine }
						}
					}
				}
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: drop.count > 1 ? `Drop ${drop.count} files to add them` : "Drop to add it"
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: "Models are sliced here, G-code is ready to print, profiles are imported"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}
		}
	}

	// ── a print that finished ────────────────────────────────────────────
	Confetti {
		id: confetti

		anchors.fill: parent
		z: 30
		colours: {
			const loaded = Printer.slots.filter(slot => slot.type !== "").map(slot => Printer.rgb(slot.color));
			return loaded.concat([Theme.primary, Printer.hot]);
		}
	}

	Connections {
		target: Printer

		function onFinished() {
			if (root.visible) confetti.burst();
		}
	}

	Component {
		id: printPage

		PrintPage {
			windowed: root.windowed
			current: root.page === 0
		}
	}

	Component {
		id: acePage

		AcePage {
			current: root.page === 1
		}
	}

	Component {
		id: statsPage

		StatsPage {
			current: root.page === 2
		}
	}

	// a heater in the header: its icon, the number counting, a thin bar
	// filling toward the target while it heats
	component TempReadout: Item {
		id: chip

		required property var modelData
		readonly property bool on: chip.modelData.target > 0
		readonly property bool heating: chip.on && chip.modelData.target - chip.modelData.now > 3
		property real shown: chip.modelData.now

		Behavior on shown {
			NumberAnimation {
				duration: 900
				easing.type: Easing.OutCubic
			}
		}

		width: chipRow.implicitWidth + 18
		height: 30

		Row {
			id: chipRow

			anchors.centerIn: parent
			spacing: 5

			Glyph {
				id: flame

				anchors.verticalCenter: parent.verticalCenter
				icon: chip.modelData.icon
				size: 14
				color: chip.on ? Printer.hot : Theme.textMuted

				SequentialAnimation on opacity {
					running: chip.heating && root.visible
					loops: Animation.Infinite
					onRunningChanged: if (!running) flame.opacity = 1
					NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
					NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
				}
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: `${Math.round(chip.shown)}°`
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
				tabular: true
			}
		}

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			width: chipRow.implicitWidth
			height: 2
			radius: 1
			color: Qt.alpha(Printer.hot, 0.18)
			opacity: chip.heating ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			Rectangle {
				width: parent.width * Math.max(0, Math.min(1, chip.shown / Math.max(1, chip.modelData.target)))
				height: parent.height
				radius: 1
				color: Printer.hot
			}
		}
	}
}
