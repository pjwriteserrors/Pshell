pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Recipe.js" as Recipe
import "Geometry.js" as Geo

// Light and colour: a look to start from, the sliders, the tone curve and
// tints for shadows and highlights. Everything shows live while it moves
// and becomes one step (undo) when it is let go.
Item {
	id: root

	property var histogram: null
	property bool clipWarning: false
	property bool splitShown: false
	signal splitToggled

	readonly property var recipe: Viewer.recipe
	// the theme's own looks first; they change with the theme
	readonly property var looks: {
		Recipe.setThemeColours(Theme.primary, Theme.secondary, Theme.tertiary);
		return [{ id: "", label: "None" }].concat(Recipe.allLooks());
	}
	property string channel: "rgb"
	property bool autoBusy: false

	function setValue(id, value, commit) {
		const next = Recipe.copy(Viewer.recipe);
		if (Math.abs(value) < 1e-4) delete next.adjust[id];
		else next.adjust[id] = Math.round(value * 100) / 100;
		if (commit) Viewer.commit(next);
		else Viewer.preview(next);
	}

	function setCurve(points, commit) {
		const next = Recipe.copy(Viewer.recipe);
		next.curves[root.channel] = points.map(p => [Math.round(p[0] * 1000) / 1000, Math.round(p[1] * 1000) / 1000]);
		if (Recipe.curveIsFlat(next.curves[root.channel])) delete next.curves[root.channel];
		if (commit) Viewer.commit(next);
		else Viewer.preview(next);
	}

	function setTone(key, value, commit) {
		const next = Recipe.copy(Viewer.recipe);
		next.tones[key] = value;
		if (commit) Viewer.commit(next);
		else Viewer.preview(next);
	}

	function auto() {
		if (root.autoBusy || !Viewer.shownPath) return;
		root.autoBusy = true;
		const path = Viewer.path;
		Viewer.request("auto", { path: Viewer.shownPath }, (data, error) => {
			root.autoBusy = false;
			if (Viewer.path !== path) return;
			if (error) return Viewer.fail(error);
			const next = Recipe.copy(Viewer.recipe);
			for (const key in data.adjust || {}) {
				const v = Number(data.adjust[key]) || 0;
				if (Math.abs(v) < 0.01) delete next.adjust[key];
				else next.adjust[key] = v;
			}
			Viewer.commit(next);
			Viewer.say(Recipe.colourIsPlain(next) ? "The picture is fine as it is" : "Light and colour set by the picture", "auto_fix");
		});
	}

	// a border around the picture, in a colour, filled up to a shape
	function setPad(changes, commit) {
		const next = Recipe.copy(commit ? Viewer.recipe : Viewer.committed);
		const pad = Object.assign({ size: 0, color: "#ffffff", aspect: 0 }, next.geometry.pad || {}, changes);
		next.geometry.pad = pad.size > 0 || pad.aspect > 0 ? pad : null;
		next.markup.items = Geo.remapItems((commit ? Viewer.recipe : Viewer.committed).markup?.items ?? [], (commit ? Viewer.recipe : Viewer.committed).geometry, next.geometry, Viewer.info?.width ?? 1, Viewer.info?.height ?? 1);
		if (commit) Viewer.commit(next);
		else Viewer.preview(next);
	}

	readonly property var pad: root.recipe.geometry?.pad ?? null

	function resetColour() {
		const next = Recipe.copy(Viewer.recipe);
		next.adjust = {};
		next.curves = {};
		next.tones = {};
		next.look = "";
		Viewer.commit(next);
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentHeight: column.implicitHeight + 24
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: column

			x: 18
			y: 12
			width: flick.width - 36
			spacing: 14

			Row {
				width: parent.width
				spacing: 8

				TextButton {
					text: root.autoBusy ? "Looking…" : "Auto"
					icon: "auto_fix"
					variant: "filled"
					busy: root.autoBusy
					onActivated: root.auto()
				}

				// before | after side by side (holding the backslash key shows all of before)
				TextButton {
					text: "Compare"
					icon: "compare"
					variant: root.splitShown ? "filled" : "tonal"
					onActivated: root.splitToggled()
				}

				Item {
					width: Math.max(0, parent.width - x - resetButton.width)
					height: 1
				}

				IconButton {
					id: resetButton

					width: 36
					height: 36
					icon: "backup_restore"
					enabled: !Recipe.colourIsPlain(root.recipe)
					opacity: enabled ? 1 : 0.4
					onClicked: root.resetColour()
				}
			}

			Histogram {
				width: parent.width
				values: root.histogram
			}

			Row {
				spacing: 8

				Toggle {
					checked: root.clipWarning
					onToggled: checked => root.clipWarning = checked
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Show clipped light and shadow"
					font.pixelSize: Theme.size.label
					tone: Theme.textMuted
				}
			}

			RevertHeader {
				width: parent.width
				text: "Looks"
				changed: !!root.recipe.look
				onReverted: Viewer.commit(Recipe.withLook(Viewer.recipe, ""))
			}

			// a row of small previews, each the picture in that look
			ListView {
				id: looks

				width: parent.width
				height: 96
				orientation: ListView.Horizontal
				spacing: 8
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				model: root.looks

				delegate: Clickable {
					id: lookTile

					required property var modelData
					readonly property bool current: (root.recipe.look || "") === modelData.id

					width: 72
					height: 96
					onClicked: Viewer.commit(Recipe.withLook(Viewer.recipe, lookTile.modelData.id))

					Rectangle {
						id: frame

						width: 72
						height: 72
						radius: Theme.radius.medium
						color: Theme.layer2
						border.width: lookTile.current ? 2 : 0
						border.color: Theme.primary
						clip: true

						Develop {
							id: mini

							readonly property real k: Math.max(72 / Math.max(1, width), 72 / Math.max(1, height))

							anchors.centerIn: parent
							transformOrigin: Item.Center
							scale: k
							source: Viewer.shownPath
							sourceWidth: Viewer.info?.width ?? 1
							sourceHeight: Viewer.info?.height ?? 1
							previewSide: 200
							recipe: Recipe.withLook(Object.assign(Recipe.blank(), { geometry: root.recipe.geometry }), lookTile.modelData.id)
							visible: Viewer.shownPath !== ""
						}
					}

					StyledText {
						anchors.top: frame.bottom
						anchors.topMargin: 5
						width: 72
						horizontalAlignment: Text.AlignHCenter
						elide: Text.ElideRight
						text: lookTile.modelData.label
						font.pixelSize: Theme.size.small
						tone: lookTile.current ? Theme.primary : Theme.textMuted
					}
				}
			}

			Repeater {
				model: ["Light", "Colour", "Effects"]

				delegate: Column {
					id: group

					required property string modelData

					width: column.width
					spacing: 4

					RevertHeader {
						width: group.width
						text: group.modelData
						changed: Recipe.SLIDERS.some(s => s.group === group.modelData && Math.abs(Recipe.value(root.recipe, s.id)) > 1e-4)
						onReverted: {
							const next = Recipe.copy(Viewer.recipe);
							for (const s of Recipe.SLIDERS) if (s.group === group.modelData) delete next.adjust[s.id];
							Viewer.commit(next);
						}
					}

					Repeater {
						model: Recipe.SLIDERS.filter(s => s.group === group.modelData)

						delegate: TuneSlider {
							required property var modelData

							width: group.width
							label: modelData.label
							icon: modelData.icon
							from: modelData.min ?? -1
							value: Recipe.value(root.recipe, modelData.id)
							onMoved: value => root.setValue(modelData.id, value, false)
							onCommitted: value => root.setValue(modelData.id, value, true)
						}
					}
				}
			}

			RevertHeader {
				width: parent.width
				text: "Curve"
				changed: !Recipe.curveIsFlat(root.recipe.curves?.[root.channel])
				onReverted: root.setCurve([[0, 0], [1, 1]], true)
			}

			Segmented {
				width: parent.width
				height: 34
				options: [{ value: "rgb", label: "Light" }, { value: "r", label: "Red" }, { value: "g", label: "Green" }, { value: "b", label: "Blue" }]
				current: root.channel
				onSelected: value => root.channel = value
			}

			CurvesEditor {
				width: parent.width
				height: width
				points: root.recipe.curves?.[root.channel] ?? [[0, 0], [1, 1]]
				tone: ({ rgb: Theme.text, r: "#ff4d5e", g: "#3ddc84", b: "#4d8dff" })[root.channel]
				histogram: root.histogram ? root.histogram[root.channel === "rgb" ? "l" : root.channel] : []
				onMoved: points => root.setCurve(points, false)
				onCommitted: points => root.setCurve(points, true)
			}

			RevertHeader {
				width: parent.width
				text: "Border"
				changed: !!root.pad
				onReverted: root.setPad({ size: 0, aspect: 0 }, true)
			}

			TuneSlider {
				width: parent.width
				label: "Width"
				icon: "border_outside"
				from: 0
				to: 0.25
				step: 0.002
				value: Number(root.pad?.size ?? 0)
				valueText: `${Math.round(shown * 400)} %`
				onMoved: value => root.setPad({ size: value }, false)
				onCommitted: value => root.setPad({ size: value }, true)
			}

			Row {
				spacing: 6

				Repeater {
					model: ["#ffffff", "#000000", "#f4efe6", "#1c1c1c", String(Theme.primary), String(Theme.base)]

					delegate: Rectangle {
						required property string modelData
						readonly property bool current: !!root.pad && Qt.colorEqual(root.pad.color, modelData)

						width: 24
						height: 24
						radius: 12
						color: modelData
						border.width: current ? 2 : 1
						border.color: current ? Theme.primary : Theme.outline

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: root.setPad({ color: parent.modelData, size: Math.max(Number(root.pad?.size ?? 0), root.pad?.aspect > 0 ? 0 : 0.04) }, true)
						}
					}
				}
			}

			StyledText {
				text: "Filled up to a shape, the whole picture kept"
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}

			Flow {
				width: parent.width
				spacing: 6

				Repeater {
					model: [{ label: "As it is", value: 0 }, { label: "1:1", value: 1 }, { label: "4:5", value: 4 / 5 }, { label: "9:16", value: 9 / 16 }, { label: "16:9", value: 16 / 9 }, { label: "3:2", value: 3 / 2 }]

					delegate: Chip {
						required property var modelData

						text: modelData.label
						selected: Math.abs(Number(root.pad?.aspect ?? 0) - modelData.value) < 1e-3
						onClicked: root.setPad({ aspect: modelData.value }, true)
					}
				}
			}

			RevertHeader {
				width: parent.width
				text: "Tint shadows and highlights"
				changed: Recipe.tonesOn(root.recipe)
				onReverted: {
					const next = Recipe.copy(Viewer.recipe);
					next.tones = {};
					Viewer.commit(next);
				}
			}

			Repeater {
				model: [{ key: "shadow", label: "Shadows" }, { key: "highlight", label: "Highlights" }]

				delegate: Column {
					id: toneRow

					required property var modelData
					readonly property string colourKey: modelData.key
					readonly property string amountKey: modelData.key + "Amount"
					readonly property color picked: root.recipe.tones?.[colourKey] ?? "#808080"

					width: column.width
					spacing: 6

					Row {
						spacing: 6

						Repeater {
							model: ["#d9534f", "#f0883e", "#f5d76e", "#6cc070", "#2f9e9e", "#4a7aa8", "#7b5ea7", "#c9709b"]

							delegate: Rectangle {
								required property string modelData
								readonly property bool current: Qt.colorEqual(toneRow.picked, modelData)

								width: 24
								height: 24
								radius: 12
								color: modelData
								border.width: current ? 2 : 0
								border.color: Theme.text
								scale: swatchMouse.containsMouse ? 1.12 : 1

								Behavior on scale {
									SpatialAnim {}
								}

								MouseArea {
									id: swatchMouse

									anchors.fill: parent
									hoverEnabled: true
									cursorShape: Qt.PointingHandCursor
									onClicked: {
										const next = Recipe.copy(Viewer.recipe);
										next.tones[toneRow.colourKey] = parent.modelData;
										if (!(Number(next.tones[toneRow.amountKey]) > 0)) next.tones[toneRow.amountKey] = 0.4;
										Viewer.commit(next);
									}
								}
							}
						}
					}

					TuneSlider {
						width: column.width
						label: toneRow.modelData.label
						icon: "format_color_fill"
						from: 0
						accent: toneRow.picked
						value: Number(root.recipe.tones?.[toneRow.amountKey]) || 0
						onMoved: value => root.setTone(toneRow.amountKey, value, false)
						onCommitted: value => root.setTone(toneRow.amountKey, value, true)
					}
				}
			}
		}
	}
}
