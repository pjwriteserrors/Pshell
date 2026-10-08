pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes

// Layout: how niri places windows – gaps, struts, centering, the sizes Mod+R
// steps through, new columns. The workspace on the right is drawn from these
// settings; its gap and edges can be dragged.
SettingsPage {
	id: root

	title: "Layout"
	description: "How windows sit next to each other. The workspace on the right follows every change – drag its gap and its edges."
	asideWidth: Math.min(560, Math.max(380, width * 0.42))

	readonly property var monitor: {
		const outputs = NiriSettings.live.outputs || [];
		return outputs.find(o => o.name === Host.primaryOutput && o.logical) ?? outputs.find(o => o.logical) ?? null;
	}
	readonly property real logicalWidth: root.monitor?.logical?.width ?? 1920
	readonly property real logicalHeight: root.monitor?.logical?.height ?? 1080

	readonly property real gaps: Number(NiriSettings.arg(["layout", "gaps"], 16))
	readonly property var struts: ({
		left: Number(NiriSettings.arg(["layout", "struts", "left"], 0)),
		right: Number(NiriSettings.arg(["layout", "struts", "right"], 0)),
		top: Number(NiriSettings.arg(["layout", "struts", "top"], 0)),
		bottom: Number(NiriSettings.arg(["layout", "struts", "bottom"], 0))
	})
	readonly property string centerMode: String(NiriSettings.arg(["layout", "center-focused-column"], "never"))
	readonly property bool centerSingle: NiriSettings.flag(["layout", "always-center-single-column"])
	readonly property string display: String(NiriSettings.arg(["layout", "default-column-display"], "normal"))
	readonly property var widthNode: NiriSettings.node(["layout", "preset-column-widths"])
	readonly property var heightNode: NiriSettings.node(["layout", "preset-window-heights"])
	readonly property var thirds: [{ kind: "proportion", value: 1 / 3 }, { kind: "proportion", value: 0.5 }, { kind: "proportion", value: 2 / 3 }]
	readonly property var widths: root.widthNode ? root.sizes(root.widthNode) : root.thirds
	readonly property var heights: root.heightNode ? root.sizes(root.heightNode) : root.thirds
	readonly property var defaultNode: NiriSettings.node(["layout", "default-column-width"])
	readonly property var defaultWidth: root.defaultNode ? Nodes.size(root.defaultNode) : { kind: "proportion", value: 0.5 }
	readonly property bool windowsDecide: !!root.defaultNode && !Nodes.size(root.defaultNode)
	// the corners every window gets (a window rule that matches all)
	readonly property real cornerRadius: {
		let radius = 0;
		for (const rule of NiriSettings.items("window-rule")) {
			if (rule.disabled || (rule.children || []).some(c => c.name === "match" || c.name === "exclude")) continue;
			const r = Nodes.arg(rule, "geometry-corner-radius", null);
			if (r !== null) radius = Number(r);
		}
		return radius;
	}

	function sizes(node) {
		return (node.children || []).filter(c => (c.name === "proportion" || c.name === "fixed") && !c.disabled).map(c => ({ kind: c.name, value: Number(c.args[0]) }));
	}

	function sizeNodes(list) {
		return list.map(p => NiriSettings.leaf(p.kind, [p.kind === "fixed" ? Math.round(p.value) : Number(p.value.toFixed(5))]));
	}

	function share(p) {
		return !p ? 0.5 : (p.kind === "fixed" ? Math.min(1, p.value / root.logicalWidth) : p.value);
	}

	function setStrut(side, value) {
		const next = Object.assign({}, root.struts);
		next[side] = value;
		const kids = ["left", "right", "top", "bottom"].filter(s => Number(next[s]) !== 0).map(s => NiriSettings.leaf(s, [Number(next[s])]));
		NiriSettings.setChildren(["layout", "struts"], kids, "Struts changed", "struts");
	}

	aside: ColumnLayout {
		anchors.fill: parent
		spacing: 12

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: preview.implicitHeight + 32
			radius: Theme.radius.huge
			color: Theme.layer1

			LayoutPreview {
				id: preview

				anchors.fill: parent
				anchors.margins: 16
				implicitHeight: (width) * root.logicalHeight / root.logicalWidth
				logicalWidth: root.logicalWidth
				logicalHeight: root.logicalHeight
				gaps: root.gaps
				struts: root.struts
				centerMode: root.centerMode
				centerSingle: root.centerSingle
				background: String(NiriSettings.arg(["layout", "background-color"], "#262626"))
				peekBackground: backgroundHover.hovered
				cornerRadius: root.cornerRadius
				columns: [
					{ width: root.windowsDecide ? 0.5 : root.share(root.defaultWidth), tabs: 1 },
					{ width: root.share(root.widths[0]), tabs: root.display === "tabbed" ? 3 : 1 },
					{ width: root.windowsDecide ? 0.5 : root.share(root.defaultWidth), tabs: 1 },
					{ width: root.share(root.widths[root.widths.length - 1]), tabs: 1 }
				]
				ring: NiriSettings.node(["layout", "focus-ring"])
				border: NiriSettings.node(["layout", "border"])
				shadow: NiriSettings.node(["layout", "shadow"])
				tabIndicator: NiriSettings.node(["layout", "tab-indicator"])
				gapsHandle: true
				strutHandles: true
				onGapsMoved: v => NiriSettings.set(["layout", "gaps"], v, `Gaps ${v} px`, "gaps")
				onStrutMoved: (side, v) => root.setStrut(side, v)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Glyph {
				icon: "gesture_tap"
				size: 15
				color: Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: "Click a window to focus it, drag the bar between the first two to set the gaps, drag the marks on the edges for struts."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Item {
			Layout.fillHeight: true
		}
	}

	// ── gaps ───────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "gaps"
		title: "Gaps"
		subtitle: "Space around and between windows, in logical pixels"
		icon: "arrow_expand_horizontal"
		modified: NiriSettings.has(["layout", "gaps"])
		onReset: NiriSettings.reset(["layout", "gaps"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			ValueSlider {
				from: 0
				to: 64
				step: 1
				unit: " px"
				icon: "arrow_expand_horizontal"
				value: root.gaps
				onMoved: v => NiriSettings.set(["layout", "gaps"], v, `Gaps ${v} px`, "gaps")
			}

			// a few that look good, as chips
			Repeater {
				model: [0, 8, 16, 24]

				delegate: Chip {
					required property int modelData

					text: `${modelData}`
					selected: root.gaps === modelData
					onClicked: NiriSettings.set(["layout", "gaps"], modelData, `Gaps ${modelData} px`, "gaps")
				}
			}
		}
	}

	// ── struts ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "struts"
		title: "Struts"
		subtitle: "Room left free at the screen edges, like an outer gap. Left and right struts let the next window peek in."
		icon: "border_outside"
		modified: NiriSettings.has(["layout", "struts"]) && NiriSettings.kids(["layout", "struts"]).length > 0
		onReset: NiriSettings.reset(["layout", "struts"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 22

			// the four edges around a small screen
			Item {
				Layout.preferredWidth: 250
				Layout.preferredHeight: 150

				Rectangle {
					anchors.centerIn: parent
					width: 120
					height: 70
					radius: 8
					color: Theme.layer2
					border.width: 1
					border.color: Theme.outline

					Rectangle {
						x: Math.max(2, Math.min(40, root.struts.left / 4)) + 4
						y: Math.max(2, Math.min(24, root.struts.top / 4)) + 4
						width: parent.width - x - Math.max(2, Math.min(40, root.struts.right / 4)) - 4
						height: parent.height - y - Math.max(2, Math.min(24, root.struts.bottom / 4)) - 4
						radius: 4
						color: Qt.alpha(Theme.primary, 0.25)
						border.width: 1
						border.color: Theme.primary

						Behavior on x {
							SpatialAnim {}
						}
						Behavior on y {
							SpatialAnim {}
						}
						Behavior on width {
							SpatialAnim {}
						}
						Behavior on height {
							SpatialAnim {}
						}
					}
				}

				NumberScrub {
					anchors.verticalCenter: parent.verticalCenter
					anchors.left: parent.left
					value: root.struts.left
					from: -64
					to: 400
					onMoved: v => root.setStrut("left", v)
				}

				NumberScrub {
					anchors.verticalCenter: parent.verticalCenter
					anchors.right: parent.right
					value: root.struts.right
					from: -64
					to: 400
					onMoved: v => root.setStrut("right", v)
				}

				NumberScrub {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.top
					value: root.struts.top
					from: -64
					to: 400
					onMoved: v => root.setStrut("top", v)
				}

				NumberScrub {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					value: root.struts.bottom
					from: -64
					to: 400
					onMoved: v => root.setStrut("bottom", v)
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: "Drag a number sideways, or the edges of the workspace on the right. Negative struts push windows past the edge."
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				// inner gaps only: struts that eat the outer gap
				TextButton {
					text: "Gaps only between windows"
					icon: "arrow_collapse_horizontal"
					variant: root.struts.left === -root.gaps && root.struts.right === -root.gaps && root.gaps > 0 ? "filled" : "tonal"
					onActivated: {
						const g = -root.gaps;
						NiriSettings.setChildren(["layout", "struts"], ["left", "right", "top", "bottom"].map(s => NiriSettings.leaf(s, [g])), "Outer gaps removed", "");
					}
				}

				TextButton {
					text: "Let the neighbours peek in"
					icon: "arrow_expand_horizontal"
					variant: root.struts.left === 64 && root.struts.right === 64 ? "filled" : "tonal"
					onActivated: NiriSettings.setChildren(["layout", "struts"], [NiriSettings.leaf("left", [64]), NiriSettings.leaf("right", [64])], "Struts left and right", "")
				}
			}
		}
	}

	// ── centering ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "centering"
		title: "Centering"
		subtitle: "Where the view goes when the focus moves to another column"
		icon: "format_horizontal_align_center"
		modified: NiriSettings.has(["layout", "center-focused-column"])
		onReset: NiriSettings.reset(["layout", "center-focused-column"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ value: "never", title: "Only when needed", subtitle: "Scrolls just enough to show it" },
					{ value: "on-overflow", title: "On overflow", subtitle: "Centers when it would not fit with the last one" },
					{ value: "always", title: "Always", subtitle: "The focused column is always in the middle" }
				]

				delegate: OptionTile {
					id: tile

					required property var modelData

					title: tile.modelData.title
					subtitle: tile.modelData.subtitle
					selected: root.centerMode === tile.modelData.value
					onClicked: NiriSettings.set(["layout", "center-focused-column"], tile.modelData.value, `Centering: ${tile.modelData.title.toLowerCase()}`, "")

					CenterDemo {
						anchors.fill: parent
						mode: tile.modelData.value
						playing: tile.playing && root.active
					}
				}
			}
		}

		FlagRow {
			title: "Center a column that is alone"
			subtitle: "A single column on a workspace sits in the middle, whatever the setting above says"
			checked: root.centerSingle
			onToggled: on => NiriSettings.setFlag(["layout", "always-center-single-column"], on)

			Rectangle {
				anchors.fill: parent
				radius: 6
				color: Theme.layer2

				Rectangle {
					width: parent.width * 0.42
					height: parent.height - 10
					y: 5
					x: root.centerSingle ? (parent.width - width) / 2 : 5
					radius: 4
					color: Theme.primary
					opacity: 0.8

					Behavior on x {
						SpatialAnim {}
					}
				}
			}
		}
	}

	// ── widths ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "widths"
		title: "Column widths"
		subtitle: "The widths Mod+R steps through, and the one new windows open with"
		icon: "arrow_split_vertical"
		modified: !!root.widthNode || !!root.defaultNode
		onReset: {
			NiriSettings.reset(["layout", "preset-column-widths"]);
			NiriSettings.reset(["layout", "default-column-width"]);
		}

		PresetRuler {
			Layout.fillWidth: true
			presets: root.widths
			defaultSize: root.windowsDecide ? null : root.defaultWidth
			logicalLength: root.logicalWidth
			onPresetsEdited: list => NiriSettings.setChildren(["layout", "preset-column-widths"], root.sizeNodes(list), "Column widths changed", "widths")
			onDefaultPicked: (size, empty) => NiriSettings.setChildren(["layout", "default-column-width"], size ? root.sizeNodes([size]) : [], `New windows open ${size ? (size.kind === "fixed" ? size.value + " px" : Nodes.fraction(size.value)) : "as they like"} wide`, "")
		}

		RowLayout {
			spacing: 8

			StyledText {
				text: "New windows:"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}

			Chip {
				text: root.windowsDecide ? "Decide themselves" : (root.defaultWidth.kind === "fixed" ? `${root.defaultWidth.value} px` : Nodes.fraction(root.defaultWidth.value))
				icon: "star"
				selected: true
			}

			Chip {
				text: "Let them decide"
				icon: "application_outline"
				visible: !root.windowsDecide
				onClicked: NiriSettings.setChildren(["layout", "default-column-width"], [], "New windows decide their width", "")
			}
		}
	}

	// ── heights ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "heights"
		title: "Window heights"
		subtitle: "The heights Mod+Ctrl+Shift+R steps through for windows stacked in a column"
		icon: "arrow_split_horizontal"
		modified: !!root.heightNode
		onReset: NiriSettings.reset(["layout", "preset-window-heights"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 24

			PresetRuler {
				Layout.fillWidth: true
				Layout.preferredHeight: 280
				vertical: true
				showDefault: false
				presets: root.heights
				logicalLength: root.logicalHeight
				onPresetsEdited: list => NiriSettings.setChildren(["layout", "preset-window-heights"], root.sizeNodes(list), "Window heights changed", "heights")
			}

			// a column whose top window steps through the heights
			Rectangle {
				id: stack

				property int step: 0
				readonly property var preset: root.heights.length > 0 ? root.heights[stack.step % root.heights.length] : null
				readonly property real share: !stack.preset ? 0.5 : (stack.preset.kind === "fixed" ? Math.min(1, stack.preset.value / root.logicalHeight) : stack.preset.value)

				Layout.preferredWidth: 150
				Layout.preferredHeight: 280
				radius: Theme.radius.medium
				color: Theme.layer2

				Timer {
					interval: 1400
					repeat: true
					running: root.active && root.heights.length > 0
					onTriggered: stack.step += 1
				}

				Rectangle {
					id: upper

					x: 8
					y: 8
					width: parent.width - 16
					height: Math.max(20, (parent.height - 24) * stack.share)
					radius: 6
					color: Qt.alpha(Theme.primary, 0.75)

					Behavior on height {
						SpatialAnim {
							duration: Motion.long
						}
					}

					StyledText {
						anchors.centerIn: parent
						text: stack.preset ? (stack.preset.kind === "fixed" ? `${Math.round(stack.preset.value)} px` : Nodes.fraction(stack.preset.value)) : ""
						tone: Theme.onPrimary
						font.weight: Font.Bold
					}
				}

				Rectangle {
					x: 8
					y: upper.y + upper.height + 8
					width: parent.width - 16
					height: Math.max(0, parent.height - y - 8)
					radius: 6
					color: Theme.layer3
				}
			}
		}
	}

	// ── new columns ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "columns"
		title: "New columns and workspaces"
		subtitle: "How a new column shows its windows, and where empty workspaces wait"
		icon: "view_column_outline"
		modified: NiriSettings.has(["layout", "default-column-display"]) || NiriSettings.has(["layout", "empty-workspace-above-first"])
		onReset: {
			NiriSettings.reset(["layout", "default-column-display"]);
			NiriSettings.reset(["layout", "empty-workspace-above-first"]);
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			OptionTile {
				id: normalTile

				title: "Stacked"
				subtitle: "Windows of a column share its height"
				selected: root.display === "normal"
				onClicked: NiriSettings.set(["layout", "default-column-display"], "normal", "New columns: stacked", "")

				Column {
					anchors.centerIn: parent
					spacing: 4

					Repeater {
						model: 3

						delegate: Rectangle {
							required property int index

							width: 64
							height: normalTile.playing ? 20 : 18
							radius: 4
							color: index === 0 ? Theme.primary : Theme.layer3

							Behavior on height {
								SpatialAnim {}
							}
						}
					}
				}
			}

			OptionTile {
				id: tabbedTile

				title: "Tabbed"
				subtitle: "One window shows, tabs beside it switch"
				selected: root.display === "tabbed"
				onClicked: NiriSettings.set(["layout", "default-column-display"], "tabbed", "New columns: tabbed", "")

				property int tab: 0

				Timer {
					interval: 900
					repeat: true
					running: tabbedTile.playing && root.active
					onTriggered: tabbedTile.tab = (tabbedTile.tab + 1) % 3
				}

				Row {
					anchors.centerIn: parent
					spacing: 4

					Column {
						spacing: 3

						Repeater {
							model: 3

							delegate: Rectangle {
								required property int index

								width: 4
								height: 20
								radius: 2
								color: index === tabbedTile.tab ? Theme.primary : Theme.layer3

								Behavior on color {
									ColorAnim {}
								}
							}
						}
					}

					Rectangle {
						width: 64
						height: 66
						radius: 5
						color: Qt.tint(Theme.layer3, Qt.alpha(Theme.primary, 0.12 + tabbedTile.tab * 0.12))

						Behavior on color {
							ColorAnim {}
						}
					}
				}
			}

			OptionTile {
				id: emptyTile

				title: "Empty workspace on top"
				subtitle: root.emptyAbove ? "On – one above the first as well" : "Off – only below the last"
				selected: root.emptyAbove
				onClicked: NiriSettings.setFlag(["layout", "empty-workspace-above-first"], !root.emptyAbove)

				Column {
					anchors.centerIn: parent
					spacing: 3

					Rectangle {
						width: 70
						height: root.emptyAbove ? 14 : 0
						radius: 3
						color: "transparent"
						border.width: 1.5
						border.color: Theme.primary
						opacity: root.emptyAbove ? 1 : 0

						Behavior on height {
							SpatialAnim {}
						}
						Behavior on opacity {
							Anim {}
						}
					}

					Repeater {
						model: 2

						delegate: Rectangle {
							width: 70
							height: 14
							radius: 3
							color: Theme.layer3
						}
					}

					Rectangle {
						width: 70
						height: 14
						radius: 3
						color: "transparent"
						border.width: 1.5
						border.color: Theme.textSubtle
					}
				}
			}
		}
	}

	readonly property bool emptyAbove: NiriSettings.flag(["layout", "empty-workspace-above-first"])

	// ── background ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "background"
		title: "Workspace background"
		subtitle: "What niri draws behind the windows – only seen where no wallpaper covers it"
		icon: "format_color_fill"
		modified: NiriSettings.has(["layout", "background-color"])
		onReset: NiriSettings.reset(["layout", "background-color"])

		HoverHandler {
			id: backgroundHover
		}

		ColorWell {
			value: String(NiriSettings.arg(["layout", "background-color"], "#262626"))
			allowTransparent: true
			onPicked: css => NiriSettings.set(["layout", "background-color"], css, "Background changed", "background")
		}
	}
}
