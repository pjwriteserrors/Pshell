pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes
import "NiriColor.js" as NiriColor
import "RuleSchema.js" as RuleSchema

// One thing a rule does, with the control that fits it. `node` is the
// property's node in the rule; changes come back whole as changed(node).
Rectangle {
	id: root

	property string kind: "window"
	property var node: ({ name: "", args: [], props: {} })
	readonly property var info: RuleSchema.info(root.kind, root.node.name)
	readonly property var arg: root.node.args?.[0]

	signal changed(var node)
	signal removed

	function withArgs(args) {
		return Object.assign({}, root.node, { args: args });
	}

	Layout.fillWidth: true
	implicitHeight: column.implicitHeight + 24
	radius: Theme.radius.large
	color: Theme.layer2

	ColumnLayout {
		id: column

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Glyph {
				icon: root.info.icon
				size: 16
				color: Theme.primary
			}

			StyledText {
				Layout.fillWidth: true
				text: root.info.label
				font.weight: Font.DemiBold
			}

			// yes / no right in the header
			Segmented {
				visible: root.info.type === "bool"
				Layout.preferredWidth: 140
				implicitHeight: 28
				options: [{ value: "true", label: "Yes" }, { value: "false", label: "No" }]
				current: root.arg === false ? "false" : "true"
				onSelected: value => root.changed(root.withArgs([value === "true"]))
			}

			IconButton {
				implicitWidth: 26
				implicitHeight: 26
				iconSize: 14
				icon: "close"
				onClicked: root.removed()
			}
		}

		// ── monitor ─────────────────────────────────────────────────────
		MonitorPicker {
			visible: root.info.type === "output"
			Layout.fillWidth: true
			Layout.preferredHeight: 90
			optional: false
			picked: String(root.arg ?? "")
			onChosen: name => root.changed(root.withArgs([name]))
		}

		// ── workspace ───────────────────────────────────────────────────
		Flow {
			visible: root.info.type === "workspace"
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: NiriSettings.items("workspace").filter(w => !w.disabled).map(w => String(w.args[0]))

				delegate: Chip {
					required property string modelData

					text: modelData
					icon: "view_grid_outline"
					selected: String(root.arg) === modelData
					onClicked: root.changed(root.withArgs([modelData]))
				}
			}

			StyledText {
				visible: NiriSettings.items("workspace").length === 0
				text: "Name workspaces on the Workspaces page first"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// ── width / height ──────────────────────────────────────────────
		ColumnLayout {
			id: sizeBox

			visible: root.info.type === "size"
			Layout.fillWidth: true
			spacing: 8

			readonly property var size: Nodes.size(root.node)

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1]

					delegate: Chip {
						required property real modelData

						text: Nodes.fraction(modelData)
						selected: !!sizeBox.size && sizeBox.size.kind === "proportion" && Math.abs(sizeBox.size.value - modelData) < 0.002
						onClicked: root.changed(Nodes.sizeNode(root.node.name, { kind: "proportion", value: modelData }))
					}
				}

				Chip {
					visible: root.node.name === "default-column-width"
					text: "App decides"
					icon: "application_outline"
					selected: !sizeBox.size
					onClicked: root.changed(Nodes.sizeNode(root.node.name, null))
				}
			}

			RowLayout {
				spacing: 8

				StyledText {
					text: "or exactly"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				NumberScrub {
					value: sizeBox.size?.kind === "fixed" ? sizeBox.size.value : 800
					from: 50
					to: 8000
					step: 10
					speed: 4
					unit: " px"
					opacity: sizeBox.size?.kind === "fixed" ? 1 : 0.55
					onMoved: v => root.changed(Nodes.sizeNode(root.node.name, { kind: "fixed", value: v }))
				}
			}
		}

		// ── floating position: a screen with nine anchors ───────────────
		RowLayout {
			id: posBox

			visible: root.info.type === "position"
			Layout.fillWidth: true
			spacing: 16

			readonly property string anchorName: String(root.node.props?.["relative-to"] ?? "top-left")
			readonly property real px: Number(root.node.props?.x ?? 0)
			readonly property real py: Number(root.node.props?.y ?? 0)

			Rectangle {
				id: mini

				Layout.preferredWidth: 170
				Layout.preferredHeight: 100
				radius: 8
				color: Theme.layer3

				readonly property var spots: ({
					"top-left": [0, 0], "top": [0.5, 0], "top-right": [1, 0],
					"left": [0, 0.5], "right": [1, 0.5],
					"bottom-left": [0, 1], "bottom": [0.5, 1], "bottom-right": [1, 1]
				})

				// the window where it would open
				Rectangle {
					readonly property var at: mini.spots[posBox.anchorName] ?? [0, 0]
					readonly property real sx: at[0] === 1 ? -1 : 1
					readonly property real sy: at[1] === 1 ? -1 : 1

					width: 46
					height: 30
					radius: 4
					color: Qt.alpha(Theme.primary, 0.7)
					x: Math.max(0, Math.min(mini.width - width, at[0] * (mini.width - width) + sx * posBox.px / 12))
					y: Math.max(0, Math.min(mini.height - height, at[1] * (mini.height - height) + sy * posBox.py / 12))

					Behavior on x {
						SpatialAnim {}
					}
					Behavior on y {
						SpatialAnim {}
					}
				}

				Repeater {
					model: Object.keys(mini.spots)

					delegate: Rectangle {
						required property string modelData
						readonly property var at: mini.spots[modelData]

						x: at[0] * (mini.width - 14)
						y: at[1] * (mini.height - 14)
						width: 14
						height: 14
						radius: 7
						color: posBox.anchorName === modelData ? Theme.primary : Qt.alpha(Theme.text, 0.25)
						border.width: 2
						border.color: Theme.layer3

						MouseArea {
							anchors.fill: parent
							anchors.margins: -6
							cursorShape: Qt.PointingHandCursor
							onClicked: root.changed(Object.assign({}, root.node, { args: [], props: Object.assign({ x: 0, y: 0 }, root.node.props, { "relative-to": modelData }) }))
						}
					}
				}
			}

			ColumnLayout {
				spacing: 8

				StyledText {
					text: "Click a dot for the corner or edge it keeps to"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				RowLayout {
					spacing: 8

					StyledText {
						text: "x"
						tone: Theme.textMuted
					}

					NumberScrub {
						value: posBox.px
						from: -4000
						to: 4000
						speed: 2
						onMoved: v => root.changed(Object.assign({}, root.node, { args: [], props: Object.assign({}, root.node.props, { x: v, y: root.node.props?.y ?? 0 }) }))
					}

					StyledText {
						text: "y"
						tone: Theme.textMuted
					}

					NumberScrub {
						value: posBox.py
						from: -4000
						to: 4000
						speed: 2
						onMoved: v => root.changed(Object.assign({}, root.node, { args: [], props: Object.assign({}, root.node.props, { x: root.node.props?.x ?? 0, y: v }) }))
					}
				}
			}
		}

		// ── column display ──────────────────────────────────────────────
		Segmented {
			visible: root.info.type === "display"
			Layout.preferredWidth: 240
			options: [{ value: "normal", label: "Stacked" }, { value: "tabbed", label: "Tabbed" }]
			current: String(root.arg ?? "tabbed")
			onSelected: value => root.changed(root.withArgs([value]))
		}

		// ── pixels ──────────────────────────────────────────────────────
		RowLayout {
			visible: root.info.type === "pixels"
			spacing: 10

			NumberScrub {
				value: Number(root.arg ?? root.info.fallback)
				from: 0
				to: 8000
				step: 10
				speed: 4
				unit: " px"
				onMoved: v => root.changed(root.withArgs([v]))
			}

			StyledText {
				text: "logical pixels – the app has the last word"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// ── opacity: a window over the wallpaper ────────────────────────
		RowLayout {
			visible: root.info.type === "opacity"
			Layout.fillWidth: true
			spacing: 14

			RoundClip {
				Layout.preferredWidth: 90
				Layout.preferredHeight: 56
				radius: 8

				Image {
					anchors.fill: parent
					source: Theme.wal?.wallpaper ? `file://${Theme.wal.wallpaper}` : ""
					fillMode: Image.PreserveAspectCrop
					sourceSize.width: 200
					asynchronous: true
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: 8
					radius: 5
					color: Theme.base
					opacity: Number(root.arg ?? 1)
				}
			}

			ValueSlider {
				from: 0
				to: 1
				step: 0.01
				value: Number(root.arg ?? 1)
				format: v => `${Math.round(v * 100)}%`
				onMoved: v => root.changed(root.withArgs([v]))
			}
		}

		// ── corners ─────────────────────────────────────────────────────
		RowLayout {
			visible: root.info.type === "radius"
			Layout.fillWidth: true
			spacing: 14

			CornerDrag {
				Layout.preferredWidth: 160
				Layout.preferredHeight: 110
				zoom: 1.4
				radius: Number(root.arg ?? 0)
				clipped: true
				onMoved: r => root.changed(root.withArgs([r]))
			}

			StyledText {
				Layout.fillWidth: true
				text: "Pull the corner. Turn on “Cut to the corners” as well so the app's own corners follow."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		// ── ring / border ───────────────────────────────────────────────
		ColumnLayout {
			visible: root.info.type === "ring"
			Layout.fillWidth: true
			spacing: 10

			FlagRow {
				title: Nodes.on(root.node, true) ? "On for these windows" : "Off for these windows"
				checked: Nodes.on(root.node, true)
				onToggled: on => root.changed(Nodes.withOn(root.node, on))
			}

			RingEditor {
				Layout.fillWidth: true
				visible: Nodes.on(root.node, true)
				section: root.node
				defaultActive: root.node.name === "border" ? "#ffc87f" : "#7fc8ff"
				onChanged: s => root.changed(s)
			}
		}

		// ── shadow ──────────────────────────────────────────────────────
		ColumnLayout {
			visible: root.info.type === "shadow"
			Layout.fillWidth: true
			spacing: 10

			FlagRow {
				title: Nodes.on(root.node, true) ? "Shadow on" : "No shadow"
				checked: Nodes.on(root.node, true)
				onToggled: on => root.changed(Nodes.withOn(root.node, on))
			}

			RowLayout {
				visible: Nodes.on(root.node, true)
				Layout.fillWidth: true
				spacing: 14

				ShadowPad {
					Layout.preferredWidth: 200
					Layout.preferredHeight: 140
					offsetX: Number(Nodes.prop(root.node, "offset", "x", 0))
					offsetY: Number(Nodes.prop(root.node, "offset", "y", 5))
					softness: Number(Nodes.arg(root.node, "softness", 30))
					spread: Number(Nodes.arg(root.node, "spread", 5))
					color: String(Nodes.arg(root.node, "color", "#00000070"))
					onMoved: (x, y) => root.changed(Nodes.withNode(root.node, "offset", [], { x: x, y: y }))
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 8

					ValueSlider {
						from: 0
						to: 100
						step: 1
						label: "Softness"
						unit: " px"
						value: Number(Nodes.arg(root.node, "softness", 30))
						onMoved: v => root.changed(Nodes.withArg(root.node, "softness", v))
					}

					ValueSlider {
						from: -30
						to: 60
						step: 1
						label: "Spread"
						unit: " px"
						value: Number(Nodes.arg(root.node, "spread", 5))
						onMoved: v => root.changed(Nodes.withArg(root.node, "spread", v))
					}

					ColorWell {
						label: "Color"
						value: String(Nodes.arg(root.node, "color", "#00000070"))
						onPicked: css => root.changed(Nodes.withArg(root.node, "color", css))
					}
				}
			}
		}

		// ── tab colors ──────────────────────────────────────────────────
		ColumnLayout {
			visible: root.info.type === "tabs"
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [{ kind: "active", label: "Active" }, { kind: "inactive", label: "Inactive" }, { kind: "urgent", label: "Urgent" }]

				delegate: PaintRow {
					required property var modelData

					Layout.fillWidth: true
					section: root.node
					kind: modelData.kind
					label: modelData.label
					fallback: modelData.kind === "active" ? "#7fc8ff" : (modelData.kind === "urgent" ? "#9b0000" : "#505050")
					onChanged: s => root.changed(s)
				}
			}
		}

		// ── background effect ───────────────────────────────────────────
		EffectEditor {
			visible: root.info.type === "effect"
			Layout.fillWidth: true
			section: root.node
			onChanged: s => root.changed(s)
		}

		// ── pop-ups ─────────────────────────────────────────────────────
		ColumnLayout {
			visible: root.info.type === "popups"
			Layout.fillWidth: true
			spacing: 10

			ValueSlider {
				from: 0
				to: 1
				step: 0.01
				label: "Opacity"
				value: Number(Nodes.arg(root.node, "opacity", 1))
				format: v => `${Math.round(v * 100)}%`
				onMoved: v => root.changed(Nodes.withArg(root.node, "opacity", v))
			}

			ValueSlider {
				from: 0
				to: 30
				step: 1
				label: "Corners"
				unit: " px"
				value: Number(Nodes.arg(root.node, "geometry-corner-radius", 0))
				onMoved: v => root.changed(v > 0 ? Nodes.withArg(root.node, "geometry-corner-radius", v) : Nodes.without(root.node, "geometry-corner-radius"))
			}

			EffectEditor {
				Layout.fillWidth: true
				section: Nodes.get(root.node, "background-effect")
				onChanged: s => root.changed(Nodes.withChild(root.node, Object.assign({}, s, { name: "background-effect" })))
			}
		}

		// ── sharing ─────────────────────────────────────────────────────
		RowLayout {
			visible: root.info.type === "blockout"
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ value: "screencast", title: "Screen sharing", subtitle: "Black in screencasts (OBS, video calls)" },
					{ value: "screen-capture", title: "Every capture", subtitle: "Screenshots of niri too" }
				]

				delegate: OptionTile {
					id: blockTile

					required property var modelData

					title: blockTile.modelData.title
					subtitle: blockTile.modelData.subtitle
					selected: String(root.arg ?? "screencast") === blockTile.modelData.value
					onClicked: root.changed(root.withArgs([blockTile.modelData.value]))

					Rectangle {
						anchors.centerIn: parent
						width: 80
						height: 50
						radius: 6
						color: Theme.layer3

						Rectangle {
							anchors.centerIn: parent
							width: 40
							height: 26
							radius: 4
							color: "black"

							Glyph {
								anchors.centerIn: parent
								icon: "eye_off_outline"
								size: 13
								color: "#888"
							}
						}
					}
				}
			}
		}

		// ── scroll factor ───────────────────────────────────────────────
		ValueSlider {
			visible: root.info.type === "factor"
			from: 0.1
			to: 4
			step: 0.05
			decimals: 2
			value: Number(root.arg ?? 1)
			format: v => `${Number(v).toFixed(2)}×`
			onMoved: v => root.changed(root.withArgs([v]))
		}

		// ── anything else, as written ───────────────────────────────────
		StyledText {
			visible: root.info.type === "raw"
			Layout.fillWidth: true
			text: `${root.node.name} ${(root.node.args || []).join(" ")}`
			font.family: Theme.monoFamily
			tone: Theme.textMuted
		}
	}
}
