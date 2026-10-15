pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The print: the part in 3D on the left (turnable, cut at the layer on the
// nozzle), on the right what fits the moment – the running print with its
// progress, speed and temperatures; a job waiting for its slots; or the
// printer at rest with its last print.
Item {
	id: root

	property bool windowed: false
	// the job shown: the one picked, else the one printing
	readonly property var job: Printer.job(Printer.selected) ?? Printer.printingJob
	readonly property bool showsLive: Printer.printing && (root.job === null || root.job === Printer.printingJob)
	readonly property string mode: root.showsLive ? "live" : (root.job !== null ? "job" : "idle")
	property var mapping: []
	readonly property bool mapped: root.mapping.length > 0 && root.mapping.every(pick => pick.slot >= 0)
	readonly property bool sending: root.job !== null && (root.job.status === "uploading" || Printer.uploads[root.job.id] !== undefined)

	// ── a model, sliced here ─────────────────────────────────────────────
	readonly property bool isModel: root.job?.kind === "model"
	readonly property bool isStl: root.isModel && root.job?.format === "stl"
	readonly property bool sliced: root.isModel && !!root.job?.file && !root.job?.slicing && (root.job?.plates ?? 0) > 0
	readonly property var settings: Printer.sliceSettings(root.job)
	property bool layMode: false

	// what the folded settings are set to, in a line
	readonly property string summary: {
		const parts = [];
		const beds = { "Cool Plate": "Cool plate", "Engineering Plate": "Engineering", "High Temp Plate": "High temp", "Textured PEI Plate": "Textured PEI" };
		if (root.isModel) {
			parts.push(beds[root.settings.bed] ?? root.settings.bed);
			if (root.settings.supports !== null && root.settings.supports !== undefined) parts.push(root.settings.supports ? "supports" : "no supports");
			if (root.settings.infill) parts.push(`${root.settings.infill} % infill`);
			if (root.settings.brim !== null && root.settings.brim !== undefined) parts.push(root.settings.brim ? "brim" : "no brim");
		}
		if (Printer.options.leveling) parts.push("leveling");
		if (Printer.options.flow) parts.push("flow");
		return parts.join(" · ");
	}

	// the slots picked for this job before (kept per job), else the ones that fit best
	function remap() {
		root.mapping = Printer.mappingFor(root.job);
	}

	// only what is still open, when the ACE answered late
	function fillOpen() {
		const suggested = Printer.suggestAll(root.job);
		root.mapping = suggested.map(entry => {
			const kept = root.mapping.find(pick => pick.tool === entry.tool);
			return kept && kept.slot >= 0 ? kept : entry;
		});
	}

	// another slot: sliced again only for another material, else just painted
	function pick(tool, slot) {
		if (root.mapping.some(entry => entry.tool === tool && entry.slot === slot)) return;
		root.mapping = root.mapping.map(entry => entry.tool === tool ? { tool, slot } : entry);
		Printer.remember(root.job, root.mapping);
		if (root.isModel && root.job.slice?.filaments !== undefined) {
			const filaments = Printer.sliceFilaments(root.job, root.mapping);
			if (Printer.needsSlice(root.job, filaments))
				Printer.sliceJob(root.job, Object.assign({}, root.settings, { filaments, mapping: root.mapping }));
			else
				Printer.recolor(root.job, root.mapping);
		} else if (!root.isModel) {
			Printer.recolor(root.job, root.mapping);
		}
	}

	// one setting changed: slice again with it
	function edit(key, value) {
		// the same again (a profile picked that was picked) changes nothing
		if (root.job?.slice?.filaments !== undefined && JSON.stringify(root.settings[key] ?? null) === JSON.stringify(value ?? null)) return;
		const next = Object.assign({}, root.settings);
		next[key] = value;
		next.filaments = Printer.sliceFilaments(root.job, root.mapping);
		next.mapping = root.mapping;
		if (key === "orient" && value) root.layMode = false;
		Printer.sliceJob(root.job, next);
	}

	// slices a model that never was – and nothing else: a model is sliced
	// again only for a setting changed by hand or a slot of another material
	function autoSlice() {
		if (!root.isModel || !root.job || root.job.slicing || !root.settings.process) return;
		if (root.job.status !== "unsliced" || root.job.sliceError || root.job.slice?.filaments !== undefined) return;
		Printer.sliceJob(root.job, Object.assign({}, root.settings, { filaments: Printer.sliceFilaments(root.job, root.mapping), mapping: root.mapping }));
	}

	// the daemon sends a job anew with every change (a slice, a picture):
	// only another job starts the slots and the lay mode over
	readonly property string jobId: root.job?.id ?? ""
	onJobIdChanged: {
		root.layMode = false;
		root.remap();
		slicer.restart();
	}
	Component.onCompleted: root.remap()

	Connections {
		target: Printer

		function onProfilesChanged() {
			slicer.restart();
		}
	}

	Timer {
		id: slicer

		interval: 700
		onTriggered: root.autoSlice()
	}

	Connections {
		target: Printer

		// the ACE answered after the job was picked: fill what is still open
		function onSlotsChanged() {
			if (root.mapping.length === 0 || root.mapping.some(pick => pick.slot < 0)) root.fillOpen();
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 18

		// ── the part ─────────────────────────────────────────────────────
		Rectangle {
			id: stage

			Layout.fillHeight: true
			Layout.preferredWidth: root.windowed ? root.width * 0.62 : 500
			radius: Theme.radius.huge
			color: Theme.layer1
			border.width: 1
			border.color: Theme.outline
			clip: true

			// a soft light from above, behind the part
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.alpha(root.showsLive ? Printer.hot : Theme.primary, 0.07)
					}
					GradientStop {
						position: 0.7
						color: "transparent"
					}
				}
			}

			ModelView {
				id: model

				anchors.fill: parent
				anchors.margins: 2
				job: root.job
				liveLayer: root.showsLive ? Printer.layer : -1
				// the panel's view or the window's: only the one that shows has a scene
				alive: root.windowed ? Printer.windowed && Printer.windowOpen : !Printer.windowed && Popups.current === "printer"
				layMode: root.layMode
				opacity: root.job?.slicing && ready ? 0.45 : 1
				onFacePicked: index => {
					Printer.layOnFace(root.job.id, index);
					root.layMode = false;
				}

				Behavior on opacity {
					Anim {}
				}
			}

			// slicing again: the old part dims under a spinner
			Column {
				anchors.centerIn: parent
				spacing: 10
				visible: !!root.job?.slicing && model.ready

				Spinner {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 36
					height: 36
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: `Slicing with ${root.settings.process}`
					font.pixelSize: Theme.size.label
				}
			}

			// what went wrong when there is no part to show
			EmptyState {
				anchors.centerIn: parent
				visible: root.isModel && !root.job?.slicing && !!root.job?.sliceError && !model.ready
				icon: "alert_circle_outline"
				title: "Could not slice"
				subtitle: root.job?.sliceError ?? ""
			}

			// laying an STL on a face, turning it automatically, back as it came
			Row {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 10
				spacing: 4
				visible: root.isStl && model.ready && !root.job?.slicing

				Repeater {
					model: [
						{ icon: "arrow_collapse_down", checked: root.layMode, label: "Lay on face", run: () => root.layMode = !root.layMode },
						{ icon: "auto_fix", checked: !!root.settings.orient, label: "Auto orient", run: () => root.edit("orient", !root.settings.orient) },
						{ icon: "restore", checked: false, label: "As it came", run: () => {
							root.layMode = false;
							if (root.settings.orient) root.edit("orient", false);
							else Printer.resetPlacement(root.job.id);
						} }
					]

					delegate: Clickable {
						id: tool

						required property var modelData

						width: toolRow.implicitWidth + 20
						height: 30
						radius: 15
						color: tool.modelData.checked ? Theme.primary : Qt.alpha(Theme.bg, 0.7)
						border.width: 1
						border.color: tool.modelData.checked ? Theme.primary : Theme.outline
						onClicked: tool.modelData.run()

						Behavior on color {
							ColorAnim {}
						}

						Row {
							id: toolRow

							anchors.centerIn: parent
							spacing: 5

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: tool.modelData.icon
								size: 14
								color: tool.modelData.checked ? Theme.onPrimary : Theme.text
							}

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								text: tool.modelData.label
								font.pixelSize: Theme.size.small
								tone: tool.modelData.checked ? Theme.onPrimary : Theme.text
							}
						}
					}
				}
			}

			// what lay mode asks for
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 46
				width: layHint.implicitWidth + 28
				height: 32
				radius: 16
				color: Theme.primary
				opacity: root.layMode ? 1 : 0
				scale: root.layMode ? 1 : 0.9
				visible: opacity > 0.01

				Behavior on opacity {
					Anim {}
				}
				Behavior on scale {
					SpatialAnim {}
				}

				StyledText {
					id: layHint

					anchors.centerIn: parent
					text: model.hoveredFace >= 0 ? "Click to lay the part on this face" : "Point at a flat face of the part"
					tone: Theme.onPrimary
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}
			}

			// the plates of a 3MF
			Row {
				anchors.left: parent.left
				anchors.bottom: scrubber.visible ? scrubber.top : parent.bottom
				anchors.margins: 12
				spacing: 6
				visible: (root.job?.plates ?? 0) > 1

				Repeater {
					model: root.job?.plates ?? 0

					delegate: Chip {
						required property int index

						text: `Plate ${index + 1}`
						selected: (root.job?.plate ?? 1) === index + 1
						onClicked: Printer.setPlate(root.job.id, index + 1)
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: root.job === null && Printer.printing
				icon: "printer_3d"
				title: "A print from elsewhere"
				subtitle: "Its part is not known here"
			}

			// nothing to print: a little print prints itself
			IdlePrint {
				anchors.fill: parent
				visible: root.job === null && !Printer.printing
				running: visible && model.alive
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 34
				visible: root.job === null && !Printer.printing
				text: "Drop a model or G-code anywhere here"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			// the layer the cut is at
			Rectangle {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.margins: 14
				width: layerText.implicitWidth + 24
				height: 28
				radius: 14
				color: Qt.alpha(Theme.bg, 0.7)
				border.width: 1
				border.color: Theme.outline
				visible: model.ready
				opacity: model.intro

				StyledText {
					id: layerText

					anchors.centerIn: parent
					text: `Layer ${model.shownLayer} / ${model.layers} · ${model.cut.toFixed(1)} mm`
					font.pixelSize: Theme.size.small
					tabular: true
				}
			}

			// a hint until the part was touched once
			Row {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 16
				spacing: 6
				visible: model.ready && !root.isStl
				opacity: model.idleSince === 0 ? 0.6 : 0

				Behavior on opacity {
					Anim {}
				}

				Glyph {
					icon: "rotate_3d_variant"
					size: 14
					color: Theme.textMuted
				}

				StyledText {
					text: "Drag to turn · wheel to zoom"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
				}
			}

			// the layer from above
			Rectangle {
				anchors.right: parent.right
				anchors.bottom: scrubber.visible ? scrubber.top : parent.bottom
				anchors.margins: 12
				width: 104
				height: 104
				radius: Theme.radius.large
				color: Qt.alpha(Theme.bg, 0.72)
				border.width: 1
				border.color: Theme.outline
				visible: (root.job?.frames ?? 0) > 0 && model.ready
				opacity: model.intro

				Image {
					anchors.fill: parent
					anchors.margins: 8
					fillMode: Image.PreserveAspectFit
					source: parent.visible ? Printer.frameUrl(root.job, "top", Printer.frameIndex(root.job, model.shownLayer)) : ""
					smooth: true
					mipmap: true
				}
			}

			// scrubbing through a job that is not printing
			Item {
				id: scrubber

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 16
				height: 22
				visible: model.ready && !model.live

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					height: 4
					radius: 2
					color: Qt.alpha(Theme.fg, 0.1)
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width * model.scrub
					height: 4
					radius: 2
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
				}

				Rectangle {
					x: parent.width * model.scrub - width / 2
					anchors.verticalCenter: parent.verticalCenter
					width: knob.pressed ? 18 : 14
					height: width
					radius: width / 2
					color: Printer.hot
					border.width: 3
					border.color: Theme.bg

					Behavior on width {
						SpatialAnim {}
					}
				}

				MouseArea {
					id: knob

					anchors.fill: parent
					anchors.margins: -6
					cursorShape: Qt.PointingHandCursor
					onPressed: mouse => model.scrub = Math.max(0, Math.min(1, mouse.x / width))
					onPositionChanged: mouse => {
						if (pressed) model.scrub = Math.max(0, Math.min(1, mouse.x / width));
					}
				}
			}
		}

		// ── what fits the moment ─────────────────────────────────────────
		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			ProfileMenu {
				id: menu

				anchors.fill: parent
				z: 10
				current: menu.kind === "filament" ? (root.settings.filament ?? "") : root.settings.process
				onPicked: (kind, name) => root.edit(kind, name)
				onOpenChanged: if (open) Printer.loadProfiles()
			}

			Repeater {
				model: ["live", "job", "idle"]

				delegate: Loader {
					id: side

					required property string modelData
					readonly property bool current: side.modelData === root.mode

					anchors.fill: parent
					active: side.current || side.opacity > 0
					opacity: side.current ? 1 : 0
					visible: opacity > 0.01
					sourceComponent: side.modelData === "live" ? liveSide : (side.modelData === "job" ? jobSide : idleSide)

					transform: Translate {
						y: side.current ? 0 : 18

						Behavior on y {
							SpatialAnim {}
						}
					}

					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}
				}
			}
		}
	}

	// ── the print running ────────────────────────────────────────────────
	Component {
		id: liveSide

		ColumnLayout {
			spacing: 14

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: root.job ? Printer.title(root.job) : Printer.nameOf(Printer.project?.filename)
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				Rectangle {
					Layout.preferredHeight: 24
					Layout.preferredWidth: stateText.implicitWidth + 20
					radius: 12
					color: Printer.paused ? Qt.alpha(Theme.warning, 0.16) : Qt.alpha(Printer.hot, 0.14)

					Behavior on color {
						ColorAnim {}
					}

					StyledText {
						id: stateText

						anchors.centerIn: parent
						text: Printer.status
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						tone: Printer.paused ? Theme.warning : Printer.hot
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 18

				ProgressDial {
					Layout.preferredWidth: 172
					Layout.preferredHeight: 172
					value: Printer.progress
					running: !Printer.paused
					color: Printer.paused ? Theme.warning : Printer.hot
					caption: `layer ${Printer.layer} of ${Printer.layers}`
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 12

					// a fixed model: the delegates stay (and animate in once) while the values change
					Repeater {
						model: ["Ready at", "Left", "Running for"]

						delegate: ColumnLayout {
							id: fact

							required property string modelData
							required property int index
							readonly property bool big: fact.index === 0
							readonly property string value: {
								if (fact.index === 0) return Printer.secondsLeft > 0 ? Qt.formatTime(new Date(Date.now() + Printer.secondsLeft * 1000), "HH:mm") : "–";
								if (fact.index === 1) return Printer.duration(Printer.secondsLeft);
								return Printer.duration(Number(Printer.project?.print_time ?? 0) * 60);
							}

							Layout.fillWidth: true
							spacing: -2
							opacity: 0
							transform: Translate {
								id: slide

								x: 16
							}

							Component.onCompleted: appear.start()

							ParallelAnimation {
								id: appear

								SequentialAnimation {
									PauseAnimation {
										duration: 120 + fact.index * 90
									}
									ParallelAnimation {
										NumberAnimation {
											target: fact
											property: "opacity"
											to: 1
											duration: 300
										}
										NumberAnimation {
											target: slide
											property: "x"
											to: 0
											duration: 520
											easing.type: Easing.OutBack
										}
									}
								}
							}

							SectionLabel {
								text: fact.modelData
							}

							StyledText {
								text: fact.value
								font.pixelSize: fact.big ? Theme.size.hero * 0.72 : Theme.size.title
								font.weight: fact.big ? Font.Bold : Font.Normal
								tabular: true
							}
						}
					}
				}
			}

			// the spools it prints from; the one feeding turns
			RowLayout {
				Layout.fillWidth: true
				spacing: 10
				visible: spools.count > 0

				SectionLabel {
					text: "Printing with"
				}

				Repeater {
					id: spools

					model: (root.job?.mapping ?? []).map(pick => Printer.slot(pick.slot)).filter(slot => slot !== null)

					delegate: Row {
						required property var modelData

						spacing: 6

						Spool {
							anchors.verticalCenter: parent.verticalCenter
							width: 26
							height: 26
							slot: modelData
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: modelData.type
							font.pixelSize: Theme.size.small
						}
					}
				}

				Item {
					Layout.fillWidth: true
				}
			}

			// the heat, the last ten minutes of it behind
			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: 58
				radius: Theme.radius.large
				color: Theme.layer1
				clip: true

				Sparkline {
					anchors.fill: parent
					anchors.topMargin: 20
					values: Printer.nozzleLog
					maximum: Math.max(260, ...Printer.nozzleLog)
					color: Printer.hot
				}

				Row {
					anchors.left: parent.left
					anchors.top: parent.top
					anchors.margins: 10
					anchors.topMargin: 8
					spacing: 14

					Repeater {
						model: [
							{ icon: "printer_3d_nozzle", value: Number(Printer.temps.curr_nozzle_temp ?? 0) },
							{ icon: "radiator", value: Number(Printer.temps.curr_hotbed_temp ?? 0) }
						]

						delegate: Row {
							required property var modelData

							spacing: 4

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: modelData.icon
								size: 13
								color: Printer.hot
							}

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								text: `${Math.round(modelData.value)}°`
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								tabular: true
							}
						}
					}
				}
			}

			Segmented {
				Layout.fillWidth: true
				Layout.preferredHeight: 32
				options: Printer.speeds
				current: String(Printer.speed)
				onSelected: value => Printer.setSpeed(Number(value))
			}

			Item {
				Layout.fillHeight: true
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				TextButton {
					Layout.fillWidth: true
					Layout.preferredHeight: 42
					text: Printer.paused ? "Resume" : "Pause"
					icon: Printer.paused ? "play" : "pause"
					onActivated: Printer.paused ? Printer.resume() : Printer.pause()
				}

				// stopping is never one stray click away
				HoldButton {
					Layout.fillWidth: true
					text: "Hold to stop"
					holdText: "Stopping…"
					icon: "stop"
					accent: Theme.danger
					onAccent: Theme.bg
					filled: false
					hold: 1200
					onActivated: Printer.stop()
				}
			}
		}
	}

	// ── a job waiting for its slots ──────────────────────────────────────
	Component {
		id: jobSide

		ColumnLayout {
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
				spacing: 6

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

					delegate: Rectangle {
						id: info

						required property var modelData
						required property int index

						width: infoRow.implicitWidth + 18
						height: 26
						radius: 13
						color: Theme.layer2
						opacity: 0
						scale: 0.9

						Component.onCompleted: appear.start()

						SequentialAnimation {
							id: appear

							PauseAnimation {
								duration: info.index * 60
							}
							ParallelAnimation {
								NumberAnimation {
									target: info
									property: "opacity"
									to: 1
									duration: 260
								}
								NumberAnimation {
									target: info
									property: "scale"
									to: 1
									duration: 380
									easing.type: Easing.OutBack
								}
							}
						}

						Row {
							id: infoRow

							anchors.centerIn: parent
							spacing: 5

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: info.modelData.icon
								size: 13
								color: Theme.textMuted
							}

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								text: info.modelData.text
								font.pixelSize: Theme.size.small
								tabular: true
							}
						}
					}
				}
			}

			Flickable {
				id: options

				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: optionColumn.implicitHeight
				clip: true
				boundsBehavior: Flickable.StopAtBounds

				Behavior on contentY {
					enabled: !options.moving
					SpatialAnim {}
				}

				ColumnLayout {
					id: optionColumn

					width: options.width
					spacing: 12

					SliceControls {
						Layout.fillWidth: true
						visible: root.isModel
						job: root.job
						settings: root.settings
						onEdit: (key, value) => root.edit(key, value)
						onOpenProfiles: kind => {
							menu.kind = kind;
							menu.open = true;
						}
					}

					RowLayout {
						Layout.fillWidth: true
						Layout.topMargin: 4

						SectionLabel {
							Layout.fillWidth: true
							text: Printer.filamentsOf(root.job).length > 1 ? "Filaments → ACE slots" : "Filament → ACE slot"
						}

						AceSync {}
					}

					Repeater {
						model: Printer.filamentsOf(root.job)

						delegate: FilamentRow {
							required property var modelData

							Layout.fillWidth: true
							filament: modelData
							// a model is sliced for the slot's material
							adapts: root.isModel
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

					// the rest, folded away: a line says what it is set to
					Clickable {
						id: more

						property bool open: false

						Layout.fillWidth: true
						Layout.preferredHeight: 40
						radius: Theme.radius.medium
						color: more.open ? Theme.layer2 : "transparent"
						border.width: 1
						border.color: Theme.outline
						onClicked: {
							more.open = !more.open;
							if (more.open) reveal.restart();
						}

						// once it unfolded, it scrolls into sight
						Timer {
							id: reveal

							interval: 380
							onTriggered: options.contentY = Math.max(0, options.contentHeight - options.height)
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 12
							anchors.rightMargin: 10
							spacing: 8

							Glyph {
								icon: "tune_variant"
								size: 15
								color: Theme.textMuted
							}

							StyledText {
								text: "More"
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								text: root.summary
								elide: Text.ElideRight
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}

							Glyph {
								icon: "chevron_down"
								size: 16
								color: Theme.textMuted
								rotation: more.open ? 180 : 0

								Behavior on rotation {
									SpatialAnim {}
								}
							}
						}
					}

					Item {
						id: fold

						Layout.fillWidth: true
						Layout.preferredHeight: more.open ? foldColumn.implicitHeight : 0
						clip: true
						opacity: more.open ? 1 : 0

						Behavior on Layout.preferredHeight {
							SpatialAnim {}
						}
						Behavior on opacity {
							Anim {}
						}

						ColumnLayout {
							id: foldColumn

							width: fold.width
							spacing: 12

							SliceControls {
								Layout.fillWidth: true
								visible: root.isModel
								part: "more"
								job: root.job
								settings: root.settings
								onEdit: (key, value) => root.edit(key, value)
							}

							Repeater {
								model: [
									{ key: "leveling", label: "Level the bed first", icon: "grid" },
									{ key: "flow", label: "Calibrate the flow", icon: "water_percent" }
								]

								delegate: RowLayout {
									id: option

									required property var modelData

									Layout.fillWidth: true
									spacing: 8

									Glyph {
										icon: option.modelData.icon
										size: 15
										color: Theme.textMuted
									}

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
						}
					}
				}
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
				spacing: 6

				IconButton {
					icon: "folder_open_outline"
					onClicked: Quickshell.execDetached(["xdg-open", root.job.dir])
				}

				// removing takes a second click
				IconButton {
					icon: removing.armed ? "alert" : "delete_outline"
					checked: removing.armed
					onClicked: {
						if (removing.armed) {
							removing.armed = false;
							Printer.forget(root.job.id);
						} else {
							removing.armed = true;
							removing.restart();
						}
					}

					Timer {
						id: removing

						property bool armed: false

						interval: 2600
						onTriggered: removing.armed = false
					}
				}

				HoldButton {
					Layout.fillWidth: true
					text: {
						if (removing.armed) return "Click the bin again to remove";
						if (root.sending) return "Sending…";
						if (root.job?.slicing) return "Slicing…";
						if (Printer.printing) return "The printer is busy";
						if (!Printer.online) return "The printer is offline";
						return "Hold to print";
					}
					icon: "printer_3d"
					busy: root.sending || !!root.job?.slicing
					hold: 650
					enabled: Printer.online && !Printer.printing && root.mapped && !root.sending && (!root.isModel || root.sliced)
					onActivated: Printer.start(root.job.id, root.mapping)
				}
			}
		}
	}

	// ── the printer at rest ──────────────────────────────────────────────
	Component {
		id: idleSide

		ColumnLayout {
			id: rest

			readonly property var last: Printer.history.length > 0 ? Printer.history[Printer.history.length - 1] : null

			spacing: 14

			StyledText {
				Layout.fillWidth: true
				text: Printer.online ? "Ready when you are" : (Printer.error ? "Not reachable" : "Connecting…")
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			StyledText {
				Layout.fillWidth: true
				Layout.topMargin: -8
				text: Printer.online ? "Drop a file on the panel, or export from OrcaSlicer into the inbox – the panel opens with it." : (Printer.error ? `${Printer.error}. With LAN mode on, a restart of the printer helps.` : "")
				wrapMode: Text.Wrap
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			// the inbox, as a place to drop on
			Clickable {
				id: inboxCard

				Layout.fillWidth: true
				Layout.preferredHeight: 64
				radius: Theme.radius.large
				color: inboxCard.hovered ? Theme.layer2 : Theme.layer1
				onClicked: Quickshell.execDetached(["xdg-open", Printer.inbox.replace(/^~/, Quickshell.env("HOME"))])

				Shape {
					anchors.fill: parent
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						strokeColor: inboxCard.hovered ? Theme.primary : Qt.alpha(Theme.fg, 0.22)
						strokeWidth: 1.5
						strokeStyle: ShapePath.DashLine
						dashPattern: [4, 3]
						fillColor: "transparent"

						PathRectangle {
							x: 1
							y: 1
							width: inboxCard.width - 2
							height: inboxCard.height - 2
							radius: inboxCard.radius
						}
					}
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 14
					spacing: 12

					Rectangle {
						Layout.preferredWidth: 36
						Layout.preferredHeight: 36
						radius: 18
						color: Theme.primarySoft

						Glyph {
							anchors.centerIn: parent
							icon: "tray_arrow_down"
							size: 18
							color: Theme.primary
							anchors.verticalCenterOffset: inboxCard.hovered ? 2 : 0

							Behavior on anchors.verticalCenterOffset {
								SpatialAnim {}
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							text: "Inbox"
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: Printer.inbox
							elide: Text.ElideMiddle
							tone: Theme.textMuted
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.small
						}
					}

					Glyph {
						icon: "folder_open_outline"
						size: 15
						color: Theme.textMuted
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: 4
				visible: Printer.online

				SectionLabel {
					Layout.fillWidth: true
					text: "Loaded in the ACE"
				}

				AceSync {}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8
				visible: Printer.slots.length > 0

				Repeater {
					model: Printer.slots

					delegate: Clickable {
						id: spoolCard

						required property var modelData
						required property int index

						Layout.fillWidth: true
						Layout.preferredHeight: 92
						radius: Theme.radius.large
						color: spoolCard.hovered ? Theme.layer2 : Theme.layer1
						onClicked: Printer.tab = "ace"

						Spool {
							id: spool

							anchors.horizontalCenter: parent.horizontalCenter
							y: 10
							width: 46
							height: 46
							slot: spoolCard.modelData
							rotation: spoolCard.hovered ? 25 : 0

							Behavior on rotation {
								SpatialAnim {}
							}
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.bottom: parent.bottom
							anchors.bottomMargin: 9
							width: parent.width - 10
							horizontalAlignment: Text.AlignHCenter
							elide: Text.ElideRight
							text: spoolCard.modelData.type || "Empty"
							tone: spoolCard.modelData.type ? Theme.text : Theme.textFaint
							font.pixelSize: Theme.size.small
						}
					}
				}
			}

			SectionLabel {
				Layout.topMargin: 4
				text: "Last print"
				visible: rest.last !== null
			}

			HistoryRow {
				Layout.fillWidth: true
				visible: rest.last !== null
				item: rest.last
			}

			Item {
				Layout.fillHeight: true
			}
		}
	}
}
