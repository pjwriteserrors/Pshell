pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
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
	// the page shows: its cards rise in again
	property bool current: true
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
		spacing: 16

		// ── the part ─────────────────────────────────────────────────────
		Rectangle {
			id: stage

			Layout.fillHeight: true
			Layout.preferredWidth: root.windowed ? root.width * 0.62 : 500
			radius: Theme.radius.huge
			color: Theme.layer1
			clip: true

			// a soft light from above, behind the part; it warms while printing
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.alpha(root.showsLive ? Printer.hot : Theme.primary, 0.1)
					}
					GradientStop {
						position: 0.75
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
				opacity: root.job?.slicing && ready ? 0.4 : 1
				onFacePicked: index => {
					Printer.layOnFace(root.job.id, index);
					root.layMode = false;
				}

				Behavior on opacity {
					Anim {}
				}
			}

			// slicing again: the old part dims under a spinner
			Glass {
				anchors.centerIn: parent
				width: slicingRow.implicitWidth + 32
				height: 44
				opacity: !!root.job?.slicing && model.ready ? 1 : 0
				scale: !!root.job?.slicing && model.ready ? 1 : 0.85
				visible: opacity > 0.01

				Behavior on opacity {
					Anim {}
				}
				Behavior on scale {
					SpatialAnim {}
				}

				Row {
					id: slicingRow

					anchors.centerIn: parent
					spacing: 10

					Spinner {
						anchors.verticalCenter: parent.verticalCenter
						width: 20
						height: 20
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: `Slicing with ${root.settings.process}`
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
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

			// a model slicing for the first time
			Column {
				anchors.centerIn: parent
				spacing: 12
				visible: root.isModel && !!root.job?.slicing && !model.ready

				Spinner {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 40
					height: 40
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: "Slicing…"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: root.settings.process
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			// the layer the cut is at
			Glass {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.margins: 12
				width: layerRow.implicitWidth + 24
				height: 30
				visible: model.ready
				opacity: model.intro

				Row {
					id: layerRow

					anchors.centerIn: parent
					spacing: 6

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: "layers_outline"
						size: 14
						color: root.showsLive ? Printer.hot : Theme.primary
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: `${model.shownLayer} / ${model.layers}`
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						tabular: true
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: `${model.cut.toFixed(1)} mm`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						tabular: true
					}
				}
			}

			// laying an STL on a face, turning it automatically, back as it came
			Glass {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 12
				width: tools.implicitWidth + 8
				height: 34
				visible: root.isStl && model.ready && !root.job?.slicing

				Row {
					id: tools

					anchors.centerIn: parent
					spacing: 2

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
							height: 28
							radius: 14
							color: tool.modelData.checked ? Theme.primary : "transparent"
							onClicked: tool.modelData.run()

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
									font.weight: Font.DemiBold
									tone: tool.modelData.checked ? Theme.onPrimary : Theme.text
								}
							}
						}
					}
				}
			}

			// what lay mode asks for
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 50
				width: layHint.implicitWidth + 28
				height: 32
				radius: 16
				color: model.faceColor
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
					tone: "#06222c"
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}
			}

			// the plates of a 3MF
			Glass {
				anchors.left: parent.left
				anchors.bottom: scrubber.visible ? scrubber.top : (live.visible ? live.top : parent.bottom)
				anchors.margins: 12
				width: plates.implicitWidth + 8
				height: 32
				visible: (root.job?.plates ?? 0) > 1

				Row {
					id: plates

					anchors.centerIn: parent
					spacing: 2

					Repeater {
						model: root.job?.plates ?? 0

						delegate: Clickable {
							id: plate

							required property int index
							readonly property bool on: (root.job?.plate ?? 1) === plate.index + 1

							width: plateText.implicitWidth + 22
							height: 26
							radius: 13
							color: plate.on ? Theme.primary : "transparent"
							onClicked: Printer.setPlate(root.job.id, plate.index + 1)

							StyledText {
								id: plateText

								anchors.centerIn: parent
								text: `Plate ${plate.index + 1}`
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								tone: plate.on ? Theme.onPrimary : Theme.text
							}
						}
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

			Glass {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 18
				width: idleHint.implicitWidth + 28
				height: 30
				visible: root.job === null && !Printer.printing

				Row {
					id: idleHint

					anchors.centerIn: parent
					spacing: 6

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: "tray_arrow_down"
						size: 14
						color: Theme.primary
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: "Drop a model or G-code anywhere here"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}
			}

			// a hint until the part was touched once
			Glass {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: parent.top
				anchors.topMargin: 56
				width: dragHint.implicitWidth + 24
				height: 28
				visible: model.ready && opacity > 0.01
				opacity: model.idleSince === 0 && !root.layMode ? 0.85 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}

				Row {
					id: dragHint

					anchors.centerIn: parent
					spacing: 6

					Glyph {
						id: turnIcon

						anchors.verticalCenter: parent.verticalCenter
						icon: "rotate_3d_variant"
						size: 14
						color: Theme.textMuted

						SequentialAnimation on rotation {
							running: dragHint.visible && root.visible
							loops: Animation.Infinite
							NumberAnimation { to: 18; duration: 700; easing.type: Easing.InOutSine }
							NumberAnimation { to: -18; duration: 1400; easing.type: Easing.InOutSine }
							NumberAnimation { to: 0; duration: 700; easing.type: Easing.InOutSine }
						}
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: "Drag to turn · wheel to zoom"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.tiny
					}
				}
			}

			// the layer from above, in the heat of the nozzle
			Glass {
				id: topView

				anchors.right: parent.right
				anchors.bottom: scrubber.visible ? scrubber.top : (live.visible ? live.top : parent.bottom)
				anchors.margins: 12
				width: 108
				height: 108
				radius: Theme.radius.large
				visible: (root.job?.frames ?? 0) > 0 && model.ready
				opacity: model.intro

				Image {
					id: topImage

					anchors.fill: parent
					anchors.margins: 10
					fillMode: Image.PreserveAspectFit
					source: topView.visible ? Printer.frameUrl(root.job, "top", Printer.frameIndex(root.job, model.shownLayer)) : ""
					smooth: true
					mipmap: true
					visible: false
				}

				MultiEffect {
					anchors.fill: topImage
					source: topImage
					colorization: 1
					colorizationColor: root.showsLive ? Printer.hot : Theme.primary
					brightness: 0.25
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 4
					text: "from above"
					tone: Theme.textSubtle
					font.pixelSize: 9
				}
			}

			// the print, along the bottom of the stage
			Item {
				id: live

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 16
				height: 22
				visible: model.ready && model.live

				Rectangle {
					id: track

					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					height: 6
					radius: 3
					color: Qt.alpha(Theme.fg, 0.1)
				}

				Rectangle {
					id: done

					anchors.verticalCenter: parent.verticalCenter
					width: Math.max(height, parent.width * Printer.progress)
					height: 6
					radius: 3
					clip: true
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: Theme.primary
						}
						GradientStop {
							position: 1
							color: Printer.paused ? Theme.warning : Printer.hot
						}
					}

					Behavior on width {
						SpatialAnim {
							duration: Motion.extraLong
						}
					}

					// a glint running along while it works
					Rectangle {
						id: glint

						width: 46
						height: parent.height
						x: -width
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop {
								position: 0
								color: "transparent"
							}
							GradientStop {
								position: 0.5
								color: Qt.rgba(1, 1, 1, 0.55)
							}
							GradientStop {
								position: 1
								color: "transparent"
							}
						}

						NumberAnimation on x {
							running: live.visible && !Printer.paused && root.visible
							from: -glint.width
							to: done.width + glint.width
							duration: 1800
							loops: Animation.Infinite
							easing.type: Easing.InOutQuad
						}
					}
				}

				// the nozzle's spot at the end
				Rectangle {
					x: done.width - width / 2
					anchors.verticalCenter: parent.verticalCenter
					width: 14
					height: 14
					radius: 7
					color: Printer.paused ? Theme.warning : Printer.hot
					border.width: 3
					border.color: Theme.layer1

					Rectangle {
						anchors.centerIn: parent
						width: 26
						height: 26
						radius: 13
						z: -1
						color: Qt.alpha(Printer.hot, 0.35)

						SequentialAnimation on scale {
							running: live.visible && !Printer.paused && root.visible
							loops: Animation.Infinite
							NumberAnimation { from: 0.5; to: 1.2; duration: 1000; easing.type: Easing.OutQuad }
							NumberAnimation { to: 0.5; duration: 1000; easing.type: Easing.InQuad }
						}
					}
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
					height: knob.pressed || knob.containsMouse ? 8 : 6
					radius: height / 2
					color: Qt.alpha(Theme.fg, 0.1)

					Behavior on height {
						SpatialAnim {}
					}
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: Math.max(height, parent.width * model.scrub)
					height: knob.pressed || knob.containsMouse ? 8 : 6
					radius: height / 2
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

					Behavior on height {
						SpatialAnim {}
					}
				}

				Rectangle {
					x: parent.width * model.scrub - width / 2
					anchors.verticalCenter: parent.verticalCenter
					width: knob.pressed ? 20 : (knob.containsMouse ? 17 : 14)
					height: width
					radius: width / 2
					color: Printer.hot
					border.width: 3
					border.color: Theme.layer1

					Behavior on width {
						SpatialAnim {}
					}
				}

				// the layer under the finger, while it scrubs
				Glass {
					x: Math.max(0, Math.min(parent.width - width, parent.width * model.scrub - width / 2))
					y: -height - 8
					width: scrubText.implicitWidth + 20
					height: 24
					opacity: knob.pressed ? 1 : 0
					scale: knob.pressed ? 1 : 0.8
					transformOrigin: Item.Bottom

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {}
					}

					StyledText {
						id: scrubText

						anchors.centerIn: parent
						text: `Layer ${model.shownLayer}`
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						tabular: true
					}
				}

				MouseArea {
					id: knob

					anchors.fill: parent
					anchors.margins: -6
					hoverEnabled: true
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
						y: side.current ? 0 : 24

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

	// a see-through pill over the part
	component Glass: Rectangle {
		radius: height / 2
		color: Qt.alpha(Theme.bg, 0.62)
	}

	// a title and a state beside it
	component Pill: Rectangle {
		id: pill

		property string text: ""
		property color tone: Theme.primary
		property bool pulsing: false

		implicitHeight: 26
		implicitWidth: pillRow.implicitWidth + 22
		radius: 13
		color: Qt.alpha(pill.tone, 0.15)

		Behavior on color {
			ColorAnim {}
		}

		Row {
			id: pillRow

			anchors.centerIn: parent
			spacing: 6

			Rectangle {
				id: pillDot

				anchors.verticalCenter: parent.verticalCenter
				width: 6
				height: 6
				radius: 3
				color: pill.tone

				SequentialAnimation on opacity {
					running: pill.pulsing && pill.visible
					loops: Animation.Infinite
					onRunningChanged: if (!running) pillDot.opacity = 1
					NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutSine }
					NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
				}
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: pill.text
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: pill.tone
			}
		}
	}

	// ── the print running ────────────────────────────────────────────────
	Component {
		id: liveSide

		ColumnLayout {
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: root.job ? Printer.title(root.job) : Printer.nameOf(Printer.project?.filename)
					font.pixelSize: Theme.size.title + 1
					font.weight: Font.Bold
					elide: Text.ElideRight
				}

				Pill {
					text: Printer.status
					tone: Printer.paused ? Theme.warning : Printer.hot
					pulsing: !Printer.paused
				}
			}

			// the progress and when it is ready
			Card {
				Layout.fillWidth: true
				Layout.preferredHeight: 176
				order: 0
				cue: root.current
				color: Qt.tint(Theme.layer1, Qt.alpha(Printer.paused ? Theme.warning : Printer.hot, 0.06))

				RowLayout {
					anchors.fill: parent
					anchors.margins: 12
					anchors.rightMargin: 18
					spacing: 16

					ProgressDial {
						Layout.preferredWidth: 152
						Layout.preferredHeight: 152
						value: Printer.progress
						running: !Printer.paused
						color: Printer.paused ? Theme.warning : Printer.hot
						caption: `layer ${Printer.layer} of ${Printer.layers}`
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						SectionLabel {
							text: "Ready at"
						}

						StyledText {
							text: Printer.secondsLeft > 0 ? Qt.formatTime(new Date(Date.now() + Printer.secondsLeft * 1000), "HH:mm") : "–"
							font.pixelSize: Theme.size.display + 6
							font.weight: Font.Bold
							tabular: true
						}

						Rectangle {
							Layout.fillWidth: true
							Layout.topMargin: 8
							Layout.bottomMargin: 8
							Layout.preferredHeight: 1
							color: Theme.outline
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 16

							Repeater {
								model: ["Left", "Running for"]

								delegate: ColumnLayout {
									id: fact

									required property string modelData
									required property int index

									Layout.fillWidth: true
									spacing: 0

									StyledText {
										text: fact.modelData
										tone: Theme.textMuted
										font.pixelSize: Theme.size.small
									}

									StyledText {
										text: fact.index === 0 ? Format.duration(Printer.secondsLeft) : Format.duration(Number(Printer.project?.print_time ?? 0) * 60)
										font.pixelSize: Theme.size.title
										font.weight: Font.DemiBold
										tabular: true
									}
								}
							}
						}
					}
				}
			}

			// the heaters, the last ten minutes of them behind
			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 80
				spacing: 10

				HeatTile {
					Layout.fillWidth: true
					Layout.fillHeight: true
					order: 1
					cue: root.current
					icon: "printer_3d_nozzle"
					label: "Nozzle"
					now: Number(Printer.temps.curr_nozzle_temp ?? 0)
					target: Number(Printer.temps.target_nozzle_temp ?? 0)
					log: Printer.nozzleLog
				}

				HeatTile {
					Layout.fillWidth: true
					Layout.fillHeight: true
					order: 2
					cue: root.current
					icon: "radiator"
					label: "Bed"
					now: Number(Printer.temps.curr_hotbed_temp ?? 0)
					target: Number(Printer.temps.target_hotbed_temp ?? 0)
					log: Printer.bedLog
				}
			}

			// the spools it prints from (the one feeding turns), the speed
			Card {
				Layout.fillWidth: true
				Layout.preferredHeight: 52
				order: 3
				cue: root.current
				radius: 26

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 8
					spacing: 10

					Row {
						spacing: -6
						visible: spools.count > 0

						Repeater {
							id: spools

							model: (root.job?.mapping ?? []).map(pick => Printer.slot(pick.slot)).filter(slot => slot !== null)

							delegate: Spool {
								required property var modelData

								width: 32
								height: 32
								slot: modelData
							}
						}
					}

					StyledText {
						visible: spools.count > 0
						text: (root.job?.mapping ?? []).map(pick => Printer.slot(pick.slot)?.type).filter(type => !!type).filter((type, i, all) => all.indexOf(type) === i).join(" · ")
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					Item {
						Layout.fillWidth: true
					}

					Segmented {
						Layout.preferredWidth: spools.count > 0 ? 270 : -1
						Layout.fillWidth: spools.count === 0
						Layout.preferredHeight: 36
						color: Theme.layer2
						options: Printer.speeds
						current: String(Printer.speed)
						onSelected: value => Printer.setSpeed(Number(value))
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
					Layout.preferredHeight: 46
					text: Printer.paused ? "Resume" : "Pause"
					icon: Printer.paused ? "play" : "pause"
					variant: Printer.paused ? "filled" : "tonal"
					onActivated: Printer.paused ? Printer.resume() : Printer.pause()
				}

				// stopping is never one stray click away
				HoldButton {
					Layout.fillWidth: true
					Layout.preferredHeight: 46
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
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				text: Printer.title(root.job)
				font.pixelSize: Theme.size.title + 1
				font.weight: Font.Bold
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: {
						const meta = root.job?.meta;
						if (!meta) return [];
						return [
							{ icon: "clock_outline", text: meta.seconds > 0 ? Format.duration(meta.seconds) : "–" },
							{ icon: "weight_gram", text: `${meta.grams} g` },
							{ icon: "layers_outline", text: `${meta.layers} layers` },
							{ icon: "ruler", text: `${meta.height} mm` }
						];
					}

					delegate: Rectangle {
						id: info

						required property var modelData
						required property int index

						width: infoRow.implicitWidth + 20
						height: 28
						radius: 14
						color: Theme.layer1
						opacity: 0
						scale: 0.85

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
									duration: 420
									easing.type: Easing.OutBack
								}
							}
						}

						Row {
							id: infoRow

							anchors.centerIn: parent
							spacing: 6

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: info.modelData.icon
								size: 14
								color: Theme.primary
							}

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								text: info.modelData.text
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
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
				Layout.topMargin: 2
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
					spacing: 10

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

					// the filaments and the ACE slots they come from
					Card {
						Layout.fillWidth: true
						Layout.preferredHeight: slotsColumn.implicitHeight + 24
						order: 2
						radius: Theme.radius.large

						ColumnLayout {
							id: slotsColumn

							anchors.fill: parent
							anchors.margins: 12
							spacing: 10

							RowLayout {
								Layout.fillWidth: true

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
						}
					}

					// the rest, folded away: a line says what it is set to
					Card {
						id: more

						property bool open: false

						Layout.fillWidth: true
						Layout.preferredHeight: 44 + (more.open ? foldColumn.implicitHeight + 10 : 0)
						order: 3
						radius: Theme.radius.large
						clip: true

						Behavior on Layout.preferredHeight {
							SpatialAnim {}
						}

						Clickable {
							anchors.left: parent.left
							anchors.right: parent.right
							height: 44
							radius: Theme.radius.large
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
								anchors.rightMargin: 12
								spacing: 10

								Rectangle {
									Layout.preferredWidth: 26
									Layout.preferredHeight: 26
									radius: 13
									color: more.open ? Theme.primary : Theme.layer3

									Behavior on color {
										ColorAnim {}
									}

									Glyph {
										anchors.centerIn: parent
										icon: "tune_variant"
										size: 14
										color: more.open ? Theme.onPrimary : Theme.text
									}
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

						ColumnLayout {
							id: foldColumn

							x: 12
							y: 48
							width: more.width - 24
							spacing: 12
							opacity: more.open ? 1 : 0

							Behavior on opacity {
								Anim {}
							}

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
					Layout.preferredWidth: 46
					Layout.preferredHeight: 46
					variant: "tonal"
					icon: "folder_open_outline"
					onClicked: Quickshell.execDetached(["xdg-open", root.job.dir])
				}

				// removing takes a second click
				IconButton {
					Layout.preferredWidth: 46
					Layout.preferredHeight: 46
					variant: removing.armed ? "danger" : "tonal"
					icon: removing.armed ? "alert" : "delete_outline"
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
					Layout.preferredHeight: 46
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

			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: Printer.online ? "Ready when you are" : (Printer.error ? "Not reachable" : "Connecting…")
					font.pixelSize: Theme.size.heading + 4
					font.weight: Font.Bold
				}

				Pill {
					text: Printer.online ? "Idle" : "Offline"
					tone: Printer.online ? Theme.success : Theme.danger
					pulsing: !Printer.online
				}
			}

			StyledText {
				Layout.fillWidth: true
				Layout.topMargin: -6
				Layout.bottomMargin: 4
				text: Printer.online ? "Drop a file on the panel, or export from OrcaSlicer into the inbox – the panel opens with it." : (Printer.error ? `${Printer.error}. With LAN mode on, a restart of the printer helps.` : "")
				wrapMode: Text.Wrap
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			// the inbox, as a place to drop on
			Card {
				Layout.fillWidth: true
				Layout.preferredHeight: 70
				order: 0
				cue: root.current
				color: "transparent"

				Clickable {
					id: inboxCard

					anchors.fill: parent
					radius: Theme.radius.huge
					color: inboxCard.hovered ? Theme.primaryContainer : Theme.layer1
					onClicked: Quickshell.execDetached(["xdg-open", Printer.inbox.replace(/^~/, Quickshell.env("HOME"))])

					Shape {
						anchors.fill: parent
						preferredRendererType: Shape.CurveRenderer

						ShapePath {
							strokeColor: inboxCard.hovered ? Theme.primary : Qt.alpha(Theme.fg, 0.16)
							strokeWidth: 1.5
							strokeStyle: ShapePath.DashLine
							dashPattern: [4, 3]
							fillColor: "transparent"

							// the dashes march while the pointer is on it
							NumberAnimation on dashOffset {
								running: inboxCard.hovered
								from: 0
								to: -14
								duration: 600
								loops: Animation.Infinite
							}

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
						anchors.rightMargin: 16
						spacing: 12

						Rectangle {
							Layout.preferredWidth: 42
							Layout.preferredHeight: 42
							radius: 21
							color: Theme.primary

							Glyph {
								id: tray

								anchors.centerIn: parent
								icon: "tray_arrow_down"
								size: 20
								color: Theme.onPrimary

								SequentialAnimation on anchors.verticalCenterOffset {
									running: inboxCard.hovered
									loops: Animation.Infinite
									onRunningChanged: if (!running) tray.anchors.verticalCenterOffset = 0
									NumberAnimation { to: 3; duration: 380; easing.type: Easing.InOutSine }
									NumberAnimation { to: -1; duration: 380; easing.type: Easing.InOutSine }
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								text: "Inbox"
								font.pixelSize: Theme.size.body
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
							size: 16
							color: inboxCard.hovered ? Theme.primary : Theme.textMuted
						}
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

					delegate: Card {
						id: spoolCard

						required property var modelData
						required property int index

						Layout.fillWidth: true
						Layout.preferredHeight: 96
						order: 1 + spoolCard.index
						cue: root.current
						radius: Theme.radius.large
						color: "transparent"

						Clickable {
							id: spoolButton

							anchors.fill: parent
							radius: Theme.radius.large
							color: spoolButton.hovered ? Theme.layer2 : Theme.layer1
							onClicked: Printer.tab = "ace"

							// the colour's glow under the pointer
							Rectangle {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 6
								width: 58
								height: 58
								radius: 29
								visible: spoolCard.modelData.type !== ""
								color: Printer.rgb(spoolCard.modelData.color)
								opacity: spoolButton.hovered ? 0.22 : 0
								scale: spoolButton.hovered ? 1.1 : 0.7

								Behavior on opacity {
									Anim {}
								}
								Behavior on scale {
									SpatialAnim {}
								}
							}

							Spool {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 12
								width: 46
								height: 46
								slot: spoolCard.modelData
								rotation: spoolButton.hovered ? 40 : 0

								Behavior on rotation {
									SpatialAnim {}
								}
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.bottom: parent.bottom
								anchors.bottomMargin: 10
								width: parent.width - 10
								horizontalAlignment: Text.AlignHCenter
								elide: Text.ElideRight
								text: spoolCard.modelData.type || "Empty"
								tone: spoolCard.modelData.type ? Theme.text : Theme.textFaint
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
							}
						}
					}
				}
			}

			SectionLabel {
				Layout.topMargin: 4
				text: "Last print"
				visible: rest.last !== null
			}

			Card {
				Layout.fillWidth: true
				Layout.preferredHeight: 58
				visible: rest.last !== null
				order: 6
				cue: root.current
				radius: Theme.radius.large

				HistoryRow {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 14
					item: rest.last
				}
			}

			Item {
				Layout.fillHeight: true
			}
		}
	}
}
