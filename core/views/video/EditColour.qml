pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "../viewer/Recipe.js" as Recipe

// Light and colour for the film, as the picture viewer has them (the same
// sliders, looks, curve and tints, the same shader): a look to start from,
// the sliders, the tone curve, tints for shadows and highlights. It all
// shows live while it moves and is one step (undo) when it is let go.
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var recipe: Video.recipe
	readonly property bool shown: !!root.editor && root.editor.tool === "colour"
	// the theme's own looks first; they change with the theme
	readonly property var looks: {
		Recipe.setThemeColours(Theme.primary, Theme.secondary, Theme.tertiary);
		return [{ id: "", label: "None" }].concat(Recipe.allLooks());
	}
	property string channel: "rgb"
	// the moment the looks are shown on (a still of it, small)
	property string still: ""
	readonly property real stillW: 240
	readonly property real stillH: root.stillW * (root.editor?.stage?.srcH ?? 9) / Math.max(1, root.editor?.stage?.srcW ?? 16)

	title: "Colour"
	subtitle: Recipe.colourIsPlain(root.recipe) ? "As it was filmed" : (root.recipe.look ? `Look: ${Recipe.lookById(root.recipe.look)?.label ?? root.recipe.look}` : "Changed by hand")
	closable: false

	// a look laid over the colours (Recipe.withLook knows only a picture's
	// recipe: its colour parts are taken over, the rest of the film's stays)
	function applyLook(id) {
		root.editor.change(r => {
			const l = Recipe.withLook(r, id);
			r.adjust = l.adjust;
			r.curves = l.curves;
			r.tones = l.tones;
			r.look = l.look;
		});
	}

	function setValue(id, value, live) {
		const fn = r => {
			r.adjust = r.adjust || {};
			if (Math.abs(value) < 1e-4) delete r.adjust[id];
			else r.adjust[id] = Math.round(value * 100) / 100;
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function setCurve(points, live) {
		const channel = root.channel;
		const fn = r => {
			r.curves = r.curves || {};
			r.curves[channel] = points.map(p => [Math.round(p[0] * 1000) / 1000, Math.round(p[1] * 1000) / 1000]);
			if (Recipe.curveIsFlat(r.curves[channel])) delete r.curves[channel];
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function setTone(key, value, live) {
		const fn = r => {
			r.tones = r.tones || {};
			r.tones[key] = value;
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function resetColour() {
		root.editor.change(r => {
			r.adjust = {};
			r.curves = {};
			r.tones = {};
			r.look = "";
		});
	}

	// a still for the looks: taken when the panel opens and the playhead rests
	function takeStill() {
		if (!root.shown || !Video.current || !root.editor) return;
		const at = Video.outToSource(root.editor.playhead);
		Video.frameOf(at.src, at.t, file => {
			if (file) root.still = file;
		}, root.stillW);
	}

	onShownChanged: if (root.shown) stillTimer.restart()
	onEditorChanged: stillTimer.restart()

	Connections {
		target: root.editor

		function onPlayheadChanged() {
			if (root.shown && !Video.playing) stillTimer.restart();
		}
	}

	Timer {
		id: stillTimer

		interval: 700
		onTriggered: root.takeStill()
	}

	Row {
		width: parent.width
		spacing: 8

		// before | after side by side
		TextButton {
			text: "Before and after"
			icon: "compare"
			variant: (root.editor?.split ?? 0) > 0 ? "filled" : "tonal"
			onActivated: root.editor.split = root.editor.split > 0 ? 0 : 0.5
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

	RevertHeader {
		width: parent.width
		text: "Looks"
		changed: !!root.recipe.look
		onReverted: root.applyLook("")
	}

	// a row of small stills, each the moment in that look
	ListView {
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
			onClicked: root.applyLook(lookTile.modelData.id)

			Rectangle {
				id: tileFrame

				width: 72
				height: 72
				radius: Theme.radius.medium
				color: Theme.layer2
				border.width: lookTile.current ? 2 : 0
				border.color: root.accent
				clip: true

				Develop {
					readonly property real k: Math.max(72 / Math.max(1, width), 72 / Math.max(1, height))

					anchors.centerIn: parent
					transformOrigin: Item.Center
					scale: k
					source: root.still
					sourceWidth: root.stillW
					sourceHeight: root.stillH
					previewSide: 240
					recipe: Recipe.withLook(Recipe.blank(), lookTile.modelData.id)
					visible: root.still !== ""
				}
			}

			StyledText {
				anchors.top: tileFrame.bottom
				anchors.topMargin: 5
				width: 72
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				text: lookTile.modelData.label
				font.pixelSize: Theme.size.small
				tone: lookTile.current ? root.accent : Theme.textMuted
			}
		}
	}

	Repeater {
		model: ["Light", "Colour", "Effects"]

		delegate: Column {
			id: group

			required property string modelData

			width: parent?.width ?? 300
			spacing: 4

			RevertHeader {
				width: group.width
				text: group.modelData
				changed: Recipe.SLIDERS.some(s => s.group === group.modelData && Math.abs(Recipe.value(root.recipe, s.id)) > 1e-4)
				onReverted: root.editor.change(r => {
					r.adjust = r.adjust || {};
					for (const s of Recipe.SLIDERS) if (s.group === group.modelData) delete r.adjust[s.id];
				})
			}

			Repeater {
				model: Recipe.SLIDERS.filter(s => s.group === group.modelData)

				delegate: TuneSlider {
					required property var modelData

					width: group.width
					label: modelData.label
					icon: modelData.icon
					accent: root.accent
					from: modelData.min ?? -1
					value: Recipe.value(root.recipe, modelData.id)
					onMoved: value => root.setValue(modelData.id, value, true)
					onCommitted: value => {
						root.setValue(modelData.id, value, true);
						root.editor.endDrag();
					}
				}
			}

			// the spatial ones are ffmpeg's in the export, the rest a lookup table
			StyledText {
				visible: group.modelData === "Effects"
				width: group.width
				wrapMode: Text.WordWrap
				text: "Sharpen, less noise, vignette and grain are made by ffmpeg's own filters in the export – close to this, not the same. Light, colour, the curve and the tints come out exactly as seen."
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}
		}
	}

	RevertHeader {
		width: parent.width
		text: "Curve"
		changed: !Recipe.curveIsFlat(root.recipe.curves?.[root.channel])
		onReverted: root.setCurve([[0, 0], [1, 1]], false)
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
		histogram: []
		onMoved: points => root.setCurve(points, true)
		onCommitted: points => {
			root.setCurve(points, true);
			root.editor.endDrag();
		}
	}

	RevertHeader {
		width: parent.width
		text: "Tint shadows and highlights"
		changed: Recipe.tonesOn(root.recipe)
		onReverted: root.editor.change(r => r.tones = {})
	}

	Repeater {
		model: [{ key: "shadow", label: "Shadows" }, { key: "highlight", label: "Highlights" }]

		delegate: Column {
			id: toneRow

			required property var modelData
			readonly property string colourKey: modelData.key
			readonly property string amountKey: modelData.key + "Amount"
			readonly property color picked: root.recipe.tones?.[colourKey] ?? "#808080"

			width: parent?.width ?? 300
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
								const colour = parent.modelData;
								root.editor.change(r => {
									r.tones = r.tones || {};
									r.tones[toneRow.colourKey] = colour;
									if (!(Number(r.tones[toneRow.amountKey]) > 0)) r.tones[toneRow.amountKey] = 0.4;
								});
							}
						}
					}
				}
			}

			TuneSlider {
				width: toneRow.width
				label: toneRow.modelData.label
				icon: "format_color_fill"
				from: 0
				accent: toneRow.picked
				value: Number(root.recipe.tones?.[toneRow.amountKey]) || 0
				onMoved: value => root.setTone(toneRow.amountKey, value, true)
				onCommitted: value => {
					root.setTone(toneRow.amountKey, value, true);
					root.editor.endDrag();
				}
			}
		}
	}
}
